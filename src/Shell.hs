{-# LANGUAGE OverloadedStrings, LambdaCase #-}
module Shell where


import Prelude hiding (last)

import System.IO hiding (hClose, withFile)
import System.Environment
import System.Process.Typed
import System.Console.ANSI.Codes
import System.Console.Haskeline

import Data.Bifunctor
import Data.Functor
import Data.Colour.SRGB hiding (RGB)
import Data.Maybe
import Data.Word (Word8)
import Data.List (delete)
import qualified Data.Text.Read as TR
import qualified Data.Text as T
import qualified Data.Map as Map
import Data.Map ((!?))

import Control.Monad.Except
import Control.Monad.Reader
import Control.DeepSeq

import GHC.IO.Handle hiding (hClose)

import UnliftIO.Directory
import UnliftIO.Exception hiding (Handler)
import qualified UnliftIO.Process as P
import UnliftIO hiding (Handler)

import Abs
import Builtins
import Parser
import Utils
import StateUtils

import System.Exit
import System.Posix.Signals
import Control.Concurrent

-- Expressions evaluation

add :: Val -> Val -> Except Err Val
add (VInt a) (VInt b) = return $ VInt $ a + b
add _ _ = throwError "Wrong type of arguments for addition"

subt :: Val -> Val -> Except Err Val
subt (VInt a) (VInt b) = return $ VInt $ a - b
subt _ _= throwError "Wrong type of arguments for subtraction"

mul :: Val -> Val -> Except Err Val
mul (VInt a) (VInt b) = return $ VInt $ a * b
mul _ _ = throwError "Wrong type of arguments for multiplication"

evalExpr :: Expr -> Except Err Val
evalExpr (ELit s) = return $ VStr s
evalExpr (EInt i) = return $ VInt i
evalExpr (Negation expr) = evalExpr $ Product (EInt (-1)) expr
evalExpr (Sum expr1 expr2) = join $ add <$> evalExpr expr1 <*> evalExpr expr2
evalExpr (Subtr expr1 expr2) = join $ subt <$> evalExpr expr1 <*> evalExpr expr2
evalExpr (Product expr1 expr2) = join $ mul <$> evalExpr expr1 <*> evalExpr expr2
evalExpr _ = throwError "Undefined type of expression"

resolveLocalName :: String -> Shell String
resolveLocalName name = do
  path <- getPath
  withCurrentDirectory path $ canonicalizePath name

printFail :: String -> [Action]
printFail msg = [APrintErr msg, AIOAction $ setErrCode (ExitFailure 1) >> return []]


mkIOAction :: Shell [Action] -> [Action]
mkIOAction = (:[]) . AIOAction

doInterpret :: Command -> [Action]
doInterpret (GenericCmd "cd" (dir:_)) = mkIOAction $ do
  path <- getPath
  absPath <- withCurrentDirectory path $ canonicalizePath $ T.unpack dir
  ifM (doesDirectoryExist absPath)
    (setPath absPath >> return [])
    (return $ printFail $ "Error: no such directory: " ++ T.unpack dir)

doInterpret (GenericCmd "exit" []) = [AExit ExitSuccess]
doInterpret (GenericCmd "exit" (code:_)) = case TR.decimal code of
  Right (exitCode, _) -> [AExit $ if exitCode == 0 then ExitSuccess else ExitFailure exitCode]
  Left str -> printFail $ "Error: wrong exit code: " ++ str
doInterpret (GenericCmd "run" args) = [ALaunchProc $ RunCommand args]
doInterpret (DeclCmd var expr) = if var == "EXITCODE" then printFail "Cannot assign to this variable." else
  case runExcept $ evalExpr expr of
    Left msg -> printFail msg
    Right val -> mkIOAction $ setVar var val >> return []
doInterpret (AliasCmd alias val) =
  if alias == "let"
    then printFail "Cannot alias with the name \"let\"."
    else mkIOAction $ addAlias alias val >> return []
doInterpret (GenericCmd name args) = [ALaunchProc $ ProgramExec name args]
doInterpret (Pipe [cmd]) = doInterpret cmd
doInterpret (Pipe cmds@(_:_)) = [APipe $ map doInterpret cmds]
doInterpret (RedirectIn path cmd) = [ARedirect RStdin path $ doInterpret cmd]
doInterpret (RedirectOut path cmd) = [ARedirect RStdout path $ doInterpret cmd]
doInterpret (RedirectErr path cmd) = [ARedirect RStderr path $ doInterpret cmd]
doInterpret _ = []


interpretCmd :: String -> Shell [Action]
interpretCmd s = do--Interpret <$> (doPreprocess s >>= parseCmd)
  dprint $ "Original command: \"" ++ s ++ "\""
  s' <- doPreprocess s
  dprint $ "After preprocess: \"" ++ s' ++ "\""
  cmd <- parseCmd s'
  dprint $ "Parsed command to " ++ show cmd ++ ", compiling..."
  let as = doInterpret cmd
  dprint $ "Command produced following actions:\n" ++ unlines (map show as)
  return as

handleEvent :: EventResult -> Shell [Action]
handleEvent Nothing = return [AExit ExitSuccess]
handleEvent (Just s) = interpretCmd s


getErrColor :: Shell (Maybe RGB)
getErrColor = getVar errColorKey >>= \case
  Just (VStr txt) -> return $ builtinColors !? T.unpack txt
  _ -> return Nothing

execSingleAction :: Action -> Shell ()
execSingleAction a = withSavedConfig $ execAction a


-- do not use this to launch processes within piping
execAction :: Action -> Shell ()
execAction a = dprint ("Exec'ing action " ++ show a ++ "...") >> go a >> dprint ("Action " ++ show a ++ " exec'd!")
  where
    go :: Action -> Shell ()
    go (APrintErr s) =
      getErrColor >>= \case
      Nothing -> liftIO $ hPutStrLn stderr s
      Just (r, g, b) -> liftIO $ hPutStrLn stderr (withColor r g b s)
    go (AExit code) = liftIO $ exitWith code
    go (AIOAction a) = do
      as <- a
      mapM_ execAction as
    go (ALaunchProc desc) = do
      conf <- getConfig
      let pipe = mkPipelineSingle desc conf
      dprint $ "Exec'ing pipe " ++ show pipe
      execPipeline pipe
    go (ARedirect rt p as) = do
      setRPath rt p
      mapM_ go as
    go (APipe as@(_:_:_)) = do
      conf <- getConfig
      job <- startJob
      let pipe = mkPipeline as conf
      dprint $ "Before plug: " ++ show pipe
      dprint $ "And from the left: " ++ doShowLeft pipe
      pipe' <- plugPipes pipe
      dprint $ "Exec'ing pipe " ++ show pipe'
      dprint $ "And from the left: " ++ doShowLeft pipe'
      execPipeline pipe'
      ps <- getJobProcs
      dprint $ "waiting for " ++ show (length ps) ++ " procs"
      waitForProcs ps
      dprint "waited for procs"
      finishJob
    go (APipe _) = error "execAction APipe"

waitForProcs :: [Async ExitCode] -> Shell ()
waitForProcs [a] = do
  ec <- wait a
  setErrCode ec
waitForProcs (a:rest) = do
  void $ wait a
  waitForProcs rest
waitForProcs [] = return ()

hasProcLaunch :: [Action] -> Bool
hasProcLaunch = any isProcLaunch

isProcLaunch :: Action -> Bool
isProcLaunch (ALaunchProc _) = True
isProcLaunch (ARedirect _ _ as) = any isProcLaunch as
isProcLaunch (APipe _) = error "isProcLaunch APipe"
isProcLaunch _ = False

countProcLaunches :: [Action] -> Int
countProcLaunches = sum . map go
  where
    go :: Action -> Int
    go (ALaunchProc _) = 1
    go (ARedirect _ _ as) = countProcLaunches as
    go (APipe _) = error "countProcLaunches APipe"
    go _ = 0

assertNoMultipleProcLaunches :: [Action] -> Shell ()
assertNoMultipleProcLaunches a | countProcLaunches a > 1 = error "More than one process launched in command."
assertNoMultipleProcLaunches _ = return ()

splitByProcessLaunch :: [Action] -> ([Action], Action, [Action])
splitByProcessLaunch = splitByPred isProcLaunch

rtToPR :: RedirectType -> HsHandle -> PipelineRedirect
rtToPR RStdin = PRStdinSource
rtToPR RStderr = PRStderrSink
rtToPR RStdout = PRStdoutSink

mkPipelineSingle :: ProcDesc -> PIOConfig -> Pipeline
mkPipelineSingle desc conf =
  let source = PRedirect PBound (PRStdinSource $ stdinH conf) pr
      pr = PProc source desc sink1
      sink1 = PRedirect pr (PRStdoutSink $ stdoutH conf) sink2
      sink2 = PRedirect sink2 (PRStderrSink $ stderrH conf) PBound
  in source

mkPipeline :: [[Action]] -> PIOConfig -> Pipeline
mkPipeline actions conf =
  let res = PRedirect PBound (PRStdinSource $ stdinH conf) next
      (next, _) = go actions conf PBound res
  in res
  where
    go :: [[Action]] -> PIOConfig -> Pipeline -> Pipeline -> (Pipeline, Pipeline)
    go [] c last prev =
      let out = PRedirect prev (PRStdoutSink $ stdoutH c) err
          err = PRedirect out (PRStderrSink $ stderrH c) last
      in (out, err)
    go (as:rest) c last prev =
      if hasProcLaunch as
      then let (pref, x, suf) = splitByProcessLaunch as
           in let res1 = if null pref then prev else PAction prev (act pref) res2
                  (res2, res2') =
                    case x of
                      ALaunchProc desc -> let res = PProc res1 desc res3 in (res, res)
                      ARedirect RStdin p ras ->
                        let red1 = PRedirect res1 (PRStdinSource $ HPath p) red2
                            (red2, red2') = go [ras] c res3 red1
                        in (red1, red2')
                      ARedirect RStdout p ras -> go [ras] c{stdoutH = HPath p} res3 res1
                      ARedirect RStderr p ras -> go [ras] c{stderrH = HPath p} res3 res1
                      _ -> error $ "mkPipeline " ++ show x
                  (res3, res3') = if null suf then (res4, res2') else let x = PAction res2' (act suf) res4 in (x, x)
                  (res4, resLast) = go' rest c last res3'
              in (if null pref then res2 else res1, resLast)
      else -- assume non processes can't use stdin and stdout for now
        let can1 = PRedirect prev PRCancel action
            action = PAction can1 (act as) can2
            can2 = PRedirect action PRCancel res
            (res, resLast) = go rest c last can2
        in (can1, resLast)
    go' as@(f:_) c last prev | hasProcLaunch f =
      let rin = PRedirect prev (PRStdinSource HPipe) rout
          rout = PRedirect rin (PRStdoutSink HPipe) rest
          (rest, resLast) = go as c last rout
      in (rin, resLast)
    go' as c last prev = go as c last prev

getSources :: Pipeline -> [HsHandle]
getSources (PRedirect next pr _) =
  case pr of
    PRStdinSource h -> h : getSources next
    PRCancel -> []
    _ -> getSources next
getSources (PAction next _ _) = getSources next
getSources _ = []

getSinks :: Pipeline -> ([HsHandle], [HsHandle])
getSinks (PRedirect _ pr next) =
  case pr of
    PRStdoutSink h -> first (h :) $ getSinks next
    PRStderrSink h -> second (h :) $ getSinks next
    PRCancel -> ([], [])
    _ -> getSinks next
getSinks (PAction _ _ next) = getSinks next
getSinks _ = ([], [])

updatePrev :: Pipeline -> Pipeline -> Pipeline
updatePrev (PRedirect _ rdr next) newPrev = PRedirect newPrev rdr next
updatePrev (PProc _ conf next) newPrev = PProc newPrev conf next
updatePrev (PAction _ action next) newPrev = PAction newPrev action next
updatePrev PBound _ = PBound

updateNext :: Pipeline -> Pipeline -> Pipeline
updateNext (PRedirect prev rdr _) newNext = PRedirect prev rdr newNext
updateNext (PProc prev conf _) newNext = PProc prev conf newNext
updateNext (PAction prev action _) newNext = PAction prev action newNext
updateNext PBound _ = PBound

insertAfter :: PipelineRedirect -> Pipeline -> Pipeline
insertAfter _ PBound = PBound -- makes no sense
insertAfter rdr (PProc prev desc next) =
  let cur = PProc prev desc newP
      newP = PRedirect cur rdr newNext
      newNext = updatePrev next newP
  in cur
insertAfter _ _ = undefined


getHandle :: IOMode -> HsHandle  -> Shell Handle
getHandle _ (HHandle h) = return h
getHandle mode (HPath p) = liftIO $ openFile p mode
getHandle _ HPipe = error "getHandle HPipe"



combineHandles :: IOMode -> [HsHandle] -> Shell Handle
combineHandles _ [] = error "need at least one handle"
combineHandles m (h:_) = getHandle m h
-- combineHandles m hs = do
--   h <- mapM (getHandle m)  hs
--   liftIO $ fold1M go h
--   where
--     go :: Handle -> Handle -> IO Handle
--     go h1 h2 = hDuplicateTo h1 h2 $> h1


countPipes :: Pipeline -> Int
countPipes (PRedirect _ (PRStdinSource HPipe) (PRedirect _ (PRStdoutSink HPipe) next)) = 1 + countPipes next
countPipes (PRedirect _ _ next) = countPipes next
countPipes (PProc _ _ next) = countPipes next
countPipes (PAction _ _ next) = countPipes next
countPipes PBound = 0


plugPipes :: Pipeline -> Shell Pipeline
plugPipes p = do
  let c = countPipes p
  hs <- replicateM c P.createPipe
  return $ go p PBound hs
  where
    go :: Pipeline -> Pipeline -> [(Handle, Handle)] -> Pipeline
    go (PRedirect _ (PRStdinSource HPipe) (PRedirect _ (PRStdoutSink HPipe) next)) prev ((readH, writeH):rest) =
      let rin = PRedirect (updateNext prev rin) (PRStdinSource $ HHandle readH) rout
          rout = PRedirect rin (PRStdoutSink $ HHandle writeH) next'
          next' = go (updatePrev next rout) rout rest
      in rin
    go (PRedirect _ rdr next) prev hs =
      let cur = PRedirect prev rdr next'
          next' = go next cur hs
      in cur
    go (PProc _ desc next) prev hs =
      let cur = PProc prev desc next'
          next' = go next cur hs
      in cur
    go (PAction _ a next) prev hs =
      let cur = PAction prev a next'
          next' = go next cur hs
      in cur
    go PBound _ [] = PBound
    go _ _ _ = error "plugPipes"


execPipeline :: Pipeline -> Shell ()
execPipeline PBound = return ()
execPipeline (PAction _ action next) = action >> execPipeline next
execPipeline (PRedirect _ _ next) = execPipeline next
execPipeline (PProc prev (RunCommand (name:args)) next) = do
  name' <- resolveLocalName $ T.unpack name
  catch (withFile name' ReadMode $ \fHandle -> liftIO (hGetContents fHandle) >>= \fContents ->
            case fContents of
              '#':'!':_ -> execPipeline (PProc prev (ProgramExec name' args) next)
              _ ->
                let sources = getSources prev
                    (outSinks, errSinks) = getSinks next
                in do
                  dprint $ "Running file " ++ name'
                  conf <- getConfig
                  conf' <- if null sources then return conf else do
                    h <- combineHandles ReadMode sources
                    return conf{stdinH = HHandle h}
                  conf'' <- if null outSinks then return conf' else do
                    h <- combineHandles WriteMode outSinks
                    return conf{stdoutH = HHandle h}
                  conf''' <- if null errSinks then return conf'' else do
                    h <- combineHandles WriteMode errSinks
                    return conf{stderrH = HHandle h}
                  lines' <- return $!! lines $!! fContents
                  grabCode $ do
                    actionsList <- mapM interpretCmd $ joinByBackslash lines'
                    setConfig conf'''
                    ecref <- liftIO $ newIORef ExitSuccess
                    mapM_ (\case
                              AExit code -> writeIORef ecref code
                              a -> execSingleAction a) $ concat actionsList
                    readIORef ecref
                  execPipeline next
        ) printOpenErr
execPipeline (PProc _ (RunCommand _) next) = act (printFail "run: Nothing to execute.") >> execPipeline next
execPipeline (PProc prev (ProgramExec name args) next) = do
  path <- getPath
  let sources = getSources prev
      (outSinks, errSinks) = getSinks next
      conf = proc name $ map T.unpack args
  dprint $ "sources: " ++ show sources ++ ", outSinks: " ++ show outSinks ++ ", errSinks: " ++ show errSinks
  (hin, conf') <- if null sources then return (Nothing, conf) else do
    h <- combineHandles ReadMode sources
    return $ if h `elem` stdHandles then (Nothing, conf) else (Just h, setStdin (handleWithIt h) conf)
  (hout, conf'') <- if null outSinks then return (Nothing, conf') else do
    h <- combineHandles WriteMode outSinks
    return $ if h `elem` stdHandles then (Nothing, conf') else (Just h, setStdout (handleWithIt h) conf')
  (herr, conf''') <- if null errSinks then return (Nothing, conf'') else do
    h <- combineHandles WriteMode errSinks
    return $ if h `elem` stdHandles then (Nothing, conf'') else (Just h, setStderr (handleWithIt h) conf'')
  dprint $ "Exec'ing process with conf: " ++ red ++ show conf''' ++ resetCol
  grabCode $ do
    dprint $ "Start " ++ show conf'''
    ec <- withCurrentDirectory path $ runProcess $ setCloseFds True $ setNewSession True conf'''
    return ec
  dprint $ "Exec'd process..."
  execPipeline next

outHandles :: [Handle]
outHandles = [stdout, stderr]

stdHandles :: [Handle]
stdHandles = stdin : outHandles

handleWithIt handle = if handle `elem` [stdin, stdout, stderr] then useHandleOpen handle else useHandleClose handle

grabCode :: Shell ExitCode -> Shell ()
grabCode action = do
  mj <- getActiveJob
  case mj of
    Nothing -> catchIO action (\e -> act (printFail $ "Command failed :(\n" ++ show e) >> return (ExitFailure 1)) >>= setErrCode
    Just _ -> async action >>= addActiveProc

type Hydraulics = Pipeline -> Shell ()

-- Execute non-process-launch actions.
act :: [Action] -> Shell ()
act = mapM_ execAction

printOpenErr :: IOException -> Shell ()
printOpenErr e = mapM_ execAction $ printFail $ "Could not open file with exception: " ++ show e

eventsManager :: EventList -> Shell ()
eventsManager [] = return ()
eventsManager events = do
  (event, res) <- waitAny events
  handleEvent res >>= mapM_ execSingleAction
  eventsManager $ delete event events



getPrompt :: Shell String
getPrompt = do
  pr <- getVarStr "PROMPT"
  home <- getVarStr "HOME"
  curDir <- getVarStr "PWD"
  setVar "HOME" (VStr "~")
  case trimCommonPrefix home curDir of
    Nothing -> return ()
    Just suf -> setVar "PWD" (strToVal $ "~" ++ suf)
  res <- doPreprocess pr
  setVar "HOME" (strToVal home)
  setVar "PWD" (strToVal curDir)
  return res

  where
  -- trimCommonPrefix x (x ++ y) = Just y
  -- trimCommonPrefix _ _        = Nothing
  trimCommonPrefix :: String -> String -> Maybe String
  trimCommonPrefix [] ys = Just ys
  trimCommonPrefix (x:xs) (y:ys) | x == y = trimCommonPrefix xs ys
  trimCommonPrefix _ _ = Nothing

runDotFile :: Shell ()
runDotFile = do
  home <- getVarStr "HOME"
  whenM (doesFileExist $ home ++ "/.hshrc") $ interpretCmd "run ~/.hshrc" >>= act


startShell :: IO ()
startShell = defaultRunShell $ runDotFile >> loop
  where
    loop :: Shell ()
    loop = do
      path <- getPath
      pr <- getPrompt
      input <- async $ lift $ getInputLine pr
      eventsManager [input]
      loop

defaultRunShell :: Shell a -> IO a
defaultRunShell m = do
  st <- initState
  runShell st m

runShell :: ShellState -> Shell a -> IO a
runShell st m = do
  homeDir <- getHomeDirectory
  stRef <- newIORef st
  let initSettings = (defaultSettings :: Settings IO)
        { historyFile = Just $ homeDir ++ "/.hsh_history"
        , complete = \ss -> do
            st <- readIORef stRef
            withCurrentDirectory (shellStPath st) $ completeFilename ss} :: Settings IO
  runInputT initSettings (runReaderT m stRef)

initEnv :: Env -> IO Env
initEnv env = do
  home <- strToVal <$> getHomeDirectory
  curDir <- strToVal <$> getCurrentDirectory
  let initVars = Map.fromList [("HOME", home), ("PWD", curDir), ("PROMPT", defaultPromptVal)]
  return $ Map.union initVars env

  where
  defaultPromptVal :: Val
  defaultPromptVal = 
    strToVal $ rgb 72 52 101 ++ "λ " ++ rgb 102 73 142 ++ "$PWD" ++ rgb 155 62 144 ++ " >>= " ++ setSGRCode [SetDefaultColor Foreground]


initState :: IO ShellState
initState = do
  env <- Map.map strToVal . Map.fromList <$> getEnvironment
  env' <- initEnv env
  ShellState env'
    <$> getCurrentDirectory
    <*> pure ExitSuccess
    <*> pure Map.empty
    <*> pure def
    <*> pure Nothing
    <*> pure Map.empty

ignoreSIGINT :: IO Handler
ignoreSIGINT = installHandler keyboardSignal (Catch (return ())) Nothing

hshMain :: IO ()
hshMain = do
  args <- getArgs
  env <- initState
  case args of
    "-c":rest -> runShell env $ interpretCmd (unwords rest) >>= mapM_ execAction
    _ -> ignoreSIGINT >> startShell

--- DEBUG


-- drs = defaultRunShell

-- tppa :: IO Pipeline
-- tppa = (\as -> mkPipeline ((\((APipe as'):[]) -> as') as) def) <$> drs (runDotFile >> interpretCmd "tpp")

-- left :: Pipeline -> Pipeline
-- left (PRedirect l _ _) = l
-- left (PProc l _ _) = l
-- left (PAction l _ _) = l
-- left (PBound) = PBound
-- right :: Pipeline -> Pipeline
-- right (PRedirect _ _ l) = l
-- right (PProc _ _ l) = l
-- right (PAction _ _ l) = l
-- right (PBound) = PBound

-- showBoth p = putStrLn $ "Pipe: " ++ show p ++ "\nfrom the left:" ++ showLeft p

