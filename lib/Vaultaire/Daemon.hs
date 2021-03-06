{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE Rank2Types                 #-}
{-# LANGUAGE RecordWildCards            #-}

-- | Encapsulates runtime requirements of a generic vaultaire daemon
--
-- Handles:
--
-- * connection to ceph,
--
-- * message retrieval/reply.
--
-- * caching of an Origin specific DayMap
module Vaultaire.Daemon
(
    -- * Types
    Daemon,
    DaemonArgs(..),
    DaemonEnv,
    Message(..),
    ReplyF,
    Address(..),
    Payload,
    Bucket,
    BucketSize,
    -- * Functions
    runDaemon,
    handleMessages,
    liftPool,
    nextMessage,
    asyncCustom,
    refreshOriginDays,
    withSimpleDayMap,
    withExtendedDayMap,
    withLockShared,
    withLockExclusive,
    cacheExpired,
    -- * Helpers
    dayMapsFromCeph,
    simpleDayOID,
    extendedDayOID,
    bucketOID,
    withPool,
    profileTime,
    profileCount,
    profileCountN,
    profileReport,
    elapsed,
    -- * Smart constructors
    daemonArgs,
    daemonArgsDefault
) where

import Control.Applicative
import Control.Concurrent
import Control.Concurrent.Async
import Control.Exception
import Control.Monad
import Control.Monad.Reader
import Control.Monad.State.Strict
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BS
import Data.List.NonEmpty (fromList)
import Data.Maybe
import Data.Monoid
import Data.Word (Word64)
import Network.URI
import System.Log.Logger
import System.Posix.Signals
import System.Rados.Monadic (Pool, fileSize, parseConfig, readFull,
                             runConnect, runObject, runObject, runPool, stat,
                             withExclusiveLock, withSharedLock)
import qualified System.Rados.Monadic as Rados
import qualified System.ZMQ4 as ZMQ
import Text.Printf
import Vaultaire.DayMap
import Vaultaire.OriginMap
import Vaultaire.Profiler
import Vaultaire.Types
import Vaultaire.Util


-- User facing API

-- | The 'Daemon' monad stores per 'Origin' 'DayMap's and queues for message
-- retrieval and reply. The underlying base monad is a rados 'Pool', you can
-- lift to this via 'liftPool'.
--
newtype Daemon a = Daemon (StateT OriginDays (ReaderT DaemonEnv Pool) a)
  deriving ( Functor, Applicative, Monad, MonadIO
           , MonadReader DaemonEnv, MonadState OriginDays)

-- | Arguments needed to be supplied by user to run a daemon
data DaemonArgs = DaemonArgs
   { broker    :: URI                -- ^ Broker, e.g. tcp://example.com:5550
   , ceph_user :: Maybe ByteString   -- ^ Username for Ceph
   , ceph_pool :: ByteString         -- ^ Pool name for Ceph
   , shutdown  :: MVar ()            -- ^ Shutdown signal
   , profiler  :: ProfilingInterface -- ^ Profiler interface to use for this daemon
   }

-- | Environment in which to run a daemon
type DaemonEnv = (SharedConnection, ProfilingInterface)

-- | Handle to commuicate with the 0MQ router.
type SharedConnection = MVar (ZMQ.Socket ZMQ.Router)

-- | Simple and extended day maps
type OriginDays = OriginMap ((FileSize, DayMap), (FileSize, DayMap))

-- | Represents a request made by a client. This could be a request to write a
-- point or a query.
--
-- All mesages follow the same asyncronous response, reply pattern.
data Message = Message
    { messageReplyF  :: ReplyF -- ^ Queue a reply to this message. This
                               --   will be transmitted automatically
                               --   at a later point.
    , messageOrigin  :: Origin
    , messagePayload :: ByteString
    }

type ReplyF     = WireFormat w => w -> Daemon ()
type Payload    = Word64
type Bucket     = Word64
type BucketSize = Word64


-- | Handle messages using an arbitrary concurrency abstraction.
--
-- In order for this to behave, your message handling function must be
-- stateless, there is no guarantee that it will be run in the same thread,
-- thus no assumptions should be made about the DayMap from a previous request
-- sticking around.
--
-- This prohibits any multi-message requests, if this is what you want you had
-- best define your own concurrency mechanism.
--
handleMessages :: DaemonArgs             -- ^ Run the daemon with these arguments
               -> (Message -> Daemon ()) -- ^ Handle messages with this handler
               -> IO ()
handleMessages args@(DaemonArgs{..}) f = runDaemon args loop
  where
    -- Dumb, no concurrency for now. WARNING we originally had tryReadMVar but
    -- it was causing non-deterministic asynchronous delayed hangs. We'll come
    -- back to this question.
    loop = do
        done <- isJust <$> liftIO (tryReadMVar shutdown)
        unless done $ do
                maybe_next <- nextMessage
                case maybe_next of
                    Nothing -> loop
                    Just msg -> f msg >> loop

-- | Encapsulating the lifetime of a daemon.
--   This will go as far as to connect to Ceph and begin listening for messages.
--
runDaemon :: DaemonArgs -- ^ With these arguments
          -> Daemon a   -- ^ Run this daemon
          -> IO a
runDaemon DaemonArgs{..} (Daemon a) =
    bracket (setupSharedConnection broker)
            (\(ctx, conn) -> do
                sock <- takeMVar conn
                ZMQ.close sock
                ZMQ.shutdown ctx)
            (\(_, conn) -> withPool ceph_user ceph_pool
                         $ flip runReaderT (conn, profiler)
                         $ evalStateT a emptyOriginMap)

-- Connect to ceph and run your pool action
withPool :: Maybe ByteString -> ByteString -> Pool a -> IO a
withPool ceph_user pool = runConnect ceph_user (parseConfig "/etc/ceph/ceph.conf") . runPool pool

-- | Lift an action from the librados 'Pool' monad.
liftPool :: Pool a -> Daemon a
liftPool = Daemon . lift . lift

-- | Pop the next message off an internal FIFO queue of messages.
--   Incoming message should be four parts:
--   1. The routing information back to the broker.
--   2. The routing information back to the client, from the broker.
--   3. The the origin, unverified and unauthenticated for now.
--   4. The client's payload.
nextMessage :: Daemon (Maybe Message)
nextMessage = do
    conn <- fst <$> ask
    liftIO $ withMVar conn $ \c -> do
        result <- ZMQ.poll 10 [ZMQ.Sock c [ZMQ.In] Nothing]
        case result of
            -- Message waiting
            [[ZMQ.In]] -> do
                msg <- doRecv c

                case msg of
                    -- Invalid message
                    Nothing -> return Nothing
                    Just (env_a, env_b, origin, payload) ->
                        -- This can be moved out of a lambda when I fully understand this:
                        -- http://www.haskell.org/pipermail/haskell-cafe/2012-August/103041.html
                        let send r = flip ZMQ.sendMulti (fromList [env_a, env_b, toWire r])
                        in return . Just $
                            Message (\r -> do var <- fst <$> ask
                                              liftIO $ withMVar var (send r))
                                    (Origin origin)
                                    payload
            -- Timeout, do nothing.
            [[]]        -> return Nothing
            _           -> fatal "Daemon.listen" "impossible"
  where
    doRecv sock =  do
        msg <- ZMQ.receiveMulti sock
        case msg of
            [env_a, env_b, origin, payload] ->
                return . Just $ (env_a, env_b, origin, payload)
            n -> do
                liftIO . errorM "Daemon.nextMessage" $
                                "bad message recieved, " ++ show (length n)
                                ++ " parts; ignoring"
                return Nothing

-- | Run an action in the 'Control.Concurrent.Async' monad.
-- State will be empty and completely separated from any other thread. This is
-- to avoid strange memory leaks and complexity.
--
-- You do however have access to the same messaging channels, so sending and
-- receiving messages will work fine and is thread safe.
asyncCustom :: Daemon a -> Daemon (Async a)
asyncCustom (Daemon a) = do
    -- TODO: Handle waiting for any 'child' threads created, as the underlying
    --       connection is now shared.
    conf <- ask
    liftPool $ Rados.async (runReaderT (evalStateT a emptyOriginMap) conf)

-- | Fetch the simple day map for a given origin
withSimpleDayMap :: Origin -> (DayMap -> a) -> Daemon (Maybe a)
withSimpleDayMap origin' f = do
    om <- get
    return $ f . snd . fst <$> originLookup origin' om

-- | Fetch the extended day map for a given origin
withExtendedDayMap :: Origin -> (DayMap -> a) -> Daemon (Maybe a)
withExtendedDayMap origin' f = do
    om <- get
    return $ f . snd . snd <$> originLookup origin' om

-- | Ensure that the 'DayMap's for a given 'Origin' are up to date.
refreshOriginDays :: Origin -> Daemon ()
refreshOriginDays origin' = do
    om <- get
    -- If we already have it, reload if modified. Otherwise we just reload.
    expired <- cacheExpired om origin'
    when expired $ reload om
  where
    reload om = do
        result <- liftPool $ dayMapsFromCeph origin'
        case result of
            Left e -> liftIO $ putStrLn e
            Right day_map -> put $ originInsert origin' day_map om

{-
    Lock management
-}

-- | Lock timeout period, in seconds.
timeout :: Int
timeout = 600 -- 10 minutes

-- | Duration of lock, in seconds.
release :: Double
release = fromIntegral $ timeout + 5

--
-- | Take a shared lock on the specified object. Others can concurrently take
-- shared locks, someone wanting an exclusive lock waits until current shared
-- lockers are finished.
--
withLockShared :: ByteString -> Daemon a -> Daemon a
withLockShared oid daemon = do
    liftIO $ debugM "Daemon.withSharedLock"
                    ("Lock shared    requested " ++ BS.unpack oid)
    result <- wrapPool (withSharedLock oid "lock" "lock" "daemon" (Just release)) $ do
                liftIO $ debugM "Daemon.withSharedLock"
                    ("Lock shared    acquired  " ++ BS.unpack oid)
                daemon
    liftIO $ debugM "Daemon.withSharedLock"
                    ("Lock exclusive released  " ++ BS.unpack oid)
    return result


--
-- | Take a exclusive lock on the specified object. Waits for current shared
-- lockers to release while inhibiting new shared locks by others. Then locks
-- exclusively, preventing other shared or exclusive locks until finished.
--
withLockExclusive :: ByteString -> Daemon a -> Daemon a
withLockExclusive oid daemon = do
    liftIO $ debugM "Daemon.withExclusiveLock"
                    ("Lock exclusive requested " ++ BS.unpack oid)
    result <- wrapPool (withExclusiveLock oid "lock" "lock" (Just release)) $ do
                liftIO $ debugM "Daemon.withExclusiveLock"
                    ("Lock exclusive acquired  " ++ BS.unpack oid)
                daemon
    liftIO $ debugM "Daemon.withExclusiveLock"
                    ("Lock exclusive released  " ++ BS.unpack oid)
    return result


{-
    In order to grab a shared lock, we lift to the Pool monad, but to run the
    user's action we must re-wrap the state. Daemon state within will not be
    updated within the 'outer' monad until the entire action completes. You
    will probably never even notice this.
-}

wrapPool :: (Pool (a, OriginDays) -> Pool (b, OriginDays))
         -> Daemon a -> Daemon b
wrapPool pool_action (Daemon r) = do
    conf  <- ask
    s <- get

    -- Start timer
    a <- liftIO $ async watchdog

    -- Carry out action with librados
    (r',s') <- liftPool $ pool_action (runReaderT (runStateT r s) conf)

    -- Completed! Don't need the watchdog anymore.
    liftIO $ cancel a

    -- Wrap up and return
    put s'
    return r'
  where
    milliseconds = 1000000

    watchdog :: IO ()
    watchdog = do
        threadDelay $ timeout * milliseconds
        criticalM "Daemon.watchdog" "WATCHDOG TIMER ELAPSED"
        raiseSignal sigKILL



-- Internal

type FileSize = Word64

-- | Check if a cached origin has expired.
cacheExpired :: OriginDays -> Origin -> Daemon Bool
cacheExpired om origin' =
    case originLookup origin' om of
        Just ((simple_size, _), (ext_size, _)) -> do
            simple_expired <- checkDayFile (simpleDayOID origin') simple_size
            if not simple_expired
                then checkDayFile (extendedDayOID origin') ext_size
                else return simple_expired
        Nothing -> return True
  where
    checkDayFile file expected_size = do
        st <- liftPool $ runObject file stat
        case st of
            Left e -> fatal "Daemon.cacheExpired" $
                            "Failed to stat day file: " ++ show file
                            ++ "( " ++ show e ++ ")"
            Right result -> return $ fileSize result /= expected_size


-- | Load a DayMap from Ceph
--
-- The file size is returned along side the map for cache invalidation.
dayMapsFromCeph :: Origin -> Pool (Either String ((FileSize, DayMap), (FileSize, DayMap)))
dayMapsFromCeph origin' = do
    simple <- tryRead (simpleDayOID origin')
    extended <- tryRead (extendedDayOID origin')
    return $ (,) <$> simple <*> extended
  where
    tryRead file =  do
        result <- runObject file readFull
        case result of
            Left e ->
                return $ Left $ "Failed to read day file: " ++ show file ++
                                " (" ++ show e ++ ")"
            Right contents ->
                tryLoad file contents

    tryLoad day_file contents = case loadDayMap contents of
        Left e ->
            return $ Left $ "Failed to load day file: " ++
                            show day_file ++ " (" ++ e ++ ")"
        Right day_map ->
            return $ Right (fromIntegral (BS.length contents), day_map)

-- | Ceph object ID of the origin's Simple DayMap.
simpleDayOID :: Origin -> ByteString
simpleDayOID (Origin origin') = "02_" <> origin' <> "_simple_days"

-- | Ceph object ID of the origin's Extended DayMap.
extendedDayOID :: Origin -> ByteString
extendedDayOID (Origin origin') = "02_" <> origin' <> "_extended_days"

-- | Ceph object ID of the bucket at the provided epoch.
bucketOID :: Origin -> Epoch -> Bucket -> String -> ByteString
bucketOID (Origin origin') epoch bucket kind = BS.pack $ printf "02_%s_%020d_%020d_%s"
                                                         (BS.unpack origin')
                                                         bucket
                                                         epoch
                                                         kind

-- | Build the 'SharedConnection' for use by potentially many consumers within
-- this 'Daemon'.
setupSharedConnection :: URI -- ^ Broker name
                      -> IO (ZMQ.Context, SharedConnection)
setupSharedConnection broker = do
    ctx <- ZMQ.context
    sock <- ZMQ.socket ctx ZMQ.Router
    ZMQ.connect sock $ show broker
    mvar <- newMVar sock
    return (ctx, mvar)


-- Convenience/Smart constructors and interface

-- | Construct necessary arguments to start a daemon
daemonArgs
  :: URI                       -- ^ Full broker URI, e.g. @tcp://example.com:9990@
  -> Maybe String              -- ^ Ceph user
  -> String                    -- ^ Ceph pool
  -> MVar ()                   -- ^ Shutdown signal
  -> Maybe String              -- ^ Indentifiable daemon name, e.g. @vault.example.com-writer-01@
  -> Maybe (Int, Period, Int)  -- ^ If has profiling, (port, profile period, profiling channel bound)
  -> IO (DaemonArgs, ProfilingEnv)
daemonArgs brokerd user pool end dname pargs = do
    (env, interface)  <- maybe (return noProfiler)
                               (\(pport, pperiod, pbound)
                                   -> hasProfiler ( fromMaybe mempty dname
                                                  , modPort brokerd pport
                                                  , pperiod
                                                  , pbound
                                                  , end )) pargs
    return ( DaemonArgs brokerd
                        (BS.pack <$> user)
                        (BS.pack     pool)
                        end
                        interface
           , env)
    where -- could probably lens this, if network.uri has lens support
          modPort u i = u { uriAuthority = (\x -> x { uriPort = ':':show i }) <$> uriAuthority u }

-- | Construct default daemon arguments, with no profiler, no name.
daemonArgsDefault
  :: URI                    -- ^ Full broker URI, e.g. tcp://example.com:9999
  -> Maybe String           -- ^ Ceph user
  -> String                 -- ^ Ceph pool
  -> MVar ()                -- ^ Shutdown Signal
  -> IO DaemonArgs
daemonArgsDefault full_broker_uri user pool shutdown
  = fst <$> daemonArgs full_broker_uri user pool shutdown Nothing Nothing

-- | Send a one-count for this telemtric type to the profiler for this daemon
--
profileCount :: TeleMsgType -> Origin -> Daemon ()
profileCount t g = do
    (_, prof) <- ask
    profCount  prof t g 1
{-# INLINE profileCount #-}

-- | Send an n-count for this telemtric type to the profiler for this daemon
--
profileCountN :: TeleMsgType -> Origin -> Int -> Daemon ()
profileCountN t g c = do
    (_, prof) <- ask
    profCount  prof t g c
{-# INLINE profileCountN #-}

-- | Measure the timelapse for a daemon operation and
--   send the result to the profiler
--
profileTime :: TeleMsgType -> Origin -> Daemon r -> Daemon r
profileTime  t g act = do
    (_, prof) <- ask
    profTime prof t g act
{-# INLINE profileTime #-}

-- | Measure the timelapse for a daemon operation.
--
elapsed :: Daemon r -> Daemon (r, Word64)
elapsed act = do
    (_, prof) <- ask
    measureTime prof act
{-# INLINE elapsed #-}

profileReport :: TeleMsgType -> Origin -> Word64 -> Daemon ()
profileReport t g p = do
    (_, prof) <- ask
    report prof t g p
{-# INLINE profileReport #-}
