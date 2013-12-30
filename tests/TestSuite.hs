--
-- Data vault for metrics
--
-- Copyright © 2013-     Anchor Systems, Pty Ltd
--
-- The code in this file, and the program it is a part of, is
-- made available to you by its authors as open source software:
-- you can redistribute it and/or modify it under the terms of
-- the BSD licence.
--

{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS -fno-warn-unused-imports #-}
{-# OPTIONS -fno-warn-orphans #-}

module TestSuite where

import Test.Hspec
import Test.Hspec.QuickCheck
import Test.HUnit
import Test.QuickCheck (elements, property)
import Test.QuickCheck.Arbitrary (Arbitrary, arbitrary)

import Control.Monad
import Data.Word

--
-- Otherwise redundent imports, but useful for testing in GHCi.
--

import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as S
import qualified Data.Map.Strict as Map
import Data.Monoid (Monoid, mempty)
import Data.ProtocolBuffers hiding (decode, encode)
import Data.Serialize
import Data.Text (Text)
import qualified Data.Text as T
import Debug.Trace

--
-- What we're actually testing.
--

import Vaultaire.Conversion.Receiver
import Vaultaire.Conversion.Transmitter
import Vaultaire.Conversion.Writer
import qualified Vaultaire.Internal.CoreTypes as Core
import Vaultaire.Persistence.Buckets
import Vaultaire.Serialize.DiskFormat (Compression (..), Quantity (..))
import qualified Vaultaire.Serialize.DiskFormat as Disk
import qualified Vaultaire.Serialize.WireFormat as Protobuf

suite :: Spec
suite = do
    describe "a DataFrame protobuf" $ do
        testSerializeDataFrame
        testConvertPoint

    describe "on-disk VaultPrefix" $ do
        testSerializeVaultHeader
        testRoundTripVaultHeader

    describe "a VaultPoint protobuf" $ do
        testSerializeVaultPoint

    describe "objects in vault" $ do
        testFormBucketLabel



testSerializeDataFrame =
    it "serializes to the correct bytes" $ do
        let gs =
               [Protobuf.SourceTag {
                    Protobuf.field = putField "hostname",
                    Protobuf.value = putField "secure.example.org"
                },
                Protobuf.SourceTag {
                    Protobuf.field = putField "metric",
                    Protobuf.value = putField "eth0-tx-bytes"
                },
                Protobuf.SourceTag {
                    Protobuf.field = putField "datacenter",
                    Protobuf.value = putField "lhr1"
                }]

        let x =
                Protobuf.DataFrame {
                    Protobuf.origin = putField (Just "perf_data"),
                    Protobuf.source = putField gs,
                    Protobuf.timestamp = putField 1387524524342329774,
                    Protobuf.payload = putField Protobuf.NUMBER,
                    Protobuf.valueNumeric = putField (Just 45007),
                    Protobuf.valueMeasurement = mempty,
                    Protobuf.valueTextual = mempty,
                    Protobuf.valueBlob = mempty
                }

        let x' = runPut $ encodeMessage x

        assertEqual "incorrect bytes!" x' x'


testConvertPoint =
    it "serializes a Core.Point to a Protobuf.DataFrame" $ do
        let tags = Map.fromList
               [("hostname", "secure.example.org"),
                ("metric", "eth0-tx-bytes"),
                ("datacenter", "lhr1"),
                ("epoch", "1")]

        let msg = Core.Point {
            Core.origin = "perf_data",
            Core.source = tags,
            Core.timestamp = 1386931666289201468,
            Core.payload = Core.Numeric 201468
        }

        let y' = encodePoints [msg]
        pendingWith "Waiting for sample protobuf"
        assertEqual "Incorrect message content" B.empty y'
        
        -- 0x0A1E0A08686F73746E616D6512127365637572652E6578616D706C652E6F72670A170A066D6574726963120D657468302D74782D62797465730A120A0A6461746163656E74657212046C6872310A0A0A0565706F6368120131113C91E890005F3F13180120FCA50C



testSerializeVaultHeader =
  let
    h1 = Disk.VaultPrefix {
                Disk.extended = False,
                Disk.version = 7,
                Disk.compression = Disk.Compressed,
                Disk.quantity = Disk.Multiple,
                Disk.size = 42
            }
  in do
    it "serializes to the correct bytes" $ do
        let h' = encode h1

        assertEqual "Incorrect number of bytes" 2 (B.length h')
        assertEqual "Incorrect serialization" [0x7c,0x2a] (B.unpack h')

    it "deserializes to the correct object" $ do
        let h' = B.pack [0x7c,0x2a]

        let eh2 = decode h'

        case eh2 of
            Left err    -> assertFailure err
            Right h2    -> assertEqual "Incorrect deserialization" h1 h2

instance Arbitrary Disk.Word3 where
    arbitrary = elements [0..7]

instance Arbitrary Disk.Compression where
    arbitrary = elements [Disk.Normal, Disk.Compressed]

instance Arbitrary Disk.Quantity where
    arbitrary = elements [Disk.Single, Disk.Multiple]

instance Arbitrary Disk.VaultPrefix where
    arbitrary = liftM5 Disk.VaultPrefix arbitrary arbitrary arbitrary arbitrary arbitrary

testRoundTripVaultHeader =
    prop "round-trips correctly at boundaries" prop_RoundTrip

prop_RoundTrip :: Disk.VaultPrefix -> Bool
prop_RoundTrip prefix =
  let
    decoded = either error id $ decode (encode prefix)
  in
    prefix == decoded

testSerializeVaultPoint =
  let
    tags = Map.fromList
           [("hostname", "secure.example.org"),
            ("metric", "eth0-tx-bytes"),
            ("datacenter", "lhr1"),
            ("epoch", "1")]

    p1 = Core.Point {
        Core.origin = "perf_data",
        Core.source = tags,
        Core.timestamp = 1386931666289201468,
        Core.payload = Core.Numeric 201468
--      payload = Core.Textual "203.0.113.101 - - [12/Dec/2013:04:11:16 +1100] \"GET /the-politics-of-praise-william-w-young-iii/prod9780754656463.html HTTP/1.1\" 200 15695 \"-\" \"Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)\""
--      payload = Core.Measurement 45.9
    }
  in
    it "serializes Core.Point to Disk.VaultPoint " $ do
        let pb1 = createDiskPoint p1
        let p1' = runPut $ encodeMessage pb1

        assertEqual "Incorrect length" 13 (S.length p1')

        let epb2 = runGet decodeMessage p1'
        case epb2 of
            Left err    -> assertFailure err
            Right pb2   -> do
                assertEqual "Incorrect de-serialization" pb1 pb2

                let p2 = undefined
                pendingWith "Implement Disk.VaultPoint -> Core.Point"

                assertEqual "Point object converted not equal to original object" p1 p2


testFormBucketLabel =
  let
{-
    b1 = Core.Bucket {
        Core.origin = "perf_data",
        Core.source2 = tags,
        Core.timemark = 1388400000
    }
-}
    t1 = Map.fromList
           [("hostname", "web01.example.com"),
            ("metric", "math-constants"),
            ("datacenter", "lhr1")]

    p1 = Core.Point {
        Core.origin = "arithmetic",
        Core.source = t1,
        Core.timestamp = 1387929601271828182,       -- 25 Dec + e
        Core.payload = Core.Measurement 2.718281    -- e
    }

    t2 = Map.fromList
           [("metric", "math-constants"),
            ("datacenter", "lhr1"),
            ("hostname", "web01.example.com")]

    p2 = Core.Point {
        Core.origin = "arithmetic",
        Core.source = t2,
        Core.timestamp = 1387929601314159265,       -- 25 Dec + pi
        Core.payload = Core.Measurement 3.141592        -- pi
    }

  in do
    it "correctly forms an object label" $ do
        let l1 = formBucketLabel p1
        assertEqual "Incorrect label"
            (S.pack "v01_arithmetic_ABCD_1387900000") l1

    it "two labels in same mark match" $ do
        let l1 = formBucketLabel p1
        let l2 = formBucketLabel p2
        assertEqual "Map should be sorted, time mark div 10^6" l1 l2
