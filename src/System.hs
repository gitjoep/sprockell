{-# LANGUAGE RecordWildCards #-}
module System where

import Control.Monad
import System.IO
import Data.Bits
import Data.Char
import Debug.Trace
import TypesEtc
import Sprockell
import PseudoRandom

-- Constants
bufferSize  = 2 -- bufferSize >  0
memorySize  = 6 -- memorySize >= 0
randomStart = 0 -- Change for different random behaviour


-- ===========================================================================================
-- IO Devices
-- ===========================================================================================
--              Shared memory    Request         Memory, reply to sprockell
type IODevice = Memory        -> SprockellOut -> IO (Memory, Reply)

memDevice :: IODevice
memDevice mem (addr, ReadReq)        = return (mem, Just $ mem !! addr)
memDevice mem (addr, WriteReq value) = return (mem <~ (addr, value), Nothing)
memDevice mem (addr, TestReq)        = return (mem <~ (addr, test),  Just test)
    where
       test  = tobit $ testBit (mem !! addr) 0

stdDevice :: IODevice
stdDevice mem (_, WriteReq value) = putChar (chr value) >> return (mem, Nothing)
stdDevice _   (a, TestReq) = error ("TestAndSet not supported on address: " ++ show a)
stdDevice mem (_, ReadReq) = fmap ((,) mem) $ do
    rdy <- hReady stdin
    if rdy
        then fmap (Just . ord) getChar        
        else return (Just (-1))
        
-- ===========================================================================================
-- ===========================================================================================
mapAddress :: Int -> IODevice
mapAddress addr | addr <= 0xFFFFFF = memDevice
                | otherwise        = stdDevice

catRequests :: [(SprockellID, Maybe SprockellOut)] -> [(SprockellID, SprockellOut)]
catRequests [] = []
catRequests ((_, Nothing):reqs)  =          catRequests reqs
catRequests ((n, Just s):reqs)   = (n, s) : catRequests reqs

processRequest :: [(SprockellID, SprockellOut)] -> [Value] -> IO ([Value], (Int, Maybe Value))
processRequest []                   mem = return (mem, (0, Nothing))
processRequest ((SprID spr, out):_) mem = do
        let ioDevice   = mapAddress (fst out)
        (mem', reply)  <- ioDevice mem out
        return (mem', (spr, reply))

system :: SystemState -> IO SystemState
system SysState{..} = do 
        let newToQueue        = shuffle cycleCount $ zip [0..] (map head buffersS2M)
        let queue'            = queue ++ (catRequests $ newToQueue)
        (mem', reply)         <- processRequest queue' sharedMem
        let replies           = (replicate (length sprs) Nothing) <~ reply
        let (sprs', sprOutps) = unzip $ zipWith (sprockell instrs) sprs (map head buffersM2S) 

        -- Update delay queues
        let buffersM2S'       = zipWith (<+) buffersM2S replies
        let buffersS2M'       = zipWith (<+) buffersS2M sprOutps

        return (SysState instrs sprs' buffersS2M' buffersM2S' (drop 1 queue') mem' (succ cycleCount))

xs <+ x = drop 1 xs ++ [x]

-- ===========================================================================================
-- ===========================================================================================
-- "Simulates" sprockells by recursively calling them over and over again
simulate :: (SystemState -> String) -> SystemState -> IO SystemState
simulate debugFunc sysState
    | all halted (sprs sysState) = return sysState
    | otherwise   = do
       	sysState' <- system sysState
        putStr (debugFunc sysState')
        simulate debugFunc sysState'

-- ===========================================================================================
-- ===========================================================================================
-- Initialise SystemState for N sprockells
initSystemState :: Int -> [Instruction] -> SystemState
initSystemState n is = SysState
        { instrs     = is
        , sprs       = map initSprockell [0..n]
        , buffersS2M = replicate n (replicate bufferSize Nothing)
        , buffersM2S = replicate n (replicate bufferSize Nothing)
        , queue      = []
        , sharedMem  = replicate memorySize 0
        , cycleCount = randomStart
        }
 
run :: Int -> [Instruction] -> IO SystemState
run = runDebug (const "")

runDebug :: (SystemState -> String) -> Int -> [Instruction] -> IO SystemState
runDebug debugFunc n instrs = simulate debugFunc (initSystemState n instrs)
