{-# LANGUAGE ScopedTypeVariables #-}
module Zookeeper.LionTamer
( LionTamerR
, ExistsCb(..)
, ChildCb(..)
, GetCb(..)
, zHandle
, init
, close
, create
, addEphemeralNode
, watchExists
, exists
, watchGet
, get
, getChildren
, watchChildren
, remWatch
) where

import qualified Zookeeper.LionTamer.Types as T
import qualified Data.IORef as IORef
import qualified Zookeeper as Zoo
import qualified Data.Map as Map

import Zookeeper.LionTamer.Types ( LionTamerR, ExistsCb(..), ChildCb(..)
                                 , GetCb(..) )
import Control.Concurrent ( forkIO )
import Control.Exception ( catch, catches, tryJust, Handler , IOException
                         , Handler(..), throwIO )
import Data.ByteString ( ByteString )

import Prelude hiding ( init, catch )

zHandle :: LionTamerR -> IO Zoo.ZHandle
zHandle lt = T.zHandle `fmap` IORef.readIORef lt

init :: String -> Int -> IO LionTamerR
init connStr timeout = do
  zh        <- Zoo.init connStr Nothing timeout
  lt <- IORef.newIORef $ T.LionTamer { T.zHandle    = zh
                                     , T.callbacks  = Map.empty
                                     , T.ephemerals = []
                                     , T.connStr    = Just connStr
                                     , T.timeout    = timeout
                                     }
  Zoo.setWatcher zh $ Just $ eventWatcher lt
  return lt

close :: LionTamerR -> IO ()
close lt = do
  zh <- IORef.atomicModifyIORef lt close'
  Zoo.close zh
  where
  close' lt_ =
    ( lt_ { T.callbacks  = Map.empty
          , T.ephemerals = []
          , T.connStr    = Nothing
          , T.timeout    = 0
          }
    , T.zHandle lt_
    )

create :: LionTamerR
       -> String
       -> Maybe ByteString
       -> Zoo.Acls
       -> Zoo.CreateMode
       -> IO String
create lt p v a m = do
  zh <- zHandle lt
  Zoo.create zh p v a m

addEphemeralNode :: LionTamerR
                 -> String
                 -> Maybe ByteString
                 -> Bool
                 -> (String -> IO ())
                 -> IO ()
                 -> IO ()
addEphemeralNode lt path value isSequential succBack errBack = do
  let ephem = T.EphemRecord { T.basePath = path
                            , T.value    = value
                            , T.seqEphem = isSequential
                            , T.callBack = succBack
                            , T.errBack  = errBack
                            }
  zh <- IORef.atomicModifyIORef lt $ updateEphemerals ephem
  zkCreateEphemeral zh ephem
  where
  updateEphemerals ephem lt_ = 
    ( lt_ { T.ephemerals = ephem:(T.ephemerals lt_) }
    , T.zHandle lt_)

exists :: LionTamerR -> String -> IO (Maybe Zoo.Stat)
exists lt path = do
  zHandle lt >>= (\zh -> Zoo.exists zh path Zoo.NoWatch)
  

watchExists :: LionTamerR -> String -> ExistsCb -> IO ()
watchExists lt path cb@(ExistsCb _id fn) = do
  zh <- IORef.atomicModifyIORef lt updateCallbacks
  catch (do
          -- give the callback its first result, if possible
          exRes <- Zoo.exists zh path Zoo.Watch
          fn path exRes)
        caught

  where
  updateCallbacks lt_ =
    let oldCbs = T.callbacks lt_
    in ( lt_ { T.callbacks = Map.insertWith (++) path [T.LionExists cb] oldCbs }
       , T.zHandle lt_)

  caught :: Zoo.ZooError -> IO ()
  caught = const $ return ()

get :: LionTamerR -> String -> IO (Maybe ByteString, Maybe Zoo.Stat)
get lt path =
  catch (do zh <- zHandle lt
            (mBS, st) <- Zoo.get zh path Zoo.NoWatch
            return (mBS, Just st))
        (\(_e :: Zoo.ZooError) -> return (Nothing, Nothing))

watchGet :: LionTamerR
         -> String
         -> GetCb
         -> IO ()
watchGet lt path cb@(GetCb _ fn) = do
  zh <- IORef.atomicModifyIORef lt updateCallbacks
  eiGet <- tryJust (\e -> Just (e :: Zoo.ZooError))
                   (Zoo.get zh path Zoo.Watch)
  case eiGet of
    Left (Zoo.ErrNoNode _s) -> fn path Nothing Nothing
    Left err                -> throwIO err
    Right (mBS, st)         -> fn path mBS (Just st)

  where
  updateCallbacks lt_ =
    let oldCbs = T.callbacks lt_
    in ( lt_ { T.callbacks = Map.insertWith (++) path [T.LionGet cb] oldCbs }
       , T.zHandle lt_)

getChildren :: LionTamerR -> String -> IO [String]
getChildren lt path =
  catch (do zh <- zHandle lt
            Zoo.getChildren zh path Zoo.NoWatch)
        (\(_e :: Zoo.ZooError) -> return [])

watchChildren :: LionTamerR -> String -> ChildCb-> IO ()
watchChildren lt path cb@(ChildCb _ fn) = do
  zh <- IORef.atomicModifyIORef lt updateCallbacks
  eiChildren <- tryJust (\e -> Just (e :: Zoo.ZooError))
                        (Zoo.getChildren zh path Zoo.Watch)
  case eiChildren of
    Left (Zoo.ErrNoNode _s) -> fn path []
    Left _err               -> return ()
    Right children          -> fn path children

  where
  updateCallbacks lt_ =
    let oldCbs = T.callbacks lt_
    in ( lt_ { T.callbacks = Map.insertWith (++) path [T.LionChild cb] oldCbs }
       , T.zHandle lt_)


remWatch :: LionTamerR -> String -> Int -> IO ()
remWatch lt path watchId = do
  IORef.modifyIORef lt (\lt_ ->
    let cbs = Map.alter trunc path $ T.callbacks lt_ 
    in  lt_ { T.callbacks = cbs })
  where
  trunc Nothing = Nothing
  trunc (Just elems) =
    case filter differentId elems of
      [] -> Nothing
      ls -> Just ls

  differentId (T.LionExists (ExistsCb id' _)) | id' == watchId = False
  differentId (T.LionGet    (GetCb id' _))    | id' == watchId = False
  differentId (T.LionChild  (ChildCb id' _))  | id' == watchId = False
  differentId _ = True

eventWatcher :: LionTamerR
             -> Zoo.ZHandle
             -> Zoo.EventType
             -> Zoo.State
             -> String
             -> IO ()
eventWatcher lt _zh _et Zoo.ExpiredSession _ = nullFork $ do
  -- session is totally gone; we need to close our old handle and make a new
  -- one
  putStrLn "!!! Zookeeper Session Expired !!!"
  lt_ <- IORef.readIORef lt
  Zoo.close $ T.zHandle lt_
  
  case T.connStr lt_ of
    Nothing -> return ()
    Just connStr -> do
      newZh <- Zoo.init connStr (Just $ eventWatcher lt) (T.timeout lt_)
      IORef.modifyIORef lt (\lt_' -> lt_' { T.zHandle = newZh })
      reEstablish lt

eventWatcher lt zh et st path = do
  putStrLn $ "Got event " ++ (show et) ++ " " ++ (show st)
  cbs <- T.callbacks `fmap` IORef.readIORef lt
  case Map.lookup path cbs of
    Nothing -> return ()
    Just forPath ->
      case et of
        Zoo.Created ->
          statFn zh path forPath
        Zoo.Deleted -> do
          statFn zh path forPath
          getFn zh path forPath
        Zoo.Changed -> do
          statFn zh path forPath
          getFn zh path forPath
        Zoo.Child -> 
          childFn zh path forPath
        _ ->
          return ()

statFn :: Zoo.ZHandle -> String -> [T.LionCallback] -> IO ()
statFn zh path forPath =
  let funs = [fn | T.LionExists (ExistsCb _ fn) <- forPath]
  in if null funs
      then return ()
      else
        nullFork $ do
          mStat <- Zoo.exists zh path Zoo.Watch
          sequence_ [ fn path mStat | fn <- funs ]

getFn :: Zoo.ZHandle -> String -> [T.LionCallback] -> IO ()
getFn zh path forPath = 
  let funs = [fn | T.LionGet (GetCb _ fn) <- forPath]
  in if null funs
      then return ()
      else
        nullFork $ do
          mRes <- tryJust (\e -> Just (e :: Zoo.ZooError))
                          (Zoo.get zh path Zoo.Watch)
          case mRes of
            Left _ ->
              return ()
            Right (value, stat) ->
              sequence_ [ fn path value (Just stat) | fn <- funs ]

childFn :: Zoo.ZHandle -> String -> [T.LionCallback] -> IO ()
childFn zh path forPath = 
  let funs = [fn | T.LionChild (ChildCb _ fn) <- forPath]
  in if null funs
      then return ()
      else
        nullFork $ do
          children <- Zoo.getChildren zh path Zoo.Watch
          sequence_ [ fn path children | fn <- funs ]

reEstablish :: LionTamerR -> IO ()
reEstablish lt = do
  lt_ <- IORef.readIORef lt
  let zh  = T.zHandle lt_
  let lst = Map.toList $ T.callbacks lt_
  mapM_ (uncurry $ statFn zh) lst
  mapM_ (uncurry $ getFn zh)  lst
  mapM_ (uncurry $ childFn zh) lst
  
  mapM_ (zkCreateEphemeral $ T.zHandle lt_) (T.ephemerals lt_)

zkCreateEphemeral :: Zoo.ZHandle
                  -> T.EphemRecord
                  -> IO ()
zkCreateEphemeral zh ephem =
  catches (do path <- Zoo.create zh
                                 (T.basePath ephem)
                                 (T.value ephem)
                                 Zoo.OpenAclUnsafe
                                 $ Zoo.CreateMode
                                     { Zoo.create_ephemeral = True
                                     , Zoo.create_sequence  = T.seqEphem ephem
                                     }
              (T.callBack ephem) path)
          [ Handler (\(_e :: IOException)  -> (T.errBack ephem))
          , Handler (\(_e :: Zoo.ZooError) -> (T.errBack ephem))
          ]


nullFork :: IO () -> IO ()
nullFork action = forkIO action >> return ()
