{-# LANGUAGE DeriveDataTypeable    #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE ViewPatterns          #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Diagrams.Backend.PGF.Render
-- Copyright   :  (c) 2015 Christopher Chalmers
-- License     :  BSD-style (see LICENSE)
-- Maintainer  :  diagrams-discuss@googlegroups.com
--
-- This is an internal module exposeing internals for rendering a
-- diagram. This is for advanced use only. 'Diagrams.Backend.PGF'
-- has enought for general use.
--
module Diagrams.Backend.PGF.Render
  ( -- * PGF Internals
    PGF (..)
  , Options (..)
  , Render (..)

  -- * Lenses
  , surface
  , sizeSpec
  , readable
  , standalone

  ) where

import           Control.Monad                (when)
import           Data.ByteString.Builder
import Diagrams.Core.Compile

import           Data.Functor
import           Data.Hashable                (Hashable (..))

import           Control.Monad.Reader         (local)
import           Diagrams.Core.Types
import           Diagrams.Prelude             hiding (local, (<~))

import           Data.Typeable
import           Diagrams.Backend.PGF.Hbox    (Hbox (..))
import           Diagrams.Backend.PGF.Surface (Surface)
import           Diagrams.TwoD.Adjust         (adjustDia2D)
import           Diagrams.TwoD.Path
import           Diagrams.TwoD.Text           (Text (..), TextAlignment (..),
                                               getFontSize, getFontSlant,
                                               getFontWeight)
import qualified Graphics.Rendering.PGF       as P

import           Prelude

-- | This data declaration is simply used as a token to distinguish
--   this rendering engine.
data PGF = PGF
  deriving (Show, Typeable)

instance TypeableFloat n => Backend PGF V2 n where
  newtype Render  PGF V2 n = R (P.Render n)
  type    Result  PGF V2 n = Builder
  data    Options PGF V2 n = PGFOptions
    { _surface    :: Surface       -- ^ Surface you want to use.
    , _sizeSpec   :: SizeSpec V2 n -- ^ The requested size.
    , _readable   :: Bool          -- ^ Indented lines for @.tex@ output.
    , _standalone :: Bool          -- ^ Should @.tex@ output be standalone.
    }

  renderDUAL _ ops t d =
    P.renderWith (ops^.surface) (ops^.readable) (ops^.standalone) bounds r
      where
        bounds = specToSize 100 (ops^.sizeSpec)
        R r    = toRender t d

  adjustDia = adjustDia2D sizeSpec

toRender :: (TypeableFloat n, Monoid' m)
         => T2 n -> QDiagram PGF V2 n m -> Render PGF V2 n
toRender = foldDia' renderPrim renderAnnot renderSty
  where
    renderPrim sty p = R $ local (P.style .~ sty) r
      where R r = render PGF p

    renderAnnot (OpacityGroup x) (R r) = R $ P.opacityGroup x r
    renderAnnot _ r                    = r

    renderSty sty (R r) = R $ clip (view _clip sty) r

instance Fractional n => Default (Options PGF V2 n) where
  def = PGFOptions
    { _surface    = def
    , _sizeSpec   = absolute
    , _readable   = True
    , _standalone = False
    }

instance Monoid (Render PGF V2 n) where
  mempty              = R $ return ()
  R ra `mappend` R rb = R $ ra >> rb

-- Lenses --------------------------------------------------------------

-- | Lens onto the surface used to render.
surface :: Lens' (Options PGF V2 n) Surface
surface = lens _surface (\o s -> o {_surface = s})

-- | Lens onto whether a standalone @.tex@ document should be produced.
--   The 'preamble' of the standalone document is determined by the
--   'surface.
standalone :: Lens' (Options PGF V2 n) Bool
standalone = lens _standalone (\o s -> o {_standalone = s})

-- | Lens onto the size of the final output.
sizeSpec :: Lens' (Options PGF V2 n) (SizeSpec V2 n)
sizeSpec = lens _sizeSpec (\o s -> o {_sizeSpec = s})

-- | Lens onto whether the lines of the @.tex@ document are indented.
readable :: Lens' (Options PGF V2 n) Bool
readable = lens _readable (\o b -> o {_readable = b})

-- Render helpers ------------------------------------------------------

-- helper function to easily get options and set them
(<~) :: AttributeClass a => (b -> P.Render n) -> (a -> b) -> P.Render n
renderF <~ getF = do
  s <- views P.style (fmap getF . getAttr)
  maybe (return ()) renderF s

infixr 2 <~

-- | Fade a colour with the opacity from the style.
fade :: Color c => c -> P.RenderM n (AlphaColour Double)
fade c = flip dissolve (toAlphaColour c) <$> view (P.style . _opacity)

-- The Path is necessary so we can clip/workout gradients.
setFillTexture :: RealFloat n => Path V2 n -> Texture n -> P.Render n
setFillTexture p t = case t of
  SC (SomeColor c) -> fade c >>= P.setFillColor
  LG g             -> P.linearGradient p g
  RG g             -> P.radialGradient p g

setLineTexture :: RealFloat n => Texture n -> P.Render n
setLineTexture (SC (SomeColor c)) = fade c >>= P.setLineColor
setLineTexture _                  = return ()

clip :: TypeableFloat n => [Path V2 n] -> P.Render n -> P.Render n
clip paths r = go paths
  where
    go []     = r
    go (p:ps) = P.scope $ P.path p >> P.clip >> go ps

-- Renderable instances ------------------------------------------------

instance TypeableFloat n => Renderable (Path V2 n) PGF where
  render _ path = R . P.scope $ do
    -- lines and loops are separated when stroking so we only need to
    -- check the first one
    let canFill = noneOf (_head . located) isLine path
    -- solid colours need to be filled with usePath
    doFill <- if canFill
      then do
        mFillTexture <- preview (P.style . _fillTexture)
        case mFillTexture of
          Nothing -> return False
          Just t  -> do
            setFillTexture path t
            P.setFillRule <~ getFillRule
            return (has _SC t)
      else return False
    --
    w <- view (P.style . _lineWidthU . non 0)
    let doStroke = w > 0.0001
    when doStroke $ do
      P.setLineWidth w
      setLineTexture <~ getLineTexture
      P.setLineJoin  <~ getLineJoin
      P.setLineCap   <~ getLineCap
      P.setDash      <~ getDashing
    --
    P.path path
    P.usePath doFill doStroke

-- | Does not support full alignment. Text is not escaped.
instance TypeableFloat n => Renderable (Text n) PGF where
  render _ (Text tt txtAlign str) = R . P.scope $ do
    setFillTexture mempty <~ getFillTexture
    --
    P.applyTransform tt
    (P.applyScale . (/8)) <~ getFontSize
        -- (/8) was obtained from trail and error
    --
    P.renderText (P.setTextAlign txtAlign) $ do
      P.setFontWeight <~ getFontWeight
      P.setFontSlant  <~ getFontSlant
      P.rawString str

instance TypeableFloat n => Renderable (Hbox n) PGF where
  render _ (Hbox tt str) = R . P.scope $ do
    P.applyTransform tt
    P.renderText (P.setTextAlign BaselineText) (P.rawString str)

-- | Supported: @.pdf@, @.jpg@, @.png@.
instance RealFloat n => Renderable (DImage n External) PGF where
  render _  = R . P.image

-- | Supported: 'ImageRGB8'. (Other types from 'DynamicImage' will
--   error)
instance RealFloat n => Renderable (DImage n Embedded) PGF where
  render _  = R . P.embeddedImage

-- Hashable instances --------------------------------------------------

instance Hashable n => Hashable (Options PGF V2 n) where
  hashWithSalt s (PGFOptions sf sz rd st)
    = s  `hashWithSalt`
      sf `hashWithSalt`
      sz `hashWithSalt`
      rd `hashWithSalt`
      st

