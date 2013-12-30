--
-- Data vault for metrics
--
-- Copyright © 2013-     Anchor Systems, Pty Ltd and Others
--
-- The code in this file, and the program it is a part of, is
-- made available to you by its authors as open source software:
-- you can redistribute it and/or modify it under the terms of
-- the BSD licence.
--

{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# OPTIONS -fno-warn-unused-imports #-}

module Vaultaire.Conversion.Transmitter (
    createDataFrame,
    encodePoints
) where

--
-- Otherwise redundent imports, but useful for testing in GHCi.
--


--
-- Code begins
--

import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as S
import Data.Hex
import Data.Int (Int64)
import Data.List (intercalate)
import qualified Data.List as List
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Monoid (Monoid, mempty)
import Data.ProtocolBuffers hiding (field)
import Data.Serialize
import Data.Text (Text)
import qualified Data.Text as T
import Data.Typeable (Typeable)
import Data.Word (Word32, Word64)

import qualified Vaultaire.Internal.CoreTypes as Core
import qualified Vaultaire.Serialize.WireFormat as Protobuf


--
-- Conversion from our internal types to a the Data.Protobuf representation,
-- suitable for subsequent encoding.
--
createDataFrame :: Core.Point -> Protobuf.DataFrame
createDataFrame p =
  let
    tags =
           Map.elems $ Map.mapWithKey createSourceTag (Core.source p)
  in
    case Core.payload p of
        Core.Empty       ->
            Protobuf.DataFrame {
                Protobuf.source = putField tags,
                Protobuf.timestamp = putField $ Core.timestamp p,
                Protobuf.payload = putField Protobuf.EMPTY,
                Protobuf.valueNumeric = mempty,
                Protobuf.valueMeasurement = mempty,
                Protobuf.valueTextual = mempty,
                Protobuf.valueBlob = mempty
            }
        Core.Numeric n   ->
            Protobuf.DataFrame {
                Protobuf.source = putField tags,
                Protobuf.timestamp = putField $ Core.timestamp p,
                Protobuf.payload = putField Protobuf.NUMBER,
                Protobuf.valueNumeric = putField (Just n),
                Protobuf.valueMeasurement = mempty,
                Protobuf.valueTextual = mempty,
                Protobuf.valueBlob = mempty
            }
        Core.Measurement r ->
            Protobuf.DataFrame {
                Protobuf.source = putField tags,
                Protobuf.timestamp = putField $ Core.timestamp p,
                Protobuf.payload = putField Protobuf.REAL,
                Protobuf.valueNumeric = mempty,
                Protobuf.valueMeasurement = putField (Just r),
                Protobuf.valueTextual = mempty,
                Protobuf.valueBlob = mempty
            }
        Core.Textual t   ->
            Protobuf.DataFrame {
                Protobuf.source = putField tags,
                Protobuf.timestamp = putField $ Core.timestamp p,
                Protobuf.payload = putField Protobuf.TEXT,
                Protobuf.valueNumeric = mempty,
                Protobuf.valueMeasurement = mempty,
                Protobuf.valueTextual = putField (Just t),
                Protobuf.valueBlob = mempty
            }
        Core.Blob b'     ->
            Protobuf.DataFrame {
                Protobuf.source = putField tags,
                Protobuf.timestamp = putField $ Core.timestamp p,
                Protobuf.payload = putField Protobuf.BINARY,
                Protobuf.valueNumeric = mempty,
                Protobuf.valueMeasurement = mempty,
                Protobuf.valueTextual = mempty,
                Protobuf.valueBlob = putField (Just b')
            }


createSourceTag :: Text -> Text -> Protobuf.SourceTag
createSourceTag k v =
    Protobuf.SourceTag {
        Protobuf.field = putField k,
        Protobuf.value = putField v
    }


{-
    Encoding and decoding. This is phrased in terms of lists at the moment,
    which will likely be horribly inefficient at any kind of scale. If so we
    can switch to Vectors (if allocation is the problem) and/or io-streams (if
    we need streaming).
-}


encodePoints :: [Core.Point] -> S.ByteString
encodePoints ps =
  let
    xs = List.map createDataFrame ps
    y  = Protobuf.DataBurst {
            Protobuf.frames = putField xs
         }
  in
    runPut $ encodeMessage y
