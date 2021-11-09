{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeApplications #-}

module Main where

import Control.Concurrent
import Control.ValidEnumerable

import qualified Data.Sequence          as Seq
import Data.Sized

import Frugel
    hiding ( Model, initialModel, updateModel )
import qualified Frugel
import Frugel.View

import Language.Javascript.JSaddle.Warp.Extra as JSaddleWarp

import Miso                             hiding ( model, node, set, view )
import qualified Miso

import Optics.Extra.Scout

import Scout
import Scout.Action
import qualified Scout.Internal.Model
import Scout.Model

import Test.QuickCheck.Gen

-- Entry point for a miso application
main :: IO ()
main = runApp $ do
    evalThreadVar <- liftIO $ newMVar Nothing
    startApp
        App { initialAction = Init  -- initial action to be executed on application load
            , model = initialModel $ programCstrSite' evalTest  -- initial model
            , update = updateModel evalThreadVar -- update function
            , view = viewModel -- view function
            , events = defaultEvents -- default delegated events
            , subs = [] -- empty subscription list
            , mountPoint = Nothing -- mount point for application (Nothing defaults to 'body')
            , logLevel = Off -- used during prerendering to see if the VDOM and DOM are in synch (only used with `miso` function)
            }

updateModel :: MVar (Maybe (ThreadId, Integer))
    -> Action
    -> Model
    -> Effect Action Model
updateModel evalThreadVar action model'
    = either id (effectSub model') $ updateModel' action model'
  where
    updateModel' Init model = Right $ \sink -> do
        focus "code-root"
        liftIO
            $ reEvaluate evalThreadVar
                         (toFrugelModel model)
                         (model & #editableDataVersion -~ 1)
                         sink
    updateModel' GenerateRandom model = Right $ \sink -> liftIO $ do
        newProgram <- unSized @500 <.> generate $ uniformValid 500
        let newFrugelModel
                = set #cursorOffset 0
                . snd
                . attemptEdit (const $ Right newProgram) -- reparse the new program for parse errors
                $ toFrugelModel model
        sink . AsyncAction $ NewProgramGenerated newFrugelModel
        reEvaluate evalThreadVar newFrugelModel model sink
    updateModel' (Log msg) _ = Right . const . consoleLog $ show msg
    updateModel' (FocusedNodeValueIndexAction indexAction) model
        = Left . effectSub (hideSelectedNodeValue newModel) $ \sink -> liftIO
        . bracketNonTermination (view #editableDataVersion newModel)
                                evalThreadVar
        . unsafeEvaluateSelectedNodeValue sink
        $ #partiallyEvaluated .~ False
        $ newModel
      where
        newModel
            = model
            & #editableDataVersion +~ 1
            & #focusedNodeValueIndex %~ case indexAction of
                Increment -> min (focusNodeValuesCount - 1) . succ
                Decrement -> max 0 . pred . min (focusNodeValuesCount - 1)
        focusNodeValuesCount
            = Seq.length $ view (#evaluationOutput % #focusedNodeValues) model
    updateModel' (ChangeSelectedNodeValueRenderDepth newDepth) model
        = Left
        . effectSub (hideSelectedNodeValue newModel & #editableDataVersion +~ 1)
        $ \sink -> liftIO
        . bracketNonTermination (view #editableDataVersion model + 1)
                                evalThreadVar
        $ do
            reEvaluatedModel <- fromFrugelModel newModel (toFrugelModel model)
            unsafeEvaluateSelectedNodeValue sink reEvaluatedModel
      where
        newModel
            = model
            & #partiallyEvaluated .~ True
            & #selectedNodeValueRenderDepth .~ newDepth
    updateModel' (ChangeFuelLimit newLimit) model
        = Left . reEvaluateModel evalThreadVar
        $ #fuelLimit .~ max 0 newLimit
        $ model
    -- reEvaluate to type error locations
    updateModel' PrettyPrint model
        = Left
        $ reEvaluateFrugelModel evalThreadVar
                                (prettyPrint $ toFrugelModel model)
                                model
    -- Move action also causes reEvaluation, because value of expression under the cursor may need to be updated
    updateModel' (GenericAction genericAction)
                 model = Left $ case editResult of
        Success -> reEvaluateFrugelModel evalThreadVar newFrugelModel model
        Failure -> noEff
            $ updateWithFrugelErrors (view #errors newFrugelModel) model
      where
        (editResult, newFrugelModel)
            = Frugel.updateModel genericAction $ toFrugelModel model
    updateModel' (AsyncAction asyncAction) model
        = if view #editableDataVersion newModel
              == view #editableDataVersion model
          then Left $ noEff newModel
          else Right . const $ pure ()
      where
        newModel = case asyncAction of
            EvaluationFinished m -> m
            NewProgramGenerated frugelModel ->
                updateWithFrugelModel frugelModel model

reEvaluateModel
    :: MVar (Maybe (ThreadId, Integer)) -> Model -> Effect Action Model
reEvaluateModel evalThreadVar model
    = reEvaluateFrugelModel evalThreadVar (toFrugelModel model) model

reEvaluateFrugelModel :: MVar (Maybe (ThreadId, Integer))
    -> Frugel.Model Program
    -> Model
    -> Effect Action Model
reEvaluateFrugelModel evalThreadVar frugelModel model
    = effectSub (updateWithFrugelModel frugelModel model) . (liftIO .)
    $ reEvaluate evalThreadVar frugelModel model

reEvaluate :: MVar (Maybe (ThreadId, Integer))
    -> Frugel.Model Program
    -> Model
    -> Sink Action
    -> IO ()
reEvaluate evalThreadVar newFrugelModel model@Model{fuelLimit} sink = do
    partialModel@Model{editableDataVersion}
        <- partialFromFrugelModel (Only fuelLimit) model newFrugelModel
    -- safe because evaluation had fuel limit
    unsafeEvaluateTopExpression sink partialModel
    bracketNonTermination (succ editableDataVersion) evalThreadVar $ do
        newModel <- fromFrugelModel model newFrugelModel
        -- sadly, it seems the models from the next to statements are not necessarily displayed in order
        -- safe because inside bracketNonTermination
        unsafeEvaluateTopExpression sink $ hideSelectedNodeValue newModel
        -- force selected node value separately because evaluation up to a certain depth may encounter non-terminating expressions that were not evaluated in the evaluation of the top expression
        unsafeEvaluateSelectedNodeValue sink newModel

bracketNonTermination
    :: Integer -> MVar (Maybe (ThreadId, Integer)) -> IO () -> IO ()
bracketNonTermination version evalThreadVar action = do
    threadId <- myThreadId
    outdated <- modifyMVar evalThreadVar $ \v -> case v of
        Just (runningId, runningVersion)
            | version > runningVersion ->
                (Just (threadId, version), False) <$ killThread runningId
        Just _ -> pure (v, True)
        Nothing -> pure (Just (threadId, version), False)
    unless outdated $ do
        u <- action
        void $ swapMVar evalThreadVar $ seq u Nothing

-- force errors to force full evaluation
unsafeEvaluateTopExpression :: Sink Action -> Model -> IO ()
unsafeEvaluateTopExpression sink model@Model{..}
    = seq (length errors) . sink . AsyncAction $ EvaluationFinished model

unsafeEvaluateSelectedNodeValue :: Sink Action -> Model -> IO ()
unsafeEvaluateSelectedNodeValue sink model@Model{..}
    = seq (lengthOf (#selectedNodeValue
                     % to (capTree selectedNodeValueRenderDepth)
                     % allEvaluatedChildren)
                    model)
    . sink
    . AsyncAction
    $ EvaluationFinished model
