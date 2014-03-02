--
-- Data vault for metrics
--
-- Copyright © 2013-2014 Operational Dynamics Consulting, Pty Ltd
-- Copyright © 2013-2014 Anchor Systems, Pty Ltd and Others
--
-- The code in this file, and the program it is a part of, is
-- made available to you by its authors as open source software:
-- you can redistribute it and/or modify it under the terms of
-- the BSD licence.
--


import Data.Char (toUpper)
import Distribution.Text (display)
import Distribution.PackageDescription (PackageDescription(..))
import Distribution.Simple
import Distribution.Simple.LocalBuildInfo (LocalBuildInfo)
import Distribution.Simple.Setup (ConfigFlags)
import Distribution.System (OS (..), buildOS)
import System.IO (IOMode (..), Handle, hPutStrLn, withFile)

main :: IO ()
main = defaultMainWithHooks $ simpleUserHooks {
       postConf = configure
    }

{-
    Simple detection of which operating system we're building on;
    there's no need to link the Cabal logic into our actual library or
    program, so we'll just use CPP in the top level code.
-}

configure :: Args -> ConfigFlags -> PackageDescription -> LocalBuildInfo -> IO ()
configure _ _ p _  = do

    withFile "config.h" WriteMode (\h -> do
        discoverOperatingSystem h
        discoverLibraryVersion h p)

    return ()

discoverOperatingSystem :: Handle -> IO ()
discoverOperatingSystem h = do
        hPutStrLn h ("#define " ++ s)

  where
    o = buildOS

    s = case o of
            Linux   -> "__LINUX__"
            OSX     -> "__MACOSX__"
            Windows -> "__WINDOWS__"
            _       -> "__" ++ up o ++ "__"

    up x = map toUpper (show x)

discoverLibraryVersion :: Handle -> PackageDescription -> IO ()
discoverLibraryVersion h p = do
        hPutStrLn h ("#define VERSION \"" ++ s ++ "\"")

  where
    i = package p
    v = pkgVersion i
    s = display v

