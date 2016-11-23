{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}

module Distribution.Types.ForeignLib(
    ForeignLib(..),
    emptyForeignLib,
    foreignLibModules,
    foreignLibIsShared,
) where

import Prelude ()
import Distribution.Compat.Prelude

import Distribution.ModuleName
import Distribution.Version

import Distribution.Types.BuildInfo
import Distribution.Types.ForeignLibType
import Distribution.Types.ForeignLibOption
import Distribution.Types.UnqualComponentName

-- | A foreign library stanza is like a library stanza, except that
-- the built code is intended for consumption by a non-Haskell client.
data ForeignLib = ForeignLib {
      -- | Name of the foreign library
      foreignLibName       :: UnqualComponentName
      -- | What kind of foreign library is this (static or dynamic).
    , foreignLibType       :: ForeignLibType
      -- | What options apply to this foreign library (e.g., are we
      -- merging in all foreign dependencies.)
    , foreignLibOptions    :: [ForeignLibOption]
      -- | Build information for this foreign library.
    , foreignLibBuildInfo  :: BuildInfo
      -- | Version information for unix style libraries.
    , foreignLibELFVersion :: Maybe Version

      -- | (Windows-specific) module definition files
      --
      -- This is a list rather than a maybe field so that we can flatten
      -- the condition trees (for instance, when creating an sdist)
    , foreignLibModDefFile :: [FilePath]
    }
    deriving (Generic, Show, Read, Eq, Typeable, Data)

instance Binary ForeignLib

instance Semigroup ForeignLib where
  a <> b = ForeignLib {
      foreignLibName       = combine'  foreignLibName
    , foreignLibType       = combine   foreignLibType
    , foreignLibOptions    = combine   foreignLibOptions
    , foreignLibBuildInfo  = combine   foreignLibBuildInfo
    , foreignLibELFVersion = combine'' foreignLibELFVersion
    , foreignLibModDefFile = combine   foreignLibModDefFile
    }
    where combine field = field a `mappend` field b
          combine' field = case ( unUnqualComponentName $ field a
                                , unUnqualComponentName $ field b) of
            ("", _) -> field b
            (_, "") -> field a
            (x, y) -> error $ "Ambiguous values for executable field: '"
                                  ++ x ++ "' and '" ++ y ++ "'"
          combine'' field = field b

instance Monoid ForeignLib where
  mempty = ForeignLib {
      foreignLibName       = mempty
    , foreignLibType       = ForeignLibTypeUnknown
    , foreignLibOptions    = []
    , foreignLibBuildInfo  = mempty
    , foreignLibELFVersion = Nothing
    , foreignLibModDefFile = []
    }
  mappend = (<>)

-- | An empty foreign library.
emptyForeignLib :: ForeignLib
emptyForeignLib = mempty

-- | Modules defined by a foreign library.
foreignLibModules :: ForeignLib -> [ModuleName]
foreignLibModules = otherModules . foreignLibBuildInfo

-- | Is the foreign library shared?
foreignLibIsShared :: ForeignLib -> Bool
foreignLibIsShared = foreignLibTypeIsShared . foreignLibType
