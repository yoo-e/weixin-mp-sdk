{-# LANGUAGE RankNTypes #-}
module WeiXin.PublicPlatform.Misc where

import ClassyPrelude
import qualified Data.Map.Strict            as Map
import qualified Data.HashMap.Strict        as HM
import qualified Data.Text                  as T
import Filesystem.Path.CurrentOS            (encodeString, fromText)
import Control.Monad.Logger

import WeiXin.PublicPlatform.Types
-- import WeiXin.PublicPlatform.WS
import WeiXin.PublicPlatform.Acid
import WeiXin.PublicPlatform.InMsgHandler
import WeiXin.PublicPlatform.Yesod.Site.Data

import Data.Aeson
import Data.Aeson.Types                     (Parser)


-- | 从字典中找出形如 "wxpp~xxxx" 的字段，每个那样的字段解释出一个 WxppAppConfig
parseMultWxppAppConfig :: Object -> Parser (Map WxppAppID WxppAppConfig)
parseMultWxppAppConfig obj = do
    liftM (Map.fromList . catMaybes) $
        forM (HM.toList obj) $ \(k, v) -> do
            if T.isPrefixOf "wxpp~" k
                then Just . (wxppAppConfigAppID &&& id) <$> parseJSON v
                else return Nothing


-- | 用于生成 yesod 的 subsite 类型的辅助工具
-- 它就是为了辅助制造一个 App -> WxppAppID -> MaybeWxppSub 这样的函数
getMaybeWxppSubOfYesodApp ::
    AcidState WxppAcidState
    -> Map WxppAppID WxppAppConfig
    -> (forall a. LoggingT IO a -> IO a)
    -> (WxppAppID -> [WxppInMsgHandlerPrototype (LoggingT IO)])
    -> Chan [WxppOutMsgEntity]
    -> WxppAppID
    -> MaybeWxppSub
getMaybeWxppSubOfYesodApp acid wxpp_config_map run_logging_t get_protos send_msg_ch app_id =
    MaybeWxppSub $ case Map.lookup app_id wxpp_config_map of
        Nothing     -> Nothing
        Just wac    ->  let data_dir    = wxppAppConfigDataDir wac
                        in Just $ WxppSub wac
                                    get_access_token
                                    send_msg
                                    (handle_msg data_dir)
                                    run_logging_t
    where
        get_access_token = wxppAcidGetUsableAccessToken acid app_id

        handle_msg data_dir bs ime = do
            err_or_in_msg_handlers <- liftIO $
                    readWxppInMsgHandlers
                        (get_protos app_id)
                        (encodeString $ data_dir </> fromText "msg-handlers.yml")

            case err_or_in_msg_handlers of
                Left err -> do
                    $logErrorS wxppLogSource $ fromString $
                        "cannot parse msg-handlers.yml: " ++ show err
                    return $ Left "msg-handlers.yml error"

                Right in_msg_handlers -> do
                    tryEveryInMsgHandler'
                            acid
                            (liftIO get_access_token)
                            in_msg_handlers
                            bs ime

        send_msg = writeChan send_msg_ch