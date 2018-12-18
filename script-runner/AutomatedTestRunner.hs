{-# LANGUAGE ApplicativeDo              #-}
{-# LANGUAGE ConstraintKinds            #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE NamedFieldPuns             #-}
{-# LANGUAGE NoImplicitPrelude          #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE TemplateHaskell       #-}

module AutomatedTestRunner (Example, getGenesisConfig, loadNKeys, doUpdate, onStartup, on, getScript, runScript, ScriptRunnerOptions(..), endScript, srCommonNodeArgs, Script, HasEpochSlots) where

import           Brick hiding (on)
import           Brick.BChan
import           BrickUI
import           BrickUITypes
import           Control.Concurrent
import           Control.Concurrent.Async.Lifted.Safe
import           Control.Exception (throw)
import           Control.Lens (to, makeLenses)
import           Control.Monad.STM (orElse)
import           Data.Constraint (Dict (Dict))
import           Data.Default (Default (def))
import qualified Data.HashMap.Strict as HM
import           Data.Ix (range)
import           Data.List ((!!))
import qualified Data.Map as Map
import           Data.Reflection (Given, give, given)
import qualified Data.Text as T
import           Data.Version (showVersion)
import           Formatting (Format, int, sformat, (%), string)
import           Graphics.Vty (defAttr, defaultConfig, mkVty)
import           Ntp.Client (NtpConfiguration)
import           Options.Applicative (Parser, execParser, footerDoc, fullDesc,
                     header, help, helper, info, infoOption, long, progDesc, switch)
import           Paths_cardano_sl (version)
import           PocMode (AuxxContext (AuxxContext, acRealModeContext, acEventChan), PocMode,
                     realModeToAuxx, writeBrickChan)
import           Pos.Chain.Block (LastKnownHeaderTag)
import           Pos.Chain.Genesis as Genesis
                     (Config (configGeneratedSecrets, configProtocolMagic),
                     configEpochSlots)
import           Pos.Chain.Txp (TxpConfiguration)
import           Pos.Chain.Update (BlockVersion, BlockVersionModifier,
                     SoftwareVersion, SystemTag, UpdateData,
                     mkUpdateProposalWSign, updateConfiguration)
import qualified Pos.Client.CLI as CLI
import           Pos.Client.KeyStorage (addSecretKey, getSecretKeysPlain)
import           Pos.Client.Update.Network (submitUpdateProposal)
import           Pos.Core (EpochIndex (EpochIndex), LocalSlotIndex, SlotCount,
                     SlotId (SlotId, siEpoch, siSlot), difficultyL,
                     getBlockCount, getChainDifficulty, getEpochIndex,
                     getEpochOrSlot, getSlotIndex, mkLocalSlotIndex)
import           Pos.Crypto (emptyPassphrase, hash, hashHexF, noPassEncrypt,
                     withSafeSigners)
import           Pos.DB.BlockIndex (getTipHeader)
import           Pos.DB.DB (initNodeDBs)
import           Pos.DB.Txp (txpGlobalSettings)
import           Pos.Infra.Diffusion.Types (Diffusion, hoistDiffusion)
import           Pos.Infra.Network.Types (NetworkConfig (ncDequeuePolicy, ncEnqueuePolicy, ncFailurePolicy, ncTopology),
                     NodeId, Topology (TopologyAuxx), topologyDequeuePolicy,
                     topologyEnqueuePolicy, topologyFailurePolicy)
import           Pos.Infra.Shutdown (triggerShutdown, triggerShutdown')
import           Pos.Infra.Slotting.Util (defaultOnNewSlotParams, onNewSlot)
import           Pos.Launcher (HasConfigurations, InitModeContext, NodeParams (npBehaviorConfig, npNetworkConfig, npUserSecret),
                     NodeResources, WalletConfiguration, bracketNodeResources,
                     loggerBracket, runNode, runRealMode, withConfigurations)
import           Pos.Util (lensOf, logException)
import           Pos.Util.CompileInfo (CompileTimeInfo (ctiGitRevision),
                     HasCompileInfo, compileInfo, withCompileInfo)
import           Pos.Util.UserSecret (readUserSecret, usKeys, usPrimKey, usVss)
import           Pos.Util.Wlog (LoggerName)
import           Pos.WorkMode (EmptyMempoolExt, RealMode)
import           Prelude (show)
import           Universum hiding (on, state, when)
import           Control.Lens (makeLensesWith)
import           Pos.Util (postfixLFields)
import           System.IO (hSetBuffering, BufferMode(LineBuffering), hPrint)
import           System.Exit (ExitCode)

data ScriptRunnerUIMode = BrickUI | PrintUI deriving Show

data ScriptRunnerOptions = ScriptRunnerOptions
  { _srCommonNodeArgs :: !CLI.CommonNodeArgs -- ^ Common CLI args for nodes
  , _srPeers          :: ![NodeId]
  , _srUiMode         :: !ScriptRunnerUIMode
  } deriving Show

makeLenses ''ScriptRunnerOptions

class TestScript a where
  getScript :: a -> Script

data ScriptBuilder = ScriptBuilder
  { sbScript        :: Script
  , sbEpochSlots    :: SlotCount
  , sbGenesisConfig :: Config
  }

instance Default Script where def = Script def def

data Script = Script
  { slotTriggers   :: Map.Map SlotId SlotTrigger
  , startupActions :: [ SlotTrigger ]
  } deriving (Show, Generic)

data SlotTrigger = SlotTrigger (Dict HasConfigurations -> Diffusion PocMode -> PocMode ())

instance Show SlotTrigger where
  show _ = "IO ()"

newtype ExampleT m a = ExampleT { runExampleT :: StateT ScriptBuilder m a } deriving (Functor, Applicative, Monad, MonadState ScriptBuilder)
newtype Example a = Example { runExample :: ExampleT (Identity) a } deriving (Applicative, Functor, Monad, MonadState ScriptBuilder)

instance HasEpochSlots => TestScript (Example a) where
  getScript action = do
    let
      script :: ScriptBuilder
      script = snd $ runIdentity $ runStateT (runExampleT $ runExample action) (ScriptBuilder def getEpochSlots getEpochSlots')
    sbScript script

instance TestScript Script where
  getScript = identity

data EpochSlots = EpochSlots { epochSlots :: SlotCount, config :: Config }
type HasEpochSlots = Given EpochSlots

getEpochSlots :: HasEpochSlots => SlotCount
getEpochSlots = epochSlots given

getEpochSlots' :: HasEpochSlots => Config
getEpochSlots' = config given

withEpochSlots :: SlotCount -> Config -> (HasEpochSlots => a) -> a
withEpochSlots epochSlots genesisConfig = give (EpochSlots epochSlots genesisConfig)

scriptRunnerOptionsParser :: Parser ScriptRunnerOptions
scriptRunnerOptionsParser = do
  let
    disabledParser :: Parser Bool
    disabledParser = switch $ long "no-brickui" <> help "Disable brick based ui"
  disableBrick <- disabledParser
  _srCommonNodeArgs <- CLI.commonNodeArgsParser
  _srPeers <- many $ CLI.nodeIdOption "peer" "Address of a peer."
  pure ScriptRunnerOptions{_srCommonNodeArgs,_srPeers,_srUiMode = if disableBrick then PrintUI else BrickUI}

getScriptRunnerOptions :: HasCompileInfo => IO ScriptRunnerOptions
getScriptRunnerOptions = execParser programInfo
  where
    programInfo = info (helper <*> versionOption <*> scriptRunnerOptionsParser) $
        fullDesc <> progDesc "Cardano SL CLI utilities."
                 <> header "CLI-based utilities (auxx)."
                 <> footerDoc (Just "todo")
    versionOption :: Parser (a -> a)
    versionOption = infoOption
      ("cardano-script-runner" <> showVersion version <> ", git revision " <> toString (ctiGitRevision compileInfo))
      (long "version" <> help "Show version.")

loggerName :: LoggerName
loggerName = "script-runner"

thing :: (TestScript a, HasCompileInfo) => ScriptRunnerOptions -> InputParams a -> IO ()
thing opts inputParams = do
  let
    conf = CLI.configurationOptions (CLI.commonArgs cArgs)
    cArgs@CLI.CommonNodeArgs{CLI.cnaDumpGenesisDataPath,CLI.cnaDumpConfiguration} = opts ^. srCommonNodeArgs
  withConfigurations Nothing cnaDumpGenesisDataPath cnaDumpConfiguration conf (runWithConfig opts inputParams)

maybeAddPeers :: [NodeId] -> NodeParams -> NodeParams
maybeAddPeers [] params = params
maybeAddPeers peers nodeParams = nodeParams { npNetworkConfig = (npNetworkConfig nodeParams) { ncTopology = TopologyAuxx peers } }

addQueuePolicies :: NodeParams -> NodeParams
addQueuePolicies nodeParams = do
  let
    topology = ncTopology $ npNetworkConfig nodeParams
  nodeParams { npNetworkConfig = (npNetworkConfig nodeParams)
    { ncEnqueuePolicy = topologyEnqueuePolicy topology
    , ncDequeuePolicy = topologyDequeuePolicy topology
    , ncFailurePolicy = topologyFailurePolicy topology
    }
  }

runWithConfig :: (TestScript a, HasCompileInfo, HasConfigurations) => ScriptRunnerOptions -> InputParams a -> Genesis.Config -> WalletConfiguration -> TxpConfiguration -> NtpConfiguration -> IO ()
runWithConfig opts inputParams genesisConfig _walletConfig txpConfig _ntpConfig = do
  let
    nArgs = CLI.NodeArgs { CLI.behaviorConfigPath = Nothing}
  (nodeParams', _mSscParams) <- CLI.getNodeParams loggerName (opts ^. srCommonNodeArgs) nArgs (configGeneratedSecrets genesisConfig)
  let
    nodeParams = maybeAddPeers (opts ^. srPeers) $ nodeParams'
    epochSlots = configEpochSlots genesisConfig
    vssSK = fromMaybe (error "no user secret given") (npUserSecret nodeParams ^. usVss)
    sscParams = CLI.gtSscParams (opts ^. srCommonNodeArgs) vssSK (npBehaviorConfig nodeParams)
    thing1 = txpGlobalSettings genesisConfig txpConfig
    thing2 :: ReaderT InitModeContext IO ()
    thing2 = initNodeDBs genesisConfig
  script <- liftIO $ withEpochSlots epochSlots genesisConfig (ipScriptGetter inputParams)
  let
    inputParams' = InputParams2 (ipEventChan inputParams) (ipReplyChan inputParams) script
  bracketNodeResources genesisConfig nodeParams sscParams thing1 thing2 (thing3 genesisConfig txpConfig inputParams')

thing3 :: (TestScript a, HasCompileInfo, HasConfigurations) => Config -> TxpConfiguration -> InputParams2 a -> NodeResources () -> IO ()
thing3 genesisConfig txpConfig inputParams nr = do
  let
    toRealMode :: PocMode a -> RealMode EmptyMempoolExt a
    toRealMode auxxAction = do
      realModeContext <- ask
      lift $ runReaderT auxxAction $ AuxxContext { acRealModeContext = realModeContext, acEventChan = ip2EventChan inputParams }
    thing2 :: Diffusion (RealMode ()) -> RealMode EmptyMempoolExt ()
    thing2 diffusion = toRealMode (thing5 (hoistDiffusion realModeToAuxx toRealMode diffusion))
    thing5 :: Diffusion PocMode -> PocMode ()
    thing5 = runNode genesisConfig txpConfig nr thing4
    thing4 :: [ (Text, Diffusion PocMode -> PocMode ()) ]
    thing4 = workers genesisConfig inputParams
  runRealMode updateConfiguration genesisConfig txpConfig nr thing2

workers :: (HasConfigurations, TestScript a) => Genesis.Config -> InputParams2 a -> [ (Text, Diffusion PocMode -> PocMode ()) ]
workers genesisConfig InputParams2{ip2EventChan,ip2Script,ip2ReplyChan} =
  [ ( T.pack "worker1", worker1 genesisConfig ip2Script ip2EventChan)
  , ( "worker2", worker2 ip2EventChan)
  , ( "brick reply worker", brickReplyWorker ip2ReplyChan)
  ]

brickReplyWorker :: HasConfigurations => BChan Reply -> Diffusion PocMode -> PocMode ()
brickReplyWorker replyChan diffusion = do
  reply <- liftIO $ readBChan replyChan
  case reply of
    TriggerShutdown -> do
      triggerShutdown
  brickReplyWorker replyChan diffusion

worker2 :: HasConfigurations => BChan CustomEvent -> Diffusion PocMode -> PocMode ()
worker2 eventChan diffusion = do
  localTip  <- getTipHeader
  headerRef <- view (lensOf @LastKnownHeaderTag)
  mbHeader <- atomically $ readTVar headerRef `orElse` pure Nothing
  let
    globalHeight = view (difficultyL . to getChainDifficulty) <$> mbHeader
    localHeight = view (difficultyL . to getChainDifficulty) localTip
    f (Just v) = Just $ getBlockCount v
    f Nothing  = Nothing
  liftIO $ do
    writeBChan eventChan $ CENodeInfo $ NodeInfo (getBlockCount localHeight) (getEpochOrSlot localTip) (f globalHeight)
    threadDelay 100000
  worker2 eventChan diffusion

worker1 :: (HasConfigurations, TestScript a) => Genesis.Config -> a -> BChan CustomEvent -> Diffusion (PocMode) -> PocMode ()
worker1 genesisConfig script eventChan diffusion = do
  let
    handler :: SlotId -> PocMode ()
    handler slotid = do
      liftIO $ writeBChan eventChan $ CESlotStart $ SlotStart (getEpochIndex $ siEpoch slotid) (getSlotIndex $ siSlot slotid)
      case Map.lookup slotid (slotTriggers realScript) of
        Just (SlotTrigger act) -> runAction act
        Nothing                -> pure ()
      pure ()
    realScript = getScript script
    errhandler :: Show e => e -> PocMode ()
    errhandler e = print e
    runAction :: (Dict HasConfigurations -> Diffusion PocMode -> PocMode ()) -> PocMode ()
    runAction act = do
      act Dict diffusion `catch` errhandler @SomeException
    realWorker = do
      mapM_ (\(SlotTrigger act) -> runAction act) (startupActions realScript)
      onNewSlot (configEpochSlots genesisConfig) defaultOnNewSlotParams handler
      pure ()
  realWorker `catch` errhandler @SomeException

data TestScript a => InputParams a = InputParams
  { ipEventChan    :: BChan CustomEvent
  , ipReplyChan    :: BChan Reply
  , ipScriptGetter :: HasEpochSlots => IO a
  }
data TestScript a => InputParams2 a = InputParams2
  { ip2EventChan :: BChan CustomEvent
  , ip2ReplyChan :: BChan Reply
  , ip2Script    :: a
  }

runScript :: TestScript a => (ScriptRunnerOptions -> IO b) -> (b -> IO ()) -> (ScriptRunnerOptions -> IO ScriptRunnerOptions) -> (HasEpochSlots => b -> IO a) -> IO ()
runScript initialize finalize optionsMutator scriptGetter = withCompileInfo $ do
  opts' <- getScriptRunnerOptions
  opts <- optionsMutator opts'
  (eventChan, replyChan, asyncUi) <- runUI' opts
  let
    loggingParams = CLI.loggingParams loggerName (opts ^. srCommonNodeArgs)
  loggerBracket "script-runner" loggingParams . logException "script-runner" $ do
    b <- initialize opts
    let
      inputParams = InputParams eventChan replyChan (scriptGetter b)
    thing opts inputParams
    finalize b
    pure ()
  liftIO $ writeBChan eventChan QuitEvent
  finalState <- wait asyncUi
  --print finalState
  pure ()

runUI' :: ScriptRunnerOptions -> IO (BChan CustomEvent, BChan Reply, Async AppState)
runUI' opts = do
  case opts ^. srUiMode of
    BrickUI -> runUI
    PrintUI -> runDummyUI

runDummyUI :: IO (BChan CustomEvent, BChan Reply, Async AppState)
runDummyUI = do
  hSetBuffering stdout LineBuffering
  eventChan <- newBChan 10
  replyChan <- newBChan 10
  let
    state :: AppState
    state = AppState 0 Nothing "" Nothing replyChan
    go :: IO AppState
    go = do
      reply <- liftIO $ readBChan eventChan
      case reply of
        QuitEvent -> pure state
        CESlotStart x -> do
          go
        CENodeInfo x -> do
          go
  fakesync <- async go
  pure (eventChan, replyChan, fakesync)

runUI :: IO (BChan CustomEvent, BChan Reply, Async AppState)
runUI = do
  eventChan <- newBChan 10
  replyChan <- newBChan 10
  let
    app = App
      { appDraw = ui
      , appChooseCursor = showFirstCursor
      , appHandleEvent = handleEvent
      , appStartEvent = \x -> pure x
      , appAttrMap = const $ attrMap defAttr []
      }
    state :: AppState
    state = AppState 0 Nothing "" Nothing replyChan
    go :: IO AppState
    go = do
      finalState <- customMain (mkVty defaultConfig) (Just eventChan) app state
      writeBChan replyChan TriggerShutdown
      pure finalState
  brick <- async go
  pure (eventChan, replyChan, brick)

getGenesisConfig :: Example Config
getGenesisConfig = sbGenesisConfig <$> get

data SlotCreationFailure = SlotCreationFailure { msg :: Text, slotsInEpoch :: SlotCount } deriving Show
instance Exception SlotCreationFailure where

onStartup :: (Dict HasConfigurations -> Diffusion PocMode -> PocMode ()) -> Example ()
onStartup action = do
  oldsb <- get
  let
    oldscript = sbScript oldsb
    script = oldscript {
      startupActions = [ SlotTrigger action ] <> (startupActions oldscript)
    }
    newsb = oldsb {
      sbScript = script
    }
  put newsb
  pure ()

endScript :: ExitCode -> PocMode ()
endScript code = do
  writeBrickChan QuitEvent
  triggerShutdown' code

on :: (Word64, Word16) -> (Dict HasConfigurations -> Diffusion PocMode -> PocMode ()) -> Example ()
on (epoch, slot) action = do
  oldsb <- get
  let
    todo = sbEpochSlots oldsb
    go :: Either Text LocalSlotIndex -> Example LocalSlotIndex
    go (Right localSlot) = pure localSlot
    go (Left err) = do
      throw $ SlotCreationFailure err todo
  localSlot <- go $ mkLocalSlotIndex todo slot
  let
    slot' = SlotId (EpochIndex epoch) localSlot
    oldscript = sbScript oldsb
    script = oldscript {
      slotTriggers = Map.insert slot' (SlotTrigger action) (slotTriggers oldscript)
    }
    newsb = oldsb {
      sbScript = script
    }
  put newsb

doUpdate :: HasConfigurations => Diffusion PocMode -> Config -> Int -> BlockVersion -> SoftwareVersion -> BlockVersionModifier -> PocMode ()
doUpdate diffusion genesisConfig keyIndex blockVersion softwareVersion blockVersionModifier = do
  let
    --tag = SystemTag "win64"
    updateData :: HM.HashMap SystemTag UpdateData
    updateData = HM.fromList [
        --(tag, UpdateData dummyHash dummyHash dummyHash dummyHash)
      ]
    voteAll = True
    errmsg :: Format r (Int -> Int -> r)
    errmsg = "Number of safe signers: " % int % ", expected " % int
    pm = configProtocolMagic genesisConfig
  skeys <- if voteAll then
      getSecretKeysPlain
    else do
      skey <- (!! keyIndex) <$> getSecretKeysPlain
      pure [ skey ]
  withSafeSigners skeys (pure emptyPassphrase) $ \ss -> do
    unless (length skeys == length ss) $ error $ sformat errmsg (length ss) (length skeys)
    let
      publisherSS = ss !! if not voteAll then 0 else keyIndex
      updateProposal = mkUpdateProposalWSign pm blockVersion blockVersionModifier softwareVersion updateData def publisherSS
      upid = hash updateProposal
    submitUpdateProposal pm diffusion ss updateProposal
    if not voteAll then
      putText (sformat ("Update proposal submitted, upId: "%hashHexF%"\n") upid)
    else
      putText (sformat ("Update proposal submitted along with votes, upId: "%hashHexF%"\n") upid)
    print updateProposal

loadNKeys :: String -> Integer -> PocMode ()
loadNKeys stateDir n = do
  let
    fmt :: Format r (String -> Integer -> r)
    fmt = string % "/genesis-keys/generated-keys/rich/key" % int % ".sk"
    loadKey :: Integer -> PocMode ()
    loadKey x = do
      let
        keypath = sformat fmt stateDir x
      secret <- readUserSecret (T.unpack keypath)
      let
        sk = maybeToList $ secret ^. usPrimKey
        secret' = secret & usKeys %~ (++ map noPassEncrypt sk)
      let primSk = fromMaybe (error "Primary key not found") (secret' ^. usPrimKey)
      addSecretKey $ noPassEncrypt primSk
  mapM_ loadKey (range (0,n - 1))
