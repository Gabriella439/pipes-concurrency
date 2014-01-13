
module Pipes.Concurrent.Broadcast (
    Broadcast(..),
    spawnBroadcast,
    spawnBroadcast',
    dupBroadcast
    ) where

import Control.Applicative ((<|>), (<*), (<$>))
import Control.Concurrent.STM
    (STM, TVar, atomically, newTVarIO, writeTVar, readTVar, check)
import Control.Concurrent.STM.TChan
    (TChan, newBroadcastTChanIO, dupTChan, writeTChan, readTChan)
import Data.IORef (newIORef, readIORef, mkWeakIORef)
import Pipes.Concurrent (Input(..), Output(..))
import GHC.Conc.Sync (unsafeIOToSTM)

newtype Broadcast a = Broadcast (TChan a, TVar Bool)

spawnBroadcast :: IO (Output a, Broadcast a)
spawnBroadcast = fmap simplify spawnBroadcast'
  where
    simplify (output, input, _) = (output, input)

spawnBroadcast' :: IO (Output a, Broadcast a, STM ())
spawnBroadcast' = do
    ch <- newBroadcastTChanIO

    sealed <- newTVarIO False
    let seal = writeTVar sealed True

    rSend <- newIORef ()
    mkWeakIORef rSend (atomically seal)

    let sendOrEnd x = do
            b <- readTVar sealed
            if b
                then return False
                else do
                    writeTChan ch x
                    return True
        _send x = sendOrEnd x <* unsafeIOToSTM (readIORef rSend)
    return (Output _send, Broadcast (ch, sealed), seal)
{-# INLINABLE spawnBroadcast #-}

dupBroadcast :: Broadcast a -> IO (Input a)
dupBroadcast (Broadcast (ch, sealed)) = do
    nch <- atomically (dupTChan ch)

    let _recv = (Just <$> readTChan ch) <|> (do
            b <- readTVar sealed
            check b
            return Nothing )
    return (Input _recv)
{-# INLINABLE dupBroadcast #-}

