
module Pipes.Concurrent.Broadcast (
    Broadcast(..),
    spawnBroadcast,
    dupBroadcast
    ) where

import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TChan
    (TChan, newBroadcastTChanIO, dupTChan, writeTChan, readTChan)
import Pipes.Concurrent (Input(..), Output(..))

newtype Broadcast a = Broadcast (TChan a)

spawnBroadcast :: IO (Output a, Broadcast a)
spawnBroadcast = do
    ch <- newBroadcastTChanIO
    let send_ x = do
        writeTChan ch x
        return True
    return (Output send_, Broadcast ch)
{-# INLINABLE spawnBroadcast #-}

dupBroadcast :: Broadcast a -> IO (Input a)
dupBroadcast (Broadcast ch) = do
    nch <- atomically (dupTChan ch)
    let recv_ = do
        x <- readTChan ch
        return (Just x)
    return (Input recv_)
{-# INLINABLE dupBroadcast #-}

