{-# LANGUAGE OverloadedStrings, DeriveGeneric, DeriveAnyClass #-}

module Lib
    ( app
    ) where

import GHC.Generics
import Data.Monoid (mappend)
import Data.Text (Text)
import Control.Exception (finally)
import Control.Monad (forM_, forever)
import Control.Concurrent (MVar, newMVar, modifyMVar_, modifyMVar, readMVar)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import qualified Data.Text.Lazy.Encoding as TL
import qualified Data.Text.Lazy as TL
import Data.Aeson as A
import qualified Data.Maybe as M
import Data.UUID.V4 as U
import Data.UUID as U

import qualified Network.WebSockets as WS

--type Client = (Text, WS.Connection)

data Client = Client { userId :: Text
                     , dId :: Text
                     , connection :: WS.Connection
                     } deriving (Generic)

instance Show Client where
   show (Client uId docId _) = show (docId, uId)

type ServerState = [Client]

data Event = Event { documentId :: Maybe String
                   , user :: String
                   , event :: String
                   , payload :: Maybe A.Value
                   } deriving (Generic, Show, ToJSON, FromJSON)

newServerState :: ServerState
newServerState = []

numClients :: ServerState -> Int
numClients = length

clientExists :: Client -> ServerState -> Bool
clientExists client = any ((== userId client) . userId)

addClient :: Client -> ServerState -> ServerState
addClient client clients = client : clients

removeClient :: Client -> ServerState -> ServerState
removeClient client = filter ((/= userId client) . userId)

broadcast :: Text -> ServerState -> IO ()
broadcast message clients = do
    T.putStrLn message
    forM_ clients $ \(Client { connection = conn }) -> WS.sendTextData conn message

getUUID Event { documentId = Just "" } = do
  uuid <- U.nextRandom
  return $ Just (toString uuid)
getUUID Event { documentId = Just "/" } = do
  uuid <- U.nextRandom
  return $ Just (toString uuid)
getUUID Event { documentId = Just dId} = do
  return $ Just dId
getUUID Event { documentId = Nothing} = do
  uuid <- U.nextRandom
  return $ Just (toString uuid)

application :: MVar ServerState -> WS.ServerApp
application state pending = do
    conn <- WS.acceptRequest pending
    WS.forkPingThread conn 30
    msg <- WS.receiveData conn
    let message = A.decode (TL.encodeUtf8 (TL.fromStrict msg)) :: Maybe Event
    case message of
      Just mess ->
        case event mess of
          "connect" -> flip finally disconnect $ do
            uuid <- getUUID mess
            let client = Client (T.pack $ user mess) (T.pack $ M.fromJust uuid) conn
            modifyMVar_ state $ \s -> do
                let s' = addClient client s
                broadcast (TL.toStrict (TL.decodeUtf8 (A.encode $ Event uuid (user mess) "user-joined" (Just $ A.String (userId client))))) s'
                return s'
            talk conn state client
          _ -> do
            putStrLn "No message"
            putStrLn $ show mess
        where
          c = M.fromMaybe (A.String "") (payload mess)
          A.String cli = c
          -- client = (cli, conn)
          client = Client (T.pack $ M.fromJust $ documentId mess) (T.pack $ user mess) conn
          disconnect = do
            putStrLn "disconnected"
            putStrLn $ show $ user mess
            -- Remove client and return new state
            s <- modifyMVar state $ \s ->
              let s' = removeClient client s in return (s', s')
            broadcast ((userId client) `mappend` " disconnected") s
      Nothing ->
        putStrLn "No message"

talk :: WS.Connection -> MVar ServerState -> Client -> IO ()
talk conn state Client { userId = user } = forever $ do
  msg <- WS.receiveData conn
  let message = A.decode (TL.encodeUtf8 (TL.fromStrict msg)) :: Maybe Event
  putStrLn "====="
  putStrLn $ show message
  putStrLn "====="
  clients <- readMVar state
  putStrLn $ show clients
  putStrLn "====="
  case message of
    Just mess ->
      let maybeId = documentId mess in
        case maybeId of
          Just docId -> do
            putStrLn "=====FILTER====="
            putStrLn docId
            putStrLn $ show (filter (\client -> dId client == T.pack docId) clients)
            putStrLn "=====FILTER====="
            broadcast (TL.toStrict (TL.decodeUtf8 (A.encode $ Event (Just docId) (T.unpack user) (event mess)  (payload mess)))) (filter (\client -> dId client == T.pack docId) clients)
          Nothing ->
            broadcast (TL.toStrict (TL.decodeUtf8 (A.encode $ Event (documentId mess) (T.unpack user) (event mess)  (payload mess)))) clients
    Nothing ->
      broadcast msg clients

app :: IO ()
app = do
  state <- newMVar newServerState
  WS.runServer "0.0.0.0" 9160 $ application state
