{-# LANGUAGE ScopedTypeVariables #-}
module WeiXin.PublicPlatform.Types
    ( module WeiXin.PublicPlatform.Types
    , Gender(..)
    , UrlText(..)
    ) where

import ClassyPrelude
import Data.SafeCopy
import Data.Aeson                           as A
import qualified Data.Text                  as T
import Data.Aeson.Types                     (Parser, Pair, typeMismatch)
import qualified Data.ByteString.Base64     as B64
import qualified Data.ByteString.Char8      as C8
import qualified Data.ByteString.Lazy       as LB
import Data.Byteable                        (toBytes)
import Crypto.Cipher                        (makeKey, Key)
import Crypto.Cipher.AES                    (AES)
import Data.Time                            (addUTCTime, NominalDiffTime)
import Data.Scientific                      (toBoundedInteger)
import Text.Read                            (reads)
import Filesystem.Path.CurrentOS            (encodeString, fromText)
import qualified Crypto.Hash.MD5            as MD5
import Database.Persist.Sql                 (PersistField(..), PersistFieldSql(..)
                                            , SqlType(SqlString))
import Yesod.Core                           (PathPiece(..))
import Text.Read                            (Read(..))

import Yesod.Helpers.Aeson                  (parseArray)
import Yesod.Helpers.Types                  (Gender(..), UrlText(..), unUrlText)
import Yesod.Helpers.Parsec                 (SimpleStringRep(..))
import Text.Parsec hiding ((<|>))
import qualified Data.HashMap.Strict        as HM

import WeiXin.PublicPlatform.Utils

-- | 客服帐号
newtype WxppKfAccount = WxppKfAccount { unWxppKfAccount :: Text }
                        deriving (Show, Eq, Ord)


-- | 为区分临时素材和永久素材，这个值专指 临时素材
newtype WxppMediaID = WxppMediaID { unWxppMediaID :: Text }
                        deriving (Show, Eq, Ord)

instance SafeCopy WxppMediaID where
    getCopy                 = contain $ safeGet
    putCopy (WxppMediaID x) = contain $ safePut x

instance PersistField WxppMediaID where
    toPersistValue      = toPersistValue . unWxppMediaID
    fromPersistValue    = fmap WxppMediaID . fromPersistValue

instance PersistFieldSql WxppMediaID where
    sqlType _ = SqlString

instance ToJSON WxppMediaID where
    toJSON = toJSON . unWxppMediaID

instance FromJSON WxppMediaID where
    parseJSON = fmap WxppMediaID . parseJSON


-- | 为区分临时素材和永久素材，这个值专指 永久素材
-- 虽然文档叫这种值 media id，但接口用的词是 material
newtype WxppMaterialID = WxppMaterialID { unWxppMaterialID :: Text }
                        deriving (Show, Eq, Ord)

instance SafeCopy WxppMaterialID where
    getCopy                 = contain $ safeGet
    putCopy (WxppMaterialID x) = contain $ safePut x

instance PersistField WxppMaterialID where
    toPersistValue      = toPersistValue . unWxppMaterialID
    fromPersistValue    = fmap WxppMaterialID . fromPersistValue

instance PersistFieldSql WxppMaterialID where
    sqlType _ = SqlString

instance ToJSON WxppMaterialID where
    toJSON = toJSON . unWxppMaterialID

instance FromJSON WxppMaterialID where
    parseJSON = fmap WxppMaterialID . parseJSON


newtype WxppOpenID = WxppOpenID { unWxppOpenID :: Text}
                    deriving (Show, Read, Eq, Ord, Typeable)

instance SafeCopy WxppOpenID where
    getCopy                 = contain $ WxppOpenID <$> safeGet
    putCopy (WxppOpenID x)  = contain $ safePut x

instance PersistField WxppOpenID where
    toPersistValue      = toPersistValue . unWxppOpenID
    fromPersistValue    = fmap WxppOpenID . fromPersistValue

instance PersistFieldSql WxppOpenID where
    sqlType _ = SqlString

instance ToJSON WxppOpenID where
    toJSON = toJSON . unWxppOpenID

instance FromJSON WxppOpenID where
    parseJSON = fmap WxppOpenID . parseJSON

instance PathPiece WxppOpenID where
    toPathPiece (WxppOpenID x)  = toPathPiece x
    fromPathPiece t             = WxppOpenID <$> fromPathPiece t

newtype WxppUnionID = WxppUnionID { unWxppUnionID :: Text }
                    deriving (Show, Eq, Ord, Typeable)

instance FromJSON WxppUnionID where
    parseJSON = fmap WxppUnionID . parseJSON

instance ToJSON WxppUnionID where
    toJSON = toJSON . unWxppUnionID

instance SafeCopy WxppUnionID where
    getCopy                 = contain $ WxppUnionID <$> safeGet
    putCopy (WxppUnionID x) = contain $ safePut x

instance PersistField WxppUnionID where
    toPersistValue      = toPersistValue . unWxppUnionID
    fromPersistValue    = fmap WxppUnionID . fromPersistValue

instance PersistFieldSql WxppUnionID where
    sqlType _ = SqlString


newtype WxppInMsgID = WxppInMsgID { unWxppInMsgID :: Word64 }
                    deriving (Show, Eq, Ord)

instance PersistField WxppInMsgID where
    toPersistValue      = toPersistValue . unWxppInMsgID
    fromPersistValue    = fmap WxppInMsgID . fromPersistValue

instance PersistFieldSql WxppInMsgID where
    sqlType _ = SqlString

instance ToJSON WxppInMsgID where
    toJSON = toJSON . unWxppInMsgID

instance FromJSON WxppInMsgID where
    parseJSON = fmap WxppInMsgID . parseJSON


-- | 二维码场景ID
-- 从文档“生成带参数的二维码”一文中看
-- 场景ID可以是个32位整数，也可以是个字串。有若干约束。
newtype WxppIntSceneID = WxppIntSceneID { unWxppIntSceneID :: Word32 }
                    deriving (Show, Eq, Ord)

newtype WxppStrSceneID = WxppStrSceneID { unWxppStrSceneID :: Text }
                    deriving (Show, Eq, Ord)

data WxppScene =    WxppSceneInt WxppIntSceneID
                    | WxppSceneStr WxppStrSceneID
                    deriving (Show, Eq, Ord)

instance ToJSON WxppScene where
    toJSON (WxppSceneInt (WxppIntSceneID x)) = object [ "scene_id" .= x ]
    toJSON (WxppSceneStr (WxppStrSceneID x)) = object [ "scene_str" .= x ]

instance FromJSON WxppScene where
    parseJSON v = do
        r <- (Left <$> parseJSON v) <|> (Right <$> parseJSON v)
        case r of
            Left i -> return $ WxppSceneInt $ WxppIntSceneID i
            Right t -> do
                when ( T.length t < 1 || T.length t > 64) $ do
                    fail $ "invalid scene id str length"
                return $ WxppSceneStr $ WxppStrSceneID t


-- | 创建二维码接口的返回报文
data WxppMakeSceneResult = WxppMakeSceneResult
                                QRTicket
                                NominalDiffTime
                                UrlText

instance FromJSON WxppMakeSceneResult where
    parseJSON = withObject "WxppMakeSceneResult" $ \obj -> do
                    WxppMakeSceneResult
                        <$> ( obj .: "ticket" )
                        <*> ( (fromIntegral :: Int -> NominalDiffTime) <$> obj .: "expire_seconds")
                        <*> ( UrlText <$> obj .: "url" )

-- | 此实例实现对应于 WxppScene 在 XML 的编码方式
-- qrscene 前缀见“接收事件推送”一文
-- 但文档仅在“用户未关注时……”这一情况下说有些前缀
-- 另一种情况“用户已关注……”时则只说是个 32 位整数
-- 因此目前不知道如果创建时用的是字串型场景ID，在后一种情况下会是什么样子
instance SimpleStringRep WxppScene where

    simpleEncode (WxppSceneInt (WxppIntSceneID x)) = "qrcode_" ++ show x
    simpleEncode (WxppSceneStr (WxppStrSceneID x)) = "qrcode_" ++ T.unpack x

    simpleParser = parse_as_int <|> parse_as_str
        where
            parse_as_int = do
                _ <- optional $ string "qrcode_"
                WxppSceneInt . WxppIntSceneID <$> simpleParser

            parse_as_str = do
                _ <- optional $ string "qrcode_"
                WxppSceneStr . WxppStrSceneID . fromString <$> many1 anyChar


newtype QRTicket = QRTicket { unQRTicket :: Text }
                    deriving (Show, Eq, Ord)

instance ToJSON QRTicket where
    toJSON = toJSON . unQRTicket

instance FromJSON QRTicket where
    parseJSON = fmap QRTicket . parseJSON

instance PersistField QRTicket where
    toPersistValue      = toPersistValue . unQRTicket
    fromPersistValue    = fmap QRTicket . fromPersistValue

instance PersistFieldSql QRTicket where
    sqlType _ = SqlString


newtype Token = Token { unToken :: Text }
                    deriving (Show, Eq, Ord)

newtype AesKey = AesKey { unAesKey :: Key AES }
                    deriving (Eq)
instance Show AesKey where
    show (AesKey k) = "AesKey:" <> (C8.unpack $ B64.encode $ toBytes k)


decodeBase64Encoded :: Text -> Either String ByteString
decodeBase64Encoded = B64.decode . encodeUtf8

decodeBase64AesKey :: Text -> Either String AesKey
decodeBase64AesKey t = fmap AesKey $ do
    decodeBase64Encoded t >>= either (Left . show) Right . makeKey

parseAesKeyFromText :: Text -> Parser AesKey
parseAesKeyFromText t = either fail return $ decodeBase64AesKey t

instance FromJSON AesKey where
    parseJSON = withText "AesKey" parseAesKeyFromText

newtype TimeStampS = TimeStampS { unTimeStampS :: Text }
                    deriving (Show, Eq)

newtype Nonce = Nonce { unNounce :: Text }
                    deriving (Show, Eq)

newtype WxppAppID = WxppAppID { unWxppAppID :: Text }
                    deriving (Show, Eq, Ord, Typeable)

instance SafeCopy WxppAppID where
    getCopy                 = contain $ WxppAppID <$> safeGet
    putCopy (WxppAppID x)   = contain $ safePut x

instance PersistField WxppAppID where
    toPersistValue      = toPersistValue . unWxppAppID
    fromPersistValue    = fmap WxppAppID . fromPersistValue

instance PersistFieldSql WxppAppID where
    sqlType _ = SqlString

instance PathPiece WxppAppID where
    toPathPiece (WxppAppID x)   = toPathPiece x
    fromPathPiece t             = WxppAppID <$> fromPathPiece t

instance ToJSON WxppAppID where toJSON = toJSON . unWxppAppID

instance FromJSON WxppAppID where parseJSON = fmap WxppAppID . parseJSON

-- | XXX: Read instance 目前只是 Yesod 生成的 Route 类型时用到
-- 但不清楚具体使用场景，不知道以下的定义是否合适
instance Read WxppAppID where
    readsPrec d s = map (WxppAppID *** id) $ readsPrec d s

-- | 为保证 access_token 的值与它生成属的 app 一致
-- 把它们打包在一个类型里
data AccessToken = AccessToken {
                        accessTokenData     :: Text
                        , accessTokenApp    :: WxppAppID
                    }
                    deriving (Show, Eq, Typeable)
$(deriveSafeCopy 0 'base ''AccessToken)

instance ToJSON AccessToken where
    toJSON x = object   [ "data"    .= accessTokenData x
                        , "app_id"  .= accessTokenApp x
                        ]

instance FromJSON AccessToken where
    parseJSON = withObject "AccessToken" $ \obj -> do
                    AccessToken <$> (obj .: "data")
                                <*> (obj .: "app_id")


-- | 等待额外的值以完整地构造 AccessToken
type AccessTokenP = WxppAppID -> AccessToken

newtype WxppAppSecret = WxppAppSecret { unWxppAppSecret :: Text }
                    deriving (Show, Eq)

data WxppAppConfig = WxppAppConfig {
                    wxppAppConfigAppID         :: WxppAppID
                    , wxppConfigAppSecret   :: WxppAppSecret
                    , wxppConfigAppToken    :: Token
                    , wxppConfigAppAesKey   :: AesKey
                    , wxppConfigAppBackupAesKeys  :: [AesKey]
                        -- ^ 多个 aes key 是为了过渡时使用
                        -- 加密时仅使用第一个
                        -- 解密时则则所有都试一次
                    , wxppAppConfigDataDir  :: FilePath
                    }
                    deriving (Show, Eq)

instance FromJSON WxppAppConfig where
    parseJSON = withObject "WxppAppConfig" $ \obj -> do
                    app_id <- fmap WxppAppID $ obj .: "app-id"
                    secret <- fmap WxppAppSecret $ obj .: "secret"
                    app_token <- fmap Token $ obj .: "token"
                    data_dir <- fromText <$> obj .: "data-dir"
                    aes_key_lst <- obj .: "aes-key"
                                    >>= return . filter (not . T.null) . map T.strip
                                    >>= mapM parseAesKeyFromText
                    case aes_key_lst of
                        []      -> fail $ "At least one AesKey is required"
                        (x:xs)  ->
                            return $ WxppAppConfig app_id secret app_token
                                        x
                                        xs
                                        data_dir


-- | 事件推送的各种值
data WxppEvent = WxppEvtSubscribe
                | WxppEvtUnsubscribe
                | WxppEvtSubscribeAtScene WxppScene QRTicket
                | WxppEvtScan WxppScene QRTicket
                | WxppEvtScanCodePush Text Text Text
                    -- ^ event key, scan type, scan result
                    -- XXX: 文档有提到这个事件类型，但没有消息的具体细节
                | WxppEvtScanCodeWaitMsg Text Text Text
                    -- ^ event key, scan type, scan result
                    -- XXX: 文档有提到这个事件类型，但没有消息的具体细节
                | WxppEvtReportLocation (Double, Double) Double
                    -- ^ (纬度，经度） 精度
                | WxppEvtClickItem Text
                | WxppEvtFollowUrl UrlText
                deriving (Show, Eq)

wxppEventTypeString :: IsString a => WxppEvent -> a
wxppEventTypeString WxppEvtSubscribe              = "subscribe"
wxppEventTypeString WxppEvtUnsubscribe            = "unsubscribe"
wxppEventTypeString (WxppEvtSubscribeAtScene {})  = "subscribe_at_scene"
wxppEventTypeString (WxppEvtScan {})              = "scan"
wxppEventTypeString (WxppEvtReportLocation {})    = "report_location"
wxppEventTypeString (WxppEvtClickItem {})         = "click_item"
wxppEventTypeString (WxppEvtFollowUrl {})         = "follow_url"
wxppEventTypeString (WxppEvtScanCodePush {})      = "scancode_push"
wxppEventTypeString (WxppEvtScanCodeWaitMsg {})   = "scancode_waitmsg"

instance ToJSON WxppEvent where
    toJSON e = object $ ("type" .= (wxppEventTypeString e :: Text)) : get_others e
      where
        get_others WxppEvtSubscribe     = []
        get_others WxppEvtUnsubscribe   = []

        get_others (WxppEvtSubscribeAtScene scene_id qrt) =
                                          [ "scene"     .= scene_id
                                          , "qr_ticket" .= qrt
                                          ]

        get_others (WxppEvtScan scene_id qrt) =
                                          [ "scene"     .= scene_id
                                          , "qr_ticket" .= qrt
                                          ]

        get_others(WxppEvtScanCodePush key scan_type scan_result) =
                                          [ "key"         .= key
                                          , "scan_type"   .= scan_type
                                          , "scan_result" .= scan_result
                                          ]

        get_others(WxppEvtScanCodeWaitMsg key scan_type scan_result) =
                                          [ "key"         .= key
                                          , "scan_type"   .= scan_type
                                          , "scan_result" .= scan_result
                                          ]

        get_others (WxppEvtReportLocation (latitude, longitude) scale) =
                                          [ "latitude"  .= latitude
                                          , "longitude" .= longitude
                                          , "scale"     .= scale
                                          ]

        get_others (WxppEvtClickItem key) = [ "key" .= key ]

        get_others (WxppEvtFollowUrl url) = [ "url" .= unUrlText url ]


instance FromJSON WxppEvent where
    parseJSON = withObject "WxppEvent" $ \obj -> do
        typ <- obj .: "type"
        case typ of
          "subscribe"   -> return WxppEvtSubscribe
          "unsubscribe" -> return WxppEvtUnsubscribe

          "subscribe_at_scene" -> liftM2 WxppEvtSubscribeAtScene
                                      (obj .: "scene")
                                      (obj .: "qr_ticket")

          "scan"  -> liftM2 WxppEvtScan
                              (obj .: "scene")
                              (obj .: "qr_ticket")

          "scancode_push" -> WxppEvtScanCodePush <$> obj .: "key"
                                                <*> obj .: "scan_type"
                                                <*> obj .: "scan_result"

          "scancode_waitmsg" -> WxppEvtScanCodeWaitMsg <$> obj .: "key"
                                                        <*> obj .: "scan_type"
                                                        <*> obj .: "scan_result"

          "report_location" -> liftM2 WxppEvtReportLocation
                                  (liftM2 (,) (obj .: "latitude") (obj .: "longitude"))
                                  (obj .: "scale")

          "click_item"  -> WxppEvtClickItem <$> obj .: "key"

          "follow_url"  -> WxppEvtFollowUrl . UrlText <$> obj .: "url"

          _ -> fail $ "unknown type: " ++ typ


-- | 收到的各种消息: 包括普通消息和事件推送
data WxppInMsg =  WxppInMsgText Text
                    -- ^ 文本消息
                | WxppInMsgImage WxppMediaID UrlText
                    -- ^ 消息
                | WxppInMsgVoice WxppMediaID Text (Maybe Text)
                    -- ^ format recognition
                | WxppInMsgVideo WxppMediaID WxppMediaID
                    -- ^ media_id, thumb_media_id
                | WxppInMsgLocation (Double, Double) Double Text
                    -- ^ (latitude, longitude) scale label
                | WxppInMsgLink UrlText Text Text
                    -- ^ url title description
                | WxppInMsgEvent WxppEvent
                deriving (Show, Eq)

wxppInMsgTypeString :: IsString a => WxppInMsg -> a
wxppInMsgTypeString (WxppInMsgText {})      = "text"
wxppInMsgTypeString (WxppInMsgImage {})     = "image"
wxppInMsgTypeString (WxppInMsgVoice {})     = "voice"
wxppInMsgTypeString (WxppInMsgVideo {})     = "video"
wxppInMsgTypeString (WxppInMsgLocation {})  = "location"
wxppInMsgTypeString (WxppInMsgLink {})      = "link"
wxppInMsgTypeString (WxppInMsgEvent {})     = "event"

instance ToJSON WxppInMsg where
    toJSON msg = object $ ("type" .= (wxppInMsgTypeString msg :: Text)) : get_others msg
      where
        get_others (WxppInMsgText t)              = [ "content" .= t ]

        get_others (WxppInMsgImage media_id url)  = [ "media_id"  .= media_id
                                                    , "url"       .= unUrlText url
                                                    ]

        get_others (WxppInMsgVoice media_id format reg) =
                                                    [ "media_id"    .= media_id
                                                    , "format"      .= format
                                                    , "recognition" .= reg
                                                    ]

        get_others (WxppInMsgVideo media_id thumb_media_id) =
                                                    [ "media_id"        .= media_id
                                                    , "thumb_media_id"  .= thumb_media_id
                                                    ]

        get_others (WxppInMsgLocation (latitude, longitude) scale loc_label) =
                                                    [ "latitude"  .= latitude
                                                    , "longitude" .= longitude
                                                    , "scale"     .= scale
                                                    , "label"     .= loc_label
                                                    ]

        get_others (WxppInMsgLink url title desc) = [ "url"   .= unUrlText url
                                                    , "title" .= title
                                                    , "desc"  .= desc
                                                    ]

        get_others (WxppInMsgEvent evt) = [ "event" .= evt ]


instance FromJSON WxppInMsg where
    parseJSON = withObject "WxppInMsg" $ \obj -> do
      typ <- obj .: "type"
      case typ of
        "text" -> WxppInMsgText <$> obj .: "content"

        "image" -> liftM2 WxppInMsgImage
                    (obj .: "media_id")
                    (UrlText <$> obj .: "url")

        "voice" -> liftM3 WxppInMsgVoice
                    (obj .: "media_id")
                    (obj .: "format")
                    (obj .:? "recognition")

        "video" -> liftM2 WxppInMsgVideo
                    (obj .: "media_id")
                    (obj .: "thumb_media_id")

        "location" -> liftM3 WxppInMsgLocation
                        (liftM2 (,) (obj .: "latitude") (obj .: "longitude"))
                        (obj .: "scale")
                        (obj .: "label")
        "link"  -> liftM3 WxppInMsgLink
                        (UrlText <$> obj .: "url")
                        (obj .: "title")
                        (obj .: "desc")

        "event" -> WxppInMsgEvent <$> obj .: "event"

        _ -> fail $ "unknown type: " ++ typ


data WxppInMsgEntity = WxppInMsgEntity
                        {
                            wxppInToUserName        :: Text
                            , wxppInFromUserName    :: WxppOpenID
                            , wxppInCreatedTime     :: UTCTime
                            , wxppInMessageID       :: Maybe WxppInMsgID
                                -- ^ 从文档看，除了事件通知，所有信息都有 MsgID
                            , wxppInMessage         :: WxppInMsg
                        }
                        deriving (Show, Eq)

instance ToJSON WxppInMsgEntity where
    toJSON e = object [ "to"            .= wxppInToUserName e
                      , "from"          .= wxppInFromUserName e
                      , "created_time"  .= wxppInCreatedTime e
                      , "msg_id"        .= wxppInMessageID e
                      , "msg"           .= wxppInMessage e
                      ]

instance FromJSON WxppInMsgEntity where
    parseJSON = withObject "WxppInMsgEntity" $ \obj -> do
                  liftM5 WxppInMsgEntity
                      (obj .: "to")
                      (obj .: "from")
                      (obj .: "created_time")
                      (obj .:? "msg_id")
                      (obj .: "msg")


-- | 转发各种消息或消息的部分时，所附带的额外信息
data WxppForwardedEnv = WxppForwardedEnv {
                            wxppFwdUnionID          :: Maybe WxppUnionID
                            , wxppFwdAccessToken    :: AccessToken
                        }

instance ToJSON WxppForwardedEnv where
    toJSON x = object
                [ "access_token"    .= wxppFwdAccessToken x
                , "union_id"        .= wxppFwdUnionID x
                ]

instance FromJSON WxppForwardedEnv where
    parseJSON = withObject "WxppForwardedEnv" $ \obj -> do
                    WxppForwardedEnv    <$> ( obj .: "union_id" )
                                        <*> ( obj .: "access_token" )


-- | 图文信息
data WxppArticle = WxppArticle {
                    wxppArticleTitle    :: Maybe Text    -- ^ title
                    , wxppArticleDesc   :: Maybe Text    -- ^ description
                    , wxppArticlePicUrl :: Maybe UrlText -- ^ pic url
                    , wxppArticleUrl    :: Maybe UrlText -- ^ url
                    }
                    deriving (Show, Eq)

instance ToJSON WxppArticle where
    toJSON wa = object
                  [ "title"   .= wxppArticleTitle wa
                  , "desc"    .= wxppArticleDesc wa
                  , "pic-url" .= (unUrlText <$> wxppArticlePicUrl wa)
                  , "url"     .= (unUrlText <$> wxppArticleUrl wa)
                  ]

type WxppArticleLoader = DelayedYamlLoader WxppArticle

instance FromJSON WxppArticle where
    parseJSON = withObject "WxppArticle" $ \obj -> do
                title <- obj .:? "title"
                desc <- obj .:? "desc"
                pic_url <- fmap UrlText <$> obj .:? "pic-url"
                url <- fmap UrlText <$> obj .:? "url"
                return $ WxppArticle title desc pic_url url

-- | 外发的信息
data WxppOutMsg = WxppOutMsgText Text
                | WxppOutMsgImage WxppMediaID
                | WxppOutMsgVoice WxppMediaID
                | WxppOutMsgVideo WxppMediaID WxppMediaID (Maybe Text) (Maybe Text)
                    -- ^ media_id thumb_media_id title description
                | WxppOutMsgMusic WxppMediaID (Maybe Text) (Maybe Text) (Maybe UrlText) (Maybe UrlText)
                    -- ^ thumb_media_id, title, description, url, hq_url
                | WxppOutMsgNews [WxppArticle]
                    -- ^ 根据文档，图文总数不可超过10
                | WxppOutMsgTransferToCustomerService
                    -- ^ 把信息转发至客服
                deriving (Show, Eq)

wxppOutMsgTypeString :: IsString a => WxppOutMsg -> a
wxppOutMsgTypeString (WxppOutMsgText {})                    = "text"
wxppOutMsgTypeString (WxppOutMsgImage {})                   = "image"
wxppOutMsgTypeString (WxppOutMsgVoice {})                   = "voice"
wxppOutMsgTypeString (WxppOutMsgVideo {})                   = "video"
wxppOutMsgTypeString (WxppOutMsgMusic {})                   = "music"
wxppOutMsgTypeString (WxppOutMsgNews {})                    = "news"
wxppOutMsgTypeString (WxppOutMsgTransferToCustomerService)  = "transfer-cs"

instance ToJSON WxppOutMsg where
    toJSON outmsg = object $ ("type" .= (wxppOutMsgTypeString outmsg :: Text)) : get_others outmsg
      where
        get_others (WxppOutMsgText t) = [ "text" .= t ]
        get_others (WxppOutMsgImage media_id) = [ "media_id" .= media_id ]
        get_others (WxppOutMsgVoice media_id) = [ "media_id" .= media_id ]
        get_others (WxppOutMsgVideo media_id thumb_media_id title desc) =
                                                [ "media_id"        .= media_id
                                                , "thumb_media_id"  .= thumb_media_id
                                                , "title"           .= title
                                                , "desc"            .= desc
                                                ]
        get_others (WxppOutMsgMusic thumb_media_id title desc url hq_url) =
                                                [ "thumb_media_id"  .= thumb_media_id
                                                , "title"           .= title
                                                , "desc"            .= desc
                                                , "url"             .= (unUrlText <$> url)
                                                , "hq_url"          .= (unUrlText <$> hq_url)
                                                ]
        get_others (WxppOutMsgNews articles) = [ "articles" .= articles ]
        get_others (WxppOutMsgTransferToCustomerService) = []


instance FromJSON WxppOutMsg where
    parseJSON = withObject "WxppOutMsg" $ \obj -> do
      typ <- obj .: "type"
      case (typ :: String) of
          "text"  -> WxppOutMsgText <$> obj .: "text"
          "image" -> WxppOutMsgImage <$> obj .: "media_id"
          "voice" -> WxppOutMsgVoice <$> obj .: "media_id"

          "video" -> liftM4 WxppOutMsgVideo
                        (obj .: "media_id")
                        (obj .: "thumb_media_id")
                        (obj .:? "title")
                        (obj .:? "desc")

          "music" -> liftM5 WxppOutMsgMusic
                        (obj .: "thumb_media_id")
                        (obj .:? "title")
                        (obj .:? "desc")
                        (fmap UrlText <$> obj .:? "url")
                        (fmap UrlText <$> obj .:? "hq_url")

          "news" -> WxppOutMsgNews <$> obj .: "articles"

          "transfer-cs" -> return WxppOutMsgTransferToCustomerService

          _   -> fail $ "unknown type: " ++ typ


-- | 外发的信息的本地信息
-- 因 WxppOutMsg 包含 media id，它只在上传3天内有效，这个类型的值代表的就是相应的本地长期有效的信息
data WxppOutMsgL = WxppOutMsgTextL Text
                | WxppOutMsgImageL FilePath
                | WxppOutMsgVoiceL FilePath
                | WxppOutMsgVideoL FilePath FilePath (Maybe Text) (Maybe Text)
                    -- ^ media_id title description
                | WxppOutMsgMusicL FilePath (Maybe Text) (Maybe Text) (Maybe UrlText) (Maybe UrlText)
                    -- ^ thumb_media_id, title, description, url, hq_url
                | WxppOutMsgNewsL [WxppArticleLoader]
                    -- ^ 根据文档，图文总数不可超过10
                | WxppOutMsgTransferToCustomerServiceL
                    -- ^ 把信息转发至客服

type WxppOutMsgLoader = DelayedYamlLoader WxppOutMsgL

instance FromJSON WxppOutMsgL where
    parseJSON = withObject "WxppOutMsgL" $ \obj -> do
                    type_s <- obj .:? "type" .!= "text"
                    case type_s of
                        "text" -> WxppOutMsgTextL <$> obj .: "text"
                        "image" -> WxppOutMsgImageL . fromText <$> obj .: "path"
                        "voice" -> WxppOutMsgVoiceL . fromText <$> obj .: "path"
                        "video" -> do
                                    path <- fromText <$> obj .: "path"
                                    path2 <- fromText <$> obj .: "thumb-image"
                                    title <- obj .:? "title"
                                    desc <- obj .:? "desc"
                                    return $ WxppOutMsgVideoL path path2 title desc
                        "music" -> do
                                    path <- fromText <$> obj .: "path"
                                    title <- obj .:? "title"
                                    desc <- obj .:? "desc"
                                    url <- fmap UrlText <$> obj .:? "url"
                                    hq_url <- fmap UrlText <$> obj .:? "hq-url"
                                    return $ WxppOutMsgMusicL path title desc url hq_url

                        "news" -> WxppOutMsgNewsL <$>
                                      ( obj .: "articles"
                                        >>= parseArray "[WxppArticleLoader]" parse_article)

                        "transfer-cs" -> return WxppOutMsgTransferToCustomerServiceL
                        _       -> fail $ "unknown type: " <> type_s
        where

          parse_article_obj = parseDelayedYamlLoader Nothing "file"

          parse_article (A.String t)  = parse_article_obj $ HM.fromList [ "file" .= t ]
          parse_article v             = withObject "WxppArticleLoader" parse_article_obj v


-- | 永久图文素材结构中的一个文章
data WxppMaterialArticle = WxppMaterialArticle {
                                wxppMaterialArticleTitle            :: Text
                                , wxppMaterialArticleThumb          :: WxppMaterialID
                                , wxppMaterialArticleAuthor         :: Maybe Text
                                , wxppMaterialArticleDigest         :: Maybe Text
                                , wxppMaterialArticleShowCoverPic   :: Bool
                                , wxppMaterialArticleContent        :: Text
                                , wxppMaterialArticleContentSrcUrl  :: UrlText
                            }

instance FromJSON WxppMaterialArticle where
    parseJSON = withObject "WxppMaterialArticle" $ \obj -> do
                    WxppMaterialArticle
                        <$> ( obj .: "title" )
                        <*> ( obj .: "thumb_media_id" )
                        <*> ( obj .:? "author" )
                        <*> ( obj .:? "digest" )
                        <*> ( int_to_bool <$> obj .: "show_cover_pic" )
                        <*> ( obj .: "content" )
                        <*> ( UrlText <$> obj .: "content_source_url" )
            where
                int_to_bool x = (x :: Int) /= 0


instance ToJSON WxppMaterialArticle where
    toJSON x = object   [ "title"           .= wxppMaterialArticleTitle x
                        , "thumb_media_id"  .= wxppMaterialArticleThumb x
                        , "author"          .= (fromMaybe "" $ wxppMaterialArticleAuthor x)
                        , "digest"          .= (fromMaybe "" $ wxppMaterialArticleDigest x)
                        , "show_cover_pic"  .= bool_to_int (wxppMaterialArticleShowCoverPic x)
                        , "content"         .= wxppMaterialArticleContent x
                        , "content_source_url" .= unUrlText (wxppMaterialArticleContentSrcUrl x)
                        ]
            where
                bool_to_int b = if b then 1 :: Int else 0

-- | 永久图文素材结构
newtype WxppMaterialNews = WxppMaterialNews [WxppMaterialArticle]

instance FromJSON WxppMaterialNews where
    parseJSON = withObject "WxppMaterialNews" $ \obj -> do
                    WxppMaterialNews <$> obj .: "articles"

instance ToJSON WxppMaterialNews where
    toJSON (WxppMaterialNews articles) = object [ "articles" .= articles ]


-- | 上传多媒体文件接口中的 type 参数
data WxppMediaType = WxppMediaTypeImage
                    | WxppMediaTypeVoice
                    | WxppMediaTypeVideo
                    | WxppMediaTypeThumb
                    deriving (Show, Eq, Ord, Enum, Bounded)

deriveSafeCopy 0 'base ''WxppMediaType

data WxppOutMsgEntity = WxppOutMsgEntity
                        {
                            wxppOutToUserName       :: WxppOpenID
                            , wxppOutFromUserName   :: Text
                            , wxppOutCreatedTime    :: UTCTime
                            , wxppOutMessage        :: WxppOutMsg
                        }
                        deriving (Show, Eq)

wxppMediaTypeString :: IsString a => WxppMediaType -> a
wxppMediaTypeString mtype =
    case mtype of
        WxppMediaTypeImage -> "image"
        WxppMediaTypeVoice -> "voice"
        WxppMediaTypeVideo -> "video"
        WxppMediaTypeThumb -> "thumb"


-- | 可以点击的菜单所携带的数据及菜单的类型
-- 虽然看上去所有菜单都只有个文本作为数据，但概念上这些文本并不相同
-- 例如，有时候它明确地就是一个 URL
data MenuItemData = MenuItemDataClick Text
                        -- ^ key
                    | MenuItemDataView UrlText
                        -- ^ url
                    | MenuItemDataScanCode Text
                        -- ^ key
                    | MenuItemDataScanCodeWaitMsg Text
                        -- ^ key
                    | MenuItemDataPicSysPhoto Text
                        -- ^ key
                    | MenuItemDataPicPhotoOrAlbum Text
                        -- ^ key
                    | MenuItemDataPicWeiXin Text
                        -- ^ key
                    | MenuItemDataLocationSelect Text
                        -- ^ key
                    deriving (Show, Eq)


menuItemDataToJsonPairs :: MenuItemData -> [Pair]
menuItemDataToJsonPairs (MenuItemDataClick key) =
                                [ "type"    .= ("click" :: Text)
                                , "key"     .= key
                                ]
menuItemDataToJsonPairs (MenuItemDataView (UrlText url)) =
                                [ "type"    .= ("view" :: Text)
                                , "url"     .= url
                                ]
menuItemDataToJsonPairs (MenuItemDataScanCode key) =
                                [ "type"    .= ("scancode_push" :: Text)
                                , "key"     .= key
                                ]
menuItemDataToJsonPairs (MenuItemDataScanCodeWaitMsg key) =
                                [ "type"    .= ("scancode_waitmsg" :: Text)
                                , "key"     .= key
                                ]
menuItemDataToJsonPairs (MenuItemDataPicSysPhoto key) =
                                [ "type"    .= ("pic_sysphoto" :: Text)
                                , "key"     .= key
                                ]
menuItemDataToJsonPairs (MenuItemDataPicPhotoOrAlbum key) =
                                [ "type"    .= ("pic_photo_or_album" :: Text)
                                , "key"     .= key
                                ]
menuItemDataToJsonPairs (MenuItemDataPicWeiXin key) =
                                [ "type"    .= ("pic_weixin" :: Text)
                                , "key"     .= key
                                ]
menuItemDataToJsonPairs (MenuItemDataLocationSelect key) =
                                [ "type"    .= ("location_select" :: Text)
                                , "key"     .= key
                                ]

menuItemDataFromJsonObj :: Object -> Parser MenuItemData
menuItemDataFromJsonObj obj = do
    typ <- obj .: "type"
    case typ of
        "click"             -> fmap MenuItemDataClick $ obj .: "key"
        "view"              -> fmap MenuItemDataView $ UrlText <$> obj .: "url"
        "scancode_push"     -> fmap MenuItemDataScanCode $ obj .: "key"
        "scancode_waitmsg"  -> fmap MenuItemDataScanCodeWaitMsg $ obj .: "key"
        "pic_sysphoto"      -> fmap MenuItemDataPicSysPhoto $ obj .: "key"
        "pic_photo_or_album"-> fmap MenuItemDataPicPhotoOrAlbum $ obj .: "key"
        "pic_weixin"        -> fmap MenuItemDataPicWeiXin $ obj .: "key"
        "location_select"   -> fmap MenuItemDataLocationSelect $ obj .: "key"
        _                   -> fail $ "unknown/unsupported menu type: " <> typ


-- | 菜单项，及其子菜单
data MenuItem = MenuItem {
                    menuItemName             :: Text
                    , menuItemDataOrSubs    :: Either MenuItemData [MenuItem]
                }
                deriving (Show, Eq)

instance ToJSON MenuItem where
    toJSON mi = object $
                    [ "name" .= menuItemName mi ]
                    ++
                        either
                            menuItemDataToJsonPairs
                            (\items -> [("sub_button" .= map toJSON items)])
                            (menuItemDataOrSubs mi)


instance FromJSON MenuItem where
    parseJSON = withObject "MenuItem" $ \obj -> do
                    name <- obj .: "name"
                    m_subs <- obj .:? "sub_button"
                    dat_or_subs <- case m_subs of
                        Just (subs@(_:_))   -> return $ Right subs
                        _                   -> fmap Left $ menuItemDataFromJsonObj obj
                    return $ MenuItem name dat_or_subs


data SimpleLocaleName = SimpleLocaleName { unSimpleLocaleName :: Text }
                    deriving (Show, Eq, Ord)

type NickName = Text
type CityName = Text
type ProvinceName = Text
type ContryName = Text

-- | 用户基础信息查询接口的返回
data EndUserQueryResult = EndUserQueryResultNotSubscribed WxppOpenID
                        | EndUserQueryResult
                            WxppOpenID
                            NickName    -- ^ nickname
                            (Maybe Gender)
                            SimpleLocaleName
                            CityName
                            ProvinceName
                            ContryName
                            UrlText     -- ^ head image url
                            UTCTime
                            (Maybe WxppUnionID)
                        deriving (Show, Eq, Ord)

instance FromJSON EndUserQueryResult where
    parseJSON = withObject "EndUserQueryResult" $ \obj -> do
                open_id <- WxppOpenID <$> obj .: "openid"
                if_sub <- (\x -> x > (0 :: Int)) <$> obj .: "subscribe"
                if not if_sub
                    then return $ EndUserQueryResultNotSubscribed open_id
                    else do
                        nickname <- obj .: "nickname"
                        m_gender <- obj .: "sex" >>= parseSexJson
                        city <- obj .: "city"
                        lang <- SimpleLocaleName <$> obj .: "language"
                        province <- obj .: "province"
                        contry <- obj .: "contry"
                        headimgurl <- UrlText <$> obj .: "headimgurl"
                        subs_time <- epochIntToUtcTime <$> obj .: "subscribe_time"
                        m_union_id <- obj .:? "unionid"
                        return $ EndUserQueryResult
                                    open_id
                                    nickname
                                    m_gender
                                    lang
                                    city
                                    province
                                    contry
                                    headimgurl
                                    subs_time
                                    m_union_id

-- | sex 字段出现在文档两处，有时候是个整数，有时候是个字串
-- 这个函数处理两种情况
parseSexJson :: Value -> Parser (Maybe Gender)
parseSexJson = go
    where
        go (A.String t) = p t $ fmap fst $ listToMaybe $ reads $ T.unpack t
        go (A.Number n) = p n $ toBoundedInteger n
        go v            = typeMismatch "Number or String" v

        p :: Show a => a -> Maybe Int -> Parser (Maybe Gender)
        p x mi = case mi of
                Just i  -> parseSexInt i
                Nothing -> fail $ "unknown sex: " <> show x


parseSexInt :: Monad m => Int -> m (Maybe Gender)
parseSexInt 0 = return Nothing
parseSexInt 1 = return $ Just Male
parseSexInt 2 = return $ Just Female
parseSexInt x = fail $ "unknown sex: " <> show x


newtype MD5Hash = MD5Hash { unMD5Hash :: ByteString }
                deriving (Show, Eq, Ord)

instance SafeCopy MD5Hash where
    getCopy             = contain $ safeGet
    putCopy (MD5Hash x) = contain $ safePut x

-- | 上传媒体文件的结果
data UploadResult = UploadResult {
                        urMediaType     :: WxppMediaType
                        , urMediaId     :: WxppMediaID
                        , urCreateTime  :: UTCTime
                        }
                        deriving (Show, Typeable)

deriveSafeCopy 0 'base ''UploadResult

instance FromJSON UploadResult where
    parseJSON = withObject "UploadResult" $ \obj -> do
        type_s <- obj .: "type"
        typ <- case type_s of
                "image" -> return WxppMediaTypeImage
                "voice" -> return WxppMediaTypeVoice
                "video" -> return WxppMediaTypeVideo
                "thumb" -> return WxppMediaTypeThumb
                _       -> fail $ "unknown type: " <> type_s
        media_id <- WxppMediaID <$> obj .: "media_id"
        t <- epochIntToUtcTime <$> obj .: "created_at"
        return $ UploadResult typ media_id t


--------------------------------------------------------------------------------

wxppLogSource :: IsString a => a
wxppLogSource = "WXPP"

md5HashFile :: FilePath -> IO MD5Hash
md5HashFile = fmap (MD5Hash . MD5.hashlazy) . LB.readFile . encodeString

-- | 上传得到的 media id 只能用一段时间
usableUploadResult :: UTCTime -> NominalDiffTime -> UploadResult -> Bool
usableUploadResult now dt ur = addUTCTime dt (urCreateTime ur) < now
