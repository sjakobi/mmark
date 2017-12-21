-- |
-- Module      :  Text.MMark.Parser
-- Copyright   :  © 2017 Mark Karpov
-- License     :  BSD 3 clause
--
-- Maintainer  :  Mark Karpov <markkarpov92@gmail.com>
-- Stability   :  experimental
-- Portability :  portable
--
-- MMark markdown parser.

{-# LANGUAGE BangPatterns      #-}
{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes        #-}
{-# LANGUAGE TypeFamilies      #-}

module Text.MMark.Parser
  ( MMarkErr (..)
  , parse )
where

import Control.Applicative
import Control.Monad
import Data.Bifunctor (Bifunctor (..))
import Data.HTML.Entities (htmlEntityMap)
import Data.List.NonEmpty (NonEmpty (..), (<|))
import Data.Maybe (isNothing, fromJust, fromMaybe, catMaybes)
import Data.Monoid (Any (..))
import Data.Semigroup (Semigroup (..))
import Data.Text (Text)
import Data.Void
import Text.MMark.Internal
import Text.MMark.Parser.Internal
import Text.Megaparsec hiding (parse, State (..))
import Text.Megaparsec.Char hiding (eol)
import Text.URI (URI)
import qualified Control.Applicative.Combinators.NonEmpty as NE
import qualified Data.Char                  as Char
import qualified Data.HashMap.Strict        as HM
import qualified Data.List.NonEmpty         as NE
import qualified Data.Set                   as E
import qualified Data.Text                  as T
import qualified Data.Text.Encoding         as TE
import qualified Data.Yaml                  as Yaml
import qualified Text.Email.Validate        as Email
import qualified Text.Megaparsec.Char.Lexer as L
import qualified Text.URI                   as URI

----------------------------------------------------------------------------
-- Auxiliary data types

-- | Frame that describes where we are in parsing inlines.

data InlineFrame
  = EmphasisFrame      -- ^ Emphasis with asterisk @*@
  | EmphasisFrame_     -- ^ Emphasis with underscore @_@
  | StrongFrame        -- ^ Strong emphasis with asterisk @**@
  | StrongFrame_       -- ^ Strong emphasis with underscore @__@
  | StrikeoutFrame     -- ^ Strikeout
  | SubscriptFrame     -- ^ Subscript
  | SuperscriptFrame   -- ^ Superscript
  deriving (Eq, Ord, Show)

-- | State of inline parsing that specifies whether we expect to close one
-- frame or there is a possibility to close one of two alternatives.

data InlineState
  = SingleFrame InlineFrame             -- ^ One frame to be closed
  | DoubleFrame InlineFrame InlineFrame -- ^ Two frames to be closed
  deriving (Eq, Ord, Show)

-- | An auxiliary type for collapsing levels of 'Either's.

data Pair s a
  = PairL s
  | PairR ([a] -> [a])

instance Semigroup s => Semigroup (Pair s a) where
  (PairL l) <> (PairL r) = PairL (l <> r)
  (PairL l) <> (PairR _) = PairL l
  (PairR _) <> (PairL r) = PairL r
  (PairR l) <> (PairR r) = PairR (l . r)

instance Semigroup s => Monoid (Pair s a) where
  mempty  = PairR id
  mappend = (<>)

----------------------------------------------------------------------------
-- Top-level API

-- | Parse a markdown document in the form of a strict 'Text' value and
-- either report parse errors or return an 'MMark' document. Note that the
-- parser has the ability to report multiple parse errors at once.

parse
  :: FilePath
     -- ^ File name (only to be used in error messages), may be empty
  -> Text
     -- ^ Input to parse
  -> Either (NonEmpty (ParseError Char MMarkErr)) MMark
     -- ^ Parse errors or parsed document
parse file input =
  case runBParser pMMark file input of
    -- NOTE This parse error only happens when document structure on block
    -- level cannot be parsed even with recovery, which should not normally
    -- happen except for the cases when we deal with YAML parsing errors.
    Left errs -> Left errs
    Right ((myaml, rawBlocks), defs) ->
      let parsed = doInline <$> rawBlocks
          doInline = fmap
            $ first (nes . replaceEof "end of inline block")
            . runIParser defs pInlinesTop
          f block =
            case foldMap e2p block of
              PairL errs -> PairL errs
              PairR _    -> PairR (fmap fromRight block :)
      in case foldMap f parsed of
           PairL errs   -> Left errs
           PairR blocks -> Right MMark
             { mmarkYaml      = myaml
             , mmarkBlocks    = blocks []
             , mmarkExtension = mempty }

----------------------------------------------------------------------------
-- Block parser

-- | Parse an MMark document on block level.

pMMark :: BParser (Maybe Yaml.Value, [Block Isp])
pMMark = do
  meyaml <- optional pYamlBlock
  setTabWidth (mkPos 4)
  blocks <- pBlocks
  eof
  return $ case meyaml of
    Nothing ->
      (Nothing, blocks)
    Just (Left (pos, err)) ->
      (Nothing, prependErr pos (YamlParseError err) blocks)
    Just (Right yaml) ->
      (Just yaml, blocks)

-- | Parse a YAML block. On success return the actual parsed 'Yaml.Value' in
-- 'Right', otherwise return 'SourcePos' of parse error and 'String'
-- describing the error as generated by the @yaml@ package in 'Left'.

pYamlBlock :: BParser (Either (SourcePos, String) Yaml.Value)
pYamlBlock = do
  dpos <- getPosition
  string "---" *> sc' *> eol
  let go = do
        l <- takeWhileP Nothing notNewline
        void (optional eol)
        e <- atEnd
        if e || T.stripEnd l == "---"
          then return []
          else (l :) <$> go
  ls <- go
  case (Yaml.decodeEither . TE.encodeUtf8 . T.intercalate "\n") ls of
    Left err' -> do
      let (apos, err) = splitYamlError (sourceName dpos) err'
      return $ Left (fromMaybe dpos apos, err)
    Right v ->
      return (Right v)

-- | Parse several (possibly zero) blocks in a row.

pBlocks :: BParser [Block Isp]
pBlocks = catMaybes <$> many pBlock

-- | Parse a single block of markdown document.

pBlock :: BParser (Maybe (Block Isp))
pBlock = do
  sc
  rlevel <- refLevel
  alevel <- L.indentLevel
  done   <- atEnd
  if done || alevel < rlevel then empty else
    case compare alevel (ilevel rlevel) of
      LT -> choice
        [ Just <$> pThematicBreak
        , Just <$> pAtxHeading
        , Just <$> pFencedCodeBlock
        , Just <$> pUnorderedList
        , Just <$> pOrderedList
        , Just <$> pBlockquote
        , Nothing <$ pReferenceDef
        , Just <$> pParagraph ]
      _  ->
          Just <$> pIndentedCodeBlock

-- | Parse a thematic break.

pThematicBreak :: BParser (Block Isp)
pThematicBreak = do
  l' <- lookAhead nonEmptyLine
  let l = T.filter (not . isSpace) l'
  if T.length l >= 3   &&
     (T.all (== '*') l ||
      T.all (== '-') l ||
      T.all (== '_') l)
    then ThematicBreak <$ nonEmptyLine <* sc
    else empty

-- | Parse an ATX heading.

pAtxHeading :: BParser (Block Isp)
pAtxHeading = do
  (void . lookAhead . try) hashIntro
  withRecovery recover $ do
    hlevel <- length <$> hashIntro
    sc1'
    ispPos <- getPosition
    r <- someTill (satisfy notNewline <?> "heading character") . try $
      optional (sc1' *> some (char '#') *> sc') *> (eof <|> eol)
    let toBlock = case hlevel of
          1 -> Heading1
          2 -> Heading2
          3 -> Heading3
          4 -> Heading4
          5 -> Heading5
          _ -> Heading6
    toBlock (IspSpan ispPos (T.strip (T.pack r))) <$ sc
  where
    hashIntro = count' 1 6 (char '#')
    recover err =
      Heading1 (IspError err) <$ takeWhileP Nothing notNewline <* sc

-- | Parse a fenced code block.

pFencedCodeBlock :: BParser (Block Isp)
pFencedCodeBlock = do
  alevel <- L.indentLevel
  (ch, n, infoString) <- pOpeningFence
  let content = label "code block content" (option "" nonEmptyLine <* eol)
  ls <- manyTill content (pClosingFence ch n)
  CodeBlock infoString (assembleCodeBlock alevel ls) <$ sc

-- | Parse the opening fence of a fenced code block.

pOpeningFence :: BParser (Char, Int, Maybe Text)
pOpeningFence = p '`' <|> p '~'
  where
    p ch = try $ do
      void $ count 3 (char ch)
      n  <- (+ 3) . length <$> many (char ch)
      ml <- optional
        (T.strip <$> someEscapedWith notNewline <?> "info string")
      guard (maybe True (not . T.any (== '`')) ml)
      (ch, n,
         case ml of
           Nothing -> Nothing
           Just l  ->
             if T.null l
               then Nothing
               else Just l) <$ eol

-- | Parse the closing fence of a fenced code block.

pClosingFence :: Char -> Int -> BParser ()
pClosingFence ch n =  try . label "closing code fence" $ do
  clevel <- ilevel <$> refLevel
  void $ L.indentGuard sc' LT clevel
  void $ count n (char ch)
  (void . many . char) ch
  sc'
  eof <|> eol

-- | Parse an indented code block.

pIndentedCodeBlock :: BParser (Block Isp)
pIndentedCodeBlock = do
  alevel <- L.indentLevel
  clevel <- ilevel <$> refLevel
  let go ls = do
        indented <- lookAhead $
          (>= clevel) <$> (sc *> L.indentLevel)
        if indented
          then do
            l        <- option "" nonEmptyLine
            continue <- eol'
            let ls' = ls . (l:)
            if continue
              then go ls'
              else return ls'
          else return ls
      -- NOTE This is a bit unfortunate, but it's difficult to guarantee
      -- that preceding space is not yet consumed when we get to
      -- interpreting input as an indented code block, so we need to restore
      -- the space this way.
      f x      = T.replicate (unPos alevel - 1) " " <> x
      g []     = []
      g (x:xs) = f x : xs
  ls <- g . ($ []) <$> go id
  CodeBlock Nothing (assembleCodeBlock clevel ls) <$ sc

-- | Parse an unorederd list.

pUnorderedList :: BParser (Block Isp)
pUnorderedList = do
  (bullet, bulletPos, minLevel, indLevel) <-
    pListBullet Nothing
  x      <- innerBlocks bulletPos minLevel indLevel
  xs     <- many $ do
    (_, bulletPos', minLevel', indLevel') <-
      pListBullet (Just (bullet, bulletPos))
    innerBlocks bulletPos' minLevel' indLevel'
  return (UnorderedList (normalizeListItems (x:|xs)))
  where
    innerBlocks bulletPos minLevel indLevel = do
      p <- getPosition
      let tooFar = sourceLine p > sourceLine bulletPos <> pos1
          rlevel = slevel minLevel indLevel
      if tooFar || sourceColumn p < minLevel
        then return [if tooFar then emptyParagraph else emptyNaked]
        else subEnv True rlevel pBlocks

-- | Parse a list bullet. Return a tuple with the following components (in
-- order):
--
--     * 'Char' used to represent the bullet
--     * 'SourcePos' at which the bullet was located
--     * the closest column position where content could start
--     * the indentation level after the bullet

pListBullet
  :: Maybe (Char, SourcePos)
     -- ^ Bullet 'Char' and start position of the first bullet in a list
  -> BParser (Char, SourcePos, Pos, Pos)
pListBullet mbullet = try $ do
  pos     <- getPosition
  l       <- (<> mkPos 2) <$> L.indentLevel
  bullet  <-
    case mbullet of
      Nothing -> char '-' <|> char '+' <|> char '*'
      Just (bullet, bulletPos) -> do
        guard (sourceColumn pos >= sourceColumn bulletPos)
        char bullet
  eof <|> sc1
  l'      <- L.indentLevel
  return (bullet, pos, l, l')

-- | Parse an ordered list.

pOrderedList :: BParser (Block Isp)
pOrderedList = do
  (startIx, del, startPos, minLevel, indLevel) <-
    pListIndex Nothing
  x  <- innerBlocks startPos minLevel indLevel
  xs <- manyIndexed (startIx + 1) $ \expectedIx -> do
    (actualIx, _, startPos', minLevel', indLevel') <-
      pListIndex (Just (del, startPos))
    let f blocks =
          if actualIx == expectedIx
            then blocks
            else prependErr
                   startPos'
                   (ListIndexOutOfOrder actualIx expectedIx)
                   blocks
    f <$> innerBlocks startPos' minLevel' indLevel'
  return . OrderedList startIx . normalizeListItems $
    (if startIx <= 999999999
       then x
       else prependErr startPos (ListStartIndexTooBig startIx) x)
    :| xs
  where
    innerBlocks indexPos minLevel indLevel = do
      p <- getPosition
      let tooFar = sourceLine p > sourceLine indexPos <> pos1
          rlevel = slevel minLevel indLevel
      if tooFar || sourceColumn p < minLevel
        then return [if tooFar then emptyParagraph else emptyNaked]
        else subEnv True rlevel pBlocks

-- | Parse a list index. Return a tuple with the following components (in
-- order):
--
--     * 'Word' parsed numeric index
--     * 'Char' used as delimiter after the numeric index
--     * 'SourcePos' at which the index was located
--     * the closest column position where content could start
--     * the indentation level after the index

pListIndex
  :: Maybe (Char, SourcePos)
     -- ^ Delimiter 'Char' and start position of the first index in a list
  -> BParser (Word, Char, SourcePos, Pos, Pos)
pListIndex mstart = try $ do
  pos <- getPosition
  i   <- L.decimal
  del <- case mstart of
    Nothing -> char '.' <|> char ')'
    Just (del, startPos) -> do
      guard (sourceColumn pos >= sourceColumn startPos)
      char del
  l   <- (<> pos1) <$> L.indentLevel
  eof <|> sc1
  l'  <- L.indentLevel
  return (i, del, pos, l, l')

-- | Parse a block quote.

pBlockquote :: BParser (Block Isp)
pBlockquote = do
  minLevel <- try $ do
    minLevel <- (<> pos1) <$> L.indentLevel
    void (char '>')
    eof <|> sc
    l <- L.indentLevel
    return $
      if l > minLevel
        then minLevel <> pos1
        else minLevel
  indLevel <- L.indentLevel
  if indLevel >= minLevel
    then do
      let rlevel = slevel minLevel indLevel
      xs <- subEnv False rlevel pBlocks
      return (Blockquote xs)
    else return (Blockquote [])

-- | Parse a link\/image reference definition and register it.

pReferenceDef :: BParser ()
pReferenceDef = do
  (pos, dlabel) <- try $ pRefLabel <* char ':'
  sc' <* optional eol <* sc'
  uri <- pUri
  mtitle <- optional . try $ do
    try (sc1' *> optional eol *> sc') <|> (sc' *> eol *> sc')
    pTitle
  sc'
  eof <|> eol
  conflict <- registerReference dlabel (uri, mtitle)
  when conflict $ do
    setPosition pos
    customFailure (DuplicateReferenceDefinition dlabel)
  sc

-- | Parse a paragraph or naked text (is some cases).

pParagraph :: BParser (Block Isp)
pParagraph = do
  startPos   <- getPosition
  allowNaked <- isNakedAllowed
  rlevel     <- refLevel
  let go ls = do
        l <- lookAhead (option "" nonEmptyLine)
        broken <- succeeds . lookAhead . try $ do
          sc
          alevel <- L.indentLevel
          guard (alevel < ilevel rlevel)
          unless (alevel < rlevel) . choice $
            [ void (char '>')
            , void pThematicBreak
            , void pAtxHeading
            , void pOpeningFence
            , void (pListBullet Nothing)
            , void (pListIndex  Nothing) ]
        if isBlank l
          then return (ls, Paragraph)
          else if broken
                 then return (ls, Naked)
                 else do
                   void nonEmptyLine
                   continue <- eol'
                   let ls' = ls . (l:)
                   if continue
                     then go ls'
                     else return (ls', Naked)
  l        <- nonEmptyLine
  continue <- eol'
  (ls, toBlock) <-
    if continue
      then go id
      else return (id, Naked)
  (if allowNaked then toBlock else Paragraph)
    (IspSpan startPos (assembleParagraph (l:ls []))) <$ sc

----------------------------------------------------------------------------
-- Inline parser

-- | The top level inline parser.

pInlinesTop :: IParser (NonEmpty Inline)
pInlinesTop = do
  inlines <- pInlines
  eof <|> void pLfdr
  return inlines

-- | Parse inlines using settings from given 'InlineConfig'.

pInlines :: IParser (NonEmpty Inline)
pInlines = do
  done        <- hidden atEnd
  allowsEmpty <- isEmptyAllowed
  if done
    then
      if allowsEmpty
        then (return . nes . Plain) ""
        else unexpEic EndOfInput
    else NE.some $ do
      mch <- lookAhead (anyChar <?> "inline content")
      case mch of
        '`' -> pCodeSpan
        '[' -> do
          allowsLinks <- isLinksAllowed
          if allowsLinks
            then pLink
            else unexpEic (Tokens $ nes '[')
        '!' -> do
          gotImage <- (succeeds . void . lookAhead . string) "!["
          allowsImages <- isImagesAllowed
          if gotImage
            then if allowsImages
                   then pImage
                   else unexpEic (Tokens . NE.fromList $ "![")
            else pPlain
        '<' -> do
          allowsLinks <- isLinksAllowed
          if allowsLinks
            then try pAutolink <|> pPlain
            else pPlain
        '\\' ->
          try pHardLineBreak <|> pPlain
        ch ->
          if isFrameConstituent ch
            then pEnclosedInline
            else pPlain

-- | Parse a code span.

pCodeSpan :: IParser Inline
pCodeSpan = do
  n <- try (length <$> some (char '`'))
  let finalizer = try $ do
        void $ count n (char '`')
        notFollowedBy (char '`')
  r <- CodeSpan . collapseWhiteSpace . T.concat <$>
    manyTill (label "code span content" $
               takeWhile1P Nothing (== '`') <|>
               takeWhile1P Nothing (/= '`'))
      finalizer
  r <$ lastOther

-- | Parse a link.

pLink :: IParser Inline
pLink = do
  void (char '[')
  pos <- getPosition
  txt <- disallowLinks (disallowEmpty pInlines)
  void (char ']')
  (dest, mtitle) <- pLocation pos txt
  Link txt dest mtitle <$ lastOther

-- | Parse an image.

pImage :: IParser Inline
pImage = do
  (pos, alt)    <- emptyAlt <|> nonEmptyAlt
  (src, mtitle) <- pLocation pos alt
  Image alt src mtitle <$ lastOther
  where
    emptyAlt = do
      pos <- getPosition
      void (string "![]")
      let alt       = nes (Plain "")
          newColumn = sourceColumn pos <> mkPos 2
      return (pos { sourceColumn = newColumn }, alt)
    nonEmptyAlt = do
      void (string "![")
      pos <- getPosition
      alt <- disallowImages (disallowEmpty pInlines)
      void (char ']')
      return (pos, alt)

-- | Parse an autolink.

pAutolink :: IParser Inline
pAutolink = between (char '<') (char '>') $ do
  uri' <- URI.parser
  let (txt, uri) =
        case isEmailUri uri' of
          Nothing ->
            ( (nes . Plain . URI.render) uri'
            , uri' )
          Just email ->
            ( nes (Plain email)
            , URI.makeAbsolute mailtoScheme uri' )
  Link txt uri Nothing <$ lastOther

-- | Parse inline content inside an enclosing construction such as emphasis,
-- strikeout, superscript, and\/or subscript markup.

pEnclosedInline :: IParser Inline
pEnclosedInline = disallowEmpty $ pLfdr >>= \case
  SingleFrame x ->
    liftFrame x <$> pInlines <* pRfdr x
  DoubleFrame x y -> do
    inlines0  <- pInlines
    thisFrame <- pRfdr x <|> pRfdr y
    let thatFrame = if thisFrame == x then y else x
    minlines1 <- optional pInlines
    void (pRfdr thatFrame)
    return . liftFrame thatFrame $
      case minlines1 of
        Nothing ->
          nes (liftFrame thisFrame inlines0)
        Just inlines1 ->
          liftFrame thisFrame inlines0 <| inlines1

-- | Parse a hard line break.

pHardLineBreak :: IParser Inline
pHardLineBreak = do
  void (char '\\')
  eol
  notFollowedBy eof
  sc'
  lastSpace
  return LineBreak

-- | Parse plain text.

pPlain :: IParser Inline
pPlain = fmap (Plain . bakeText) . foldSome $ do
  ch <- lookAhead (anyChar <?> "inline content")
  let newline' =
        (('\n':) . dropWhile isSpace) <$ eol <* sc' <* lastSpace
  case ch of
    '\\' -> (:) <$>
      ((escapedChar <* lastOther) <|>
        try (char '\\' <* notFollowedBy eol <* lastOther))
    '\n' ->
      newline'
    '\r' ->
      newline'
    '!' -> do
      notFollowedBy (string "![")
      (:) <$> char '!'
    '<' -> do
      notFollowedBy pAutolink
      (:) <$> char '<'
    '&' -> choice
      [ (:) <$> numRef
      , (++) . reverse <$> entityRef
      , (:) <$> char '&' ]
    _ ->
      (:) <$> pOther ch
  where
    pOther ch
      | isSpace ch = char ch <* lastSpace
      | isTrans ch = char ch <* lastSpace
      | isOther ch = char ch <* lastOther
      | otherwise  = failure
          (Just . Tokens . nes $ ch)
          (E.singleton . Label . NE.fromList $ "inline content")
    isTrans x = isTransparentPunctuation x && x /= '!'
    isOther x = not (isMarkupChar x) && x /= '\\' && x /= '!' && x /= '<'

----------------------------------------------------------------------------
-- Auxiliary inline-level parsers

-- | Parse an inline and reference-style link\/image location.

pLocation
  :: SourcePos         -- ^ Location where the content inlines start
  -> NonEmpty Inline   -- ^ The inner content inlines
  -> IParser (URI, Maybe Text) -- ^ URI and optionally title
pLocation innerPos inner = do
  mr <- optional (inplace <|> withRef)
  case mr of
    Nothing ->
      collapsed innerPos inner <|> shortcut innerPos inner
    Just (dest, mtitle) ->
      return (dest, mtitle)
  where
    inplace = do
      void (char '(') <* sc
      dest   <- pUri
      mtitle <- optional (sc1 *> pTitle)
      sc <* char ')'
      return (dest, mtitle)
    withRef =
      pRefLabel >>= uncurry lookupRef
    collapsed pos inlines = do
      -- NOTE We need to do these manipulations so the failure caused by
      -- 'string' "" does not overwrite our custom failures.
      pos' <- getPosition
      setPosition pos
      (void . hidden . string) "[]"
      setPosition pos'
      lookupRef pos (mkLabel inlines)
    shortcut pos inlines =
      lookupRef pos (mkLabel inlines)
    lookupRef pos dlabel =
      lookupReference dlabel >>= \case
        Left names -> do
          setPosition pos
          customFailure (CouldNotFindReferenceDefinition dlabel names)
        Right x ->
          return x
    mkLabel = T.unwords . T.words . asPlainText

-- | Parse a URI.

pUri :: (Ord e, Show e, MonadParsec e Text m) => m URI
pUri = between (char '<') (char '>') URI.parser <|> naked
  where
    naked = do
      let f x = not (isSpaceN x || x == ')')
          l   = "end of URI"
      (s, s') <- T.span f <$> getInput
      when (T.null s) . void $
        (satisfy f <?> "URI") -- this will now fail
      setInput s
      r <- region (replaceEof l) (URI.parser <* label l eof)
      setInput s'
      return r

-- | Parse a title of a link or an image.

pTitle :: MonadParsec MMarkErr Text m => m Text
pTitle = choice
  [ p '\"' '\"'
  , p '\'' '\''
  , p '('  ')' ]
  where
    p start end = between (char start) (char end) $
      let f x = x /= end
      in manyEscapedWith f "unescaped character"

-- | Parse label of a reference link.

pRefLabel :: MonadParsec MMarkErr Text m => m (SourcePos, Text)
pRefLabel = do
  try $ do
    void (char '[')
    notFollowedBy (char ']')
  pos <- getPosition
  sc
  let f x = x /= '[' && x /= ']'
  dlabel <- someEscapedWith f <?> "reference label"
  void (char ']')
  return (pos, dlabel)

-- | Parse an opening markup sequence corresponding to given 'InlineState'.

pLfdr :: IParser InlineState
pLfdr = try $ do
  pos <- getPosition
  let r st = st <$ string (inlineStateDel st)
  st <- hidden $ choice
    [ r (DoubleFrame StrongFrame StrongFrame)
    , r (DoubleFrame StrongFrame EmphasisFrame)
    , r (SingleFrame StrongFrame)
    , r (SingleFrame EmphasisFrame)
    , r (DoubleFrame StrongFrame_ StrongFrame_)
    , r (DoubleFrame StrongFrame_ EmphasisFrame_)
    , r (SingleFrame StrongFrame_)
    , r (SingleFrame EmphasisFrame_)
    , r (DoubleFrame StrikeoutFrame StrikeoutFrame)
    , r (DoubleFrame StrikeoutFrame SubscriptFrame)
    , r (SingleFrame StrikeoutFrame)
    , r (SingleFrame SubscriptFrame)
    , r (SingleFrame SuperscriptFrame) ]
  let dels = inlineStateDel st
      failNow = do
        setPosition pos
        (customFailure . NonFlankingDelimiterRun . toNesTokens) dels
  isLastOther >>= flip when failNow
  rch <- lookAhead (optional anyChar)
  when (maybe True isTransparent rch) failNow
  return st

-- | Parse a closing markup sequence corresponding to given 'InlineFrame'.

pRfdr :: InlineFrame -> IParser InlineFrame
pRfdr frame = try $ do
  let dels = inlineFrameDel frame
      expectingInlineContent = region $ \case
        TrivialError pos us es -> TrivialError pos us $
          E.insert (Label $ NE.fromList "inline content") es
        other -> other
  pos <- getPosition
  (void . expectingInlineContent . string) dels
  let failNow = do
        setPosition pos
        (customFailure . NonFlankingDelimiterRun . toNesTokens) dels
      goodAfter x =
        isTransparent x || isMarkupChar x
  isLastSpace >>= flip when failNow
  rch <- lookAhead (optional anyChar)
  unless (maybe True goodAfter rch) failNow
  return frame

----------------------------------------------------------------------------
-- Parsing helpers

nonEmptyLine :: BParser Text
nonEmptyLine = takeWhile1P Nothing notNewline

manyEscapedWith :: MonadParsec MMarkErr Text m
  => (Char -> Bool)
  -> String
  -> m Text
manyEscapedWith f l = fmap bakeText . foldMany . choice $
  [ (:) <$> escapedChar
  , (:) <$> numRef
  , (++) . reverse <$> entityRef
  , (:) <$> satisfy f <?> l ]

someEscapedWith :: MonadParsec MMarkErr Text m
  => (Char -> Bool)
  -> m Text
someEscapedWith f = fmap bakeText . foldSome . choice $
  [ (:) <$> escapedChar
  , (:) <$> numRef
  , (++) . reverse <$> entityRef
  , (:) <$> satisfy f ]

escapedChar :: MonadParsec e Text m => m Char
escapedChar = label "escaped character" $
  try (char '\\' *> satisfy isAsciiPunctuation)

-- | Parse an HTML5 entity reference.

entityRef :: MonadParsec MMarkErr Text m => m String
entityRef = do
  pos  <- getPosition
  let f (TrivialError _ us es) = TrivialError (nes pos) us es
      f (FancyError   _ xs)    = FancyError   (nes pos) xs
  name <- try . region f $ between (char '&') (char ';')
    (takeWhile1P Nothing Char.isAlphaNum <?> "HTML5 entity name")
  case HM.lookup name htmlEntityMap of
    Nothing -> do
      setPosition pos
      customFailure (UnknownHtmlEntityName name)
    Just txt -> return (T.unpack txt)

-- | Parse a numeric character using the given numeric parser.

numRef :: MonadParsec MMarkErr Text m => m Char
numRef = do
  pos <- getPosition
  let f = between (string "&#") (char ';')
  n   <- try (f (char' 'x' *> L.hexadecimal)) <|> f L.decimal
  if n == 0 || n > fromEnum (maxBound :: Char)
    then do
      setPosition pos
      customFailure (InvalidNumericCharacter n)
    else return (Char.chr n)

sc :: MonadParsec e Text m => m ()
sc = void $ takeWhileP (Just "white space") isSpaceN

sc1 :: MonadParsec e Text m => m ()
sc1 = void $ takeWhile1P (Just "white space") isSpaceN

sc' :: MonadParsec e Text m => m ()
sc' = void $ takeWhileP (Just "white space") isSpace

sc1' :: MonadParsec e Text m => m ()
sc1' = void $ takeWhile1P (Just "white space") isSpace

eol :: MonadParsec e Text m => m ()
eol = void . label "newline" $ choice
  [ string "\n"
  , string "\r\n"
  , string "\r" ]

eol' :: MonadParsec e Text m => m Bool
eol' = option False (True <$ eol)

----------------------------------------------------------------------------
-- Other helpers

slevel :: Pos -> Pos -> Pos
slevel a l = if l >= ilevel a then a else l

ilevel :: Pos -> Pos
ilevel = (<> mkPos 4)

isSpace :: Char -> Bool
isSpace x = x == ' ' || x == '\t'

isSpaceN :: Char -> Bool
isSpaceN x = isSpace x || x == '\n' || x == '\r'

notNewline :: Char -> Bool
notNewline x = x /= '\n' && x /= '\r'

isBlank :: Text -> Bool
isBlank = T.all isSpace

isFrameConstituent :: Char -> Bool
isFrameConstituent = \case
  '*' -> True
  '^' -> True
  '_' -> True
  '~' -> True
  _   -> False

isMarkupChar :: Char -> Bool
isMarkupChar x = isFrameConstituent x || f x
  where
    f = \case
      '[' -> True
      ']' -> True
      '`' -> True
      _   -> False

isAsciiPunctuation :: Char -> Bool
isAsciiPunctuation x =
  (x >= '!' && x <= '/') ||
  (x >= ':' && x <= '@') ||
  (x >= '[' && x <= '`') ||
  (x >= '{' && x <= '~')

isTransparentPunctuation :: Char -> Bool
isTransparentPunctuation = \case
  '!' -> True
  '"' -> True
  '(' -> True
  ')' -> True
  ',' -> True
  '-' -> True
  '.' -> True
  ':' -> True
  ';' -> True
  '?' -> True
  '{' -> True
  '}' -> True
  '–' -> True
  '—' -> True
  _   -> False

isTransparent :: Char -> Bool
isTransparent x = Char.isSpace x || isTransparentPunctuation x

assembleCodeBlock :: Pos -> [Text] -> Text
assembleCodeBlock indent ls = T.unlines (stripIndent indent <$> ls)

stripIndent :: Pos -> Text -> Text
stripIndent indent txt = T.drop m txt
  where
    m = snd $ T.foldl' f (0, 0) (T.takeWhile p txt)
    p x = isSpace x || x == '>'
    f (!j, !n) ch
      | j  >= i    = (j, n)
      | ch == ' '  = (j + 1, n + 1)
      | ch == '\t' = (j + 4, n + 1)
      | otherwise  = (j, n)
    i = unPos indent - 1

assembleParagraph :: [Text] -> Text
assembleParagraph = go
  where
    go []     = ""
    go [x]    = T.dropWhileEnd isSpace x
    go (x:xs) = x <> "\n" <> go xs

collapseWhiteSpace :: Text -> Text
collapseWhiteSpace =
  T.stripEnd . T.filter (/= '\0') . snd . T.mapAccumL f True
  where
    f seenSpace ch =
      case (seenSpace, g ch) of
        (False, False) -> (False, ch)
        (True,  False) -> (False, ch)
        (False, True)  -> (True,  ' ')
        (True,  True)  -> (True,  '\0')
    g ' '  = True
    g '\t' = True
    g '\n' = True
    g _    = False

inlineStateDel :: InlineState -> Text
inlineStateDel = \case
  SingleFrame x   -> inlineFrameDel x
  DoubleFrame x y -> inlineFrameDel x <> inlineFrameDel y

liftFrame :: InlineFrame -> NonEmpty Inline -> Inline
liftFrame = \case
  StrongFrame      -> Strong
  EmphasisFrame    -> Emphasis
  StrongFrame_     -> Strong
  EmphasisFrame_   -> Emphasis
  StrikeoutFrame   -> Strikeout
  SubscriptFrame   -> Subscript
  SuperscriptFrame -> Superscript

inlineFrameDel :: InlineFrame -> Text
inlineFrameDel = \case
  EmphasisFrame    -> "*"
  EmphasisFrame_   -> "_"
  StrongFrame      -> "**"
  StrongFrame_     -> "__"
  StrikeoutFrame   -> "~~"
  SubscriptFrame   -> "~"
  SuperscriptFrame -> "^"

replaceEof :: forall e. Show e => String -> ParseError Char e -> ParseError Char e
replaceEof altLabel = \case
  TrivialError pos us es -> TrivialError pos (f <$> us) (E.map f es)
  FancyError   pos xs    -> FancyError pos xs
  where
    f EndOfInput = Label (NE.fromList altLabel)
    f x          = x

isEmailUri :: URI -> Maybe Text
isEmailUri uri =
  case URI.unRText <$> URI.uriPath uri of
    [x] ->
      if Email.isValid (TE.encodeUtf8 x) &&
          (isNothing (URI.uriScheme uri) ||
           URI.uriScheme uri == Just mailtoScheme)
        then Just x
        else Nothing
    _ -> Nothing

splitYamlError :: FilePath -> String -> (Maybe SourcePos, String)
splitYamlError file str = maybe (Nothing, str) (first pure) (parseMaybe p str)
  where
    p :: Parsec Void String (SourcePos, String)
    p = do
      void (string "YAML parse exception at line ")
      l <- mkPos . (+ 2) <$> L.decimal
      void (string ", column ")
      c <- mkPos . (+ 1) <$> L.decimal
      void (string ":\n")
      r <- takeRest
      return (SourcePos file l c, r)

emptyParagraph :: Block Isp
emptyParagraph = Paragraph (IspSpan (initialPos "") "")

emptyNaked :: Block Isp
emptyNaked = Naked (IspSpan (initialPos "") "")

manyIndexed :: (Alternative m, Num n) => n -> (n -> m a) -> m [a]
manyIndexed n' m = go n'
  where
    go !n = liftA2 (:) (m n) (go (n + 1)) <|> pure []

foldMany :: Alternative f => f (a -> a) -> f (a -> a)
foldMany f = go
  where
    go = (flip (.) <$> f <*> go) <|> pure id

foldSome :: Alternative f => f (a -> a) -> f (a -> a)
foldSome f = flip (.) <$> f <*> foldMany f

normalizeListItems :: NonEmpty [Block Isp] -> NonEmpty [Block Isp]
normalizeListItems xs' =
  if getAny $ foldMap (foldMap (Any . isParagraph)) (drop 1 x :| xs)
    then fmap toParagraph <$> xs'
    else case x of
           [] -> xs'
           (y:ys) -> r $ (toNaked y : ys) :| xs
  where
    (x:|xs) = r xs'
    r = NE.reverse . fmap reverse
    isParagraph = \case
      OrderedList _ _ -> False
      UnorderedList _ -> False
      Naked         _ -> False
      _               -> True
    toParagraph (Naked inner) = Paragraph inner
    toParagraph other         = other
    toNaked (Paragraph inner) = Naked inner
    toNaked other             = other

e2p :: Either a b -> Pair a b
e2p = \case
  Left  a -> PairL a
  Right b -> PairR (b:)

succeeds :: Alternative m => m () -> m Bool
succeeds m = True <$ m <|> pure False

prependErr :: SourcePos -> MMarkErr -> [Block Isp] -> [Block Isp]
prependErr pos custom blocks = Naked (IspError err) : blocks
  where
    err = FancyError (nes pos) (E.singleton $ ErrorCustom custom)

mailtoScheme :: URI.RText 'URI.Scheme
mailtoScheme = fromJust (URI.mkScheme "mailto")

toNesTokens :: Text -> NonEmpty Char
toNesTokens = NE.fromList . T.unpack

unexpEic :: MonadParsec e Text m => ErrorItem Char -> m a
unexpEic x = failure
  (Just x)
  (E.singleton . Label . NE.fromList $ "inline content")

nes :: a -> NonEmpty a
nes a = a :| []

fromRight :: Either a b -> b
fromRight (Right x) = x
fromRight _         =
  error "Text.MMark.Parser.fromRight: the impossible happened"

bakeText :: (String -> String) -> Text
bakeText = T.pack . reverse . ($ [])
