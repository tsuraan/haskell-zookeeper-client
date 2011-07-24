module Zookeeper.LionTamer
( LionTamer(..)
, LionCallback(..)
, init
, exists
, get
, getChildren
, remWatch
) where

import qualified Zookeeper as Zoo
import qualified Data.IORef as IORef
import           Data.IORef (IORef)
import qualified Data.Map as Map
import           Data.Map (Map)
import           Control.Concurrent (forkIO)
import           Prelude hiding (init)

data LionCallback
  = ExistsCb Int (String -> Zoo.EventType -> (Maybe Zoo.Stat) -> IO ())
  | GetCb Int (String -> Zoo.EventType -> (Maybe String) -> Zoo.Stat -> IO ())
  | ChildCb Int (String -> Zoo.EventType -> [String] -> IO ())
  | NoCb

data LionTamer = LionTamer { zHandle :: Zoo.ZHandle
                           , callbacks :: IORef (Map String [LionCallback])
                           }

init :: String -> Int -> IO LionTamer
init connStr timeout = do
  dm <- IORef.newIORef Map.empty
  zh <- Zoo.init connStr (eventWatcher dm) timeout
  return $ LionTamer zh dm

exists :: LionTamer -> String -> LionCallback -> IO (Maybe Zoo.Stat)
exists lt path cb@(ExistsCb _ _) = do
  _ <- IORef.atomicModifyIORef (callbacks lt)
                               (\m -> (Map.insertWith (++) path [cb] m, ()))
  Zoo.exists (zHandle lt) path Zoo.Watch

exists lt path NoCb = Zoo.exists (zHandle lt) path Zoo.NoWatch
exists _lt _path _ = error "exists callback must be an instance of ExistsCb"


get :: LionTamer -> String -> LionCallback -> IO (Maybe String, Zoo.Stat)
get lt path cb@(GetCb _ _) = do
  _ <- IORef.atomicModifyIORef (callbacks lt)
                               (\m -> (Map.insertWith (++) path [cb] m, ()))
  Zoo.get (zHandle lt) path Zoo.Watch

get lt path NoCb = Zoo.get (zHandle lt) path Zoo.NoWatch
get _lt _path _ = error "get callback must be an instance of GetCb"

getChildren :: LionTamer -> String -> LionCallback -> IO [String]
getChildren lt path cb@(ChildCb _ _) = do
  _ <- IORef.atomicModifyIORef (callbacks lt)
                               (\m -> (Map.insertWith (++) path [cb] m, ()))
  Zoo.getChildren (zHandle lt) path Zoo.Watch

getChildren lt path NoCb = Zoo.getChildren (zHandle lt) path Zoo.NoWatch
getChildren _lt _path _ = error "getChildren callback must be a ChildCb"

remWatch :: LionTamer -> String -> Int -> IO ()
remWatch lt path id = do
  IORef.atomicModifyIORef (callbacks lt) (\m -> (Map.alter trunc path m, ()))
  where
  trunc Nothing = Nothing
  trunc (Just elems) =
    case filter pred elems of
      [] -> Nothing
      ls -> Just ls

  pred (ExistsCb id' _) | id' == id = False
  pred (GetCb id' _)    | id' == id = False
  pred (ChildCb id' _)  | id' == id = False
  pred _ = True

eventWatcher :: IORef (Map String [LionCallback])
             -> Zoo.ZHandle
             -> Zoo.EventType
             -> Zoo.State
             -> String
             -> IO ()
eventWatcher cbsRef zh et st path = do
  cbs <- IORef.readIORef cbsRef
  case Map.lookup path cbs of
    Nothing -> return ()
    Just forPath ->
      case et of
        Zoo.Created ->
          statFn forPath
        Zoo.Deleted -> do
          statFn forPath
          getFn forPath
        Zoo.Changed -> do
          statFn forPath
          getFn forPath
        Zoo.Child -> 
          childFn forPath
        _ ->
          return ()
  where

  statFn forPath = do
    _ <- forkIO $ do
      mStat <- Zoo.exists zh path Zoo.Watch
      sequence_ [fn path et mStat | ExistsCb _ fn <- forPath]
    return ()

  getFn forPath = do
    _ <- forkIO $ do
      mRes <- Zoo.get' zh path Zoo.Watch
      case mRes of
        Nothing ->
          return ()
        Just (value, stat) -> do
          sequence_ [fn path et value stat | GetCb _ fn <- forPath]
    return ()

  childFn forPath = do
    _ <- forkIO $ do
      children <- Zoo.getChildren zh path Zoo.Watch
      sequence_ [fn path et children | ChildCb _ fn <- forPath]
    return ()
