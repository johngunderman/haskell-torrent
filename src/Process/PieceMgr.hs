module Process.PieceMgr
    ( PieceMgrMsg(..)
    , PieceMgrChannel
    , ChokeInfoChannel
    , ChokeInfoMsg(..)
    , Blocks(..)
    , start
    , createPieceDb
    )
where


import Control.Concurrent
import Control.Concurrent.CML.Strict
import Control.DeepSeq

import Control.Monad.State
import Data.List
import qualified Data.ByteString as B
import qualified Data.Map as M
import qualified Data.Set as S
import qualified Data.IntSet as IS

import Prelude hiding (log)

import System.Random
import System.Random.Shuffle

import Process.FS hiding (start)
import Process.Status as STP hiding (start) 
import Supervisor
import Torrent
import Process

----------------------------------------------------------------------

-- | The Piece Database tracks the current state of the Torrent with respect to pieces.
--   In the database, we book-keep what pieces are missing, what are done and what are
--   currently in the process of being downloaded. The crucial moment is when we think
--   we have a full piece: we check it against its SHA1 and if it is good, we can mark
--   that piece as done.
--
--   Better implementations for selecting among the pending Pieces is probably crucial
--   to an effective client, but we keep it simple for now.
data PieceDB = PieceDB
    { pendingPieces :: IS.IntSet -- ^ Pieces currently pending download
    , donePiece     :: IS.IntSet -- ^ Pieces that are done
    , donePush      :: [ChokeInfoMsg] -- ^ Pieces that should be pushed to the Choke Mgr.
    , inProgress    :: M.Map PieceNum InProgressPiece -- ^ Pieces in progress
    , downloading   :: [(PieceNum, Block)]    -- ^ Blocks we are currently downloading
    , infoMap       :: PieceMap   -- ^ Information about pieces
    , endGaming     :: Bool       -- ^ If we have done any endgame work this is true
    , assertCount   :: Int        -- ^ When to next check the database for consistency
    } deriving Show

-- | The InProgressPiece data type describes pieces in progress of being downloaded.
--   we keep track of blocks which are pending as well as blocks which are done. We
--   also keep track of a count of the blocks. When a block is done, we cons it unto
--   @ipHaveBlocks@. When @ipHave == ipDone@, we check the piece for correctness. The
--   field @ipHaveBlocks@ could in principle be omitted, but for now it is kept since
--   we can use it for asserting implementation correctness. We note that both the
--   check operations are then O(1) and probably fairly fast.
data InProgressPiece = InProgressPiece
    { ipDone  :: Int -- ^ Number of blocks when piece is done
    , ipHaveBlocks :: S.Set Block -- ^ The blocks we have
    , ipPendingBlocks :: [Block] -- ^ Blocks still pending
    } deriving Show

-- INTERFACE
----------------------------------------------------------------------

-- | When the PieceMgrP returns blocks to a peer, it will return them in either
--   "Leech Mode" or in "Endgame mode". The "Leech mode" is when the client is
--   leeching like normal. The "Endgame mode" is when the client is entering the
--   endgame. This means that the Peer should act differently to the blocks.
data Blocks = Leech [(PieceNum, Block)]
            | Endgame [(PieceNum, Block)]

instance NFData Blocks where
  rnf a = a `seq` ()

-- | Messages for RPC towards the PieceMgr.
data PieceMgrMsg = GrabBlocks Int IS.IntSet (Channel Blocks)
                   -- ^ Ask for grabbing some blocks
                 | StoreBlock PieceNum Block B.ByteString
                   -- ^ Ask for storing a block on the file system
                 | PutbackBlocks [(PieceNum, Block)]
                   -- ^ Put these blocks back for retrieval
                 | AskInterested IS.IntSet (Channel Bool)
                   -- ^ Ask if any of these pieces are interesting
                 | GetDone (Channel [PieceNum])
                   -- ^ Get the pieces which are already done

instance NFData PieceMgrMsg where
    rnf a = case a of
              (GrabBlocks _ is _) -> rnf is
              a                   -> a `seq` ()

data ChokeInfoMsg = PieceDone PieceNum
                  | BlockComplete PieceNum Block
                  | TorrentComplete
    deriving (Eq, Show)

instance NFData ChokeInfoMsg where
  rnf a = a `seq` ()

type PieceMgrChannel = Channel PieceMgrMsg
type ChokeInfoChannel = Channel ChokeInfoMsg

data PieceMgrCfg = PieceMgrCfg
    { pieceMgrCh :: PieceMgrChannel
    , fspCh :: FSPChannel
    , chokeCh :: ChokeInfoChannel
    , statusCh :: StatusChan
    }

instance Logging PieceMgrCfg where
  logName _ = "Process.PieceMgr"

type PieceMgrProcess v = Process PieceMgrCfg PieceDB v

start :: PieceMgrChannel -> FSPChannel -> ChokeInfoChannel -> StatusChan -> PieceDB
      -> SupervisorChan -> IO ThreadId
start mgrC fspC chokeC statC db supC =
    {-# SCC "PieceMgr" #-}
    spawnP (PieceMgrCfg mgrC fspC chokeC statC) db
                    (catchP (forever pgm)
                        (defaultStopHandler supC))
  where pgm = do
          assertPieceDB
          dl <- gets donePush
          (if dl == []
              then receiveEvt
              else chooseP [receiveEvt, sendEvt (head dl)]) >>= syncP
        sendEvt elem = do
            ev <- sendPC chokeCh elem
            wrapP ev remDone
        remDone :: () -> Process PieceMgrCfg PieceDB ()
        remDone () = modify (\db -> db { donePush = tail (donePush db) })
        receiveEvt = do
            ev <- recvPC pieceMgrCh
            wrapP ev (\msg ->
              case msg of
                GrabBlocks n eligible c ->
                    do debugP "Grabbing Blocks"
                       blocks <- grabBlocks' n eligible
                       debugP "Grabbed..."
                       syncP =<< sendP c blocks
                StoreBlock pn blk d ->
                    do debugP $ "Storing block: " ++ show (pn, blk)
                       storeBlock pn blk d
                       modify (\s -> s { downloading = downloading s \\ [(pn, blk)] })
                       endgameBroadcast pn blk
                       done <- updateProgress pn blk
                       when done
                           (do assertPieceComplete pn
                               pend <- gets pendingPieces
                               iprog <- gets inProgress
                               infoP $ "Piece #" ++ show pn
                                         ++ " completed, there are " 
                                         ++ (show $ IS.size pend) ++ " pending "
                                         ++ (show $ M.size iprog) ++ " in progress"
                               l <- gets infoMap >>=
                                    (\pm -> case M.lookup pn pm of
                                                    Nothing -> fail "Storeblock: M.lookup"
                                                    Just x -> return $ len x)
                               sendPC statusCh (CompletedPiece l) >>= syncP
                               pieceOk <- checkPiece pn
                               case pieceOk of
                                 Nothing ->
                                        do fail "PieceMgrP: Piece Nonexisting!"
                                 Just True -> do completePiece pn
                                                 markDone pn
                                                 checkFullCompletion
                                 Just False -> putbackPiece pn)
                PutbackBlocks blks ->
                    mapM_ putbackBlock blks
                GetDone c -> do done <- liftM IS.toList $ gets donePiece
                                syncP =<< sendP c done
                AskInterested pieces retC -> do
                    inProg <- liftM (IS.fromList . M.keys) $ gets inProgress
                    pend   <- gets pendingPieces
                    -- @i@ is the intersection with with we need and the peer has.
                    let i = IS.null $ IS.intersection pieces
                                   $ IS.union inProg pend
                    syncP =<< sendP retC (not i))
        storeBlock n blk contents = syncP =<< (sendPC fspCh $ WriteBlock n blk contents)
        endgameBroadcast pn blk =
            gets endGaming >>=
              flip when (modify (\db -> db { donePush = (BlockComplete pn blk) : donePush db }))
        markDone pn = do
            modify (\db -> db { donePush = (PieceDone pn) : donePush db })
        checkPiece n = do
            ch <- liftIO channel
            syncP =<< (sendPC fspCh $ CheckPiece n ch)
            syncP =<< recvP ch (const True)

-- HELPERS
----------------------------------------------------------------------

createPieceDb :: PiecesDoneMap -> PieceMap -> PieceDB
createPieceDb mmap pmap = PieceDB pending done [] M.empty [] pmap False 0
  where pending = filt (==False)
        done    = filt (==True)
        filt f  = IS.fromList . M.keys $ M.filter f mmap

----------------------------------------------------------------------

-- | The call @completePiece db pn@ will mark that the piece @pn@ is completed
completePiece :: PieceNum -> PieceMgrProcess ()
completePiece pn = modify (\db -> db { inProgress = M.delete pn (inProgress db),
                                       donePiece  = IS.insert pn $ donePiece db })

-- | Handle torrent completion
checkFullCompletion :: PieceMgrProcess ()
checkFullCompletion = do
    doneP <- gets donePiece
    im    <- gets infoMap
    when (M.size im == IS.size doneP)
        (do liftIO $ putStrLn "Torrent Completed"
            sendPC statusCh STP.TorrentCompleted >>= syncP
            sendPC chokeCh  TorrentComplete >>= syncP)

-- | The call @putBackPiece db pn@ will mark the piece @pn@ as not being complete
--   and put it back into the download queue again.
putbackPiece :: PieceNum -> PieceMgrProcess ()
putbackPiece pn = modify (\db -> db { inProgress = M.delete pn (inProgress db),
                                      pendingPieces = IS.insert pn $ pendingPieces db })

-- | Put back a block for downloading.
--   TODO: This is rather slow, due to the (\\) call, but hopefully happens rarely.
putbackBlock :: (PieceNum, Block) -> PieceMgrProcess ()
putbackBlock (pn, blk) = do
    done <- gets donePiece
    unless (IS.member pn done) -- Happens at endgame, stray block
      $ modify (\db -> db { inProgress = ndb (inProgress db)
                          , downloading = downloading db \\ [(pn, blk)]})
  where ndb db = M.alter f pn db
        -- The first of these might happen in the endgame
        f Nothing     = fail "The 'impossible' happened"
        f (Just ipp) = Just ipp { ipPendingBlocks = blk : ipPendingBlocks ipp }

-- | Assert that a Piece is Complete. Can be omitted when we know it works
--   and we want a faster client.
assertPieceComplete :: PieceNum -> PieceMgrProcess ()
assertPieceComplete pn = do
    inprog <- gets inProgress
    ipp <- case M.lookup pn inprog of
                Nothing -> fail "assertPieceComplete: Could not lookup piece number"
                Just x -> return x
    dl <- gets downloading
    pm <- gets infoMap
    sz <- case M.lookup pn pm of
            Nothing -> fail "assertPieceComplete: Could not lookup piece in piecemap"
            Just x -> return $ len x
    unless (assertAllDownloaded dl pn)
      (fail "Could not assert that all pieces were downloaded when completing a piece")
    unless (assertComplete ipp sz)
      (fail $ "Could not assert completion of the piece #" ++ show pn
                ++ " with block state " ++ show ipp)
  where assertComplete ip sz = checkContents 0 (fromIntegral sz) (S.toAscList (ipHaveBlocks ip))
        -- Check a single block under assumptions of a cursor at offs
        checkBlock (offs, left, state) blk = (offs + blockSize blk,
                                              left - blockSize blk,
                                              state && offs == blockOffset blk)
        checkContents os l blks = case foldl checkBlock (os, l, True) blks of
                                    (_, 0, True) -> True
                                    _            -> False
        assertAllDownloaded blocks pn = all (\(pn', _) -> pn /= pn') blocks

-- | Update the progress on a Piece. When we get a block from the piece, we will
--   track this in the Piece Database. This function returns a pair @(complete, nDb)@
--   where @complete@ is @True@ if the piece is percieved to be complete and @False@
--   otherwise.
updateProgress :: PieceNum -> Block -> PieceMgrProcess Bool
updateProgress pn blk = do
    ipdb <- gets inProgress
    case M.lookup pn ipdb of
      Nothing -> do debugP "updateProgress can't find progress block, error?"
                    return False
      Just pg ->
          let blkSet = ipHaveBlocks pg
          in if blk `S.member` blkSet
               then return False -- Stray block download.
                                 -- Will happen without FAST extension
                                 -- at times
               else checkComplete pg { ipHaveBlocks = S.insert blk blkSet }
  where checkComplete pg = do
            modify (\db -> db { inProgress = M.adjust (const pg) pn (inProgress db) })
            debugP $ "Iphave : " ++ show (ipHave pg) ++ " ipDone: " ++ show (ipDone pg)
            return (ipHave pg == ipDone pg)
        ipHave = S.size . ipHaveBlocks

blockPiece :: BlockSize -> PieceSize -> [Block]
blockPiece blockSz pieceSize = build pieceSize 0 []
  where build 0         os accum = reverse accum
        build leftBytes os accum | leftBytes >= blockSz =
                                     build (leftBytes - blockSz)
                                           (os + blockSz)
                                           $ Block os blockSz : accum
                                 | otherwise = build 0 (os + leftBytes) $ Block os leftBytes : accum

-- | The call @grabBlocks' n eligible db@ tries to pick off up to @n@ pieces from
--   the @n@. In doing so, it will only consider pieces in @eligible@. It returns a
--   pair @(blocks, db')@, where @blocks@ are the blocks it picked and @db'@ is the resulting
--   db with these blocks removed.
grabBlocks' :: Int -> IS.IntSet -> PieceMgrProcess Blocks
grabBlocks' k eligible = {-# SCC "grabBlocks'" #-} do
    blocks <- tryGrabProgress k eligible []
    pend <- gets pendingPieces
    if blocks == [] && IS.null pend
        then do blks <- grabEndGame k eligible
                modify (\db -> db { endGaming = True })
                debugP $ "PieceMgr entered endgame."
                return $ Endgame blks
        else do modify (\s -> s { downloading = blocks ++ (downloading s) })
                return $ Leech blocks
  where
    -- Grabbing blocks is a state machine implemented by tail calls
    -- Try grabbing pieces from the pieces in progress first
    tryGrabProgress 0 _  captured = return captured
    tryGrabProgress n ps captured = do
        inProg <- gets inProgress
        let is = IS.intersection ps (IS.fromList $ M.keys inProg)
        case IS.null is of
            True -> tryGrabPending n ps captured
            False -> grabFromProgress n ps (head $ IS.elems is) captured
    -- The Piece @p@ was found, grab it
    grabFromProgress n ps p captured = do
        inprog <- gets inProgress
        ipp <- case M.lookup p inprog of
                  Nothing -> fail "grabFromProgress: could not lookup piece"
                  Just x -> return x
        let (grabbed, rest) = splitAt n (ipPendingBlocks ipp)
            nIpp = ipp { ipPendingBlocks = rest }
        -- This rather ugly piece of code should be substituted with something better
        if grabbed == []
             -- All pieces are taken, try the next one.
             then tryGrabProgress n (IS.delete p ps) captured
             else do modify (\db -> db { inProgress = M.insert p nIpp inprog })
                     tryGrabProgress (n - length grabbed) ps ([(p,g) | g <- grabbed] ++ captured)
    -- Try grabbing pieces from the pending blocks
    tryGrabPending n ps captured = do
        pending <- gets pendingPieces
        let isn = IS.intersection ps pending
        case IS.null isn of
            True -> return $ captured -- No (more) pieces to download, return
            False -> do
              h <- pickRandom (IS.toList isn)
              infMap <- gets infoMap
              inProg <- gets inProgress
              blockList <- createBlock h
              let sz  = length blockList
                  ipp = InProgressPiece sz S.empty blockList
              modify (\db -> db { pendingPieces = IS.delete h (pendingPieces db),
                                  inProgress    = M.insert h ipp inProg })
              tryGrabProgress n ps captured
    grabEndGame n ps = do -- In endgame we are allowed to grab from the downloaders
        dls <- liftM (filter (\(p, _) -> IS.member p ps)) $ gets downloading
        g <- liftIO newStdGen
        let shuffled = shuffle' dls (length dls) g
        return $ take n shuffled
    pickRandom pieces = do
        n <- liftIO $ getStdRandom (\gen -> randomR (0, length pieces - 1) gen)
        return $ pieces !! n
    createBlock :: Int -> PieceMgrProcess [Block]
    createBlock pn = do
        gets infoMap >>= (\im -> case M.lookup pn im of
                                    Nothing -> fail "createBlock: could not lookup piece"
                                    Just ipp -> return $ cBlock ipp)
            where cBlock = blockPiece defaultBlockSize . fromInteger . len

assertPieceDB :: PieceMgrProcess ()
assertPieceDB = {-# SCC "assertPieceDB" #-} do
    c <- gets assertCount
    if c == 0
        then do modify (\db -> db { assertCount = 10 })
                assertSets >> assertInProgress >> assertDownloading
        else modify (\db -> db { assertCount = assertCount db - 1 })
  where
    -- If a piece is pending in the database, we have the following rules:
    --
    --  - It is not done.
    --  - It is not being downloaded
    --  - It is not in progresss.
    --
    -- If a piece is done, we have the following rules:
    --
    --  - It is not in progress.
    --  - There are no more downloading blocks.
    assertSets = do
        pending <- gets pendingPieces
        done    <- gets donePiece
        down    <- liftM (IS.fromList . map fst) $ gets downloading
        iprog   <- liftM (IS.fromList . M.keys) $ gets inProgress
        let pdis = IS.intersection pending done
            pdownis = IS.intersection pending down
            piprogis = IS.intersection pending iprog
            doneprogis = IS.intersection done iprog
            donedownis = IS.intersection done down
        unless (IS.null pdis)
            (fail $ "Pending/Done violation of pieces: " ++ show pdis)
        unless (IS.null pdownis)
            (fail $ "Pending/Downloading violation of pieces: " ++ show pdownis)
        unless (IS.null piprogis)
            (fail $ "Pending/InProgress violation of pieces: " ++ show piprogis)
        unless (IS.null doneprogis)
            (fail $ "Done/InProgress violation of pieces: " ++ show doneprogis)
        unless (IS.null donedownis)
            (fail $ "Done/Downloading violation of pieces: " ++ show donedownis)

    -- If a piece is in Progress, we have:
    --
    --  - There is a relationship with what pieces are downloading
    --    - If a block is ipPending, it is not in the downloading list
    --    - If a block is ipHave, it is not in the downloading list
    assertInProgress = do
        inProg <- gets inProgress
        mapM_ checkInProgress $ M.toList inProg
    checkInProgress (pn, ipp) = do
        when ( (S.size $ ipHaveBlocks ipp) >= ipDone ipp)
            (fail $ "Piece in progress " ++ show pn
                    ++ " has downloaded more blocks than the piece has")
    assertDownloading = do
        down <- gets downloading
        mapM_ checkDownloading down
    checkDownloading (pn, blk) = do
        prog <- gets inProgress
        case M.lookup pn prog of
            Nothing -> fail $ "Piece " ++ show pn ++ " not in progress while We think it was"
            Just ipp -> do
                when (blk `elem` ipPendingBlocks ipp)
                    (fail $ "P/Blk " ++ show (pn, blk) ++ " is in the Pending Block list")
                when (S.member blk $ ipHaveBlocks ipp)
                    (fail $ "P/Blk " ++ show (pn, blk) ++ " is in the HaveBlocks set")


