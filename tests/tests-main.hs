module Main ( main ) where

import Control.Concurrent
import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Proxy
import Control.Proxy.Concurrent
import System.Exit
import System.IO
import System.Timeout

defaultTimeout = 10^5           -- 0.1 s

labelPrintD :: (Show a, Proxy p) => String -> x -> p x a x a IO r
labelPrintD label = runIdentityK $ foreverK $ \x -> do
  a <- request x
  lift $ putStrLn $ label ++ ": " ++ show a
  respond a

testSenderClose :: Buffer Int -> IO ()
testSenderClose buffer = do
  (input, output) <- spawn buffer
  t1 <- async $ do
    runProxy $ fromListS [1..5] >-> sendD input
    performGC
  t2 <- async $ do
    runProxy $ recvS output >-> execD (threadDelay 1000) >-> printD
    performGC
  wait t1
  wait t2

testSenderCloseDelayedSend :: Buffer Int -> IO ()
testSenderCloseDelayedSend buffer = do
  (input, output) <- spawn buffer
  t1 <- async $ do
    runProxy $ fromListS [1..5] >-> sendD input >-> execD (threadDelay 2000)
    performGC
  t2 <- async $ do
    runProxy $ recvS output >-> execD (threadDelay 1000) >-> printD
    performGC
  wait t1
  wait t2

testReceiverClose :: Buffer Int -> IO ()
testReceiverClose buffer = do
  (input, output) <- spawn buffer
  t1 <- async $ do
    runProxy $ fromListS [1..] >-> sendD input >-> execD (threadDelay 1000) >-> printD
    performGC
  t2 <- async $ do
    runProxy $ recvS output >-> takeB 10
    performGC
  wait t1
  wait t2

testReceiverCloseDelayedReceive :: Buffer Int -> IO ()
testReceiverCloseDelayedReceive buffer = do
  (input, output) <- spawn buffer
  t1 <- async $ do
    runProxy $ fromListS [1..] >-> sendD input >-> execD (threadDelay 1000) >-> labelPrintD "Send"
    performGC
  t2 <- async $ do
    runProxy $ recvS output >-> takeB 10 >-> execD (threadDelay 800) >-> labelPrintD "Recv"
    performGC
  wait t1
  wait t2

runTest :: IO () -> String -> IO ()
runTest test name = do
  putStrLn $ "Starting test: " ++ name
  hFlush stdout
  result <- timeout defaultTimeout test
  case result of
    Nothing -> do putStrLn $ "Test " ++ name ++ " timed out. Aborting."
                  exitFailure
    Just _  -> do putStrLn $ "Test " ++ name ++ " finished."
  hFlush stdout

main = do
  runTest (testSenderClose Unbounded) "UnboundedSenderClose"
  runTest (testSenderClose $ Bounded 3) "BoundedFilledSenderClose"
  runTest (testSenderClose $ Bounded 7) "BoundedNotFilledSenderClose"
  runTest (testSenderClose Single) "SingleSenderClose"
  runTest (testSenderCloseDelayedSend $ Latest 42) "LatestSenderClose"
  --
  runTest (testReceiverClose Unbounded) "UnboundedReceiverClose"
  runTest (testReceiverClose $ Bounded 3) "BoundedFilledReceiverClose"
  runTest (testReceiverClose $ Bounded 7) "BoundedNotFilledReceiverClose"
  runTest (testReceiverClose Single) "SingleReceiverClose"
  runTest (testReceiverCloseDelayedReceive $ Latest 42) "LatestReceiverClose"
