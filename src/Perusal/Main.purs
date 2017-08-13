module Perusal.Main (fromJS, fromConfig) where

import Prelude

import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Class (class MonadEff, liftEff)
import Control.Monad.Error.Class (class MonadError, throwError)
import Control.Monad.Except.Trans (runExceptT)
import Control.Monad.Reader.Class (class MonadReader)
import Control.Monad.Reader.Trans (runReaderT)
import DOM (DOM)
import DOM.Classy.ParentNode (class IsParentNode)
import DOM.HTML (window)
import DOM.HTML.Types (ALERT, htmlDocumentToDocument)
import DOM.HTML.Window (alert, document)
import DOM.Node.Types (Element)
import Data.Argonaut.Core (Json)
import Data.Argonaut.Decode.Class (decodeJson)
import Data.Chain (Chain, left, right)
import Data.Either (Either(..), either)
import Data.Maybe (Maybe(..), maybe)
import Data.Set (Set, singleton)
import Data.Traversable (sequence)
import Data.Tuple (Tuple(..))
import FRP (FRP)
import FRP.Event (Event, mapMaybe, subscribe)
import FRP.Event.Time (animationFrame)
import Perusal.Config.Types (Config, Keyframe, Milliseconds(..), RenderFrame, freeze, fromConfigSpec, reverse, toChain)
import Perusal.HTML (render)
import Perusal.Navigation.Controls (fromDirection, fromInput, mapAccum, withBlocking, withDelay, withLastJust)

-- | Well, well, well... Look who decided to join the party! Happy to
-- | have you :) If you're using _this_ function, you've written some
-- | PureScript! All you need is `main = fromConfig ...`, where `...`
-- | is your big `Config` value. Simples :)
fromConfig :: forall eff
            . Config
           -> Eff (alert :: ALERT, dom :: DOM, frp :: FRP | eff) Unit
fromConfig config = runReaderT (animate config)
  { prev: singleton 37, next: singleton 39 }


-- | Given some JavaScript object (i.e. the result of `JSON.parse` or
-- | actual primitives), make the magic happen!
fromJS :: forall eff
        . Json
       -> Eff (alert :: ALERT, dom :: DOM, frp :: FRP | eff) Unit
fromJS json = do
  window'   <- window
  document' <- htmlDocumentToDocument <$> document window'
  config    <- runExceptT $ parse document' json

  case config of Right text -> fromConfig text
                 Left error -> alert error window'


parse :: forall document eff m
       . IsParentNode document
      => MonadEff (dom :: DOM | eff) m
      => MonadError String m
      => document
      -> Json
      -> m Config
parse document = decodeJson
  >>> either throwError pure
  >=> fromConfigSpec document


-- | With all the other stuff out the way, we can get to the *main
-- | event*. This function turns a `Chain` into a keyboard-sensitive
-- | `Event`, returning the `Keyframe` to animate the movement. Note
-- | that this is actually *effectful*, as we need to produce a new
-- | event to handle the status of the animation queue. Within this
-- | function, `event` is a Bool event stream indicating whether the
-- | animation queue be free.
animate :: forall eff m
         . MonadEff (frp :: FRP, dom :: DOM | eff) m
        => MonadReader { prev :: Set Int, next :: Set Int } m
        => Config
        -> m Unit
animate config = do
  -- Block the input according to this `isBusy` function.
  { event: inputs, push: isFree } <- fromInput >>= withBlocking

  let
    -- Convert a `Config` to a `Chain`, create an event that yields
    -- the frames that we move over, remove the invalid steps!
    navigation :: Event (Tuple Element Keyframe)
    navigation = mapMaybe id
      $ mapAccum go (fromDirection left' right <$> inputs)
      $ toChain config

    left' :: forall f
           . Functor f
          => Chain (f Keyframe)
          -> Maybe (Tuple (Chain (f Keyframe)) (f Keyframe))
    left' = map (map (map reverse)) <$> left

    go :: forall a b. (a -> Maybe (Tuple a b)) -> a -> Tuple a (Maybe b)
    go f cs = maybe (Tuple cs Nothing) (map Just) (f cs)

    navigation' :: Event (Maybe RenderFrame)
    navigation' = sequence
      <<< (\(Tuple delay xs) -> freeze (Milliseconds delay) <$> xs)
      <$> withDelay animationFrame navigation

  liftEff
    $ subscribe (withLastJust navigation')
    $ maybe (isFree true) -- Queue is empty!
            (render >=> \_ -> isFree false)

  liftEff $ isFree true
