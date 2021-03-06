--
-- Data vault for metrics
--
-- Copyright © 2013-2014 Anchor Systems, Pty Ltd and Others
--
-- The code in this file, and the program it is a part of, is
-- made available to you by its authors as open source software:
-- you can redistribute it and/or modify it under the terms of
-- the 3-clause BSD licence.
--

{-# LANGUAGE OverloadedStrings #-}

-- | This is a way for vaultaire components to store data within the Vault
--   itself.
module Vaultaire.InternalStore
(
    writeTo,
    readFrom,
    enumerateOrigin,
    internalStoreBuckets
) where

import Control.Monad.State.Strict
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BS
import Data.Monoid
import Data.Packer
import Data.Time
import Data.Word (Word64)
import Pipes
import Pipes.Parse
import qualified Pipes.Prelude as Pipes
import Vaultaire.Daemon (Daemon, profileTime)
import Vaultaire.Origin
import Vaultaire.Reader (getBuckets, readExtendedInternal)
import Vaultaire.ReaderAlgorithms (mergeNoFilter)
import Vaultaire.Types
import Vaultaire.Writer (BatchState (..), appendExtended, write)

-- | Given an origin and an address, write the given bytes.
writeTo :: Origin -> Address -> ByteString -> Daemon ()
writeTo origin addr payload =
    write Internal origin False makeState
  where
    makeState :: BatchState
    makeState =
        let zt     = UTCTime (ModifiedJulianDay 0) 0 in -- kind of dumb
        let empty  = BatchState mempty mempty mempty 0 0 mempty 0 zt in
        let bucket = calculateBucketNumber internalStoreBuckets addr in
        let len    = fromIntegral $ BS.length payload in
        execState (appendExtended 0 bucket addr 0 len payload) empty

-- | To save bootstrapping the system with actual day map files we will simply
-- mod this value. This could be a scaling issue with huge data sets.
internalStoreBuckets :: Word64
internalStoreBuckets = 128

-- | Given an origin and an address, read the avaliable bytes.
readFrom :: Origin -> Address -> Daemon (Maybe ByteString)
readFrom origin addr =
    evalStateT draw $ yield (0, internalStoreBuckets)
                      >-> readExtendedInternal origin addr 0 0
                      >-> Pipes.map extractPayload
  where
    extractPayload bs = attemptUnpacking bs $ do
        unpackSetPosition 16
        len <- getWord64LE
        getBytes (fromIntegral len)

    attemptUnpacking bs a =
        case tryUnpacking a bs of
            Left e -> error $ "failed to unpack internal payload: " ++ show e
            Right v -> v

-- | Provide a Producer of address and payload tuples.
enumerateOrigin :: Origin -> Producer (Address, ByteString) Daemon ()
enumerateOrigin origin =
    forM_ [0,2..internalStoreBuckets] $ \bucket -> do
        -- This is using the Reader so the profiled time is not exactly just
        -- Ceph waiting time, but also some reader checking.
        buckets <- lift $ profileTime ContentsEnumerateCeph origin
                 $ getBuckets Internal origin 0 bucket
        case buckets of
            Nothing -> return ()
            Just (s,e) -> mergeNoFilter s e
