
-- A simple parser for the Frank language
{-# LANGUAGE PackageImports #-}
module Parser (runTokenProgParse, runTokenParse, tm) where

import Control.Applicative
import Control.Monad
import Control.Monad.IO.Class

import Data.Char
import qualified Data.Map.Strict as M
import qualified Data.HashSet as HashSet

import Text.Trifecta
import Text.Trifecta.Delta
import "indentation-trifecta" Text.Trifecta.Indentation

import Text.Parser.Token as Tok
import Text.Parser.Token.Style
import qualified Text.Parser.Token.Highlight as Hi

import qualified Data.ByteString.Char8 as Char8

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, assertEqual, assertFailure, Assertion)

import BwdFwd
import Syntax
import ParserCommon
import Debug

---------------------------
-- Top-level definitions --
---------------------------

-- the eof disallows gibberish at the end of the file!
prog :: (MonadicParsing m) => m (Prog Raw)
prog = MkProg <$ whiteSpace <*> do tts <- many def; eof; return tts

def :: MonadicParsing m => m (TopTm Raw)
def = attachLoc (DataTm <$> dataDef <|>
                 SigTm <$> try handlerTopSig <|>
                 ClsTm <$> handlerTopCls <|>
                 ItfTm <$> try itfDef <|>
                 ItfAliasTm <$> itfAliasDef)

dataDef :: MonadicParsing m => m (DataT Raw)
dataDef = attachLoc $ do reserved "data"
                         name <- identifier
                         ps <- many tyVar
                         symbol "="
                         cs <- localIndentation Gt ctrList
                         return $ DT name ps cs

tyVar :: MonadicParsing m => m (Id, Kind)
tyVar = (\x -> (x, ET)) <$> brackets evar <|>
        (\x -> (x, VT)) <$> identifier

evar :: MonadicParsing m => m Id
evar = do mx <- optional identifier
          case mx of
            Nothing -> return "£"
            Just x -> return x

ctrList :: MonadicParsing m => m [Ctr Raw]
ctrList = sepBy ctr (symbol "|")

ctr :: MonadicParsing m => m (Ctr Raw)
ctr = attachLoc $ do name <- identifier
                     args <- many vtype'
                     return $ Ctr name args

handlerTopSig :: MonadicParsing m => m (MHSig Raw)
handlerTopSig = attachLoc $ do name <- identifier
                               symbol ":"
                               ty <- sigType
                               return (Sig name ty)

-- As the outer braces are optional in top-level signatures we require
-- that plain pegs must have explicit ability brackets.
--
-- The following collections of signatures are equivalent:
--
--   f : {A -> B -> C}  and  f : A -> B -> C
--   x : {Int}  and  x : {[]Int}  and x : []Int
--
-- A signature of the form
--
--   x : Int
--
-- is not currently valid. Once we add support for top level values it
-- will become valid, but will not mean the same thing as:
--
--   x : []Int
sigType :: MonadicParsing m => m (CType Raw)
sigType = (do a <- getLoc
              symbol "{"
              ct <- ctype
              symbol "}"
              rest <- optional (symbol "->" *> ctype)
              return $
                case rest of
                  Nothing -> modifyAnn a ct
                  Just (CType ports peg a') ->
                        CType (Port idAdjRaw (SCTy ct a') a' : ports) peg a) <|>
          attachLoc (do ports <- some (try (port <* symbol "->"))
                        peg <- peg
                        return $ CType ports peg) <|>
          attachLoc (do peg <- pegExplicit
                        return $ CType [] peg)

handlerTopCls :: MonadicParsing m => m (MHCls Raw)
handlerTopCls = provideLoc $ \a -> do
                  name <- identifier
                  ps <- choice [some pattern, symbol "!" >> return []]
                  symbol "="
                  seq <- localIndentation Gt tm
                  return $ MHCls name (Cls ps seq a) a

itfDef :: MonadicParsing m => m (Itf Raw)
itfDef = attachLoc $ do
             reserved "interface"
             name <- identifier
             ps <- many tyVar
             symbol "="
             xs <- localIndentation Gt $ sepBy1 cmdDef (symbol "|")
             return (Itf name ps xs)

cmdDef :: MonadicParsing m => m (Cmd Raw)
cmdDef = attachLoc $ do cmd <- identifier
                        ps <- many tyVar  -- polymorphic commands
                        symbol ":"
                        (xs,y) <- cmdDefType
                        return (Cmd cmd ps xs y)

-- input types, output type
cmdDefType :: MonadicParsing m => m ([VType Raw], VType Raw)
cmdDefType = do vs <- sepBy1 vtype (symbol "->")
                if length vs == 1 then return ([],head vs)
                else return (init vs, last vs)

itfAliasDef :: MonadicParsing m => m (ItfAlias Raw)
itfAliasDef = attachLoc $ do reserved "interface"
                             name <- identifier
                             ps <- many tyVar
                             symbol "="
                             symbol "["
                             m <- itfInstances
                             symbol "]"
                             return $ ItfAlias name ps m

-----------
-- Types --
-----------

ctype :: MonadicParsing m => m (CType Raw)
ctype = attachLoc $ do ports <- many (try (port <* symbol "->"))
                       peg <- peg
                       return $ CType ports peg

port :: MonadicParsing m => m (Port Raw)
port = attachLoc $ do adj <- adj
                      ty <- vtype
                      return $ Port adj ty

peg :: MonadicParsing m => m (Peg Raw)
peg = attachLoc $ do ab <- ab
                     ty <- vtype
                     return $ Peg ab ty

pegExplicit :: MonadicParsing m => m (Peg Raw)
pegExplicit = attachLoc $ do ab <- abExplicit
                             ty <- vtype
                             return $ Peg ab ty

adj :: MonadicParsing m => m (Adj Raw)
adj = provideLoc $ \a -> do
              mItfMap <- optional $ angles itfInstances
              case mItfMap of
                Nothing -> return $ Adj (ItfMap M.empty a) a
                Just itfMap -> return $ Adj itfMap a

-- TODO: LC: Name consistently `instances` or `instantiations`
itfInstances :: MonadicParsing m => m (ItfMap Raw)
itfInstances = do
  a <- getLoc
  insts <- sepBy itfInstance (symbol ",")
  return $ foldl addInstanceToItfMap (ItfMap M.empty a) insts

ab :: MonadicParsing m => m (Ab Raw)
ab = do mxs <- optional $ abExplicit
        case mxs of
          Nothing -> provideLoc $ \a ->
            return $ Ab (AbVar "£" a) (ItfMap M.empty a) a
          Just ab -> return ab

abExplicit :: MonadicParsing m => m (Ab Raw)
abExplicit = brackets abBody

-- 0 | 0|Interfaces | E|Interfaces | Interfaces
abBody :: MonadicParsing m => m (Ab Raw)
abBody = provideLoc $ \a ->
           -- closed ability: [0] or [0 | i_1, ... i_n]
           (do symbol "0"
               m <- option (ItfMap M.empty a) (symbol "|" *> itfInstances)
               return $ Ab (EmpAb a) m a) <|>
           -- open ability:   [i_1, ..., i_n] (implicitly e := £) or [e | i_1, ..., i_n]
           (do e <- option (AbVar "£" a) (try $ AbVar <$> identifier <* symbol "|" <*> pure a)
               m <- itfInstances
               return $ Ab e m a)

itfInstance :: MonadicParsing m => m (Id, [TyArg Raw])
itfInstance = do x <- identifier
                 ts <- many tyArg
                 return (x, ts)

-- This parser gives higher precedence to MkDTTy when coming across "X"
-- E.g., the type "X" becomes   MkDTTy "X" []   (instead of MkTVar "X")
vtype :: MonadicParsing m => m (VType Raw)
vtype = try dataInstance <|> -- could possibly also be a MKTvar (determined
                                 -- during refinement)
             vtype'

-- This parser gives higher precedence to MkTVar when coming across "X"
-- E.g., the type "X" becomes   MkTVar "X"   (instead of MkDTTy "X" [])
-- By writing "(X)" one can escape back to vtype
vtype' :: MonadicParsing m => m (VType Raw)
vtype' = parens vtype <|>
              (attachLoc $ SCTy <$> try (braces ctype)) <|>
              (attachLoc $ StringTy <$ reserved "String") <|>
              (attachLoc $ IntTy <$ reserved "Int") <|>
              (attachLoc $ CharTy <$ reserved "Char") <|>
              -- could possibly also be a MkDTTy (determined during refinement)
              (attachLoc $ TVar <$> identifier)

tyArg :: MonadicParsing m => m (TyArg Raw)
tyArg = attachLoc $ VArg <$> vtype' <|>
                         EArg <$> abExplicit

-- Parse a potential datatype. Note it may actually be a type variable.
dataInstance :: MonadicParsing m => m (VType Raw)
dataInstance = attachLoc $ do x <- identifier
                              args <- localIndentation Gt $ many tyArg
                              return $ DTTy x args

-----------
-- Terms --
-----------

-- term
tm :: MonadicParsing m => m (Tm Raw)                  -- ltm ; ... ; ltm
tm = provideLoc $ \a -> do
       t <- ltm
       m <- optional $ symbol ";"
       case m of
         Just _ -> do t' <- tm
                      return $ TmSeq t t' a
         Nothing -> return t

-- let-term
ltm :: MonadicParsing m => m (Tm Raw)
ltm = parseLet tm tm <|>                              -- let x = tm in tm
      btm                                             -- btm

-- binary operation term (takes care of associativity)
btm :: MonadicParsing m => m (Tm Raw)
btm = do t <- utm
         binOperation t
  where
    binOperation :: (MonadicParsing m) => Tm Raw -> m (Tm Raw)
    binOperation t =
      (provideLoc $ \a -> do
         operator <- binOpLeft                        -- utm +  ...  + utm
         t' <- utm
         binOperation (Use (RawComb operator [t, t'] a) a)) <|>
      (provideLoc $ \a -> do
         operator <- binOpRight                       -- utm :: ... :: utm
         t' <- btm
         binOperation (Use (RawComb operator [t, t'] a) a)) <|>
      (return t)

-- unary operation term
utm :: MonadicParsing m => m (Tm Raw)
utm = unOperation <|>                                 -- - utm
      ctm                                             -- ctm
  where
    unOperation :: (MonadicParsing m) => m (Tm Raw)
    unOperation = provideLoc $ \a -> do
                    symbol "-"
                    t <- utm
                    return $ Use (RawComb (RawId "-" a) [IntTm 0 a, t] a) a

-- nun-nullary comb term
ctm :: MonadicParsing m => m (Tm Raw)
ctm = (attachLoc $ Use <$> comb) <|>                  -- comb
      nctm                                            -- nctm

-- nullary comb term
nctm :: MonadicParsing m => m (Tm Raw)
nctm = (attachLoc $ Use <$> nullaryComb) <|>          -- nullaryComb
       atm                                            -- atm

-- atomic term
atm :: MonadicParsing m => m (Tm Raw)
atm = (attachLoc $ Use <$> idUse) <|>                 -- x
      (attachLoc $ SC <$> suspComp) <|>               -- { p_1 -> t_1 | ... }
      (attachLoc $ StrTm <$> stringLiteral) <|>       -- "string"
      (attachLoc $ IntTm <$> natural) <|>             -- 42
      (attachLoc $ CharTm <$> charLiteral) <|>        -- 'c'
      (attachLoc $ ListTm <$> listTm) <|>             -- [t_1, ..., t_n]
      parens tm                                       -- (tm ; ... ; tm)

comb :: MonadicParsing m => m (Use Raw)
comb = attachLoc $ try $ do
         x <- choice [idUse,                          --      x nctm ... nctm   or      x!
                      parens comb]                    -- (comb) nctm ... nctm   or (comb)!
         args <- choice [some nctm, symbol "!" >> return []]
         return $ RawComb x args

nullaryComb :: MonadicParsing m => m (Use Raw)
nullaryComb = attachLoc $ try $ do
                x <- choice [idUse,                 --      x!
                             parens comb]             -- (comb)!
                symbol "!"
                return $ RawComb x []

idUse :: MonadicParsing m => m (Use Raw)
idUse = attachLoc $ do x <- identifier
                       return $ RawId x

parseLet :: MonadicParsing m => m (Tm Raw) -> m (Tm Raw) -> m (Tm Raw)
parseLet p p' = attachLoc $ do reserved "let"
                               x <- identifier
                               symbol "="
                               t <- p
                               reserved "in"
                               t' <- p'
                               return $ Let x t t'

listTm :: MonadicParsing m => m [Tm Raw]              -- [t_1, ..., t_n]
listTm = brackets (sepBy tm (symbol ","))

suspComp :: MonadicParsing m => m (SComp Raw)
suspComp = attachLoc $ localIndentation Gt $ absoluteIndentation $
             do cs <- braces $ sepBy anonymousCls (symbol "|")
                return $ SComp cs

anonymousCls :: MonadicParsing m => m (Clause Raw)
anonymousCls = attachLoc $ do ps <- choice [try patterns, pure []]
                              seq <- tm
                              return $ Cls ps seq
  where patterns = do
          ps <- choice [some pattern, symbol "!" >> return []]
          symbol "->"
          return ps

binOpLeft :: MonadicParsing m => m (Use Raw)
binOpLeft = attachLoc $ do op <- choice $ map symbol ["+","-","*","/"]
                           return $ RawId op

binOpRight :: MonadicParsing m => m (Use Raw)
binOpRight = attachLoc $ do op <- choice $ map symbol ["::"]
                            let op' = if op == "::" then "cons" else op
                            return $ RawId op'

--------------
-- Patterns --
--------------

pattern :: MonadicParsing m => m (Pattern Raw)
pattern = try compPat <|> (attachLoc $ VPat <$> valPat)

compPat :: MonadicParsing m => m (Pattern Raw)
compPat = between (symbol "<") (symbol ">") $
            try cmdPat <|> thunkPat

thunkPat :: MonadicParsing m => m (Pattern Raw)
thunkPat = attachLoc $ do x <- identifier
                          return (ThkPat x)

cmdPat :: MonadicParsing m => m (Pattern Raw)
cmdPat = attachLoc $ do cmd <- identifier
                        ps <- many valPat
                        symbol "->"
                        g <- identifier
                        return (CmdPat cmd ps g)

valPat :: MonadicParsing m => m (ValuePat Raw)
valPat = dataPat <|>
         (attachLoc $ do x <- identifier
                         return $ VarPat x) <|>
         (attachLoc $ IntPat <$> try integer) <|> -- try block for unary minus
         (attachLoc $ CharPat <$> charLiteral) <|>
         (attachLoc $ StrPat <$> stringLiteral) <|>
         (attachLoc $ ListPat <$> brackets (sepBy valPat (symbol ",")))

dataPat :: MonadicParsing m => m (ValuePat Raw)
dataPat = attachLoc $ parens $ ((try (do p <- valPat
                                         symbol "::"
                                         q <- valPat
                                         return $ ConsPat p q)) <|>
                                   (do k <- identifier
                                       ps <- many valPat
                                       return $ DataPat k ps))

----------------------
-- Helper functions --
----------------------

evalCharIndentationParserT :: Monad m => FrankParser Char m a ->
                              IndentationState -> m a
evalCharIndentationParserT = evalIndentationParserT . runFrankParser

evalTokenIndentationParserT :: Monad m => FrankParser Token m a ->
                               IndentationState -> m a
evalTokenIndentationParserT = evalIndentationParserT . runFrankParser

--TODO: LC: Give types, make parsing-interface clearer
runParse ev p input =
   let indA = ev p $ mkIndentationState 0 infIndentation True Ge
   in case parseString indA (Directed Char8.empty 0 0 0 0) input of
    Failure err -> Left (show err)
    Success t -> Right t

runProgParse ev input = runParse ev prog input

-- runParseFromFileEx ev p fname =
--   let indA = ev p $ mkIndentationState 0 infIndentation True Ge in
--   do res <- parseFromFileEx indA fname
--      case res of
--        Failure err -> return $ Left (show err)
--        Success t -> return $ Right t

-- runProgParseFromFileEx ev fname = runParseFromFileEx ev prog fname

-- runTokenParseFromFile :: (MonadIO m, Applicative m, MonadicParsing m) =>
--                          String -> m (Either String (Prog Raw))
-- runTokenParseFromFile = runProgParseFromFileEx evalTokenIndentationParserT

runTokenParse p = runParse evalTokenIndentationParserT p
runTokenProgParse = runProgParse evalTokenIndentationParserT

getLoc :: (MonadicParsing m) => m Raw
getLoc = do r <- rend
            line <- line
            pos <- position
            case delta r of
              (Directed _ l c _ _) -> return $ Raw $ InCode (fromIntegral l + 1, fromIntegral c + 1)
              _ -> error "precondition not fulfilled"

attachLoc :: (MonadicParsing m) => m (Raw -> AnnotTFix Raw f) -> m (AnnotTFix Raw f)
attachLoc parser = do a <- getLoc
                      parser <*> pure a

provideLoc :: (MonadicParsing m) => (Raw -> m (AnnotTFix Raw f)) -> m (AnnotTFix Raw f)
provideLoc parser = do a <- getLoc
                       parser a


-- Tests
input = [ "tests/evalState.fk"
        , "tests/listMap.fk"
        , "tests/suspended_computations.fk"
        , "tests/fib.fk"
        , "tests/paper.fk"]

--outputc = map runCharParseFromFile input
--outputt = map runTokenParseFromFile input

assertParsedOk :: (Show err, Show a, Eq a) => IO (Either err a) -> IO a
                  -> Assertion
assertParsedOk actual expected =
  do x <- actual
     case x of
       Right ok -> do y <- expected
                      assertEqual "parsing succeeded, but " y ok
       Left err -> do y <- expected
                      assertFailure ("parse failed with " ++ show err
                                     ++ ", expected " ++ show y)
