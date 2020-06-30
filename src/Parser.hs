{-# LANGUAGE OverloadedStrings, GADTs #-}
module Parser (parseCmd, doPreprocess) where

import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Combinators.Expr
import Data.Char
import qualified Data.Text as T
import Data.Text (Text)
import Data.Maybe
import Text.Megaparsec
import Text.Megaparsec.Char
import qualified Text.Megaparsec.Char.Lexer as L

import Abs
import Utils
import StateUtils


-- | Type used for parsing command arguments

data Arg = Generic Text | Redirect (Text, Path)

-- | Preprocessing part.
{-
doPreprocess :: String -> Shell String
doPreprocess t = do
  ecpeb <- runParserT (linePreprocessor 0) "preprocessing" $ T.pack t
  either (\peb -> t <$ liftIO (putStrLn $ errorBundlePretty peb)) return ecpeb

linePreprocessor :: Integer -> Parser String
linePreprocessor acc = do
  x <- optional pCharAndEscape
  case x of
    Nothing -> return ""
    Just x' -> do
      let escape = x' == '\\'
      let acc' = if escape then acc + 1 else 0
      if x' == '$' && acc `mod` 2 == 0
        then do
          val <- preprocessVar
          next <- linePreprocessor acc'
          return $ val ++ next
        else do
          next <- linePreprocessor acc'
          return $ (if escape && acc' `mod` 2 == 1 then "" else [x']) ++ next

preprocessVar :: Parser String
preprocessVar = do
    var <- pName
    val <- getVar var
    return $ show $ fromMaybe (VStr "") val

pCharAndEscape :: Parser Char
pCharAndEscape = try (char '\\') <|> L.charLiteral   return $ show $ fromMaybe (VStr "") val
-}

--this is my best attempt at a bitmap one could pattern match into

data EscapeState = ENormal | EEscaped
data SpaceState = ENoSpace | EAfterSpace

type EscapingState = (EscapeState, SpaceState)

normSt :: EscapingState
normSt = (ENormal, ENoSpace)

getVarStr :: String -> Shell String
getVarStr name = do
  val <- getVar name
  return $ show $ fromMaybe (VStr "") val

unescaper :: String -> Shell String
unescaper = go normSt
  where
    go :: EscapingState -> String -> Shell String
    go _ [] = return []
    go (ENormal, e) ('\\':rest) = go (EEscaped, e)  rest
    go (ENormal, _) ('$':rest) = do
      ecpeb <- runParserT pVarNameAndRest "preprocessing" rest -- TODO: this makes preprocessing O(n^2)
      case ecpeb of
        Left peb -> do liftIO $ putStrLn $ "Getting variable name failed!\n" ++ errorBundlePretty peb
                       ('$':) <$> go normSt rest
        Right (name, rest') -> do
          val <- getVarStr name
          (val ++) <$> go normSt rest'
    go (EEscaped, _) (' ':rest) = (' ':) <$> go normSt rest
    go (ENormal, _) (' ':rest) = (' ':) <$> go (ENormal, EAfterSpace) rest
    go (ENormal, EAfterSpace) ('~':rest) = do
      home <- getVarStr "HOME"
      (home ++) <$> go normSt rest
    go _ (c:rest) = (c:) <$> go normSt rest

doPreprocess :: String -> Shell String
doPreprocess = unescaper


pVarNameAndRest :: ParserS (String, String)
pVarNameAndRest = (,) <$> pNameS <*> takeWhileP Nothing (const True)


-- | Parsing expressions.

pInteger :: Parser Expr
pInteger = EInt <$> integer

pLit :: Parser Expr
pLit = ELit <$> stringLiteral

parens :: Parser a -> Parser a
parens = between (symbol "(") (symbol ")")

pTerm :: Parser Expr
pTerm = choice
  [ parens pExpr
  , pLit
  , pInteger
  ]

pExpr :: Parser Expr
pExpr = makeExprParser pTerm operatorTable

operatorTable :: [[Operator Parser Expr]]
operatorTable =
  [
    [ prefix "-" Negation
    , prefix "+" id
    ]
  , [ binary "*" Product
    ]
  , [ binary "+" Sum
    , binary "-" Subtr
    ]
  ]

binary :: Text -> (Expr -> Expr -> Expr) -> Operator Parser Expr
binary name f = InfixL (f <$ symbol name)

prefix :: Text -> (Expr -> Expr) -> Operator Parser Expr
prefix name f = Prefix (f <$ symbol name)

-- | Parsing utilities.
-- Parsing is done on Text instead of String to improve performance when parsing source code files.

parseCmd :: String -> Shell Command
parseCmd = doParseLine . T.pack

doParseLine :: Text -> Shell Command
doParseLine t = do
  ecpeb <- runParserT commandParser "input command" t
  either (\peb -> DoNothing <$ liftIO (putStrLn $ errorBundlePretty peb)) return ecpeb

-- TODO: maybe one can make those for generic Char streams?

sc :: Parser ()
sc = L.space space1 (L.skipLineComment "#") empty

scS :: ParserS ()
scS = L.space space1 (L.skipLineComment "#") empty

lexeme :: Parser a -> Parser a
lexeme = L.lexeme sc

lexemeS :: ParserS a -> ParserS a
lexemeS = L.lexeme scS

symbol :: Text -> Parser Text
symbol = L.symbol sc

integer :: Parser Integer
integer = lexeme L.decimal

stringLiteral :: Parser Text
stringLiteral = T.pack <$> (char '\"' *> manyTill L.charLiteral (char '\"'))

pKeyword :: Text -> Parser Text
pKeyword keyword = lexeme (string keyword <* notFollowedBy alphaNumChar)

pName :: Parser String
pName = lexeme ((:) <$> letterChar <*> many alphaNumChar <?> "command name")

pNameS :: ParserS String
pNameS = lexemeS ((:) <$> letterChar <*> many alphaNumChar <?> "command name")

notSpaceOrPipe :: Parser Text
notSpaceOrPipe = lexeme $ takeWhile1P Nothing $ (not . isSpace) .&& (/= '|')

genericArgument :: Parser Text
genericArgument = stringLiteral <|> notSpaceOrPipe

genericArg :: Parser Arg
genericArg = Generic <$> genericArgument

redirectArg :: Parser Arg
redirectArg = do
  opName <- try $ choice $ symbol <$> [ "<", ">", "2>" ]
  path <- T.unpack <$> notSpaceOrPipe
  return $ Redirect (opName, path)

distributeArgs :: [Arg] -> ([Text], [(Text, Path)])
distributeArgs (Redirect (op, path):t) = (genericArgs, (op, path):redirectArgs)
  where
    (genericArgs, redirectArgs) = distributeArgs t
distributeArgs (Generic arg:t) = (arg:genericArgs, redirectArgs)
  where
    (genericArgs, redirectArgs) = distributeArgs t
distributeArgs [] = ([], [])

constructCommand :: String -> [(Text, Path)] -> [Text] -> Command
constructCommand name [] args = GenericCmd name args
constructCommand name (("<", path):t) args = RedirectIn path $ constructCommand name t args
constructCommand name ((">", path):t) args = RedirectOut path $ constructCommand name t args
constructCommand name (("2>", path):t) args = RedirectErr path $ constructCommand name t args


commandParser :: Parser Command
commandParser = sc >> noCommand <|> pCommandList

noCommand :: Parser Command
noCommand = DoNothing <$ eof

pLet :: Parser Command
pLet = pLetAlias <|> pLetVar

pLetAlias :: Parser Command
pLetAlias =
  AliasCmd <$ pKeyword "alias" <*> pName <* symbol "=" <*> (T.unpack <$> genericArgument)

pLetVar :: Parser Command
pLetVar = do
  var <- pName
  symbol "="
  DeclCmd var <$> pExpr


addPrefix :: String -> Parser ()
addPrefix s = do
  inp <- getInput
-- TODO: this will not do when input is script file, O(n^2) complexity!
  setInput $ T.snoc (T.pack s) ' ' `T.append` inp
--  inp' <- getInput
--  liftIO $ putStrLn $ "new input: \"" ++ T.unpack inp' ++ "\""

addAliasPrefix :: String -> Parser ()
addAliasPrefix s = getAlias s >>= addPrefix

pCommand :: Parser Command
pCommand = do
  name <- pName
  if name == "let"
    then pLet
    else do
    ifM (isAlias name) (addAliasPrefix name) (addPrefix name)
    name' <- pName
    (genericArgs, redirectArgs) <- distributeArgs <$> many (redirectArg <|> genericArg)
    return $ constructCommand name' redirectArgs genericArgs

pCommandList :: Parser Command
pCommandList = foldl1 Pipe <$> pCommand `sepBy1` symbol "|"

genericCommandGuide :: ParseGuide [Text]
genericCommandGuide = Many AnyStr

parserFromGuide :: ParseGuide a -> Parser a
parserFromGuide = go
  where
    go :: ParseGuide a -> Parser a
    go NoArgs = return ()
    go (Many l) = many (go l)
    go (a :+: b) = (,) <$> go a <*> go b
    go (a :>: b) = go a >> go b
    go (ExactStr s) = symbol (T.pack s)
    go (Discard a) = void (go a)
    go AnyStr = genericArgument
    go AnyInt = integer
