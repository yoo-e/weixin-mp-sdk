{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module WeiXin.PublicPlatform.Pay where

import ClassyPrelude

import           Control.DeepSeq        (NFData)
import           Control.Lens           hiding ((.=))
import           Control.Monad.Except
import           Control.Monad.Logger
import           Control.Monad.Reader   (asks)
import qualified Crypto.Hash.MD5        as MD5
import           Data.Binary            (Binary)
import qualified Data.ByteString.Base16 as B16
import qualified Data.ByteString.Char8  as C8
import           Data.Default           (def)
import           Data.Monoid            (Endo (..))
import qualified Data.Text              as T
import qualified Data.Text.Lazy         as LT
import           Data.Time              (hoursToTimeZone, localTimeToUTC, LocalTime)
import           Data.Time.Format       (parseTimeM)
import           Network.Wreq           (responseBody)
import qualified Network.Wreq.Session   as WS
import           Text.Blaze.Html        (ToMarkup (..))
import           Text.Shakespeare.I18N  (ToMessage (..))
import           Text.XML               (Document (..), Element (..), Name (..),
                                         Node (..), Prologue (..), renderText, parseLBS)
import           Text.XML.Cursor        (child, content, fromDocument, fromNode
                                        , node, ($/), ($|), (&|)
                                        )

import           Text.Parsec.TX.Utils   (SimpleStringRep (..), deriveJsonS,
                                         derivePersistFieldS,
                                         makeSimpleParserByTable)
import           Yesod.Helpers.Parsec   (derivePathPieceS)

import WeiXin.PublicPlatform.Types
import WeiXin.PublicPlatform.Class
import WeiXin.PublicPlatform.WS
import WeiXin.PublicPlatform.Security


-- | 微信企业支付所产生的订单号
newtype WxMchTransTradeNo = WxMchTransTradeNo { unWxMchTransTradeNo :: Text }
  deriving (Show, Read, Eq, Ord, Typeable, Generic, Binary
           , NFData
           , ToMessage, ToMarkup)


newtype WxPayAppKey = WxPayAppKey { unWxPayAppKey :: Text }
  deriving (Show, Read, Eq, Ord, Typeable, Generic, Binary
           , NFData
           , ToMessage, ToMarkup)


newtype WxPaySignature = WxPaySignature { unWxPaySignature :: Text }
  deriving (Show, Read, Eq, Ord, Typeable, Generic, Binary
           , NFData
           , ToMessage, ToMarkup)


-- | 微信支付商户号
newtype WxPayMchID = WxPayMchID { unWxPayMchID :: Text }
  deriving (Show, Read, Eq, Ord, Typeable, Generic, Binary
           , NFData
           , ToMessage, ToMarkup)


-- | 微信支付的设备号
-- 至于 Info 这个词是因为文档也是用这个词的
newtype WxPayDeviceInfo = WxPayDeviceInfo { unWxPayDeviceInfo :: Text }
  deriving (Show, Read, Eq, Ord, Typeable, Generic, Binary
           , NFData
           , ToMessage, ToMarkup)


-- | 微信支付接口的结果代码
-- 注意: 有两种结果代码: 返回状态状态码, 业务状态码
--       目前看, 内容是一致的
data WxPayResultCode = WxPaySuccess
                     | WxPayFail
                     deriving (Show, Eq, Ord, Enum, Bounded)

$(derivePersistFieldS "WxPayResultCode")
$(derivePathPieceS "WxPayResultCode")
$(deriveJsonS "WxPayResultCode")

instance SimpleStringRep WxPayResultCode where
  simpleEncode WxPaySuccess = "SUCCESS"
  simpleEncode WxPayFail    = "FAIL"

  simpleParser = makeSimpleParserByTable
                    [ ("SUCCESS", WxPaySuccess)
                    , ("FAIL", WxPayFail)
                    ]


-- | 微信支付错误代码
newtype WxPayErrorCode = WxPayErrorCode { unWxPayErrorCode :: Text }
  deriving (Show, Read, Eq, Ord, Typeable, Generic, Binary
           , NFData
           , ToMessage, ToMarkup)


type WxPayParams = HashMap Text Text

-- | 微信签名算法
wxPaySign :: WxPayAppKey
          -> WxPayParams
          -- ^ not including: nonce_str, key
          -> Nonce
          -> WxPaySignature
wxPaySign (WxPayAppKey ak) params (Nonce nonce_str) =
  WxPaySignature $ toUpper $ fromString $
    C8.unpack $ B16.encode $ MD5.hash $ encodeUtf8 str_to_sign
  where
    params_all  = insertMap "nonce_str" nonce_str $ params
    mks k v     = mconcat [ k, "=", v ]
    str_to_sign = intercalate "&" $
                    fmap (uncurry mks) $
                      filter (not . null . snd) $
                        (sortBy (comparing fst) (mapToList params_all)) <> [("key", ak)]


-- | 微信支付调用XML
wxPayOutgoingXmlDoc :: WxPayAppKey
                    -> WxPayParams
                    -- ^ not including: nonce_str, key
                    -> Nonce
                    -> Document
wxPayOutgoingXmlDoc app_key params nonce@(Nonce raw_nonce) =
  Document (Prologue [] Nothing []) root []
  where
    root        = Element "xml" mempty nodes
    nodes       = map (uncurry mk_node) (mapToList params) <> [ node_nonce, node_sign ]
    node_nonce  = mk_node "nonce_str" raw_nonce
    sign        = wxPaySign app_key params nonce
    node_sign   = mk_node "sign" (unWxPaySignature sign)
    mk_node k v = NodeElement $
                    Element (Name k Nothing Nothing) mempty
                      [ NodeContent v ]


wxPayRenderOutgoingXmlDoc :: WxPayAppKey
                          -> WxPayParams
                          -- ^ not including: nonce_str, key
                          -> Nonce
                          -> LT.Text
wxPayRenderOutgoingXmlDoc app_key params nonce =
  renderText def $ wxPayOutgoingXmlDoc app_key params nonce


wxPayParseIncmingXmlDoc :: WxPayAppKey
                        -> Document
                        -> Either Text WxPayParams
wxPayParseIncmingXmlDoc app_key doc = do
  (nonce, params1) <- fmap (first Nonce) $ pop_up_find "nonce_str" all_params
  (sign, params2) <- fmap (first WxPaySignature) $ pop_up_find "sign" params1
  let params = params2
  let sign2 = wxPaySign app_key params nonce

  unless (sign2 == sign) $ do
    Left $ "incorrect signature"

  return params

  where
    cursor = fromDocument doc

    all_params = mapFromList $
                  catMaybes $ map param_from_node $
                    cursor $| child &| node

    pop_up_find name ps = do
      let (m_matched, unmatched) = (lookup name &&& deleteMap name) ps

      matched_one <- maybe (Left $ "'" <> name <> "' not found: " <> tshow ps) return m_matched
      return (matched_one, unmatched)

    param_from_node n@(NodeElement ele) = do
      v <- listToMaybe $ fromNode n $/ content
      let name = nameLocalName (elementName ele)
      return (name, v)

    param_from_node _ = Nothing


data WxCheckName =  WxNoCheckName
                  | WxOptCheckName Text
                  | WxReqCheckName Text
                  deriving (Eq, Show)

-- | 金额指定用分作单位
data WxPayMoneyAmount = WxPayMoneyAmount { unWxPayMoneyAmount :: Int }


-- | 调用时的"通信标识" 为 FAIL 时的数据
-- 出现这种错误时, 认为是程序错误, 直接抛出异常
data WxPayCallReturnError = WxPayCallReturnError
                              (Maybe Text)  -- ^ error message
                              deriving (Show)

instance Exception WxPayCallReturnError


data WxPayDiagError = WxPayDiagError Text
                      deriving (Show)

instance Exception WxPayDiagError


-- | 业务层面上的错误: result_code 为 FAIL 时的数据
data WxPayCallResultError = WxPayCallResultError
                              WxPayErrorCode
                              Text
                            deriving (Show)


-- | 支付时的商户订单号
newtype WxPayMchTradeNo = WxPayMchTradeNo { unWxPayMchTradeNo :: Text }
  deriving (Show, Read, Eq, Ord, Typeable, Generic, Binary
           , NFData
           , ToMessage, ToMarkup)


-- | 微信企业支付成功调用返回的结果
data WxPayTransOk = WxPayTransOk
  { wxPayTransOkPartnerTradeNo :: WxPayMchTradeNo
  , wxPayTransOkWxTradeNo      :: WxMchTransTradeNo
  , wxPayTransOkPaidTime       :: UTCTime
    -- ^ 这个时间的意义不明，不一定是真正成功的时间
    -- 因为还有一个查询接口，有可能返回＂处理中＂的状态
    -- 说明不是一次调用成功就能保证成功的
  }


-- | 微信企业支付
-- CAUTION: 目前未实现双向数字证书认证
--          实用上的解决方法是使用反向代理(例如HAProxy)提供双向证书认证,
--          我们这里只发起普通的http/https请求
wxPayMchTransfer :: (WxppApiMonad env m)
                 => WxPayAppKey
                 -> WxPayMchID
                 -> Maybe WxPayDeviceInfo
                 -> WxPayMchTradeNo
                 -> WxppAppID
                 -> WxppOpenID
                 -> WxCheckName
                 -> WxPayMoneyAmount
                 -> Text          -- ^ description
                 -> Text          -- ^ ip address
                 -> m (Either WxPayCallResultError WxPayTransOk)
wxPayMchTransfer app_key mch_id m_dev_info mch_trade_no app_id open_id check_name pay_amount desc ip_str = do
  url_conf <- asks getWxppUrlConfig
  let url = wxppUrlConfPayApiBase url_conf <> "/promotion/transfers"

  let params :: WxPayParams
      params = mempty &
                (appEndo $ mconcat $ catMaybes
                    [ Just $ Endo $ insertMap "mchid" (unWxPayMchID mch_id)
                    , Just $ Endo $ insertMap "mch_appid" (unWxppAppID app_id)
                    , flip fmap m_dev_info $ \dev -> Endo $ insertMap "device_info" (unWxPayDeviceInfo dev)

                    , Just $ Endo $ insertMap "partner_trade_no" (unWxPayMchTradeNo mch_trade_no)

                    , Just $ Endo $ insertMap "openid" (unWxppOpenID open_id)

                    , case check_name of
                        WxNoCheckName -> Nothing

                        WxOptCheckName name ->
                          Just $ mconcat
                                  [ Endo $ insertMap "check_name" "OPTION_CHECK"
                                  , Endo $ insertMap "re_user_name" name
                                  ]

                        WxReqCheckName name ->
                          Just $ mconcat
                                  [ Endo $ insertMap "check_name" "FORCE_CHECK"
                                  , Endo $ insertMap "re_user_name" name
                                  ]

                    , Just $ Endo $ insertMap "amount" (tshow $ unWxPayMoneyAmount pay_amount)
                    , Just $ Endo $ insertMap "desc" desc
                    , Just $ Endo $ insertMap "spbill_create_ip" ip_str
                    ])


  runExceptT $ do
    resp_params <- ExceptT $ wxPayCallInternal app_key url params
    let lookup_param n = maybe
                          (throwM $ WxPayDiagError $ "Invalid response XML: Element '" <> n <> "' not found")
                          return
                          (lookup n resp_params)


    mch_out_trade_no <- fmap WxPayMchTradeNo $ lookup_param "partner_trade_no"
    wx_trade_no <- fmap WxMchTransTradeNo $ lookup_param "payment_no"
    pay_time_t <- lookup_param "payment_time"
    local_time <- maybe
                    (throwM $ WxPayDiagError $ "Invalid response XML: time string is invalid: " <> pay_time_t)
                    return
                    (wxPayParseTimeStr $ T.unpack pay_time_t)

    let pay_time = localTimeToUTC tz local_time

    return $ WxPayTransOk mch_out_trade_no wx_trade_no pay_time

  where
    tz = hoursToTimeZone 8



wxPayCallInternal :: (WxppApiMonad env m)
                  => WxPayAppKey
                  -> String
                  -> WxPayParams
                  -> m (Either WxPayCallResultError WxPayParams)
wxPayCallInternal app_key url params = do
  sess <- asks getWreqSession
  nonce <- wxppMakeNonce 32
  let doc_txt = wxPayRenderOutgoingXmlDoc app_key params nonce

  r <- liftIO (WS.post sess url $ encodeUtf8 doc_txt)
  let lbs = r ^. responseBody
  case parseLBS def lbs of
      Left ex         -> do
        $logErrorS wxppLogSource $ "Failed to parse XML: " <> tshow ex
        throwM ex

      Right resp_doc  -> do
        case wxPayParseIncmingXmlDoc app_key resp_doc of
          Left err -> do
            $logErrorS wxppLogSource $ "Invalid response XML: " <> err
            throwM $ WxPayDiagError err

          Right resp_params -> do
            let lookup_param n = maybe
                                  (throwM $ WxPayDiagError $ "Invalid response XML: Element '" <> n <> "' not found")
                                  return
                                  (lookup n resp_params)

            ret_code <- lookup_param "return_code"
            unless (ret_code == "SUCCESS") $ do
              let m_err_msg = lookup "return_msg" resp_params
              throwM $ WxPayCallReturnError m_err_msg

            result_code <- lookup_param "result_code"
            if result_code == "SUCCESS"
               then do
                 return $ Right resp_params

               else do
                 -- failed
                 err_code <- fmap WxPayErrorCode $ lookup_param "err_code"
                 err_desc <- lookup_param "err_code_des"
                 return $ Left $ WxPayCallResultError err_code err_desc


-- | 文档里的示示例, 时分秒的分隔符是全角的
-- 这个函数能兼容全角和半角两种情况
wxPayParseTimeStr :: String -> Maybe LocalTime
wxPayParseTimeStr t =
  parseTimeM True locale fmt1 t <|> parseTimeM True locale fmt2 t
  where
    fmt1   = "%Y-%m-%d %H:%M:%S"
    fmt2   = "%Y-%m-%d %H：%M：%S"
    locale = defaultTimeLocale
