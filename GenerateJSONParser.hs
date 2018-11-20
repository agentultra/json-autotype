{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE OverloadedStrings    #-}
{-# LANGUAGE NamedFieldPuns       #-}
{-# LANGUAGE ViewPatterns         #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
module Main where

import           Control.Applicative
import           Control.Exception              (assert)
import           Control.Monad                  (forM_, when, unless)
import           Data.Maybe
import           Data.Monoid
import           Data.List                      (partition)
import           System.Exit
import           System.IO                      (stdin, stderr, IOMode(..))
--import           System.IO.Posix.MMap           (mmapFileByteString)
import           System.FilePath                (splitExtension)
import           System.Process                 (system)
import qualified Data.ByteString.Lazy.Char8 as BSL
import qualified Data.HashMap.Strict        as Map
import           Data.Aeson(Value(..), decode, encode, FromJSON(..), ToJSON(..))
import qualified Data.Text                  as Text
import qualified Data.Text.IO               as Text
import           Data.Text                      (Text)
import           Text.PrettyPrint.GenericPretty (pretty)

import           Data.Aeson.AutoType.CodeGen
import           Data.Aeson.AutoType.Extract
import           Data.Aeson.AutoType.Format
import           Data.Aeson.AutoType.Split
import           Data.Aeson.AutoType.Type
import           Data.Aeson.AutoType.Util
import qualified Data.Yaml as Yaml

import           Options.Applicative
import           CommonCLI

-------------------------------------------------------------------------------

-- | CLI flags to identify program behaviour 
data Options = 
  Options 
    { tyOpts         :: TypeOpts    -- ^ 
    , outputFilename :: FilePath    -- ^ Generated file name
    , typecheck      :: Bool        -- ^ Skip typecheck or not
    , yaml           :: Bool        -- ^ parse inputs as Yaml
    , preprocessor   :: Bool        -- ^ wheater skip or not preprocessing phase
    , filenames      :: [FilePath]  -- ^
    }

optParser :: Parser Options
optParser  =
  Options <$> 
    tyOptParser
      <*> strOption (short 'o'             <>
                     long "output"         <>
                     long "outputFilename" <> 
                     value "")
      <*> unflag    (short 'n'             <>
                     long "no-typecheck"   <> 
                     help "Do not typecheck after unification")
      <*> switch    (long  "yaml"          <> 
                     help "Parse inputs as YAML instead of JSON")
      <*> switch    (short 'p'             <>
                     long "preprocessor"   <>
                     help "Work as GHC preprocessor (and skip preprocessor pragma)")
      <*> some (argument str (metavar "FILES..."))

-- | Report an error to error output.
report   :: Text -> IO ()
report    = Text.hPutStrLn stderr

-- | Report an error and terminate the program.
fatal    :: Text -> IO ()
fatal msg = do 
  report msg
  exitFailure

-- | Extracts type from JSON file, along with the original @Value@.
-- In order to facilitate dealing with failures, it returns a triple of
-- @FilePath@, extracted @Type@, and a JSON @Value@.
extractTypeFromJSONFile :: Options -> FilePath -> IO (Maybe (FilePath, Type, Value))
extractTypeFromJSONFile opts inputFilename =
      withFileOrHandle inputFilename ReadMode stdin $ \hInput ->
        -- First we decode JSON input into Aeson's Value type
        do Text.hPutStrLn stderr $ "Processing " `Text.append` Text.pack (show inputFilename)
           decodedJSON :: Maybe Value <- decoder <$> BSL.hGetContents hInput
           --let decodedJSON :: Maybe Value =  decodeValue input
           -- myTrace ("Decoded JSON: " ++ pretty decoded)
           case decodedJSON of
             Nothing -> do report $ "Cannot decode JSON input from " `Text.append` Text.pack (show inputFilename)
                           return Nothing
             Just v  -> do -- If decoding JSON was successful...
               -- We extract type structure from the JSON value.
               let t :: Type = extractType v
               myTrace $ "Type: " ++ pretty t
               (v `typeCheck` t) `unless` fatal ("Typecheck against base type failed for "
                                                    `Text.append` Text.pack inputFilename)
               return $ Just (inputFilename, t, v)
  where
    decoder | yaml opts = Yaml.decode . BSL.toStrict
            | otherwise =      decode
    -- | Works like @Debug.trace@ when the --debug flag is enabled, and does nothing otherwise.
    myTrace :: String -> IO ()
    myTrace msg = debug (tyOpts opts) `when` putStrLn msg
    -- | Perform preprocessing of JSON input to drop initial pragma.
    preprocess :: BSL.ByteString -> BSL.ByteString
    preprocess | preprocessor opts = dropPragma
               | otherwise         = id

-- | Type checking all input files with given type,
-- and return a list of filenames for files that passed the check.
typeChecking :: Type -> [FilePath] -> [Value] -> IO [FilePath]
typeChecking ty inputFilenames values = do
    unless (null failures) $ report $ Text.unwords $ "Failed to typecheck with unified type: ":
                                                          (Text.pack `map` failures)
    when (      null successes) $ fatal    "No files passed the typecheck."
    return successes
  where
    checkedFiles = zip inputFilenames $ map (`typeCheck` ty) values
    (map fst -> successes,
     map fst -> failures) = partition snd checkedFiles

-- | Take a set of JSON input filenames
--   Haskell output filename, and generate module parsing these JSON files.
generateParserFromJSONs :: Options 
                        -> [FilePath] 
                        -> FilePath 
                        -> IO ()
generateParserFromJSONs opts inputFilenames outputFilename = do
  case lang $ tyOpts $ opts of 
    Haskell    -> generateHaskellFromJSONs    opts inputFilenames outputFilename
    Elm        -> generateElmFromJSONs        opts inputFilenames outputFilename
    PureScript -> generatePureScriptFromJSONs opts inputFilenames outputFilename


-- | Drop initial pragma.
dropPragma :: BSL.ByteString -> BSL.ByteString
dropPragma input | "{-#" `BSL.isPrefixOf` input = BSL.dropWhile (/='\n') input
                 | otherwise                    = input

-- | Everything related to Haskell module generation
generateHaskellFromJSONs :: Options    -- ^
                         -> [FilePath] -- ^ 
                         -> FilePath   -- ^
                         -> IO ()
generateHaskellFromJSONs opts inputFilenames outputFilename = do

  let tyopts    = tyOpts opts
      toplevel' = toplevel tyopts
      lang'     = lang tyopts
      test'     = test tyopts

-- Read type from each file
  (filenames,
   typeForEachFile,
   valueForEachFile) <- unzip3 . catMaybes <$> mapM (extractTypeFromJSONFile opts) inputFilenames
  
-- Unify all input types
  when (null typeForEachFile) $ do
    report "No valid JSON input file..."
    exitFailure

  let finalType = foldr1 unifyTypes typeForEachFile
  passedTypeCheck <-
   case typecheck opts of
     False -> return filenames
     True  -> typeChecking finalType filenames valueForEachFile

-- We split different dictionary labels to become different type trees (and thus different declarations.)
  let splitted = splitTypeByLabel toplevelName finalType
  myTrace $ "SPLITTED: " ++ pretty splitted

  assert (not $ any hasNonTopTObj $ Map.elems splitted) $ do
    -- We compute which type labels are candidates for unification
    let uCands = unificationCandidates splitted
    myTrace $ "CANDIDATES:\n" ++ pretty uCands
    when (suggest $ tyOpts opts) $ forM_ uCands $ \cs -> do
                           putStr "-- "
                           Text.putStrLn $ "=" `Text.intercalate` cs

    -- We unify the all candidates or only those that have been given as command-line flags.
    let unified = if autounify $ tyOpts opts
                    then unifyCandidates uCands splitted
                    else splitted
    myTrace $ "UNIFIED:\n" ++ pretty unified
    
    -- We start by writing module header
    writeModule lang' outputFilename toplevelName unified
    when test' $
      exitWith =<< runModule lang' (outputFilename:passedTypeCheck)
  
  where
    -- | Works like @Debug.trace@ when the --debug flag is enabled, and does nothing otherwise.
    myTrace :: String -> IO ()
    myTrace msg = debug (tyOpts opts) `when` putStrLn msg
    toplevelName = capitalize $ Text.pack (toplevel $ tyOpts opts)
 

-- | Everything related to Purescript module generation
generatePureScriptFromJSONs :: Options    -- ^
                            -> [FilePath] -- ^ 
                            -> FilePath   -- ^
                            -> IO ()
generatePureScriptFromJSONs opts inputFilenames outputFilename = undefined

-- | Everything related to Elm module generation
-- TODO
generateElmFromJSONs :: Options    -- ^
                     -> [FilePath] -- ^ 
                     -> FilePath   -- ^
                     -> IO ()
generateElmFromJSONs opts inputFilenames outputFilename = undefined

-- | Initialize flags, and run @generateHaskellFromJSONs@.
main :: IO ()
main = do 
  opts <- execParser optInfo
  generateParserFromJSONs opts (filenames opts) (outputFilename opts)
    where
      optInfo = 
        info 
          (optParser <**> helper)
          (  fullDesc
          <> progDesc "Parser JSON or YAML, get its type, and generate appropriate parser."
          <> header "json-autotype -- automatic type and parser generation from JSON")
