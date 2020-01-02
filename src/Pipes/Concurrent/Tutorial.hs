{-| This module provides a tutorial for the @pipes-concurrency@ library.

    This tutorial assumes that you have read the @pipes@ tutorial in
    @Pipes.Tutorial@.

    I've condensed all the code examples into self-contained code listings in
    the Appendix section that you can use to follow along.
-}

module Pipes.Concurrent.Tutorial (
    -- * Introduction
    -- $intro

    -- * Work Stealing
    -- $steal

    -- * Termination
    -- $termination

    -- * Mailbox Sizes
    -- $mailbox

    -- * Broadcasts
    -- $broadcast

    -- * Updates
    -- $updates

    -- * Callbacks
    -- $callback

    -- * Safety
    -- $safety

    -- * Conclusion
    -- $conclusion

    -- * Appendix
    -- $appendix
    ) where

import Control.Concurrent
import Control.Monad
import Pipes
import Pipes.Concurrent
import qualified Pipes.Prelude as P
import Data.Monoid

{- $intro
    The @pipes-concurrency@ library provides a simple interface for
    communicating between concurrent pipelines.  Use this library if you want
    to:

    * merge multiple streams into a single stream,

    * stream data from a callback \/ continuation,

    * broadcast data,

    * build a work-stealing setup, or

    * implement basic functional reactive programming (FRP).

    For example, let's say that we want to design a simple game with two
    concurrent sources of game @Event@s.

    One source translates user input to game events:

> -- The game events
> data Event = Harm Integer | Heal Integer | Quit deriving (Show)
>
> user :: IO Event
> user = do
>     command <- getLine
>     case command of
>         "potion" -> return (Heal 10)
>         "quit"   -> return  Quit
>         _        -> do
>             putStrLn "Invalid command"
>             user  -- Try again

    ... while the other creates inclement weather:

> import Control.Concurrent (threadDelay)
> import Control.Monad (forever)
> import Pipes
>
> acidRain :: Producer Event IO r
> acidRain = forever $ do
>     lift $ threadDelay 2000000  -- Wait 2 seconds
>     yield (Harm 1)

    We can asynchronously merge these two separate sources of @Event@s into a
    single stream by 'spawn'ing a first-in-first-out (FIFO) mailbox:

@
 'spawn' :: 'Buffer' a -> 'IO' ('Output' a, 'Input' a)
@

    'spawn' takes a 'Buffer' as an argument which specifies how many messages to
    store.  In this case we want our mailbox to store an 'Unbounded' number of
    messages:

> import Pipes.Concurrent
> 
> main = do
>     (output, input) <- spawn Unbounded
>     ...

   'spawn' creates this mailbox in the background and then returns two values:

    * an @(Output a)@ that we use to add messages of type @a@ to the mailbox

    * an @(Input a)@ that we use to consume messages of type @a@ from the
      mailbox

    We will be streaming @Event@s through our mailbox, so our @output@ has type
    @(Output Event)@ and our @input@ has type @(Input Event)@.

    To stream @Event@s into the mailbox , we use 'toOutput', which writes values
    to the mailbox's 'Output' end:

@
 'toOutput' :: ('MonadIO' m) => 'Output' a -> 'Consumer' a m ()
@

    We can concurrently forward multiple streams to the same 'Output', which
    asynchronously merges their messages into the same mailbox:

>     ...
>     forkIO $ do runEffect $ lift user >~  toOutput output
>                 performGC  -- I'll explain 'performGC' below
> 
>     forkIO $ do runEffect $ acidRain  >-> toOutput output
>                 performGC
>     ...

    To stream @Event@s out of the mailbox, we use 'fromInput', which streams
    values from the mailbox's 'Input' end using a 'Producer':

@
 'fromInput' :: ('MonadIO' m) => 'Input' a -> 'Producer' a m ()
@

    For this example we'll build a 'Consumer' to handle this stream of @Event@s,
    that either harms or heals our intrepid adventurer depending on which
    @Event@ we receive:

> handler :: Consumer Event IO ()
> handler = loop 100
>   where
>     loop health = do
>         lift $ putStrLn $ "Health = " ++ show health
>         event <- await
>         case event of
>             Harm n -> loop (health - n)
>             Heal n -> loop (health + n)
>             Quit   -> return ()

    Now we can just connect our @Event@ 'Producer' to our @Event@ 'Consumer'
    using ('>->'):

>     ...
>     runEffect $ fromInput input >-> handler

    Our final @main@ looks like this:

> main = do
>     (output, input) <- spawn Unbounded
>
>     forkIO $ do runEffect $ lift user >~  toOutput output
>                 performGC  
>
>     forkIO $ do runEffect $ acidRain  >-> toOutput output
>                 performGC
>
>     runEffect $ fromInput input >-> handler

    ... and when we run it we get the desired concurrent behavior:

> $ ./game
> Health = 100
> Health = 99
> Health = 98
> potion<Enter>
> Health = 108
> Health = 107
> Health = 106
> potion<Enter>
> Health = 116
> Health = 115
> quit<Enter>
> $
-}

{- $mailbox
    When we find it convenient we can use the 'Mailbox' type, which just
    combines an 'Output' a with an 'Input' a together.

    So, we had the previous code:

> main = do
>     (output, input) <- spawn Unbounded
>
>     forkIO $ do runEffect $ lift user >~  toOutput output
>                 performGC
>
>     forkIO $ do runEffect $ acidRain  >-> toOutput output
>                 performGC
>
>     runEffect $ fromInput input >-> handler

    It could be changed into this equivalent implementation:

> main = do
>     mailbox <- spawn Unbounded
>
>     forkIO $ do runEffect $ lift user >~  toMailbox mailbox
>                 performGC
>
>     forkIO $ do runEffect $ acidRain  >-> toMailbox mailbox
>                 performGC
>
>     runEffect $ fromMailbox mailbox >-> handler

    Behavior continues to be exactly the same, as expected.

    Real implementation can change, but we can think 'Mailbox' as the
    following type:

> type Mailbox a = (Output a, Input a)
-}

{- $steal
    You can also have multiple pipes reading from the same mailbox.  Messages
    get split between listening pipes on a first-come first-serve basis.

    For example, we'll define a \"worker\" that takes a one-second break each
    time it receives a new job:

> import Control.Concurrent (threadDelay)
> import Control.Monad
> import Pipes
> 
> worker :: (Show a) => Int -> Consumer a IO r
> worker i = forever $ do
>     a <- await
>     lift $ threadDelay 1000000  -- 1 second
>     lift $ putStrLn $ "Worker #" ++ show i ++ ": Processed " ++ show a

    Fortunately, these workers are cheap, so we can assign several of them to
    the same job:

> import Control.Concurrent.Async
> import qualified Pipes.Prelude as P
> import Pipes.Concurrent
> 
> main = do
>     (output, input) <- spawn Unbounded
>     as <- forM [1..3] $ \i ->
>           async $ do runEffect $ fromInput input  >-> worker i
>                      performGC
>     a  <- async $ do runEffect $ each [1..10] >-> toOutput output
>                      performGC
>     mapM_ wait (a:as)

    The above example uses @Control.Concurrent.Async@ from the @async@ package
    to fork each thread and wait for all of them to terminate:

> $ ./work
> Worker #2: Processed 3
> Worker #1: Processed 2
> Worker #3: Processed 1
> Worker #3: Processed 6
> Worker #1: Processed 5
> Worker #2: Processed 4
> Worker #2: Processed 9
> Worker #1: Processed 8
> Worker #3: Processed 7
> Worker #2: Processed 10
> $

    What if we replace 'each' with a different source that reads lines from user
    input until the user types \"quit\":

> user :: Producer String IO ()
> user = P.stdinLn >-> P.takeWhile (/= "quit")
> 
> main = do
>     (output, input) <- spawn Unbounded
>     as <- forM [1..3] $ \i ->
>           async $ do runEffect $ fromInput input >-> worker i
>                      performGC
>     a  <- async $ do runEffect $ user >-> toOutput output
>                      performGC
>     mapM_ wait (a:as)

    This still produces the correct behavior:

> $ ./work
> Test<Enter>
> Worker #1: Processed "Test"
> Apple<Enter>
> Worker #2: Processed "Apple"
> 42<Enter>
> Worker #3: Processed "42"
> A<Enter>
> B<Enter>
> C<Enter>
> Worker #1: Processed "A"
> Worker #2: Processed "B"
> Worker #3: Processed "C"
> quit<Enter>
> $
-}

{- $termination

    Wait...  How do the workers know when to stop listening for data?  After
    all, anything that has a reference to 'Output' could potentially add more
    data to the mailbox.

    It turns out that 'spawn' is smart and instruments the 'Input' to
    terminate when the 'Output' is garbage collected.  'fromInput' builds on top
    of the more primitive 'recv' command, which returns a 'Nothing' when the
    'Input' terminates:

@
 'recv' :: 'Input' a -> 'STM' ('Maybe' a)
@

    Otherwise, 'recv' will block if the mailbox is empty since if the 'Output'
    has not been garbage collected then somebody might still produce more data.

    Does it work the other way around?  What happens if the workers go on strike
    before processing the entire data set?

>     ...
>     as <- forM [1..3] $ \i ->
>           -- Each worker refuses to process more than two values
>           async $ do runEffect $ fromInput input >-> P.take 2 >-> worker i
>                      performGC
>     ...

    Let's find out:

> $ ./work
> How<Enter>
> Worker #1: Processed "How"
> many<Enter>
> roads<Enter>
> Worker #2: Processed "many"
> Worker #3: Processed "roads"
> must<Enter>
> a<Enter>
> man<Enter>
> Worker #1: Processed "must"
> Worker #2: Processed "a"
> Worker #3: Processed "man"
> walk<Enter>
> $

    'spawn' tells the 'Output' to similarly terminate when the 'Input' is
    garbage collected, preventing the user from submitting new values.
    'toOutput' builds on top of the more primitive 'send' command, which returns
    a 'False' when the 'Output' terminates:

@
 'send' :: 'Output' a -> a -> 'STM' 'Bool'
@

    Otherwise, 'send' will blocks if the mailbox is full, since if the 'Input'
    has not been garbage collected then somebody could still consume a value
    from the mailbox, making room for a new value.

    This is why we have to insert 'performGC' calls whenever we release a
    reference to either the 'Output' or 'Input'.  Without these calls we cannot
    guarantee that the garbage collector will trigger and notify the opposing
    end if the last reference was released.

    There are two ways to avoid using 'performGC'.  First, you can omit the
    'performGC' call, which is safe and preferable for long-running programs.
    This simply delays garbage collecting mailboxes until the next garbage
    collection cycle.

    Second, you can use the 'spawn'' command, which returns a third @seal@
    action:

> (output, input, seal) <- spawn' buffer
> ...

    Use this to @seal@ the mailbox so that it cannot receive new messages.  This
    allows both readers and writers to shut down early without relying on
    garbage collection:

    * writers will shut down immediately because they can no longer write to the
      mailbox

    * readers will shut down when the mailbox goes empty because they know that
      no new data will arrive

    For simplicity, this tutorial will continue to use `performGC` since all
    the examples are short-lived programs that do not build up a large heap.
    However, when the heap grows large you want to avoid `performGC` and
    consider using one of the above two alternatives instead.

    Note only 'Input's and 'Output's specifically built using 'spawn' or
    'spawn'' make use of the garbage collector.  If you build your own custom
    'Input's and 'Output's then you do not need to use 'performGC' at all.
-}

{- $mailbox
    So far we haven't observed 'send' blocking because we only 'spawn'ed
    'Unbounded' mailboxes.  However, we can control the size of the mailbox to
    tune the coupling between the 'Output' and the 'Input' ends.

    If we set the mailbox 'Buffer' to 'Single', then the mailbox holds exactly
    one message, forcing synchronization between 'send's and 'recv's.  Let's
    observe this by sending an infinite stream of values, logging all values to
    the console:

> main = do
>     (output, input) <- spawn Single
>     as <- forM [1..3] $ \i ->
>           async $ do runEffect $ fromInput input >-> P.take 2 >-> worker i
>                      performGC
>     a  <- async $ do runEffect $ each [1..] >-> P.chain print >-> toOutput output
>                      performGC
>     mapM_ wait (a:as)

    The 7th value gets stuck in the mailbox, and the 8th value blocks because
    the mailbox never clears the 7th value:

> $ ./work
> 1
> 2
> 3
> 4
> 5
> Worker #3: Processed 3
> Worker #2: Processed 2
> Worker #1: Processed 1
> 6
> 7
> 8
> Worker #1: Processed 6
> Worker #2: Processed 5
> Worker #3: Processed 4
> $

    Contrast this with an 'Unbounded' mailbox for the same program, which keeps
    accepting values until downstream finishes processing the first six values:

> $ ./work
> 1
> 2
> 3
> 4
> 5
> 6
> 7
> 8
> 9
> ...
> 487887
> 487888
> Worker #3: Processed 3
> Worker #2: Processed 2
> Worker #1: Processed 1
> 487889
> 487890
> ...
> 969188
> 969189
> Worker #1: Processed 6
> Worker #2: Processed 5
> Worker #3: Processed 4
> 969190
> 969191
> $

    You can also choose something in between by using a 'Bounded' mailbox which
    caps the mailbox size to a fixed value.  Use 'Bounded' when you want mostly
    loose coupling but still want to guarantee bounded memory usage:

> main = do
>     (output, input) <- spawn (Bounded 100)
>     ...

> $ ./work
> ...
> 103
> 104
> Worker #3: Processed 3
> Worker #2: Processed 2
> Worker #1: Processed 1
> 105
> 106
> 107
> Worker #1: Processed 6
> Worker #2: Processed 5
> Worker #3: Processed 4
> $
-}

{- $broadcast
    You can also broadcast data to multiple listeners instead of dividing up the
    data.  Just use the 'Monoid' instance for 'Output' to combine multiple
    'Output' ends together into a single broadcast 'Output':

> -- broadcast.hs
>
> import Control.Monad
> import Control.Concurrent.Async
> import Pipes
> import Pipes.Concurrent
> import qualified Pipes.Prelude as P
> import Data.Monoid
> 
> main = do
>     (output1, input1) <- spawn Unbounded
>     (output2, input2) <- spawn Unbounded
>     a1 <- async $ do
>         runEffect $ P.stdinLn >-> toOutput (output1 <> output2)
>         performGC
>     as <- forM [input1, input2] $ \input -> async $ do
>         runEffect $ fromInput input >-> P.take 2 >-> P.stdoutLn
>         performGC
>     mapM_ wait (a1:as)

    In the above example, 'P.stdinLn' will broadcast user input to both
    mailboxes, and each mailbox forwards its values to 'P.stdoutLn', echoing the
    message to standard output:

> $ ./broadcast
> ABC<Enter>
> ABC
> ABC
> DEF<Enter>
> DEF
> DEF
> GHI<Enter>
> $ 

    The combined 'Output' stays alive as long as any of the original 'Output's
    remains alive.  In the above example, 'toOutput' terminates on the third
    'send' attempt because it detects that both listeners died after receiving
    two messages.

    Use 'mconcat' to broadcast to a list of 'Output's, but keep in mind that you
    will incur a performance price if you combine thousands of 'Output's or more
    because they will create a very large 'STM' transaction.  You can improve
    performance for very large broadcasts if you sacrifice atomicity and
    manually combine multiple 'send' actions in 'IO' instead of 'STM'.
-}

{- $updates
    Sometimes you don't want to handle every single event.  For example, you
    might have an input and output device (like a mouse and a monitor) where the
    input device updates at a different pace than the output device

> import Control.Concurrent (threadDelay)
> import Control.Monad
> import Pipes
> import qualified Pipes.Prelude as P
> 
> -- Fast input updates
> inputDevice :: (Monad m) => Producer Integer m ()
> inputDevice = each [1..]
> 
> -- Slow output updates
> outputDevice :: Consumer Integer IO r
> outputDevice = forever $ do
>     n <- await
>     lift $ do
>         print n
>         threadDelay 1000000

    In this scenario you don't want to enforce a one-to-one correspondence
    between input device updates and output device updates because you don't
    want either end to block waiting for the other end.  Instead, you just need
    the output device to consult the 'Latest' value received from the 'Input':

> import Control.Concurrent.Async
> import Pipes.Concurrent
> 
> main = do
>     (output, input) <- spawn (Latest 0)
>     a1 <- async $ do runEffect $ inputDevice >-> toOutput output
>                      performGC
>     a2 <- async $ do runEffect $ fromInput input >-> P.take 5 >-> outputDevice
>                      performGC
>     mapM_ wait [a1, a2]

    'Latest' selects a mailbox that always stores exactly one value.  The
    'Latest' constructor takes a single argument (@0@, in the above example)
    specifying the starting value to store in the mailbox.  'send' overrides the
    currently stored value and 'recv' peeks at the latest stored value without
    consuming it.  In the above example the @outputDevice@ periodically peeks at    the latest value stashed inside the mailbox:

> $ ./peek
> 7
> 2626943
> 5303844
> 7983519
> 10604940
> $

    A 'Latest' mailbox is never empty because it begins with a default value and
    'recv' never removes the value from the mailbox.  A 'Latest' mailbox is also
    never full because 'send' always succeeds, overwriting the previously stored
    value.

    Another alternative is to use the 'Newest' mailbox, which is like a
    'Bounded' mailbox, except 'send' never blocks (the mailbox is never full).
    Instead, if there is no room 'send' will remove the oldest message from the
    mailbox to make room for a new message.

    The 'New' mailbox is like the 'Newest' mailbox, except optimized for the
    special case where you want to store a single message.  You can use 'New' to
    read from a source that might potentially update rapidly, but still sleep if
    the source has no new values:

> inputDevice :: Producer Integer IO ()
> inputDevice = do
>     each [1..100]               -- Rapid updates
>     lift $ threadDelay 4000000  -- Source goes quiet for 4 seconds
>     each [101..]                -- More rapid updates
>
> main = do
>     (output, input) <- spawn New
>     ...

    When the source goes quiet, the 'Input' will now block and wait, and will
    never read the same value twice:

> $ ./peek
> 7
> 100
> <Longer pause>
> 16793
> 5239440
> 10474439
> $

-}

{- $callback
    @pipes-concurrency@ also solves the common problem of getting data out of a
    callback-based framework into @pipes@.

    For example, suppose that we have the following callback-based function:

> import Control.Monad
> 
> onLines :: (String -> IO a) -> IO b
> onLines callback = forever $ do
>     str <- getLine
>     callback str

    We can use 'send' to free the data from the callback and then we can
    retrieve the data on the outside using 'fromInput':

> import Pipes
> import Pipes.Concurrent
> import qualified Pipes.Prelude as P
> 
> onLines' :: Producer String IO ()
> onLines' = do
>     (output, input) <- lift $ spawn Single
>     lift $ forkIO $ onLines (\str -> atomically $ send output str)
>     fromInput input
> 
> main = runEffect $ onLines' >-> P.takeWhile (/= "quit") >-> P.stdoutLn

    Now we can stream from the callback as if it were an ordinary 'Producer':

> $ ./callback
> Test<Enter>
> Test
> Apple<Enter>
> Apple
> quit<Enter>
> $

-}

{- $safety
    @pipes-concurrency@ avoids deadlocks because 'send' and 'recv' always
    cleanly return before triggering a deadlock.  This behavior works even in
    complicated scenarios like:

    * cyclic graphs of connected mailboxes,

    * multiple readers and multiple writers to the same mailbox, and

    * dynamically adding or garbage collecting mailboxes.

    The following example shows how @pipes-concurrency@ will do the right thing
    even in the case of cycles:

> -- cycle.hs
>
> import Control.Concurrent.Async
> import Pipes
> import Pipes.Concurrent
> import qualified Pipes.Prelude as P
> 
> main = do
>     (out1, in1) <- spawn Unbounded
>     (out2, in2) <- spawn Unbounded
>     a1 <- async $ do
>         runEffect $ (each [1,2] >> fromInput in1) >-> toOutput out2
>         performGC
>     a2 <- async $ do
>         runEffect $ fromInput in2 >-> P.chain print >-> P.take 6 >-> toOutput out1
>         performGC
>     mapM_ wait [a1, a2]

    The above program jump-starts a cyclic chain with two input values and
    terminates one branch of the cycle after six values flow through.  Both
    branches correctly terminate and get garbage collected without triggering
    deadlocks when 'takeB_' finishes:

> $ ./cycle
> 1
> 2
> 1
> 2
> 1
> 2
> $

-}

{- $conclusion
    @pipes-concurrency@ adds an asynchronous dimension to @pipes@.  This
    promotes a natural division of labor for concurrent programs:

    * Fork one pipeline per deterministic behavior

    * Communicate between concurrent pipelines using @pipes-concurrency@

    This promotes an actor-style approach to concurrent programming where
    pipelines behave like processes and mailboxes behave like ... mailboxes.

    You can ask questions about @pipes-concurrency@ and other @pipes@ libraries
    on the official @pipes@ mailing list at
    <mailto:haskell-pipes@googlegroups.com>.
-}

{- $appendix
    I've provided the full code for the above examples here so you can easily
    try them out:

>-- game.hs
>
>import Control.Concurrent (threadDelay)
>import Control.Monad (forever)
>import Pipes
>import Pipes.Concurrent
>
>data Event = Harm Integer | Heal Integer | Quit deriving (Show)
>
>user :: IO Event
>user = do
>    command <- getLine
>    case command of
>        "potion" -> return (Heal 10)
>        "quit"   -> return  Quit
>        _        -> do
>            putStrLn "Invalid command"
>            user
>
>acidRain :: Producer Event IO r
>acidRain = forever $ do
>    lift $ threadDelay 2000000  -- Wait 2 seconds
>    yield (Harm 1)
>
>handler :: Consumer Event IO ()
>handler = loop 100
>  where
>    loop health = do
>        lift $ putStrLn $ "Health = " ++ show health
>        event <- await
>        case event of
>            Harm n -> loop (health - n)
>            Heal n -> loop (health + n)
>            Quit   -> return ()
>
>main = do
>    (output, input) <- spawn Unbounded
>
>    forkIO $ do runEffect $ lift user >~  toOutput output
>                performGC
>
>    forkIO $ do runEffect $ acidRain  >-> toOutput output
>                performGC
>
>    runEffect $ fromInput input >-> handler

>-- work.hs
>
>import Control.Concurrent (threadDelay)
>import Control.Concurrent.Async
>import Control.Monad
>import Pipes
>import Pipes.Concurrent
>import qualified Pipes.Prelude as P
>
>worker :: (Show a) => Int -> Consumer a IO r
>worker i = forever $ do
>    a <- await
>    lift $ threadDelay 1000000  -- 1 second
>    lift $ putStrLn $ "Worker #" ++ show i ++ ": Processed " ++ show a
>
>user :: Producer String IO ()
>user = P.stdinLn >-> P.takeWhile (/= "quit")
>
>main = do
>--  (output, input) <- spawn Unbounded
>--  (output, input) <- spawn Single
>    (output, input) <- spawn (Bounded 100)
>
>    as <- forM [1..3] $ \i ->
>--        async $ do runEffect $ fromInput input  >-> worker i
>          async $ do runEffect $ fromInput input  >-> P.take 2 >-> worker i
>                     performGC
>
>--  a  <- async $ do runEffect $ each [1..10]                 >-> toOutput output
>--  a  <- async $ do runEffect $ user                         >-> toOutput output
>    a  <- async $ do runEffect $ each [1..] >-> P.chain print >-> toOutput output
>                     performGC
>
>    mapM_ wait (a:as)

>-- peek.hs
>
>import Control.Concurrent (threadDelay)
>import Control.Concurrent.Async
>import Control.Monad
>import Pipes
>import Pipes.Concurrent
>import qualified Pipes.Prelude as P
>
>inputDevice :: (Monad m) => Producer Integer m ()
>inputDevice = each [1..]
>
>outputDevice :: Consumer Integer IO r
>outputDevice = forever $ do
>    n <- await
>    lift $ do
>        print n
>        threadDelay 1000000
>
>main = do
>    (output, input) <- spawn (Latest 0)
>    a1 <- async $ do runEffect $ inputDevice >-> toOutput output
>                     performGC
>    a2 <- async $ do runEffect $ fromInput input >-> P.take 5 >-> outputDevice
>                     performGC
>    mapM_ wait [a1, a2]

>-- callback.hs
>
>import Control.Monad
>import Pipes
>import Pipes.Concurrent
>import qualified Pipes.Prelude as P
>
>onLines :: (String -> IO a) -> IO b
>onLines callback = forever $ do
>    str <- getLine
>    callback str
>
>onLines' :: Producer String IO ()
>onLines' = do
>    (output, input) <- lift $ spawn Single
>    lift $ forkIO $ onLines (\str -> atomically $ send output str)
>    fromInput input
>
>main = runEffect $ onLines' >-> P.takeWhile (/= "quit") >-> P.stdoutLn
-}
