{-# OPTIONS -fglasgow-exts #-}
{-# LANGUAGE Arrows #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell #-}

module Lib
    ( Lib.app
    ) where

import GHC.Generics
import System.Environment
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
import qualified Data.Vector as V
import qualified Data.Scientific as S
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Char8 as BS
import qualified Network.WebSockets as WS
import Control.Arrow

import           Opaleye (Query, Column, Table(Table), QueryArr,
                          required, optional, (.==), (.<), runQuery,
                          arrangeDeleteSql, arrangeInsertManySql,
                          arrangeUpdateSql, arrangeInsertManyReturningSql,
                          queryTable, restrict, PGInt4, PGFloat8)
import           Data.Profunctor.Product (p6)
import           Data.Profunctor.Product.Default (def)
import qualified Opaleye.Internal.Unpackspec as U
import qualified Opaleye.PGTypes as P
import qualified Opaleye.Constant as C
import qualified Opaleye.Manipulation as OM
import qualified Database.PostgreSQL.Simple as PG
import qualified Data.List as L

table :: Table
    (Maybe (Column PGInt4), Column P.PGText, Column P.PGText, Column P.PGText, Maybe (Column P.PGJsonb), Column P.PGText)
    (Column PGInt4, Column P.PGText, Column P.PGText, Column P.PGText, Column P.PGJsonb, Column P.PGText)
table = Table "events" (p6 ( optional "id"
                              , required "event_id"
                              , required "document_id"
                              , required "type"
                              , optional "payload"
                              , required "user_id"))

        
runTableQuery :: PG.Connection -> Query (Column PGInt4, Column P.PGText, Column P.PGText, Column P.PGText, Column P.PGJsonb, Column P.PGText) -> IO [(Int, String, String, String, String, String)]
runTableQuery = runQuery


{-| Key of an attribute
-}
type Key =
    Text


{-| D attribute in path elements
-}
data DElement
    = M Float Float
    | L Float Float
    deriving (Generic, Show, Read)

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

{-| Value of an attribute
-}
data Value
    = D ([DElement])
    | Value String String
    deriving (Generic, Show, Read)

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

{-| SvgAst type
-}
data SvgAst
  = Tag TagName [Lib.Value] [SvgAst]
  deriving (Generic, Show, Read)

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
    deriving (Generic, Show, Read)

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
                   } deriving (Generic, Show, ToJSON, FromJSON, Read)

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

svgMap :: (SvgAst -> SvgAst) -> SvgAst -> SvgAst
svgMap fn ast =
    case ast of
        Tag name attrs children ->
          fn $ Tag name attrs (map (svgMap fn) children)

        _ ->
            fn ast


isKey key (Lib.Value k _) = key == k
isKey _ _ = False

getStringAttribute :: String -> [Lib.Value] -> Maybe String
getStringAttribute key attrs =
    let
        value =
            L.find (isKey key) attrs
    in
        case value of
            Just (Lib.Value _ val) ->
                Just val

            _ ->
                Nothing


updateIfSameId :: SvgAst -> SvgAst -> SvgAst
updateIfSameId a1 a2 =
    case a1 of
        Tag _ attr1 _ ->
            case a2 of
                Tag _ attr2 _ ->
                    let
                        id1 =
                          M.fromMaybe "-1" $ getStringAttribute "id" attr1

                        id2 =
                          M.fromMaybe  "-2" $ getStringAttribute "id" attr2
                    in
                        if id1 == id2 then
                            a1
                        else
                            a2

                _ ->
                    a2

        _ ->
            a2

updateAst :: SvgAst -> SvgAst -> SvgAst
updateAst new ast =
    svgMap (updateIfSameId new) ast


updateAsts :: [SvgAst] -> [SvgAst] -> [SvgAst]
updateAsts asts newAsts =
    foldr (\ast updated -> map (updateAst ast) updated) asts newAsts
parseAst :: [SvgAst] -> SvgAst -> [SvgAst]
parseAst svg object =
    case svg of
        (x : xs) ->
            case x of
                Tag "g" attr objects ->
                    (Tag "g" attr (object : objects)) : xs

                _ ->
                    x : (parseAst svg object)

        [] ->
            [ (Tag "g" [] [ object ]) ]

addIdToObject :: SvgAst -> Int -> SvgAst
addIdToObject svgast id =
    case svgast of
        Tag name attrs children ->
            Tag name (Lib.Value "id" (show id):attrs) children
        _ ->
            svgast


insertObject :: [SvgAst] -> SvgAst -> Int -> [SvgAst]
insertObject svg object id =
  parseAst svg (addIdToObject object id)

updateSvgAst :: Maybe Event -> [SvgAst] -> [SvgAst]
updateSvgAst mev state =
  case mev of
    Just ev ->
      case event ev of
        "delete" ->
          case payload ev of
            AstList payload ->
              removeLists payload state
            _ -> state
        "update" ->
          case payload ev of
            AstList payload ->
              updateAsts state payload
            _ ->
              state
        "insert" ->
          case payload ev of
            Ast payload ->
              insertObject state payload 0
            _ ->
              state
        _ -> state
    _ -> state


newServerState :: ServerState
newServerState = [] --, Map.empty)

numClients :: ServerState -> Int
numClients = length

clientExists :: Client -> ServerState -> Bool
clientExists client = any ((== userId client) . userId)

addClient :: Client -> ServerState -> ServerState
addClient client state = (client : state)

--personQuery :: Query (Column P.PGText, Column PGInt4, Column P.PGText)
--documentQuery :: String -> Query (Maybe (Column PGInt4), Column P.PGText, Column P.PGText, Column P.PGText, Maybe (Column P.PGJsonb), Column P.PGText)
documentQuery docId = proc () -> do
    row@(_, _, dId, _, _, _) <- queryTable table -< ()
    restrict -< dId .== (P.pgString docId)
    returnA -< row

persistEvent :: PG.Connection -> Event -> IO ()
persistEvent conn (Event { documentId = dId
                    , user = u
                    , event = ev
                    , payload = p
                    }) = do
  OM.runInsertMany conn table (return (Nothing, P.pgString "", P.pgString (M.fromMaybe "" dId), P.pgString ev, Just $ P.pgStrictJSONB $ BL.toStrict (A.encode p), P.pgString u))
  return ()

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

rowToEvent :: (Int, String, String, String, String, String) -> Maybe Event
rowToEvent (id, _, dId, ev, p, u) =
  let pload = A.decode (BS.pack p) in
    case  pload of
      Just p ->
        Just $ Event { documentId = Just dId
              , user = u
              , event = ev
              , payload = p
              }
      _ -> Nothing

initialSvg = [Tag "g" [] []]

connect :: WS.Connection -> PG.Connection -> MVar ServerState -> Event -> IO ()
connect conn dbConn state mess = forever $ flip finally disconnect $ do
  modifyMVar_ state $ \s -> do
    let s' = addClient client s
    let dId = documentId mess
    case dId of
      Just d -> do
        res <- runTableQuery dbConn (documentQuery d)
        let events = map rowToEvent res
        let payload = foldr updateSvgAst initialSvg events
        broadcast (TL.toStrict (TL.decodeUtf8 (A.encode $ Event dId (user mess) "insert" (AstList payload)))) [client]
        putStrLn (show $ payload)
      _ ->
        putStrLn "No docId"
    putStrLn (show $ uuid)
    broadcast (TL.toStrict (TL.decodeUtf8 (A.encode $ Event uuid (user mess) "user-joined" (Uuid $ T.unpack $ (userId client))))) s'
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

--application :: MVar ServerState -> WS.Pending -> WS.ServerApp
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
            putStrLn (show uuid)
            let newMess = Event uuid (user mess) (event mess) (payload mess)
            let client = Client (T.pack $ user mess) (T.pack $ M.fromJust uuid) c
            if clientExists client serverState then putStrLn "Client exists" else connect c conn state newMess
          _ -> do
            serverState <- readMVar state
            uuid <- getUUID mess
            let client = Client (T.pack $ user mess) (T.pack $ M.fromJust uuid) c
            let newMess = Event uuid (user mess) (event mess) (payload mess)
            case documentId mess of
              Just docId -> do
                persistEvent conn mess
                broadcast (TL.toStrict (TL.decodeUtf8 (A.encode $ newMess))) (filter (\client -> dId client == T.pack docId) serverState)
                if clientExists client serverState then putStrLn "Client exists" else connect c conn state newMess
              Nothing ->
                if clientExists client serverState then putStrLn "Client exists" else connect c conn state newMess
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
  let message = A.decode (TL.encodeUtf8 (TL.fromStrict msg)) :: Maybe (Event)
  serverState <- readMVar state
  case message of
    Just mess ->
      let maybeId = documentId mess in
        case maybeId of
          Just docId -> do
            persistEvent dbConn mess
            broadcast (TL.toStrict (TL.decodeUtf8 (A.encode $ Event (Just docId) (T.unpack user) (event mess)  (payload mess)))) (filter (\client -> dId client == T.pack docId) serverState)
          Nothing -> do
            persistEvent dbConn mess
            broadcast (TL.toStrict (TL.decodeUtf8 (A.encode $ Event (documentId mess) (T.unpack user) (event mess)  (payload mess)))) serverState
    Nothing ->
      broadcast msg serverState

dbConfig :: String -> String -> String -> PG.ConnectInfo
dbConfig username password database = PG.ConnectInfo {
  PG.connectHost = "localhost"
, PG.connectUser = username
, PG.connectPort = 5432
, PG.connectPassword = password
, PG.connectDatabase = database
  }


app :: IO ()
app = do
  state <- newMVar newServerState
  username <- getEnv "username"
  password <- getEnv "password"
  database <- getEnv "database"
  conn <- PG.connect $ dbConfig username password database
  WS.runServer "0.0.0.0" 9162 $ application state conn
