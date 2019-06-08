{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

-- | The 'MonadTrace' class
module Control.Monad.Trace.Class
  ( MonadTrace(..)
  , Builder(..), Name, SpanID, TraceID, Reference(..), builder
  , Span(..), Context(..)
  , Key, Value, tagDoubleValue, tagInt64Value, tagTextValue, logValue, logValueAt
  ) where

import Control.Monad.Trace.Internal

import Control.Monad.Except (ExceptT(..))
import Control.Monad.Identity (Identity(..))
import Control.Monad.Reader (ReaderT(..))
import qualified Control.Monad.RWS.Lazy as RWS.Lazy
import qualified Control.Monad.RWS.Strict as RWS.Strict
import qualified Control.Monad.State.Lazy as State.Lazy
import qualified Control.Monad.State.Strict as State.Strict
import Control.Monad.Trans.Class (MonadTrans, lift)
import qualified Control.Monad.Writer.Lazy as Writer.Lazy
import qualified Control.Monad.Writer.Strict as Writer.Strict
import qualified Data.Aeson as JSON
import Data.ByteString (ByteString)
import Data.Int (Int64)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import qualified Data.Text as T
import Data.Time.Clock.POSIX (POSIXTime)
import Data.String (IsString(..))
import Data.Text (Text)

class Monad m => MonadTrace m where

  -- | Starts a new child span, wrapping the input action.
  trace :: Builder -> m a -> m a

  -- | Extracts the currently active span.
  activeSpan :: m (Maybe Span)
  default activeSpan :: (MonadTrace n, MonadTrans t, m ~ t n) => m (Maybe Span)
  activeSpan = lift activeSpan

  -- | Adds information to the active span, if present.
  addSpanEntry :: Key -> Value -> m ()
  default addSpanEntry :: (MonadTrace n, MonadTrans t, m ~ t n) => Key -> Value -> m ()
  addSpanEntry key = lift . addSpanEntry key

instance (Monad m, MonadTrace m) => MonadTrace (ExceptT e m) where
  trace name (ExceptT actn) = ExceptT $ trace name actn

instance (Monad m, MonadTrace m) => MonadTrace (ReaderT r m) where
  trace name (ReaderT actn) = ReaderT $ \r -> trace name (actn r)

instance (Monad m, MonadTrace m, Monoid w) => MonadTrace (RWS.Lazy.RWST r w s m) where
  trace name (RWS.Lazy.RWST actn) = RWS.Lazy.RWST $ \r s -> trace name (actn r s)

instance (Monad m, MonadTrace m, Monoid w) => MonadTrace (RWS.Strict.RWST r w s m) where
  trace name (RWS.Strict.RWST actn) = RWS.Strict.RWST $ \r s -> trace name (actn r s)

instance (Monad m, MonadTrace m) => MonadTrace (State.Lazy.StateT s m) where
  trace name (State.Lazy.StateT actn) = State.Lazy.StateT $ \s -> trace name (actn s)

instance (Monad m, MonadTrace m) => MonadTrace (State.Strict.StateT s m) where
  trace name (State.Strict.StateT actn) = State.Strict.StateT $ \s -> trace name (actn s)

instance (Monad m, MonadTrace m, Monoid w) => MonadTrace (Writer.Lazy.WriterT w m) where
  trace name (Writer.Lazy.WriterT actn) = Writer.Lazy.WriterT $ trace name actn

instance (Monad m, MonadTrace m, Monoid w) => MonadTrace (Writer.Strict.WriterT w m) where
  trace name (Writer.Strict.WriterT actn) = Writer.Strict.WriterT $ trace name actn

instance MonadTrace Identity where
  trace _ = id
  activeSpan = pure Nothing
  addSpanEntry _ _ = pure ()

-- Creating traces

-- | A trace builder.
--
-- Note that 'Builder' has an 'IsString' instance, producing a span with the given string as name,
-- no additional references, tags, or baggages. This allows convenient creation of spans via the
-- @OverloadedStrings@ pragma.
data Builder = Builder
  { builderName :: !Name
  -- ^ Name of the generated span.
  , builderTraceID :: !(Maybe TraceID)
  -- ^ The trace ID of the generated span. If unset, the active span's trace ID will be used if
  -- present, otherwise a new ID will be generated.
  , builderSpanID :: !(Maybe SpanID)
  -- ^ The ID of the generated span, otherwise the ID will be auto-generated.
  , builderReferences :: !(Set Reference)
  -- ^ Span references.
  , builderTags :: !(Map Key JSON.Value)
  -- ^ Initial set of tags.
  , builderBaggages :: !(Map Key ByteString)
  -- ^ Span context baggages.
  } deriving Show

-- | Returns a 'Builder' with the given input as name and all other fields empty.
builder :: Name -> Builder
builder name = Builder name Nothing Nothing Set.empty Map.empty Map.empty

instance IsString Builder where
  fromString = builder . T.pack

-- Writing metadata

-- | Generates a tag value from a double.
tagDoubleValue :: Double -> Value
tagDoubleValue = TagValue . JSON.toJSON

-- | Generates a 64-bit integer tag value from any integer.
tagInt64Value :: Integral a => a -> Value
tagInt64Value = TagValue . (JSON.toJSON @Int64) . fromIntegral

-- | Generates a Unicode text tag value.
tagTextValue :: Text -> Value
tagTextValue = TagValue . JSON.toJSON

-- | Generates a log value with the time of writing as timestamp. Note that the value may be written
-- later than it is created. For more control on the timestamp, use 'logValueAt'.
logValue :: JSON.ToJSON a => a -> Value
logValue v = LogValue (JSON.toJSON v) Nothing

-- | Generates a log value with a custom time.
logValueAt :: JSON.ToJSON a => POSIXTime -> a -> Value
logValueAt t v = LogValue (JSON.toJSON v) (Just t)
