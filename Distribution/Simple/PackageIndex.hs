-----------------------------------------------------------------------------
-- |
-- Module      :  Distribution.Simple.PackageIndex
-- Copyright   :  (c) David Himmelstrup 2005,
--                    Bjorn Bringert 2007,
--                    Duncan Coutts 2008
-- License     :  BSD-like
--
-- Maintainer  :  Duncan Coutts <duncan@haskell.org>
-- Stability   :  provisional
-- Portability :  portable
--
-- An index of packages.
-----------------------------------------------------------------------------
module Distribution.Simple.PackageIndex (
  -- * Package index data type
  PackageIndex,

  -- * Creating an index
  fromList,

  -- * Updates
  merge,
  insert,
  delete,

  -- * Queries

  -- ** Precise lookups
  lookupPackageId,
  lookupDependency,

  -- ** Case-insensitive searches
  searchByName,
  SearchResult(..),
  searchByNameSubstring,

  -- ** Bulk queries
  allPackages,
  allPackagesByName,

  -- ** Special queries
  brokenPackages,
  dependencyClosure,
  reverseDependencyClosure,
  dependencyInconsistencies,
  dependencyCycles,
  dependencyGraph,
  ) where

import Prelude hiding (lookup)
import Control.Exception (assert)
import qualified Data.Map as Map
import Data.Map (Map)
import qualified Data.Tree  as Tree
import qualified Data.Graph as Graph
import qualified Data.Array as Array
import Data.Array ((!))
import Data.List (nubBy, group, sort, groupBy, sortBy, find)
import Data.Monoid (Monoid(..))
import Data.Maybe (isNothing, fromMaybe)

import Distribution.Package
         ( PackageIdentifier, Package(..), packageName, packageVersion
         , Dependency(Dependency), PackageFixedDeps(..) )
import Distribution.Version
         ( Version, withinRange )
import Distribution.Simple.Utils (lowercase, equating, comparing, isInfixOf)

#if defined(__GLASGOW_HASKELL__) && (__GLASGOW_HASKELL__ < 606)
import Text.Read
import qualified Text.Read.Lex as L
#endif

-- | The collection of information about packages from one or more 'PackageDB's.
--
-- It can be searched effeciently by package name and version.
--
data Package pkg => PackageIndex pkg = PackageIndex
  -- This index maps lower case package names to all the
  -- 'InstalledPackageInfo' records matching that package name
  -- case-insensitively. It includes all versions.
  --
  -- This allows us to do case sensitive or insensitive lookups, and to find
  -- all versions satisfying a dependency, all by varying how we filter. So
  -- most queries will do a map lookup followed by a linear scan of the bucket.
  --
  (Map String [pkg])

#if !defined(__GLASGOW_HASKELL__) || (__GLASGOW_HASKELL__ >= 606)
  deriving (Show, Read)
#else
instance (Package pkg, Show pkg) => Show (PackageIndex pkg) where
  showsPrec d (PackageIndex m) =
      showParen (d > 10) (showString "PackageIndex" . shows (Map.toList m))

instance (Package pkg, Read pkg) => Read (PackageIndex pkg) where
  readPrec = parens $ prec 10 $ do
    Ident "PackageIndex" <- lexP
    xs <- readPrec
    return (PackageIndex (Map.fromList xs))
      where parens :: ReadPrec a -> ReadPrec a
            parens p = optional
             where
               optional  = p +++ mandatory
               mandatory = paren optional

            paren :: ReadPrec a -> ReadPrec a
            paren p = do L.Punc "(" <- lexP
                         x          <- reset p
                         L.Punc ")" <- lexP
                         return x

  readListPrec = readListPrecDefault
#endif

instance Package pkg => Monoid (PackageIndex pkg) where
  mempty  = PackageIndex (Map.empty)
  mappend = merge
  --save one mappend with empty in the common case:
  mconcat [] = mempty
  mconcat xs = foldr1 mappend xs

invariant :: Package pkg => PackageIndex pkg -> Bool
invariant (PackageIndex m) = all (uncurry goodBucket) (Map.toList m)
  where goodBucket name pkgs =
             lowercase name == name
          && not (null pkgs)
          && all ((lowercase name==) . lowercase . packageName) pkgs
--          && all (\pkg -> pkgInfoId pkg
--                       == (packageId . packageDescription . pkgDesc) pkg) pkgs
          && distinct (map packageId pkgs)

        distinct = all ((==1). length) . group . sort

internalError :: String -> a
internalError name = error ("PackageIndex." ++ name ++ ": internal error")

-- | When building or merging we have to eliminate duplicates of the exact
-- same package name and version (case-sensitively) to preserve the invariant.
--
stripDups :: Package pkg => [pkg] -> [pkg]
stripDups = nubBy (equating packageId)

-- | Lookup a name in the index to get all packages that match that name
-- case-insensitively.
--
lookup :: Package pkg => PackageIndex pkg -> String -> [pkg]
lookup index@(PackageIndex m) name =
  assert (invariant index) $
  case Map.lookup (lowercase name) m of
    Nothing   -> []
    Just pkgs -> pkgs

-- | Build an index out of a bunch of 'Package's.
--
-- If there are duplicates, earlier ones mask later one.
--
fromList :: Package pkg => [pkg] -> PackageIndex pkg
fromList pkgs =
  let index = (PackageIndex . Map.map stripDups . Map.fromListWith (++))
                [ let key = (lowercase . packageName) pkg
                   in (key, [pkg])
                | pkg <- pkgs ]
   in assert (invariant index) index

-- | Merge two indexes.
--
-- Packages from the second mask packages of the same exact name
-- (case-sensitively) from the first.
--
merge :: Package pkg => PackageIndex pkg -> PackageIndex pkg -> PackageIndex pkg
merge i1@(PackageIndex m1) i2@(PackageIndex m2) =
  assert (invariant i1 && invariant i2) $
  let index = PackageIndex (Map.unionWith mergeBuckets m1 m2)
   in assert (invariant index) index

-- | Elements in the second list mask those in the first.
mergeBuckets :: Package pkg => [pkg] -> [pkg] -> [pkg]
mergeBuckets pkgs1 pkgs2 = stripDups (pkgs2 ++ pkgs1)

-- | Inserts a single package into the index.
--
-- This is equivalent to (but slightly quicker than) using 'mappend' or
-- 'merge' with a singleton index.
--
insert :: Package pkg => pkg -> PackageIndex pkg -> PackageIndex pkg
insert pkg (PackageIndex index) = PackageIndex $
  let key = (lowercase . packageName) pkg
   in Map.insertWith (flip mergeBuckets) key [pkg] index

-- | Removes a single package from the index.
--
delete :: Package pkg => PackageIdentifier -> PackageIndex pkg -> PackageIndex pkg
delete pkgid (PackageIndex index) = PackageIndex $
  let key = (lowercase . packageName) pkgid
   in Map.update filterBucket key index
  where
    filterBucket = deleteEmptyBucket
                 . filter (\pkg -> packageId pkg /= pkgid)
    deleteEmptyBucket []        = Nothing
    deleteEmptyBucket remaining = Just remaining

-- | Get all the packages from the index.
--
allPackages :: Package pkg => PackageIndex pkg -> [pkg]
allPackages (PackageIndex m) = concat (Map.elems m)

-- | Get all the packages from the index.
--
-- They are grouped by package name, case-sensitively.
--
allPackagesByName :: Package pkg => PackageIndex pkg -> [[pkg]]
allPackagesByName (PackageIndex m) = concatMap groupByName (Map.elems m)
  where groupByName :: Package pkg => [pkg] -> [[pkg]]
        groupByName = groupBy (equating packageName)
                    . sortBy (comparing packageName)

-- | Does a case-insensitive search by package name.
--
-- If there is only one package that compares case-insentiviely to this name
-- then the search is unambiguous and we get back all versions of that package.
-- If several match case-insentiviely but one matches exactly then it is also
-- unambiguous.
--
-- If however several match case-insentiviely and none match exactly then we
-- have an ambiguous result, and we get back all the versions of all the
-- packages. The list of ambiguous results is split by exact package name. So
-- it is a non-empty list of non-empty lists.
--
searchByName :: Package pkg => PackageIndex pkg -> String -> SearchResult [pkg]
searchByName index name =
  case groupBy (equating  packageName)
     . sortBy  (comparing packageName)
     $ lookup index name of
    []     -> None
    [pkgs] -> Unambiguous pkgs
    pkgss  -> case find ((name==) . packageName . head) pkgss of
                Just pkgs -> Unambiguous pkgs
                Nothing   -> Ambiguous   pkgss

data SearchResult a = None | Unambiguous a | Ambiguous [a]

-- | Does a case-insensitive substring search by package name.
--
-- That is, all packages that contain the given string in their name.
--
searchByNameSubstring :: Package pkg => PackageIndex pkg -> String -> [pkg]
searchByNameSubstring (PackageIndex m) searchterm =
  [ pkg
  | (name, pkgs) <- Map.toList m
  , searchterm' `isInfixOf` name
  , pkg <- pkgs ]
  where searchterm' = lowercase searchterm

-- | Does a lookup by package id (name & version).
--
-- Since multiple package DBs mask each other case-sensitively by package name,
-- then we get back at most one package.
--
lookupPackageId :: Package pkg => PackageIndex pkg -> PackageIdentifier -> Maybe pkg
lookupPackageId index pkgid =
  case [ pkg | pkg <- lookup index (packageName pkgid)
             , packageId pkg == pkgid ] of
    []    -> Nothing
    [pkg] -> Just pkg
    _     -> internalError "lookupPackageIdentifier"

-- | Does a case-sensitive search by package name and a range of versions.
--
-- We get back any number of versions of the specified package name, all
-- satisfying the version range constraint.
--
lookupDependency :: Package pkg => PackageIndex pkg -> Dependency -> [pkg]
lookupDependency index (Dependency name versionRange) =
  [ pkg | pkg <- lookup index name
        , packageName pkg == name
        , packageVersion pkg `withinRange` versionRange ]

-- | All packages that have dependencies that are not in the index.
--
-- Returns such packages along with the dependencies that they're missing.
--
brokenPackages :: PackageFixedDeps pkg
               => PackageIndex pkg
               -> [(pkg, [PackageIdentifier])]
brokenPackages index =
  [ (pkg, missing)
  | pkg  <- allPackages index
  , let missing = [ pkg' | pkg' <- depends pkg
                         , isNothing (lookupPackageId index pkg') ]
  , not (null missing) ]

-- | Tries to take the transative closure of the package dependencies.
--
-- If the transative closure is complete then it returns that subset of the
-- index. Otherwise it returns the broken packages as in 'brokenPackages'.
--
-- * Note that if the result is @Right []@ it is because at least one of
-- the original given 'PackageIdentifier's do not occur in the index.
--
dependencyClosure :: PackageFixedDeps pkg
                  => PackageIndex pkg
                  -> [PackageIdentifier]
                  -> Either (PackageIndex pkg)
                            [(pkg, [PackageIdentifier])]
dependencyClosure index pkgids0 = case closure mempty [] pkgids0 of
  (completed, []) -> Left completed
  (completed, _)  -> Right (brokenPackages completed)
  where
    closure completed failed []             = (completed, failed)
    closure completed failed (pkgid:pkgids) = case lookupPackageId index pkgid of
      Nothing   -> closure completed (pkgid:failed) pkgids
      Just pkg  -> case lookupPackageId completed (packageId pkg) of
        Just _  -> closure completed  failed pkgids
        Nothing -> closure completed' failed pkgids'
          where completed' = insert pkg completed
                pkgids'    = depends pkg ++ pkgids

-- | Takes the transative closure of the packages reverse dependencies.
--
-- * The given 'PackageIdentifier's must be in the index.
--
reverseDependencyClosure :: PackageFixedDeps pkg
                         => PackageIndex pkg
                         -> [PackageIdentifier]
                         -> [PackageIdentifier]
reverseDependencyClosure index =
    map vertexToPkgId
  . concatMap Tree.flatten
  . Graph.dfs reverseDepGraph
  . map (fromMaybe noSuchPkgId . pkgIdToVertex)

  where
    (depGraph, vertexToPkgId, pkgIdToVertex) = dependencyGraph index
    reverseDepGraph = Graph.transposeG depGraph
    noSuchPkgId = error "reverseDependencyClosure: package is not in the graph"

-- | Given a package index where we assume we want to use all the packages
-- (use 'dependencyClosure' if you need to get such a index subset) find out
-- if the dependencies within it use consistent versions of each package.
-- Return all cases where multiple packages depend on different versions of
-- some other package.
--
-- Each element in the result is a package name along with the packages that
-- depend on it and the versions they require. These are guaranteed to be
-- distinct.
--
dependencyInconsistencies :: PackageFixedDeps pkg
                          => PackageIndex pkg
                          -> [(String, [(PackageIdentifier, Version)])]
dependencyInconsistencies index =
  [ (name, inconsistencies)
  | (name, uses) <- Map.toList inverseIndex
  , let inconsistencies = duplicatesBy uses
  , not (null inconsistencies) ]

  where inverseIndex = Map.fromListWith (++)
          [ (packageName dep, [(packageId pkg, packageVersion dep)])
          | pkg <- allPackages index
          , dep <- depends pkg ]

        duplicatesBy = (\groups -> if length groups == 1
                                     then []
                                     else concat groups)
                     . groupBy (equating snd)
                     . sortBy (comparing snd)

-- | Find if there are any cycles in the dependency graph. If there are no
-- cycles the result is @[]@.
--
-- This actually computes the strongly connected components. So it gives us a
-- list of groups of packages where within each group they all depend on each
-- other, directly or indirectly.
--
dependencyCycles :: PackageFixedDeps pkg
                 => PackageIndex pkg
                 -> [[pkg]]
dependencyCycles index =
  [ vs | Graph.CyclicSCC vs <- Graph.stronglyConnComp adjacencyList ]
  where
    adjacencyList = [ (pkg, packageId pkg, depends pkg)
                    | pkg <- allPackages index ]

-- | Builds a graph of the package dependencies.
--
-- Dependencies on other packages that are in the index are discarded.
-- You can check if there are any such dependencies with 'brokenPackages'.
--
dependencyGraph :: PackageFixedDeps pkg
                => PackageIndex pkg
                -> (Graph.Graph,
                    Graph.Vertex -> PackageIdentifier,
                    PackageIdentifier -> Maybe Graph.Vertex)
dependencyGraph index = (graph, vertexToPkgId, pkgIdToVertex)
  where
    graph = Array.listArray bounds
              [ [ v | Just v <- map pkgIdToVertex (depends pkg) ]
              | pkg <- pkgs ]
    vertexToPkgId vertex = pkgIdTable ! vertex
    pkgIdToVertex = binarySearch 0 topBound

    pkgIdTable = Array.listArray bounds (map packageId pkgs)
    pkgs = sortBy (comparing packageId) (allPackages index)
    topBound = length pkgs - 1
    bounds = (0, topBound)

    binarySearch a b key
      | a > b     = Nothing
      | otherwise = case compare key (pkgIdTable ! mid) of
          LT -> binarySearch a (mid-1) key
          EQ -> Just mid
          GT -> binarySearch (mid+1) b key
      where mid = (a + b) `div` 2
