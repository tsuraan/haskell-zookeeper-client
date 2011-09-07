module Zookeeper.LionTamer.Types
( ExistsCb(..)
, ChildCb(..)
, GetCb(..)
, EphemRecord(..)
, LionCallback(..)
, LionTamer(..)
, LionTamerR
)

where

import qualified Zookeeper as Zoo

import Data.ByteString ( ByteString )
import Data.IORef (IORef)
import Data.Int (Int32)
import Data.Map (Map)

data ExistsCb = ExistsCb Int (String -> (Maybe Zoo.Stat) -> IO ()) 
data ChildCb  = ChildCb  Int (String -> [String] -> IO ())
data GetCb    = GetCb    Int ( String
                             -> (Maybe ByteString)
                             -> Maybe Zoo.Stat
                             -> IO ())

data EphemRecord = EphemRecord { basePath :: String
                               , value    :: Maybe ByteString
                               , seqEphem :: Bool
                               , callBack :: String -> IO ()
                               , errBack  :: IO ()
                               }

data LionCallback = LionGet GetCb
                  | LionChild ChildCb
                  | LionExists ExistsCb

data LionTamer = LionTamer { zHandle    :: Zoo.ZHandle
                           , callbacks  :: Map String [LionCallback]
                           , ephemerals :: [EphemRecord]
                           , connStr    :: String
                           , timeout    :: Int32
                           }

type LionTamerR = IORef LionTamer

