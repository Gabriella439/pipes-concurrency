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

module Control.Proxy.Concurrent (
    -- * Spawn mailboxes
    spawn,
    Buffer(..),
    Input,
    Output,

    -- * Send and receive messages
    send,
    recv,

    -- * Proxy utilities
    sendD,
    recvS,

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
import qualified Control.Proxy as P
import Data.IORef (newIORef, readIORef, mkWeakIORef)
import Data.Monoid (Monoid(mempty, mappend))
import GHC.Conc.Sync (unsafeIOToSTM)
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
    rUp  <- newIORef ()
    doneUp <- S.newTVarIO False
    mkWeakIORef rUp (S.atomically $ S.writeTVar doneUp True)

    {- Use an IORef to keep track of whether the 'Output' end has been garbage
       collected and run a finalizer when the collection occurs
    -}
    rDn  <- newIORef ()
    doneDn <- S.newTVarIO False
    mkWeakIORef rDn (S.atomically $ S.writeTVar doneDn True)

    let sendOrEnd a = do
          b <- S.readTVar doneDn
          if b
          then return False
          else do
            write a
            return True
        readTestEnd = do
          b <- S.readTVar doneUp
          S.check b
          return Nothing
        {- The '_send' action aborts if the 'Output' has been garbage collected,
           since there is no point wasting memory if nothing can empty the
           mailbox.  This protects against careless users not checking send's
           return value, especially if they use a mailbox of 'Unbounded' size.
        -}
        _send a = sendOrEnd a <* unsafeIOToSTM (readIORef rUp)
        _recv = (Just <$> read <|> readTestEnd) <* unsafeIOToSTM (readIORef rDn)
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

{-| Writes all messages flowing \'@D@\'ownstream to the given 'Input'

    'sendD' terminates when the corresponding 'Output' is garbage collected.

> sendD :: (P.Proxy p) => Input a -> () -> Pipe p a a IO ()
-}
sendD :: (P.Proxy p) => Input a -> x -> p x a x a IO ()
sendD input = P.runIdentityK loop
  where
    loop x = do
        a <- P.request x
        alive <- P.lift $ S.atomically $ send input a
        if alive
            then do
                x2 <- P.respond a
                loop x2
            else return ()
{-# INLINABLE sendD #-}

{-| Convert an 'Output' to a 'P.Producer'

    'recvS' terminates when the 'Buffer' is empty and the corresponding 'Input'
    is garbage collected.

> recvS :: (Proxy p) => Output a -> () -> Producer p a IO ()
-}
recvS :: (P.Proxy p) => Output a -> r -> p x' x y' a IO r
recvS output r = P.runIdentityP go
  where
    go = do
        ma <- P.lift $ S.atomically $ recv output
        case ma of
            Nothing -> return r
            Just a  -> do
                P.respond a
                go
{-# INLINABLE recvS #-}

{- $reexport
    @Control.Concurrent@ re-exports 'forkIO', although I recommend using the
    @async@ library instead.

    @Control.Concurrent.STM@ re-exports 'atomically' and 'STM'.

    @System.Mem@ re-exports 'performGC'.
-}
