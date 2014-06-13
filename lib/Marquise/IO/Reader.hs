--
-- Copyright © 2013-2014 Anchor Systems, Pty Ltd and Others
--
-- The code in this file, and the program it is a part of, is
-- made available to you by its authors as open source software:
-- you can redistribute it and/or modify it under the terms of
-- the 3-clause BSD licence.
--

{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Marquise.IO.Reader
(
) where

import Marquise.Classes
import Marquise.IO.Connection
import System.ZMQ4(Socket, Dealer)

instance MarquiseReaderMonad IO (Socket Dealer) where
    withReaderConnection broker =
        withConnection ("tcp://" ++ broker ++ ":5570")
    sendReaderRequest = send
    recvReaderResponse = recv
