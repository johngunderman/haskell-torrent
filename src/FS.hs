-- Haskell Torrent
-- Copyright (c) 2009, Jesper Louis Andersen,
-- All rights reserved.
--
-- Redistribution and use in source and binary forms, with or without
-- modification, are permitted provided that the following conditions are
-- met:
--
--  * Redistributions of source code must retain the above copyright
--    notice, this list of conditions and the following disclaimer.
--  * Redistributions in binary form must reproduce the above copyright
--    notice, this list of conditions and the following disclaimer in the
--    documentation and/or other materials provided with the distribution.
--
-- THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS
-- IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
-- THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
-- PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR
-- CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
-- EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
-- PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
-- PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
-- LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
-- NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
-- SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

-- | Filesystem routines. These are used for working with and
--   manipulating files in the filesystem.
module FS (PieceInfo(..),
           PieceMap,
           readPiece,
           readBlock,
           writeBlock,
           mkPieceMap,
           checkFile,
           checkPiece,
           openAndCheckFile,
           canSeed)
where

import Control.Monad

import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as L
import qualified Data.Map as M
import Data.Maybe
import System.IO

import BCode
import qualified Digest as D
import Torrent

pInfoLookup :: PieceNum -> PieceMap -> IO PieceInfo
pInfoLookup pn mp = case M.lookup pn mp of
                      Nothing -> fail "FS: Error lookup in PieceMap"
                      Just i -> return i

readPiece :: PieceNum -> Handle -> PieceMap -> IO L.ByteString
readPiece pn handle mp =
    do pInfo <- pInfoLookup pn mp
       hSeek handle AbsoluteSeek (offset pInfo)
       bs <- L.hGet handle (fromInteger . len $ pInfo)
       if L.length bs == (fromInteger . len $ pInfo)
          then return bs
          else fail "FS: Wrong number of bytes read"

readBlock :: PieceNum -> Block -> Handle -> PieceMap -> IO B.ByteString
readBlock pn blk handle mp =
    do pInfo <- pInfoLookup pn mp
       hSeek handle AbsoluteSeek (offset pInfo + (fromIntegral $ blockOffset blk))
       B.hGet handle (blockSize blk)

-- | The call @writeBlock h n blk pm blkData@ will write the contents of @blkData@
--   to the file pointed to by handle at the correct position in the file. If the
--   block is of a wrong length, the call will fail.
writeBlock :: Handle -> PieceNum -> Block -> PieceMap -> B.ByteString -> IO ()
writeBlock h n blk pm blkData = do hSeek h AbsoluteSeek pos
                                   when lenFail $ fail "Writing block of wrong length"
                                   B.hPut h blkData
                                   hFlush h
                                   return ()
  where pos = offset (fromJust $ M.lookup n pm) + fromIntegral (blockOffset blk)
        lenFail = B.length blkData /= blockSize blk

-- | The @checkPiece h inf@ checks the file system for correctness of a given piece, namely if
--   the piece described by @inf@ is correct inside the file pointed to by @h@.
checkPiece :: PieceInfo -> Handle -> IO Bool
checkPiece inf h = do
  hSeek h AbsoluteSeek (offset inf)
  bs <- L.hGet h (fromInteger . len $ inf)
  return $ D.digest bs == digest inf

-- | Create a MissingMap from a file handle and a piecemap. The system will read each part of
--   the file and then check it against the digest. It will create a map of what we are missing
--   in the file as a missing map. We could alternatively choose a list of pieces missing rather
--   then creating the data structure here. This is perhaps better in the long run.
checkFile :: Handle -> PieceMap -> IO PiecesDoneMap
checkFile handle pm = do l <- mapM checkP pieces
                         return $ M.fromList l
    where pieces = M.toAscList pm
          checkP :: (PieceNum, PieceInfo) -> IO (PieceNum, Bool)
          checkP (pn, pInfo) = do b <- checkPiece pInfo handle
                                  return (pn, b)

-- | Extract the PieceMap from a bcoded structure
--   Needs some more defense in the long run.
mkPieceMap :: BCode -> Maybe PieceMap
mkPieceMap bc = fetchData
  where fetchData = do pLen <- infoPieceLength bc
                       pieceData <- infoPieces bc
                       tLen <- infoLength bc
                       return . M.fromList . zip [0..] . extract pLen tLen 0 $ pieceData
        extract :: Integer -> Integer -> Integer -> [B.ByteString] -> [PieceInfo]
        extract _    0     _    []       = []
        extract plen tlen offst (p : ps) | tlen < plen = PieceInfo { offset = offst,
                                                          len = tlen,
                                                          digest = L.fromChunks  [p] } : extract plen 0 (offst + plen) ps
                                  | otherwise = inf : extract plen (tlen - plen) (offst + plen) ps
                                       where inf = PieceInfo { offset = offst,
                                                               len = plen,
                                                               digest = L.fromChunks [p] }
        extract _ _ _ _ = error "mkPieceMap: the impossible happened!"

-- | Predicate function. True if nothing is missing from the map.
canSeed :: PiecesDoneMap -> Bool
canSeed = M.fold (&&) True

-- | Process a BCoded torrent file. Open the file in question, check it and return a handle
--   plus a haveMap for the file
openAndCheckFile :: BCode -> IO (Handle, PiecesDoneMap, PieceMap)
openAndCheckFile bc =
    do
       h <- openBinaryFile fpath ReadWriteMode
       have <- checkFile h pieceMap
       return (h, have, pieceMap)
  where Just fpath = BCode.fromBS `fmap` BCode.infoName bc
        Just pieceMap = mkPieceMap bc






