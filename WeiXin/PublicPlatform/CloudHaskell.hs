module WeiXin.PublicPlatform.CloudHaskell where

import           ClassyPrelude                                      hiding
                                                                     (newChan)
import           Control.Distributed.Process
import           Control.Distributed.Process.Async
import           Control.Distributed.Process.Node                   hiding (newLocalNode)
import           Control.Monad.Except                               (runExceptT,
                                                                     throwError)
import           Control.Monad.Logger
import           Control.Monad.Trans.Control                        (MonadBaseControl)
import           Data.Aeson
import           Data.Binary                                        (Binary (..))
import qualified Data.ByteString.Lazy                               as LB
import           System.Timeout                                     (timeout)

import           WeiXin.PublicPlatform.InMsgHandler
import           WeiXin.PublicPlatform.Types


-- | 代表一种能找到接收 w 信息的 Process/SendPort 信息
data CloudBackendInfo w = CloudBackendInfo
                            (IO LocalNode)
                              -- ^ create new LocalNode
                            (IO [SendPort w])
                              -- ^ 与这些 Process 通讯来处理真正的业务逻辑

-- | A middleware to send event notifications of some types to the cloud (async)
data TeeEventToCloud = TeeEventToCloud
                          WxppAppID
                          (CloudBackendInfo WrapInMsgHandlerInput)
                          [Text]
                            -- ^ event names to forward (wxppEventTypeString)
                            -- if null, forward all.

instance JsonConfigable TeeEventToCloud where
    type JsonConfigableUnconfigData TeeEventToCloud =
            (WxppAppID, CloudBackendInfo WrapInMsgHandlerInput)

    -- | 假定每个算法的配置段都有一个 name 的字段
    -- 根据这个方法选择出一个指定算法类型，
    -- 然后从 json 数据中反解出相应的值
    isNameOfInMsgHandler _ = (== "tee-to-cloud")

    parseWithExtraData _ (x1, x2) o = TeeEventToCloud x1 x2
                                        <$> o .: "event-types"

instance (MonadIO m, MonadLogger m) => IsWxppInMsgProcMiddleware m TeeEventToCloud where
    preProcInMsg
      (TeeEventToCloud app_id (CloudBackendInfo new_local_node get_ports) evt_types)
      _cache bs m_ime = do
          forM_ m_ime $ \ime -> do
            case wxppInMessage ime of
              WxppInMsgEvent evt -> do
                when (null evt_types || wxppEventTypeString evt `elem` evt_types) $ do
                  send_port_list <- liftIO get_ports
                  if null send_port_list
                     then do
                       $logWarnS wxppLogSource $ "No SendPort available to send event notifications"
                     else do
                       let msg = WrapInMsgHandlerInput app_id bs ime
                       node <- liftIO new_local_node
                       liftIO $ runProcess node $ do
                         forM_ send_port_list $ \sp -> do
                           sendChan sp msg

              _ -> return ()

          return $ Just (bs, m_ime)


-- | A message handler that send WxppInMsgEntity to peers and wait for responses
data DelegateInMsgToCloud (m :: * -> *) =
                          DelegateInMsgToCloud
                              WxppAppID
                              (CloudBackendInfo (WrapInMsgHandlerInput, SendPort WxppInMsgHandlerResult))
                              Int
                                -- ^ timeout (ms) when selecting processes to handle
                                -- 配置时用的单位是秒，浮点数

instance JsonConfigable (DelegateInMsgToCloud m) where
    type JsonConfigableUnconfigData (DelegateInMsgToCloud m) =
            (WxppAppID, CloudBackendInfo (WrapInMsgHandlerInput, SendPort WxppInMsgHandlerResult))

    -- | 假定每个算法的配置段都有一个 name 的字段
    -- 根据这个方法选择出一个指定算法类型，
    -- 然后从 json 数据中反解出相应的值
    isNameOfInMsgHandler _ = (== "deletgate-to-cloud")

    parseWithExtraData _ (x1, x2) o = DelegateInMsgToCloud x1 x2
                                  <$> (fmap (round . (* 1000000)) $
                                          o .:? "timeout" .!= (5 :: Float)
                                      )
                                      -- ^ timeout number is a float in seconds

type instance WxppInMsgProcessResult (DelegateInMsgToCloud m) = WxppInMsgHandlerResult

instance (MonadIO m, MonadLogger m, MonadBaseControl IO m)
  => IsWxppInMsgProcessor m (DelegateInMsgToCloud m) where
    processInMsg
      (DelegateInMsgToCloud app_id (CloudBackendInfo new_local_node get_ports) t1)
      _cache bs m_ime = runExceptT $ do
        case m_ime of
          Nothing   -> return []
          Just ime  -> do
            send_port_list <- liftIO get_ports
            when (null send_port_list) $ do
              let msg = "No SendPort available in cloud haskell"
              $logErrorS wxppLogSource $ fromString msg
              throwError msg

            let cloud_pack_msg = WrapInMsgHandlerInput app_id bs ime

            let send_recv sp = do
                  (send_port, recv_port) <- newChan
                  sendChan sp (cloud_pack_msg, send_port)
                  receiveChanTimeout t1 recv_port

            let get_answer = do
                  node <- liftIO new_local_node
                  Just async_res_list <- liftIO $ runProcessTimeout maxBound node $ do
                                      async_list <- forM send_port_list $ \sp -> do
                                                      asyncLinked $ AsyncTask $ send_recv sp
                                      mapM wait async_list
                  res_list <- forM (zip [0..] async_res_list) $ \(idx, async_res) -> do
                                case async_res of
                                  AsyncDone mx -> do
                                    when (isNothing mx) $ do
                                        $logWarnS wxppLogSource $ "Cloud SendPort at pos #"
                                                                    <> tshow (idx :: Int)
                                                                    <> " timed-out."
                                    return mx

                                  AsyncPending -> do
                                    $logErrorS wxppLogSource $
                                      "AsyncResult should never be AsyncPending"
                                    return Nothing

                                  r -> do
                                    $logErrorS wxppLogSource $
                                        "error when handling msg with cloud: "
                                        <> tshow r
                                    return Nothing

                  return $ join $ catMaybes res_list

            let handle_err err = do
                  let msg = "got exception when running cloud-haskell code: "
                              <> show err
                  $logErrorS wxppLogSource $ fromString msg
                  throwError msg

            get_answer `catchAny` handle_err


-- | Cloud message that wraps incoming message info
data WrapInMsgHandlerInput = WrapInMsgHandlerInput
                                WxppAppID
                                LB.ByteString
                                WxppInMsgEntity
                            deriving (Typeable, Generic)
instance Binary WrapInMsgHandlerInput



runProcessTimeout :: Int -> LocalNode -> Process a -> IO (Maybe a)
runProcessTimeout t node proc = do
  mv <- newEmptyMVar
  timeout t $ do
    runProcess node $ do
      r <- proc
      liftIO $ putMVar mv r
    readMVar mv