{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveAnyClass #-}

module Lib
    ( app
    ) where

import GHC.Generics
import Data.Monoid (mappend)
import Data.Text (Text)
import Control.Exception (finally)
import Control.Monad (forM_, forever, mzero)
import Control.Concurrent (MVar, newMVar, modifyMVar_, modifyMVar, readMVar)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import qualified Data.Text.Lazy.Encoding as TL
import qualified Data.Text.Lazy as TL
import Data.Aeson as A
import qualified Data.Maybe as M
import Data.UUID.V4 as U
import Data.UUID as U
import qualified Data.Map as Map
import Data.HashMap.Lazy (HashMap)
import qualified Data.Foldable as F
import qualified Data.Vector as V
import qualified Data.Scientific as S
import GHC.Int
import GHC.Word

import qualified Database.Persist as DB
import qualified Database.Persist.Postgresql as DB

import qualified Database.PostgreSQL.Simple as PG
import qualified Database.PostgreSQL.Simple.ToField as PG


import qualified Network.WebSockets as WS



{-| Key of an attribute
-}
type Key =
    Text


{-| D attribute in path elements
-}
data DElement
    = M Float Float
    | L Float Float
    deriving (Generic, Show, PG.ToField)

instance ToJSON DElement where
  toJSON (M f1 f2) =
    object [ "M" .= [f1, f2] ]
  toJSON (L f1 f2) =
    object [ "L" .= [f1, f2] ]


instance FromJSON DElement where
  parseJSON (Object o) = do
    Array m <- o .:? "M" .!= (Array (V.fromList []))
    if (length m) > 0 then do
      let [A.Number x1, A.Number x2] = V.toList m
      return $ M (S.toRealFloat x1) (S.toRealFloat x2)
    else do
      Array l <- o .:? "L" .!= (Array (V.fromList []))
      if (length l) > 0 then do
        let [A.Number x1, A.Number x2] = V.toList l
        return $ L (S.toRealFloat x1) (S.toRealFloat x2)
      else
        return $ M 1 1

instance PG.ToField [DElement]

{-| Value of an attribute
-}
data Value
    = D ([DElement])
    | Value String String
    deriving (Generic, Show, PG.ToField)

instance ToJSON Lib.Value where
  toJSON (D list) =
    object [ "key"   .= T.pack "d"
           , "value" .= list ]
  toJSON (Value key value) =
    object [ "key"   .= key
           , "value" .= value ]

instance FromJSON Lib.Value where
  parseJSON (Object o) = do
    String key <- o .: "key"
    case key of
      "d" -> do
        A.Array val <- (o .: "value")
        list <- mapM parseJSON (V.toList val)
        return $ D list
      _ -> do
        val <- o .: "value"
        return $ Lib.Value (T.unpack key) val


{-| Svg TagName
-}
type TagName =
    Text

instance PG.ToField [Lib.Value]

instance PG.ToField [SvgAst]

{-| SvgAst type
-}
data SvgAst
  = Tag TagName [Lib.Value] [SvgAst]
  deriving (Generic, Show, PG.ToField)

fold :: (SvgAst -> a -> a) -> a -> SvgAst -> a
fold fn base ast =
    case ast of
        Tag name attrs children ->
            fn (Tag name attrs children) (foldl (\n ast -> Lib.fold fn n ast) base children)

        _ ->
            base



instance FromJSON SvgAst where
  parseJSON (Object v) =
    Tag <$> v .: "name"
        <*> v .: "attributes"
        <*> v .: "children"
  parseJSON _ = mzero

instance ToJSON SvgAst where
  toJSON (Tag name attributes children) =
    object [ "name"       .= name
           , "attributes" .= attributes
           , "children"   .= children
             ]

data Client = Client { userId :: Text
                     , dId :: Text
                     , connection :: WS.Connection
                     } deriving (Generic)

instance Show Client where
   show (Client uId docId _) = show (docId, uId)

type ServerState = [Client] --, Map.Map String [Event])

newtype AggregateId = AggregateId String deriving (Eq, Show, Ord, Generic)

data Payload
    = Ast SvgAst
    | AstList [SvgAst]
    | Uuid String
    | Empty
    deriving (Generic, Show, PG.ToField)

instance ToJSON Payload where
  toJSON (Ast ast) =
    toJSON ast
  toJSON (AstList list) =
    toJSON list
  toJSON (Uuid uuid) =
    toJSON uuid

instance FromJSON Payload where
  parseJSON (Object v) =
    Ast <$> parseJSON (Object v)
  parseJSON (Array v) =
    AstList <$> parseJSON (Array v)
  parseJSON (String v) =
    return $ Uuid $ T.unpack v
  parseJSON _ = return Empty



data Event = Event { documentId :: Maybe String
                   , user :: String
                   , event :: String
                   , payload :: Payload
                   } deriving (Generic, Show, ToJSON, FromJSON)

getId :: [Lib.Value] -> String
getId [] = "defaultId"
getId ((Lib.Value "id" id):xs) = id
getId (x:xs) = getId xs

equalId :: SvgAst -> SvgAst -> Bool
equalId ast1 ast2 =
    case ast1 of
        Tag _ attr1 _ ->
            case ast2 of
                Tag _ attr2 _ ->
                    let id1 = getId attr1
                        id2 = getId attr2
                    in
                        id1 == id2 && id1 /= "defaultId"
                _ -> False
        _ -> False


idExists :: [SvgAst] -> SvgAst -> Bool
idExists removing list =
    foldl (\res curr -> (equalId list curr) || res) False removing

removeList :: [SvgAst] -> SvgAst -> SvgAst -> SvgAst
removeList removing list base =
    case list of
        Tag name attrs children ->
            Tag name attrs (filter (\el -> not $ idExists removing el) children)
        _ -> list


removeLists :: [SvgAst] -> [SvgAst] -> [SvgAst]
removeLists removing lists =
    map (Lib.fold (removeList removing) (Tag "comment" [] [])) lists


{-removeListsFromEvents :: [SvgAst] -> [Event] -> [Event]
removeListFromClient :: Event -> ServerState -> ServerState
removeListFromClient (Event { documentId, user, event, (AstList removed)}) (clients, map) =
  (clients, Map.update removeListsFromEvents user map)
-}

updateSvgAst :: Event -> ServerState -> ServerState
updateSvgAst ev state =
  case event ev of
    "delete" ->
      case payload ev of
        AstList payload ->
          state
          -- state
          -- ( { model | svg = removeLists payload model.svg }, Cmd.none )
        _ -> state
    "update" ->
      case payload ev of
        AstList payload ->
          state
          -- ( { model | svg = updateAsts model.svg payload }, Cmd.none )
        _ ->
          state
    "insert" ->
      case payload ev of
        Ast payload ->
          state
          --( { model | svg = insertObject model.svg (Just payload) model.currentId, currentId = model.currentId + 1 }, Cmd.none )
        _ ->
          state
    _ -> state
      --"user-joined" ->
                                --( { model | documentId = decoded.documentId }, newUrl <| M.withDefault "" decoded.documentId )



newServerState :: ServerState
newServerState = [] --, Map.empty)

numClients :: ServerState -> Int
numClients = length

clientExists :: Client -> ServerState -> Bool
clientExists client = any ((== userId client) . userId)

addClient :: Client -> ServerState -> ServerState
addClient client state = (client : state)

persistEvent :: PG.Connection -> Event -> IO GHC.Int.Int64
persistEvent conn Event { documentId = dId, user = usr, event = ev, payload = p } =
 PG.execute conn "insert into events (document_id, type, user_id, payload) values (?, ?, ?, ?)"
             (dId, ev, usr, p)

-- addEvent :: Event -> ServerState -> ServerState
-- addEvent (Event {documentId = Just docId, user = userId, event = ev, payload = pl}) clients = clients
  -- where
--     existing = M.fromMaybe [] $ Map.lookup docId events
--     updated = existing ++ [(Event (Just docId) userId ev pl)]
--     newMap = Map.insert docId updated events
-- add
  -- Event _ state = state

removeClient :: Client -> ServerState -> ServerState
removeClient client state = filter ((/= userId client) . userId) state

broadcast :: Text -> [Client] -> IO ()
broadcast message clients = do
    T.putStrLn message
    forM_ clients $ \(Client { connection = conn }) -> WS.sendTextData conn message

getUUID Event { documentId = Just "" } = do
  uuid <- U.nextRandom
  return $ Just (toString uuid)
getUUID Event { documentId = Just "/" } = do
  uuid <- U.nextRandom
  return $ Just (toString uuid)
getUUID Event { documentId = Just docId} = return $ Just docId
getUUID Event { documentId = Nothing} = do
  uuid <- U.nextRandom
  return $ Just (toString uuid)


connect :: WS.Connection -> PG.Connection -> MVar ServerState -> Event -> IO ()
connect conn dbConn state mess = forever $ flip finally disconnect $ do
  modifyMVar_ state $ \s -> do
    let s' = addClient client s
    broadcast (TL.toStrict (TL.decodeUtf8 (A.encode $ Event uuid (user mess) "user-joined" (Uuid $ T.unpack $ (userId client))))) s'
    -- let events = M.fromMaybe [] (Map.lookup (M.fromMaybe "" (documentId mess)) (snd s))
    -- forM_ events $ \ev -> broadcast (TL.toStrict (TL.decodeUtf8 (A.encode ev))) [client]
    return s'
  talk conn dbConn state client
    where
      uuid = documentId mess
      client = Client (T.pack $ user mess) (T.pack $ M.fromMaybe "" uuid) conn
      disconnect = do
        -- Remove client and return new state
        s <- modifyMVar state $ \s ->
          let s' = removeClient client s in return (s', s')
        broadcast ((userId client) `mappend` " disconnected") s

--application :: MVar ServerState -> PG.Connection -> WS.Pending -> WS.ServerApp
application state conn pending = do
    c <- WS.acceptRequest pending
    WS.forkPingThread c 30
    msg <- WS.receiveData c
    let message = A.decode (TL.encodeUtf8 (TL.fromStrict msg)) :: Maybe Event
    case message of
      Just mess ->
        case event mess of
          "connect" -> do
            serverState <- readMVar state
            uuid <- getUUID mess
            let client = Client (T.pack $ user mess) (T.pack $ M.fromJust uuid) c
            if clientExists client serverState then putStrLn "Client exists" else connect c conn state mess
          _ -> do
            serverState <- readMVar state
            uuid <- getUUID mess
            let client = Client (T.pack $ user mess) (T.pack $ M.fromJust uuid) c
            case documentId mess of
              Just docId -> do
                persistEvent conn mess
                -- modifyMVar_ state $ \s -> return $ addEvent mess s
                broadcast (TL.toStrict (TL.decodeUtf8 (A.encode $ Event (documentId mess) (user mess) (event mess) (payload mess)))) (filter (\client -> dId client == T.pack docId) serverState)
                if clientExists client serverState then putStrLn "Client exists" else connect c conn state mess
              Nothing ->
                if clientExists client serverState then putStrLn "Client exists" else connect c conn state mess
        where
          client = Client (T.pack $ M.fromJust $ documentId mess) (T.pack $ user mess) c
          disconnect = do
            -- Remove client and return new state
            s <- modifyMVar state $ \s ->
              let s' = removeClient client s in return (s', s')
            broadcast ((userId client) `mappend` " disconnected") s
      Nothing ->
        putStrLn "No message"

talk :: WS.Connection -> PG.Connection -> MVar ServerState -> Client -> IO ()
talk conn dbConn state Client { userId = user } = forever $ do
  msg <- WS.receiveData conn
  let message = A.decode (TL.encodeUtf8 (TL.fromStrict msg)) :: Maybe Event
  serverState <- readMVar state
  case message of
    Just mess ->
      let maybeId = documentId mess in
        case maybeId of
          Just docId -> do
            -- modifyMVar_ state $ \s -> return $ addEvent mess s
            persistEvent dbConn mess
            broadcast (TL.toStrict (TL.decodeUtf8 (A.encode $ Event (Just docId) (T.unpack user) (event mess)  (payload mess)))) (filter (\client -> dId client == T.pack docId) serverState)
          Nothing ->
            broadcast (TL.toStrict (TL.decodeUtf8 (A.encode $ Event (documentId mess) (T.unpack user) (event mess)  (payload mess)))) serverState
    Nothing ->
      broadcast msg serverState

dbConfig :: PG.ConnectInfo
dbConfig = PG.ConnectInfo {
  PG.connectHost = "localhost"
, PG.connectUser = "vimond"
, PG.connectPort = 5432
, PG.connectPassword = "peltonasje"
, PG.connectDatabase = "drawable"
                             }

app :: IO ()
app = do
  -- (DB.createPostgresqlPool "" 10
  conn <- PG.connect dbConfig
  state <- newMVar newServerState
  WS.runServer "0.0.0.0" 9162 $ application state conn
