{-# LANGUAGE DataKinds #-}

{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}

{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

module Frugel.Internal.Program where

import           Data.Has

import           Frugel.Internal.Meta ( ProgramMeta(standardMeta) )
import           Frugel.Node

import           Optics

data Program
    = Program { meta        :: ProgramMeta
              , expr        :: Expr
              , whereClause :: Maybe WhereClause
              }
    | ProgramCstrSite ProgramMeta CstrSite
    deriving ( Show, Eq, Generic, Has ProgramMeta )

makeFieldLabelsWith noPrefixFieldLabels ''Program

instance Has Meta Program where
    getter p = standardMeta $ getter p
    modifier = over (programMeta % #standardMeta)

programMeta :: Lens' Program ProgramMeta
programMeta = hasLens

instance Refracts' A_Getter NoIx CstrSite Program where
    optic' = to $ ProgramCstrSite defaultProgramMeta
