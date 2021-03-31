module Frugel.Model where

import           Frugel.Meta
import           Frugel.Program

data Model
    = Model { program :: Program, cursorOffset :: Integer, errors :: [String] }
    deriving ( Show, Eq )

initialModel :: Model
initialModel
    = Model { program      = ProgramCstrSite defaultProgramMeta $ fromList []
            , cursorOffset = 0
            , errors       = []
            }

fileName :: FilePath
fileName = "notepad"
