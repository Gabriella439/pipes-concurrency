-- | Asynchronous communication between proxies

{-# LANGUAGE CPP #-}

#if __GLASGOW_HASKELL__ >= 702
{-# LANGUAGE Trustworthy #-}
#endif
{- 'unsafeIOToSTM' requires the Trustworthy annotation.

    I use 'unsafeIOToSTM' to touch an IORef to mark it as still alive. This
    action satisfies the necessary safety requirements because:

    * You can safely repeat it if the transaction rolls back

    * It does not acquire any resources

    * It does not leak any inconsistent view of memory to the outside world

    It appears to be unnecessary to read the IORef to keep it from being garbage
    collected, but I wanted to be absolutely certain since I cannot be sure that
    GHC won't optimize away the reference to the IORef.

    The other alternative was to make 'send' and 'recv' use the 'IO' monad
    instead of 'STM', but I felt that it was important to preserve the ability
    to combine them into larger transactions.
-}

module Pipes.Concurrent (
    -- * Spawn mailboxes
    spawn,
    Buffer(..),
    Input,
    Output,

    -- * Send and receive messages
    send,
    recv,

    -- * Pipe utilities
    toInput,
    fromOutput,

    -- * Re-exports
    -- $reexport
    module Control.Concurrent,
    module Control.Concurrent.STM,
    module System.Mem
    ) where

import Control.Applicative (
    Alternative(empty, (<|>)), Applicative(pure, (<*>)), (<*), (<$>) )
import Control.Concurrent (forkIO)
import Control.Concurrent.STM (atomically, STM)
import qualified Control.Concurrent.STM as S
import Control.Monad (when)
import Data.IORef (newIORef, readIORef, mkWeakIORef)
import Data.Monoid (Monoid(mempty, mappend))
import GHC.Conc.Sync (unsafeIOToSTM)
import Pipes (lift, yield, await)
import Pipes.Core (Producer', Consumer')
import qualified Pipes.Core as P
import System.Mem (performGC)

{-| Spawn a mailbox that has an 'Input' and 'Output' end, using the specified
    'Buffer' to store messages
-}
spawn :: Buffer a -> IO (Input a, Output a)
spawn buffer = do
    (read, write) <- case buffer of
        Bounded n -> do
            q <- S.newTBQueueIO n
            return (S.readTBQueue q, S.writeTBQueue q)
        Unbounded -> do
            q <- S.newTQueueIO
            return (S.readTQueue q, S.writeTQueue q)
        Single    -> do
            m <- S.newEmptyTMVarIO
            return (S.takeTMVar m, S.putTMVar m)
        Latest a  -> do
            t <- S.newTVarIO a
            return (S.readTVar t, S.writeTVar t)

    {- Use an IORef to keep track of whether the 'Input' end has been garbage
       collected and run a finalizer when the collection occurs
    -}
    rSend  <- newIORef ()
    doneSend <- S.newTVarIO False
    mkWeakIORef rSend (S.atomically $ S.writeTVar doneSend True)

    {- Use an IORef to keep track of whether the 'Output' end has been garbage
       collected and run a finalizer when the collection occurs
    -}
    rRecv  <- newIORef ()
    doneRecv <- S.newTVarIO False
    mkWeakIORef rRecv (S.atomically $ S.writeTVar doneRecv True)

    let sendOrEnd a = do
          b <- S.readTVar doneRecv
          if b
            then return False
            else do
              write a
              return True
        readTestEnd = do
          b <- S.readTVar doneSend
          S.check b
          return Nothing
        {- The '_send' action aborts if the 'Output' has been garbage collected,
           since there is no point wasting memory if nothing can empty the
           mailbox.  This protects against careless users not checking send's
           return value, especially if they use a mailbox of 'Unbounded' size.
        -}
        _send a = sendOrEnd a <* unsafeIOToSTM (readIORef rSend)
        _recv = (Just <$> read <|> readTestEnd) <* unsafeIOToSTM (readIORef rRecv)
    return (Input _send, Output _recv)
{-# INLINABLE spawn #-}

{-| 'Buffer' specifies how to store messages sent to the 'Input' end until the
    'Output' receives them.
-}
data Buffer a
    -- | Store an 'Unbounded' number of messages in a FIFO queue
    = Unbounded
    -- | Store a 'Bounded' number of messages, specified by the 'Int' argument
    | Bounded Int
    -- | Store a 'Single' message (like @Bounded 1@, but more efficient)
    | Single
    {-| Store the 'Latest' message, beginning with an initial value

        'Latest' is never empty nor full.
    -}
    | Latest a

-- | Accepts messages for the mailbox
newtype Input a = Input {
    {-| Send a message to the mailbox

        * Fails and returns 'False' if the mailbox's 'Output' has been garbage
          collected (even if the mailbox is not full), otherwise it:

        * Retries if the mailbox is full, or:

        * Succeeds if the mailbox is not full and returns 'True'.
    -}
    send :: a -> S.STM Bool }

instance Monoid (Input a) where
    mempty  = Input (\_ -> return False)
    mappend i1 i2 = Input (\a -> (||) <$> send i1 a <*> send i2 a)

-- | Retrieves messages from the mailbox
newtype Output a = Output {
    {-| Receive a message from the mailbox

        * Succeeds and returns a 'Just' if the mailbox is not empty, otherwise
          it:

        * Retries if mailbox's 'Input' has not been garbage collected, or:

        * Fails if the mailbox's 'Input' has been garbage collected and returns
          'Nothing'.
    -}
    recv :: S.STM (Maybe a) }

instance Functor Output where
    fmap f m = Output (fmap (fmap f) (recv m))

instance Applicative Output where
    pure r    = Output (pure (pure r))
    mf <*> mx = Output ((<*>) <$> recv mf <*> recv mx)

instance Monad Output where
    return r = Output (return (return r))
    m >>= f  = Output $ do
        ma <- recv m
        case ma of
            Nothing -> return Nothing
            Just a  -> recv (f a)

instance Alternative Output where
    empty   = Output empty
    x <|> y = Output (recv x <|> recv y)

{-| Convert an 'Input' to a 'Pipes.Consumer'

    'toInput' terminates when the corresponding 'Output' is garbage collected.
-}
toInput :: Input a -> Consumer' a IO ()
toInput input = loop
  where
    loop = do
        a     <- await
        alive <- lift $ S.atomically $ send input a
        when alive loop
{-# INLINABLE toInput #-}

{-| Convert an 'Output' to a 'Pipes.Producer'

    'fromOutput' terminates when the 'Buffer' is empty and the corresponding
    'Input' is garbage collected.
-}
fromOutput :: Output a -> Producer' a IO ()
fromOutput output = loop
  where
    loop = do
        ma <- lift $ S.atomically $ recv output
        case ma of
            Nothing -> return ()
            Just a  -> do
                yield a
                loop
{-# INLINABLE fromOutput #-}

{- $reexport
    @Control.Concurrent@ re-exports 'forkIO', although I recommend using the
    @async@ library instead.

    @Control.Concurrent.STM@ re-exports 'atomically' and 'STM'.

    @System.Mem@ re-exports 'performGC'.
-}
