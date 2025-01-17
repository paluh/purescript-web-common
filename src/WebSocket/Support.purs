module WebSocket.Support
  ( WebSocketManager
  , mkWebSocketManager
  , runWebSocketManager
  , managerWriteOutbound
  , URI(..)
  , FromSocket(..)
  , ToSocket(..)
  ) where

import Prologue
import Concurrent.Queue (Queue)
import Concurrent.Queue as Queue
import Control.Monad.Rec.Class (forever)
import Control.Parallel (parSequence_)
import Data.Argonaut.Core (stringify)
import Data.Argonaut.Decode (class DecodeJson, JsonDecodeError)
import Data.Argonaut.Encode (class EncodeJson, encodeJson)
import Data.Argonaut.Extra (parseDecodeJson)
import Data.Argonaut.Foreign (decodeForeign)
import Data.Foldable (for_)
import Effect (Effect)
import Effect.AVar (AVar, AVarCallback)
import Effect.AVar as AVar
import Effect.Aff (Aff, launchAff)
import Effect.Class (class MonadEffect, liftEffect)
import Effect.Console (log)
import Effect.Exception (Error)
import Web.Event.EventTarget (addEventListener, eventListener)
import Web.HTML as W
import Web.HTML.Location as WL
import Web.HTML.Window as WW
import Web.Socket.Event.CloseEvent (CloseEvent)
import Web.Socket.Event.CloseEvent as CloseEvent
import Web.Socket.Event.EventTypes (onClose, onMessage, onOpen)
import Web.Socket.Event.MessageEvent (MessageEvent)
import Web.Socket.Event.MessageEvent as MessageEvent
import Web.Socket.WebSocket (WebSocket)
import Web.Socket.WebSocket as WS

-- | A type that manages a queue of messages going-to and coming-from a websocket.
-- |
-- | You may ask, "Why not use the websocket directly?" and the answer
-- | is so we can transparently manage network problems and reconnections
-- | for you. Messages go into inbound and outbound queues, and if the
-- | connection drops we hold the queue while we get it back up.
-- |
-- | See `runWebSocketManager` for an example of how to use this.
newtype WebSocketManager i o
  = WebSocketManager
  { inbound :: Queue (FromSocket i)
  , outbound :: Queue (ToSocket o)
  , socket :: AVar WebSocket
  }

unWebSocketManager
  :: forall i o
   . WebSocketManager i o
  -> { inbound :: Queue (FromSocket i)
     , outbound :: Queue (ToSocket o)
     , socket :: AVar WebSocket
     }
unWebSocketManager (WebSocketManager a) = a

managerReadInbound :: forall i o. WebSocketManager i o -> Aff (FromSocket i)
managerReadInbound = unWebSocketManager >>> _.inbound >>> Queue.read

managerWriteInbound
  :: forall i o. WebSocketManager i o -> FromSocket i -> Aff Unit
managerWriteInbound = unWebSocketManager >>> _.inbound >>> Queue.write

managerReadOutbound :: forall i o. WebSocketManager i o -> Aff (ToSocket o)
managerReadOutbound = unWebSocketManager >>> _.outbound >>> Queue.read

managerWriteOutbound
  :: forall i o. WebSocketManager i o -> ToSocket o -> Aff Unit
managerWriteOutbound = unWebSocketManager >>> _.outbound >>> Queue.write

mkWebSocketManager :: forall i o. Aff (WebSocketManager i o)
mkWebSocketManager = do
  inbound <- Queue.new
  outbound <- Queue.new
  socket <- liftEffect AVar.empty
  pure $ WebSocketManager { inbound, outbound, socket }

------------------------------------------------------------
data FromSocket a
  = WebSocketOpen
  | ReceiveMessage (Either JsonDecodeError a)
  | WebSocketClosed CloseEvent

data ToSocket a
  = SendMessage a

------------------------------------------------------------
newtype URI
  = URI String

mkSocket
  :: URI -> Effect WebSocket
mkSocket (URI uri) = do
  window <- W.window
  location <- WW.location window
  protocol <- WL.protocol location
  hostname <- WL.hostname location
  port <- WL.port location
  let
    wsProtocol = case protocol of
      "https:" -> "wss"
      _ -> "ws"

    wsPath = wsProtocol <> "://" <> hostname <> ":" <> port <> uri
  WS.create wsPath []

------------------------------------------------------------
-- | Take a resource that's wrapped in an AVar, then lock it, use it and unlock it.
bracket
  :: forall m a
   . MonadEffect m
  => (Error -> Effect Unit)
  -> (a -> Effect Unit)
  -> AVar a
  -> m Unit
bracket errorHandler successHandler resourceVar =
  void $ liftEffect
    $ AVar.take resourceVar
    $ withError
    $ \resource -> do
        successHandler resource
        void $ AVar.put resource resourceVar $ withError pure
  where
  withError :: forall b. (b -> Effect Unit) -> Either Error b -> Effect Unit
  withError _ (Left err) = errorHandler err

  withError f (Right value) = f value

------------------------------------------------------------
-- | Wire a websocket into a Halogen app. Example usage:
-- |
-- | ```
-- | data MessageToServer = BuyWidgets Int | ...
-- | data MessageFromServer = OrderReceived Date | ...
-- |
-- | main = do
-- |   runHalogenAff do
-- |     body <- awaitBody
-- |     halogenDriver <- runUI initialMainFrame Init body
-- |     wsManager :: WebSocketManager MessageFromServer MessageToServer <-
-- |       mkWebSocketManager
-- |     void
-- |       $ forkAff
-- |       $ WS.runWebSocketManager
-- |           (WS.URI "/ws")
-- |           (\msg -> void $ halogenDriver.query
-- |                         $ ReceiveWebSocketMessage msg unit)
-- |           wsManager
-- |     driver.subscribe
-- |       $ consumer
-- |       $ case _ of
-- |           (WebSocketMessage msg) -> do
-- |             WS.managerWriteOutbound wsManager $ WS.SendMessage msg
-- |             pure Nothing
-- | ```
runWebSocketManager
  :: forall o i
   . DecodeJson i
  => EncodeJson o
  => URI
  -> (FromSocket i -> Aff Unit)
  -> WebSocketManager i o
  -> Aff Unit
runWebSocketManager uri handler manager =
  parSequence_
    [ liftEffect $ runWebSocketManagerListeners uri manager
    , runWebSocketManagerSender manager
    , forever $ managerReadInbound manager >>= handler
    ]

runWebSocketManagerSender
  :: forall i o. EncodeJson o => WebSocketManager i o -> Aff Unit
runWebSocketManagerSender manager =
  forever
    $ do
        contents <- managerReadOutbound manager
        case contents of
          SendMessage msg -> do
            bracket
              (\err -> log $ "Fatal websocket error: " <> show err)
              (\socket -> WS.sendString socket $ stringify $ encodeJson msg)
              (_.socket $ unWebSocketManager manager)

runWebSocketManagerListeners
  :: forall i o. DecodeJson i => URI -> WebSocketManager i o -> Effect Unit
runWebSocketManagerListeners uri manager = do
  socket <- mkSocket uri
  -- Listen for messages and store them.
  messageListener <-
    eventListener \event -> do
      for_ (MessageEvent.fromEvent event) \messageEvent -> do
        launchAff $ managerWriteInbound manager
          (ReceiveMessage $ decoder messageEvent)
  addEventListener onMessage messageListener false (WS.toEventTarget socket)
  -- Listen for the close and get ready to reconnect.
  closeListener <-
    eventListener \event -> do
      for_ (CloseEvent.fromEvent event) \closeEvent -> do
        void $ launchAff $ managerWriteInbound manager
          (WebSocketClosed closeEvent)
        reconnect
  addEventListener onClose closeListener false (WS.toEventTarget socket)
  -- Listen for the open and store the socket when it's useable.
  openListener <-
    eventListener $ const do
      void $ launchAff $ managerWriteInbound manager WebSocketOpen
      liftEffect $ AVar.put socket (_.socket $ unWebSocketManager manager)
        $ withHandler
        $ const
        $ pure unit
  addEventListener onOpen openListener false (WS.toEventTarget socket)
  where
  decoder :: MessageEvent -> Either JsonDecodeError i
  decoder msgEvent = do
    str <- decodeForeign $ MessageEvent.data_ msgEvent
    parseDecodeJson str

  -- | Reconnect discards the existing socket and boots up a new one.
  reconnect = do
    void
      $ AVar.take (_.socket $ unWebSocketManager manager)
      $ withHandler
      $ const
      $ runWebSocketManagerListeners uri manager

withHandler :: forall a. (a -> Effect Unit) -> AVarCallback a
withHandler _ (Left err) = log $ "Fatal websocket error: " <> show err

withHandler handler (Right value) = handler value
