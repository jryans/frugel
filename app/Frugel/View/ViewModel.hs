{-# LANGUAGE LambdaCase #-}

{-# LANGUAGE TemplateHaskell #-}

module Frugel.View.ViewModel where

import           Frugel.PrettyPrinting

import           Optics

data HorizontalOpenness
    = HorizontalOpenness { openLeft :: Bool, openRight :: Bool }
    deriving ( Show, Eq )

data RenderAnnotation
    = CompletionAnnotation CompletionStatus HorizontalOpenness
    deriving ( Show, Eq )

data DocTextTree ann
    = TextLeaf Text | LineLeaf | Annotated ann [DocTextTree ann]
    deriving ( Show, Eq )

data AnnotationTree = Leaf Text | Node RenderAnnotation [AnnotationTree]

newtype Line = Line [AnnotationTree]

makePrisms ''DocTextTree

makePrisms ''Line

singleLineOpenness, firstLineOpenness, middleLinesOpenness, lastLineOpenness
    :: HorizontalOpenness
singleLineOpenness = HorizontalOpenness { openLeft = False, openRight = False }

firstLineOpenness = HorizontalOpenness { openLeft = False, openRight = True }

middleLinesOpenness = HorizontalOpenness { openLeft = True, openRight = True }

lastLineOpenness = HorizontalOpenness { openLeft = True, openRight = False }

isEmptyTree :: DocTextTree ann -> Bool
isEmptyTree = \case
    TextLeaf "" -> True
    Annotated _ [] -> True
    Annotated _ trees -> all isEmptyTree trees
    _ -> False
