module Chanterelle.Internal.Compile
  ( compile
  , makeSolcInput
  , compileModuleWithoutWriting
  , decodeContract
  , resolveContractMainModule
  , module CompileReexports
  ) where

import Prelude (Unit, bind, discard, map, not, pure, show, ($), (*>), (<$>), (<<<), (<>), (==), (>>=))
import Chanterelle.Internal.Logging (LogLevel(..), log)
import Chanterelle.Internal.Types.Compile (CompileError(..), OutputContract, SolcContract(..), SolcError(..), SolcInput(..), SolcOutput(..), SolcSettings(..), encodeOutputContract, parseSolcOutput)
import Chanterelle.Internal.Types.Compile (CompileError(..), OutputContract(..), SolcContract(..), SolcError(..), SolcInput(..), SolcOutput(..), SolcSettings(..), parseOutputContract) as CompileReexports
import Chanterelle.Internal.Types.Project (ChanterelleProject(..), ChanterelleProjectSpec(..), ChanterelleModule(..), Dependency(..))
import Chanterelle.Internal.Utils.FS (assertDirectory, fileIsDirty)
import Chanterelle.Internal.Utils.Json (jsonStringifyWithSpaces)
import Control.Error.Util (hush)
import Control.Monad.Aff (attempt)
import Control.Monad.Aff.Class (class MonadAff, liftAff)
import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Class (class MonadEff, liftEff)
import Control.Monad.Eff.Exception (catchException)
import Control.Monad.Eff.Now (NOW, now)
import Control.Monad.Error.Class (class MonadThrow, throwError)
import Control.Monad.Reader (class MonadAsk, ask)
import Data.Argonaut (encodeJson)
import Data.Argonaut as A
import Data.Argonaut.Parser as AP
import Data.Array (catMaybes, filter)
import Data.DateTime.Instant (unInstant)
import Data.Either (Either(..))
import Data.Function.Uncurried (Fn2, runFn2)
import Data.Lens ((^?))
import Data.Lens.Index (ix)
import Data.Maybe (Maybe(..))
import Data.StrMap as M
import Data.Time.Duration (Milliseconds(..))
import Data.Traversable (for, for_)
import Data.Tuple (Tuple(..))
import Network.Ethereum.Core.HexString (fromByteString)
import Network.Ethereum.Core.Keccak256 (keccak256)
import Node.Encoding (Encoding(UTF8))
import Node.FS.Aff as FS
import Node.FS.Sync as FSS
import Node.Path (FilePath)
import Node.Path as Path
import Node.Process as P

--------------------------------------------------------------------------------

foreign import data SolcInputCallbackResult :: Type
foreign import solcInputCallbackSuccess :: String -> SolcInputCallbackResult
foreign import solcInputCallbackFailure :: String -> SolcInputCallbackResult
foreign import _compile :: forall eff cbEff. Fn2 String (String -> Eff cbEff SolcInputCallbackResult) (Eff eff String)

-- | compile and write the artifact
compile
  :: forall eff m.
     MonadAff (fs :: FS.FS, process :: P.PROCESS, now :: NOW | eff) m
  => MonadThrow CompileError m
  => MonadAsk ChanterelleProject m
  => m (M.StrMap (Tuple ChanterelleModule SolcOutput))
compile = do
  p@(ChanterelleProject project) <- ask
  let (ChanterelleProjectSpec spec) = project.spec
  dirtyModules <- modulesToCompile project.modules
  solcInputs <- for dirtyModules $ \m@(ChanterelleModule mod) -> do
      input <- makeSolcInput mod.solContractName mod.solPath
      pure $ Tuple m input
  solcOutputs <-  for solcInputs compileModule
  pure $ M.fromFoldable solcOutputs

-- | Get all of the dirty modules that need to be recompiled
-- NOTE: This is pretty ugly because there are many things that could go wrong,
-- should probably fix.
modulesToCompile
  :: forall eff m.
     MonadAff (fs :: FS.FS, process :: P.PROCESS | eff) m
  => MonadThrow CompileError m
  => Array ChanterelleModule
  -> m (Array ChanterelleModule)
modulesToCompile modules = do
  mModules <- for modules $ \m@(ChanterelleModule mod) -> do
    ejson <- liftAff $ attempt $ FS.readTextFile UTF8 mod.jsonPath
    case ejson of
      Left _ -> pure $ Just m
      Right json -> case hush (AP.jsonParser json) >>= \json' -> json' ^? A._Object <<< ix "compiledAt" <<< A._Number of
        Nothing -> log Debug ("Couldn't find 'compiledAt' timestamp for dirty file checking: " <> mod.jsonPath) *> pure (Just m)
        Just compiledAt -> do
          eIsDirty <- liftAff <<< attempt $ fileIsDirty mod.solPath (Milliseconds compiledAt)
          case eIsDirty of
            Left err -> throwError $ MissingArtifactError {fileName: mod.solPath, objectName: mod.solContractName}
            Right isDirty ->
              if not isDirty
                then log Debug ("File is clean: " <> mod.solPath) *> pure Nothing
                else pure (Just m)
  pure $ catMaybes mModules

compileModule
  :: forall eff m.
     MonadAff (fs :: FS.FS, process :: P.PROCESS, now :: NOW | eff) m
  => MonadThrow CompileError m
  => MonadAsk ChanterelleProject m
  => Tuple ChanterelleModule SolcInput
  -> m (Tuple String (Tuple ChanterelleModule SolcOutput))
compileModule (Tuple m@(ChanterelleModule mod) solcInput) = do
  output <- compileModuleWithoutWriting m solcInput
  writeBuildArtifact mod.solContractName mod.jsonPath output mod.solContractName
  pure $ Tuple mod.moduleName (Tuple m output)

compileModuleWithoutWriting
  :: forall eff m.
     MonadAff (fs :: FS.FS, process :: P.PROCESS, now :: NOW | eff) m
  => MonadThrow CompileError m
  => MonadAsk ChanterelleProject m
  => ChanterelleModule
  -> SolcInput
  -> m SolcOutput
compileModuleWithoutWriting m@(ChanterelleModule mod) solcInput = do
  (ChanterelleProject project) <- ask
  log Info ("compiling " <> mod.moduleName)
  output <- liftEff $ runFn2 _compile (A.stringify $ encodeJson solcInput) (loadSolcCallback project.root project.spec)
  case AP.jsonParser output >>= parseSolcOutput of
    Left err -> throwError $ CompileParseError {objectName: "Solc Output", parseError: err}
    Right output' -> pure output'


-- | load a file when solc requests it
-- | TODO: secure it so that it doesnt try loading crap like /etc/passwd, etc. :P
-- | TODO: be more clever about dependency resolution, that way we don't even have to do
-- |       any remappings!
loadSolcCallback
  :: forall eff.
     FilePath
  -> ChanterelleProjectSpec
  -> String
  -> Eff (fs :: FS.FS | eff) SolcInputCallbackResult
loadSolcCallback root (ChanterelleProjectSpec project) filePath = do
  let isAbs = Path.isAbsolute filePath
      fullPath = if isAbs
                   then filePath
                   else Path.normalize (Path.concat [root, project.sourceDir, filePath])
  log Debug ("Solc load: " <> filePath <> " -> " <> fullPath)
  catchException (pure <<< solcInputCallbackFailure <<< show) (solcInputCallbackSuccess <$> (FSS.readTextFile UTF8 fullPath))

makeSolcContract
  :: String
  -> SolcContract
makeSolcContract  sourceCode =
  SolcContract { content: sourceCode
               , hash: fromByteString $ keccak256 sourceCode
               }

--------------------------------------------------------------------------------
-- | SolcInput
--------------------------------------------------------------------------------

makeSolcInput
  :: forall eff m.
     MonadAff (fs :: FS.FS | eff) m
  => MonadAsk ChanterelleProject m
  => String
  -> FilePath
  -> m SolcInput
makeSolcInput moduleName sourcePath = do
  (ChanterelleProject project) <- ask
  let (ChanterelleProjectSpec spec) = project.spec
  code <- liftAff $ FS.readTextFile UTF8 sourcePath
  let language = "Solidity"
      sources = M.singleton (moduleName <> ".sol") (makeSolcContract code)
      outputSelection = M.singleton "*" (M.singleton "*" (["abi", "evm.deployedBytecode.object", "evm.bytecode.object"] <> spec.solcOutputSelection))
      depMappings = (\(Dependency dep) -> dep <> "=" <> (project.root <> "/node_modules/" <> dep)) <$> spec.dependencies
      sourceDirMapping = [":g" <> (Path.concat [project.root, spec.sourceDir])]
      remappings = sourceDirMapping <> depMappings
      settings = SolcSettings { outputSelection, remappings, libraries }
      libraries = M.singleton (moduleName <> ".sol") spec.libraries
  pure $ SolcInput { language, sources, settings }

--------------------------------------------------------------------------------
-- | Solc Output
--------------------------------------------------------------------------------

decodeContract
  :: forall m eff.
     MonadEff eff m
  => MonadThrow CompileError m
  => String
  -> SolcOutput
  -> m (M.StrMap OutputContract)
decodeContract srcName (SolcOutput output) = do
    let srcNameWithSol = srcName <> ".sol"
        warnings = filter (\(SolcError se) -> se.severity == "warning") output.errors
    for_ warnings $ \(SolcError err) -> log Warn err.formattedMessage
    case M.lookup srcNameWithSol output.contracts of
      Nothing -> do
        let errs = filter (\(SolcError se) -> se.severity == "error") output.errors
        throwError <<< CompilationError $ map (\(SolcError se) -> se.formattedMessage) errs
      Just contractMap' -> pure contractMap'


writeBuildArtifact
  :: forall eff m.
     MonadAff (fs :: FS.FS, now :: NOW | eff) m
  => MonadThrow CompileError m
  => String
  -> FilePath
  -> SolcOutput
  -> String
  -> m Unit
writeBuildArtifact srcName filepath output solContractName = do
  co <- decodeContract srcName output
  co' <- resolveContractMainModule filepath co solContractName
        
  assertDirectory (Path.dirname filepath)
  epochTime <- unInstant <$> liftEff now
  log Debug $ "Writing artifact " <> filepath
  liftAff $ FS.writeTextFile UTF8 filepath <<< jsonStringifyWithSpaces 4 $ encodeOutputContract co' epochTime

resolveContractMainModule
  :: forall eff m.
     MonadAff eff m
  => MonadThrow CompileError m
  => FilePath
  -> M.StrMap OutputContract
  -> String
  -> m OutputContract
resolveContractMainModule fileName decodedOutputs solContractName =
  case M.lookup solContractName decodedOutputs of
    Nothing -> throwError $ MissingArtifactError {fileName, objectName: solContractName}
    Just co' -> pure co'