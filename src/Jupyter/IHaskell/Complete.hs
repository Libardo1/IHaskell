{-|
Module      : Jupyter.IHaskell.Complete
Description : Autocompletion for IHaskell 
Copyright   : (c) Andrew Gibiansky, 2016
License     : MIT
Maintainer  : andrew.gibiansky@gmail.com
Stability   : stable
Portability : POSIX

This module provides autocompletion functionality for IHaskell. The exported interface
is purposefully kept extremely simple: the 'complete' function returns a list of completions
for any given piece of text.
-}

{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE OverloadedStrings #-}

module Jupyter.IHaskell.Complete (Completion(..), complete) where

-- Imports from 'base'
import           Control.Arrow ((>>>))
import           Control.Exception (SomeException)
import           Data.Char (isSymbol)
import           Data.IORef (readIORef)
import           Data.List (sortOn, partition, nub)
import           Data.Monoid ((<>))
import           System.Environment (getEnvironment)

-- Imports from 'extra'
import           Control.Monad.Extra (partitionM)

-- Imports from 'directory'
import           System.Directory (getDirectoryContents, doesDirectoryExist)

-- Imports from 'transformers'
import           Control.Monad.IO.Class (MonadIO(liftIO))

-- Imports from 'text'
import           Data.Text (Text)
import qualified Data.Text as T

-- Imports from 'ghc'
import           Avail (availNames)
import           DynFlags (DynFlags(pkgDatabase), xFlags, flagSpecName, fLangFlags, fFlags,
                           fWarningFlags)
import           Exception (ghandle)
import           GHC (moduleNameString, moduleName, getSessionDynFlags, InteractiveImport(IIDecl),
                      simpleImportDecl, getContext, setContext, mkModuleName, gbracket)
import           GhcMonad (withSession)
import           HscTypes (hsc_EPS, eps_PIT, mi_exports)
import           Module (moduleEnvToList, moduleEnvElts)
import           Name (nameOccName)
import           OccName (occNameString)
import           PackageConfig (PackageConfig, InstalledPackageInfo(exposed), exposedModules)

-- Imports from 'bin-package-db'
import           GHC.PackageDb (ExposedModule(exposedName))

-- Imports from 'ihaskell'
import           Jupyter.IHaskell.Interpreter (Interpreter, ghc)

-- | An autocompletion result.
data Completion =
       Completion
         { completionContext :: Int -- ^ How many characters before the cursor to replace with the
                                    -- autocompletion result.
         , completionText :: Text   -- ^ The text of the autocompletion result.
         }
  deriving (Eq, Ord, Show)

-- | Generate completions at the end of a given block of text. If this function were used to
-- generate completions within an IDE, the passed in text would be all the content preceeding the
-- cursor.
complete :: Text -- ^ Text preceeding the cursor to base completions off of.
         -> Interpreter [Completion]
complete text =
  -- Take only the last line for context. If there's no content, offer no completions.
  if text == ""
    then return []
    else completeLine $ T.strip $ last $ T.lines text

-- | Generate completions, assuming that the input is only one line of text. Completions are
-- generated as if the cursor is at the end of the line.
completeLine :: Text -- ^ A single line of text.
             -> Interpreter [Completion]
completeLine text
  -- For shell commands, complete filenames only.
  | T.isPrefixOf ":!" text = completeFile text

  -- For load commands, complete Haskell filenames only.
  | T.isPrefixOf ":l" text = completeSourceFile text

  -- For :set commands, complete dyn flags.
  | T.isPrefixOf ":s" text = completeFlag text

  -- When inside a string literal, complete filenames.
  | insideString text = completeFile text

  -- For imports, complete module names or identifiers in modules.
  | T.isPrefixOf "import" text = completeImport text

  -- In most contexts, complete in-scope identifiers.
  | otherwise =
      case T.splitOn "." (lastToken text) of
        [identifier] -> completeIdentifier identifier
        names        -> completeQualified names

-- | Check whether the end of the text is ostensibly inside a string literal, handling an escaped
-- double quote properly.
--
-- >>> insideString "Hello" == False
-- >>> insideString "He \"llo" == True
-- >>> insideString "He \"ll \" o" == False
-- >>> insideString "He \"ll\\\"" == True
insideString :: Text -> Bool
insideString text =
  case T.breakOn "\"" text of
    (_, "") -> False
    ("", after) -> not $ insideString $ T.tail after
    (before, after) ->
      case T.last before of
        '\\' -> insideString $ T.tail after
        _    -> not $ insideString $ T.tail after

-- | Generate completions given an import line. There are several types of completions generated on
-- import lines:
--
--    1. Keyword completion: Autocomplete "qualified" if the user types "qu" or more.
--    2. Module name completion: Autocomplete "Data.Monoid" if the user types "Data.Mo" or more.
--    3. Module prefix completion: Autocomplete "Data." if the user types "Dat" or more.
--    4. Identifier completion: Autocomplete "mempty" if the user types "import Data.Monoid (me".
--
-- Module prefix completion should be prioritized used when there are no good module name
-- completions, where a good module name completion is one that does not require adding any periods.
completeImport :: Text -> Interpreter [Completion]
completeImport text
  | T.isPrefixOf "qu" token =
      ghc $ mkCompletions token ["qualified"]

  | otherwise =
      case T.breakOn "(" text of
        (_, "") -> completeModule (extractModuleName text)
        (before, after) ->
          case T.breakOn ")" after of
            (importList, "") -> completeIdentifierFromModule (extractModuleName before) $ lastToken importList
            _ -> return []
  where
    token = lastToken text
    extractModuleName = lastToken . T.strip

-- | Complete module names and prefixes.
--
-- (See 'completeImport' for more info on import completions.)
completeModule :: Text -- ^ The prefix of the module, e.g. @System.Env@.
               -> Interpreter [Completion]
completeModule name = do
  flags <- ghc getSessionDynFlags
  case pkgDatabase flags of
    Nothing -> return []
    Just pkgConfigs -> do
      -- Treat "good" and "bad" completions separately. See 'completeImport' for more info.
      let packageCandidates = filter (T.isPrefixOf name) . nub . concatMap getModuleNames
          candidates = packageCandidates . filter exposed $ pkgConfigs
          (good, bad) = partition goodCompletion candidates
          top =
            case good of
              [] -> sortOn T.length . nub . map mkPrefixCompletion $ bad
              _  -> sortOn T.length good
          bottom = sortOn T.length bad
      mkCompletions name (top ++ bottom)

  where
    getModuleNames :: PackageConfig -> [Text]
    getModuleNames = map (T.pack . moduleNameString . exposedName) . exposedModules

    goodCompletion :: Text -> Bool
    goodCompletion candidate = T.count "." candidate == T.count "." name

    mkPrefixCompletion :: Text -> Text
    mkPrefixCompletion =
      -- Divide a module name into the constituent directory names.
      T.splitOn "." >>>
      -- Take as many of them as there are in our query.
      take (T.count "." name + 1) >>>
      -- Put the names back together with a "." separator.
      T.intercalate "." >>>
      -- Add another separator, since we'll need one!
      flip T.append "."

-- | Complete an identifier in an import list by looking up the list of identifier in the module for
-- which this import list is for and autocompleting based on those identifiers.
completeIdentifierFromModule :: Text -- ^ Module name being imported from
                             -> Text -- ^ Prefix of the identifier being imported
                             -> Interpreter [Completion]
completeIdentifierFromModule name token = ghc $ withSession $ \env ->
  -- Ensure that we don't lose our old context; reset it after we're done.
  gbracket getContext setContext $ const $
    -- An exception will be thrown if we can't load the module; return an empty completion list.
    ghandle returnNothing $ do
      -- Ensure we have the module we're completing from loaded.
      setContext [IIDecl $ simpleImportDecl $ mkModuleName $ T.unpack name]

      -- Once the module we're completing from is loaded, all of the information should be available to
      -- us. Module interfaces are stored in the EPS (ExternalPackageState), which contains the PIT
      -- (package interface table), which contains a bunch of MIs (module interfaces). Module interfaces
      -- have a list of associated exported names, which we use for completion.
      pkgState <- liftIO $ readIORef (hsc_EPS env)
      let pkgIfaceTable = eps_PIT pkgState
          ifaces = map snd $ filter (namedModule . fst) $ moduleEnvToList pkgIfaceTable
          exports = concatMap availNames $ concatMap mi_exports ifaces
          exportNames = filter (T.isPrefixOf token) $
            map (T.pack . occNameString . nameOccName) exports
      mkCompletions token $ sortOn T.length exportNames
  where
    namedModule = (== name) . T.pack . moduleNameString . moduleName

    -- If we cannot load the module into the current context, return an empty completion list.
    returnNothing :: Monad m => SomeException -> m [a]
    returnNothing _ = return []

-- | Complete known flags, such as -XExtensions. This is intended to complete only flags supported
-- by IHaskell, but also *all* flags supported by IHaskell.
completeFlag :: Text  -- ^ Line of text to complete.
             -> Interpreter [Completion]
completeFlag text =
  -- Collect string representations of all flags by looking in the DynFlags module and then looking
  -- for flags matching the requested prefix.
  mkCompletions token $ filter (T.isPrefixOf token) $ map T.pack allNames
  where
    token = lastWord text
    otherNames = ["-package", "-Wall", "-w"]

    -- Possibly leave out the fLangFlags? The -XUndecidableInstances vs. obsolete
    -- -fallow-undecidable-instances.
    fNames = concat
               [ map flagSpecName fFlags
               , map flagSpecName fWarningFlags
               , map flagSpecName fLangFlags
               ]
    fNoNames = map ("no" ++) fNames
    fAllNames = map ("-f" ++) (fNames ++ fNoNames)

    xNames = map flagSpecName xFlags
    xNoNames = map ("No" ++) xNames
    xAllNames = map ("-X" ++) (xNames ++ xNoNames)

    allNames = concat [xAllNames, otherNames, fAllNames]

-- | Complete in-scope identifiers. These are identifiers that have been loaded into scope with
-- evaluated import statements or are in implicit imports (like Prelude).
completeIdentifier :: Text -- ^ Line of text to complete.
                   -> Interpreter [Completion]
completeIdentifier token = ghc $ withSession $ \env -> do
  -- Module interfaces are stored in the EPS (ExternalPackageState), which contains the PIT
  -- (package interface table), which contains a bunch of MIs (module interfaces). Module interfaces
  -- have a list of associated exported names, which we use for completion.
  pkgState <- liftIO $ readIORef (hsc_EPS env)
  let pkgIfaceTable = eps_PIT pkgState
      exports = concatMap availNames $ concatMap mi_exports $ moduleEnvElts pkgIfaceTable
      exportNames = filter (T.isPrefixOf token) $ map (T.pack . occNameString . nameOccName) exports
  mkCompletions token $ sortOn T.length exportNames

-- | Complete qualified names. For example, @Data.List.interc@ will be completed to
-- @Data.List.intercalate@.
--
-- The input should have at least two elements, which are separated by ".". The last element
-- is allowed to be an empty string.
completeQualified :: [Text] -- ^ Pieces of the last token which are separated by ".".
                  -> Interpreter [Completion]
completeQualified names =
  -- For a qualified name, we need at least Module.identifierPrefix. If we have less than that, we can
  -- offer no completions; this function shouldn't even be called.
  if length names < 2
    then return []
    else do
      -- The completion can either be a module (@Data.Li@ completing to @Data.List@) or an identifier
      -- (@Data.List.inter@ completing to @Data.List.intercalate@).
      let modname = T.intercalate "." $ init names
          identifier = last names
      idents <- completeIdentifierFromModule modname identifier
      modules <- completeModule $ T.intercalate "." names
      return $ idents ++ modules

-- | Complete directory and file names.
completeFile :: Text -- ^ Line of text to complete.
             -> Interpreter [Completion]
completeFile = completeFileWithFilter (const True)

-- | Complete directory and Haskell source names.
completeSourceFile :: Text -- ^ Line of text to complete.
                   -> Interpreter [Completion]
completeSourceFile = completeFileWithFilter ((||) <$> T.isSuffixOf ".hs" <*> T.isSuffixOf ".lhs")

-- | Complete directory and file names, with a filter applied to the files before they are suggested
-- as completions.
--
-- This completion generator only goes one level deep and does not recurse into subdirectories to
-- generate completions. For example, in a directory structure @a/b/c@, if you run completion and
-- are in directory @a@, only @b@ will be suggested, not @b/c@.
completeFileWithFilter :: (Text -> Bool) -- ^ Filter to apply to filenames (not directory names).
                       -> Text -- ^ Line of text to complete.
                       -> Interpreter [Completion]
completeFileWithFilter predicate text = liftIO $ do
  -- Attempt to get $HOME, in order to support using ~ in paths.
  -- If no $HOME is present (which is a bit weird), treat ~ literally.
  home <- maybe "~" T.pack . lookup "HOME" <$> getEnvironment

  -- Separate the file prefix desired for the completion, and the directory
  -- in which the file should be. For example, if the text is @hello/go@, then 
  -- the directory is @hello@ and the file prefix is @go@.
  let (toplevelRaw, filePrefix) = T.breakOnEnd "/" token
      toplevel = T.unpack $ path home toplevelRaw

  toplevelExists <- doesDirectoryExist toplevel
  if null toplevel || not toplevelExists
    then return []
    else do
      -- Find all files in toplevel directory, but ignore "." and "..".
      -- Nobody needs to see that! 
      entries <- getDirectoryContents toplevel
      let valid p = p /= "." && p /= ".." && T.isPrefixOf filePrefix (T.pack p)
          isDirectory dir = doesDirectoryExist (toplevel ++ "/" ++ dir)

      -- Display directories before files, always, and hidden files after normal files, always.
      (directories, files) <- partitionM isDirectory (filter valid entries)
      let allowedFiles = filter (predicate . T.pack) files
          completions = sortOn (T.isPrefixOf ".") $ map T.pack $ map (++ "/") directories ++ allowedFiles
      mkCompletions token $ map (T.append toplevelRaw) completions

  where
    token = lastWord text

    -- Try to convert a user input into an absolute or relative path.
    -- Replaces ~ with $HOME, and adds ./ if no relative prefix exists.
    path home dir =
      if T.isPrefixOf "~/" dir
        then T.replace "~/" (home <> "/") dir
        else if any (flip T.isPrefixOf dir) ["./", "../", "/"]
               then dir
               else "./" <> dir

-- | Utility for creating completions for a token.
mkCompletions :: Monad m
              => Text -- ^ Token being completed. Length of this token is the context.
              -> [Text] -- ^ Text to replace the token with.
              -> m [Completion] -- ^ Generated completions.
mkCompletions token = return . map (Completion $ T.length token)

-- | Get the last, incomplete token in the text. A token is defined as a series of contiguous
-- non-separator characters. This is left intentionally (possibly frustratingly) vague, as the
-- entire method of completion parsing is a combination of heuristics and guesswork.
lastToken :: Text -> Text
lastToken = T.takeWhileEnd (not . delimiter)
  where
    delimiter :: Char -> Bool
    delimiter char = isSymbol char || char `elem` (" :!-\n\t(),{}[]\\'\"`" :: String)

-- | Get the last, incomplete word in the text. A word is defined as a series of contiguous
-- non-whitespace characters.
lastWord :: Text -> Text
lastWord = T.takeWhileEnd (not . delimiter)
  where
    delimiter :: Char -> Bool
    delimiter char = char `elem` (" \t\n\"" :: String)
