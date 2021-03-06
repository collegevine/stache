-- |
-- Module      :  Text.Mustache.Render
-- Copyright   :  © 2016 Stack Builders
-- License     :  BSD 3 clause
--
-- Maintainer  :  Mark Karpov <markkarpov@openmailbox.org>
-- Stability   :  experimental
-- Portability :  portable
--
-- Functions for rendering Mustache templates. You don't usually need to
-- import the module, because "Text.Mustache" re-exports everything you may
-- need, import that module instead.

{-# LANGUAGE CPP               #-}
{-# LANGUAGE OverloadedStrings #-}

module Text.Mustache.Render
  ( renderMustache )
where

import Control.Monad.Reader
import Control.Monad.Writer.Lazy
import Data.Aeson
import Data.Foldable (asum)
import Data.List (tails)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Text.Megaparsec.Pos (Pos, unPos)
import Text.Mustache.Type
import qualified Data.ByteString.Lazy   as B
import qualified Data.HashMap.Strict    as H
import qualified Data.List.NonEmpty     as NE
import qualified Data.Map               as M
import qualified Data.Semigroup         as S
import qualified Data.Text              as T
import qualified Data.Text.Encoding     as T
import qualified Data.Text.Lazy         as TL
import qualified Data.Text.Lazy.Builder as B
import qualified Data.Vector            as V

#if !MIN_VERSION_base(4,8,0)
import Control.Applicative
#endif

----------------------------------------------------------------------------
-- The rendering monad

-- | Synonym for the monad we use for rendering. It allows to share context
-- and accumulate the result as 'B.Builder' data which is then turned into
-- lazy 'TL.Text'.

type Render a = ReaderT RenderContext (Writer B.Builder) a

-- | The render monad context.

data RenderContext = RenderContext
  { rcIndent   :: Maybe Pos      -- ^ Actual indentation level
  , rcContext  :: NonEmpty Value -- ^ The context stack
  , rcPrefix   :: Key            -- ^ Prefix accumulated by entering sections
  , rcTemplate :: Template       -- ^ The template to render
  , rcLastNode :: Bool           -- ^ Is this last node in this partial?
  }

----------------------------------------------------------------------------
-- High-level interface

-- | Render a Mustache 'Template' using Aeson's 'Value' to get actual values
-- for interpolation.

renderMustache :: Template -> Value -> TL.Text
renderMustache t =
  runRender (renderPartial (templateActual t) Nothing renderNode) t

-- | Render a single 'Node'.

renderNode :: Node -> Render ()
renderNode (TextBlock txt) = outputIndented txt
renderNode (EscapedVar k) =
  lookupKey k >>= outputRaw . escapeHtml . renderValue
renderNode (UnescapedVar k) =
  lookupKey k >>= outputRaw . renderValue
renderNode (Section k ns) = do
  val <- lookupKey k
  enterSection k $
    unless (isBlank val) $
      case val of
        Array xs ->
          forM_ (V.toList xs) $ \x ->
            addToLocalContext x (renderMany renderNode ns)
        _ ->
          addToLocalContext val (renderMany renderNode ns)
renderNode (InvertedSection k ns) = do
  val <- lookupKey k
  when (isBlank val) $
    renderMany renderNode ns
renderNode (Partial pname indent) =
  renderPartial pname indent renderNode

----------------------------------------------------------------------------
-- The rendering monad vocabulary

-- | Run 'Render' monad given template to render and a 'Value' to take
-- values from.

runRender :: Render a -> Template -> Value -> TL.Text
runRender m t v = (B.toLazyText . execWriter) (runReaderT m rc)
  where
    rc = RenderContext
      { rcIndent   = Nothing
      , rcContext  = v :| []
      , rcPrefix   = mempty
      , rcTemplate = t
      , rcLastNode = True }
{-# INLINE runRender #-}

-- | Output a piece of strict 'Text'.

outputRaw :: Text -> Render ()
outputRaw = tell . B.fromText
{-# INLINE outputRaw #-}

-- | Output indentation consisting of appropriate number of spaces.

outputIndent :: Render ()
outputIndent = asks rcIndent >>= outputRaw . buildIndent
{-# INLINE outputIndent #-}

-- | Output piece of strict 'Text' with added indentation.

outputIndented :: Text -> Render ()
outputIndented txt = do
  level <- asks rcIndent
  lnode <- asks rcLastNode
  let f x = outputRaw (T.replace "\n" ("\n" <> buildIndent level) x)
  if lnode && T.isSuffixOf "\n" txt
    then f (T.init txt) >> outputRaw "\n"
    else f txt
{-# INLINE outputIndented #-}

-- | Render a partial.

renderPartial
  :: PName             -- ^ Name of partial to render
  -> Maybe Pos         -- ^ Indentation level to use
  -> (Node -> Render ()) -- ^ How to render nodes in that partial
  -> Render ()
renderPartial pname i f =
  local u (outputIndent >> getNodes >>= renderMany f)
  where
    u rc = rc
      { rcIndent   = addIndents i (rcIndent rc)
      , rcPrefix   = mempty
      , rcTemplate = (rcTemplate rc) { templateActual = pname }
      , rcLastNode = True }
{-# INLINE renderPartial #-}

-- | Get collection of 'Node's for actual template.

getNodes :: Render [Node]
getNodes = do
  Template actual cache <- asks rcTemplate
  return (M.findWithDefault [] actual cache)
{-# INLINE getNodes #-}

-- | Render many nodes.

renderMany
  :: (Node -> Render ()) -- ^ How to render a node
  -> [Node]            -- ^ The collection of nodes to render
  -> Render ()
renderMany _ [] = return ()
renderMany f [n] = do
  ln <- asks rcLastNode
  local (\rc -> rc { rcLastNode = ln && rcLastNode rc }) (f n)
renderMany f (n:ns) = do
  local (\rc -> rc { rcLastNode = False }) (f n)
  renderMany f ns

-- | Lookup a 'Value' by its 'Key'.

lookupKey :: Key -> Render Value
lookupKey (Key []) = NE.head <$> asks rcContext
lookupKey k = do
  v <- asks rcContext
  p <- asks rcPrefix
  let f x = asum (simpleLookup False (x <> k) <$> v)
  (return . fromMaybe Null . asum) (fmap (f . Key) . reverse . tails $ unKey p)

-- | Lookup a 'Value' by traversing another 'Value' using given 'Key' as
-- “path”.

simpleLookup
  :: Bool
     -- ^ At least one part of the path matched, in this case we are
     -- “committed” to this lookup and cannot say “there is nothing, try
     -- other level”. This is necessary to pass the “Dotted Names — Context
     -- Precedence” test from the “interpolation.yml” spec.
  -> Key               -- ^ The key to lookup
  -> Value             -- ^ Source value
  -> Maybe Value       -- ^ Looked-up value
simpleLookup _ (Key [])     obj        = return obj
simpleLookup c (Key (k:ks)) (Object m) =
  case H.lookup k m of
    Nothing -> if c then Just Null else Nothing
    Just  v -> simpleLookup True (Key ks) v
simpleLookup _ _ _ = Nothing
{-# INLINE simpleLookup #-}

-- | Enter the section by adding given 'Key' prefix to current prefix.

enterSection :: Key -> Render a -> Render a
enterSection p =
  local (\rc -> rc { rcPrefix = p <> rcPrefix rc })
{-# INLINE enterSection #-}

-- | Add new value on the top of context. The new value has the highest
-- priority when lookup takes place.

addToLocalContext :: Value -> Render a -> Render a
addToLocalContext v =
  local (\rc -> rc { rcContext = NE.cons v (rcContext rc) })
{-# INLINE addToLocalContext #-}

----------------------------------------------------------------------------
-- Helpers

-- | Add two 'Maybe' 'Pos' values together.

addIndents :: Maybe Pos -> Maybe Pos -> Maybe Pos
addIndents Nothing  Nothing  = Nothing
addIndents Nothing  (Just x) = Just x
addIndents (Just x) Nothing  = Just x
addIndents (Just x) (Just y) = Just (x S.<> y)
{-# INLINE addIndents #-}

-- | Build intentation of specified length by repeating the space character.

buildIndent :: Maybe Pos -> Text
buildIndent Nothing = ""
buildIndent (Just p) = let n = fromIntegral (unPos p) - 1 in T.replicate n " "
{-# INLINE buildIndent #-}

-- | Select invisible values.

isBlank :: Value -> Bool
isBlank Null         = True
isBlank (Bool False) = True
isBlank (Object   m) = H.null m
isBlank (Array    a) = V.null a
isBlank (String   s) = T.null s
isBlank _            = False
{-# INLINE isBlank #-}

-- | Render Aeson's 'Value' /without/ HTML escaping.

renderValue :: Value -> Text
renderValue Null         = ""
renderValue (String str) = str
renderValue value        = (T.decodeUtf8 . B.toStrict . encode) value
{-# INLINE renderValue #-}

-- | Escape HTML represented as strict 'Text'.

escapeHtml :: Text -> Text
escapeHtml txt = foldr (uncurry T.replace) txt
  [ ("\"", "&quot;")
  , ("<",  "&lt;")
  , (">",  "&gt;")
  , ("&",  "&amp;") ]
{-# INLINE escapeHtml #-}
