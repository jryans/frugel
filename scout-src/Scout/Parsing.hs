{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

module Scout.Parsing
    ( module Scout.Parsing
    , module Scout.Parsing.Error
    , module Scout.Parsing.Whitespace
    , module Scout.Lexing
    ) where

import Control.Monad.Combinators.Expr

import Data.Composition

import Optics.Extra.Scout

import Prelude                  hiding ( some )

import Scout.Lexing
import Scout.Node
import qualified Scout.Node     as Node
import Scout.Parsing.Error
import Scout.Parsing.Whitespace

import Text.Megaparsec          as Megaparsec hiding ( ParseError, many, some )

identifier :: Parser Identifier
identifier
    = Identifier .: (:|) <$> letter <*> many alphaNumChar <?> "an identifier"

node :: (IsNode a, NodeOf a ~ Node) => String -> Parser a
node name = namedToken name $ preview (_Right % nodePrism)

anyNode :: Parser Node
anyNode
    = choice [ WhereNode <$> whereClause
             , DeclNode <$> try decl
             , ExprNode <$> try expr
             ]

term :: Parser Expr
term
    = choice
        [ surroundOriginalWhitespace
          <$> (char '(' *%> fmap noWhitespace expr <*% char ')')
        , setWhitespace
          <$> choice
              [ Node.abstraction' <$% char '\\' <*%> identifier <*% char '='
                <*%> expr
                -- Non recursive production rules at the bottom
              , exprCstrSite' (CstrSite empty) <$% string "..."
              , literal'
                <$%> choice
                    [ Boolean
                      <$> (True <$ string "True" <|> False <$ string "False")
                    , Integer <$> decimal
                    ]
                <* notFollowedBy alphaNumChar
              , variable' <$%> identifier
              ]
        , node "an expression node"
        ]
  where
    surroundOriginalWhitespace
        (whitespaceFragments, e) = case whitespaceFragments of
        [rightFragment, leftFragment] -> e
            & exprMeta % #parenthesisLevels +~ 1
            & exprMeta % #standardMeta % #interstitialWhitespace
            %~ cons leftFragment . flip snoc rightFragment
        _ -> error
            $ toText ("Unexpected number of whitespace fragments: "
                      ++ show whitespaceFragments)

expr :: Parser Expr
expr
    = makeExprParser term
    $ [ [ InfixL (Application . setWhitespace
                  <$> try (defaultExprMeta 1 <<$> whitespace
                           <* notFollowedBy illegalTrailingApplicationTokens)) -- Ugly lookahead to fix problem of succeeding on whitespace between expression and +. Fixable by indentation sensitive parsing, but that requires a TraversableStream instance (or rebuilding the combinators)
        ]
      , [ binOpParser Or ] -- Todo: unary operations
      ]
    ++ (binOpParser <<$>> binaryOperatorPrecedence)
  where
    illegalTrailingApplicationTokens
        = choice
            [ ()
              <$ choice (map string
                         $ [ "where", ")" ]
                         ++ map binaryOperatorSymbol (concat binaryOperatorPrecedence))
            , () <$ node @WhereClause ""
            , () <$ (() <$% identifier <*% char '=')
            , () <$ node @Decl ""
            , eof
            ]
    binOpParser binOp
        = parserAssociativity
            (associativity binOp)
            (binaryOperation'' binOp . setWhitespace
             <$> try (defaultExprMeta 2 <$% pure ()
                      <*% string (binaryOperatorSymbol @String binOp)
                      <* notFollowedBy (char '=') <*% pure ()))

parserAssociativity
    :: Associativity -> Parser (a -> a -> a) -> Operator Parser a
parserAssociativity = \case
    LeftAssociative -> InfixL
    RightAssociative -> InfixR
    NotAssociative -> InfixN

decl :: Parser Decl
decl = setWhitespace <$> literalDecl <|> declNode
  where
    literalDecl = Node.decl' <$%> identifier <*% char '=' <*%> expr -- <*%> whereClause
    declNode = node "a declaration node"

whereClause :: Parser WhereClause
whereClause = whereNode <|> setWhitespace <$> literalWhere -- it's important that whereNode is tried first, because literalWhere succeeds on empty input
  where
    literalWhere = Node.whereClause' <<$>> (string "where" *%> wSome decl)
    whereNode = node "a where clause node"
