{-# LANGUAGE ScopedTypeVariables #-}
module WeiXin.PublicPlatform.Types
    ( module WeiXin.PublicPlatform.Types
    , Gender(..)
    , UrlText(..)
    ) where

import ClassyPrelude
import Data.SafeCopy
import Data.Aeson
import Data.Aeson.Types                     (Parser, Pair)
import qualified Data.ByteString.Base64     as B64
import qualified Data.ByteString.Char8      as C8
import Data.Byteable                        (toBytes)
import Crypto.Cipher                        (makeKey, Key)
import Crypto.Cipher.AES                    (AES)
import Data.Time.Clock.POSIX                ( posixSecondsToUTCTime
                                            , utcTimeToPOSIXSeconds)
import Data.Time                            (NominalDiffTime)

import Yesod.Helpers.Aeson                  (parseBase64ByteString)
import Yesod.Helpers.Types                  (Gender(..), UrlText(..), unUrlText)


newtype WxppMediaID = WxppMediaID { unWxppMediaID :: Text }
                        deriving (Show, Eq, Ord)

newtype WxppOpenID = WxppOpenID { unWxppOpenID :: Text}
                    deriving (Show, Eq, Ord)

newtype WxppInMsgID = WxppInMsgID { unWxppInMsgID :: Word64 }
                    deriving (Show, Eq, Ord)

newtype WxppSceneID = WxppSceneID { unWxppSceneID :: Word32 }
                    deriving (Show, Eq, Ord)

newtype QRTicket = QRTicket { unQRTicket :: Text }
                    deriving (Show, Eq, Ord)

newtype Token = Token { unToken :: Text }
                    deriving (Show, Eq, Ord)

newtype AesKey = AesKey { unAesKey :: Key AES }
                    deriving (Eq)
instance Show AesKey where
    show (AesKey k) = "AesKey:" <> (C8.unpack $ B64.encode $ toBytes k)

instance FromJSON AesKey where
    parseJSON = fmap AesKey .
                    (withText "AesKey" $ \t -> do
                        bs <- parseBase64ByteString "AesKey" t
                        either (fail . show) return $ makeKey bs
                    )

newtype TimeStampS = TimeStampS { unTimeStampS :: Text }
                    deriving (Show, Eq)

newtype Nonce = Nonce { unNounce :: Text }
                    deriving (Show, Eq)

newtype AccessToken = AccessToken { unAccessToken :: Text }
                    deriving (Show, Eq, Typeable)
$(deriveSafeCopy 0 'base ''AccessToken)


newtype WxppAppID = WxppAppID { unWxppAppID :: Text }
                    deriving (Show, Eq)

newtype WxppAppSecret = WxppAppSecret { unWxppAppSecret :: Text }
                    deriving (Show, Eq)

data WxppAppConfig = WxppAppConfig {
                    wxppConfigAppID         :: WxppAppID
                    , wxppConfigAppSecret   :: WxppAppSecret
                    , wxppConfigAppToken    :: Token
                    , wxppConfigAppAesKey   :: AesKey
                    , wxppConfigAppBackupAesKeys  :: [AesKey]
                        -- ^ 多个 aes key 是为了过渡时使用
                        -- 加密时仅使用第一个
                        -- 解密时则则所有都试一次
                    }
                    deriving (Show, Eq)

instance FromJSON WxppAppConfig where
    parseJSON = withObject "WxppAppConfig" $ \obj -> do
                    app_id <- fmap WxppAppID $ obj .: "app-id"
                    secret <- fmap WxppAppSecret $ obj .: "secret"
                    token <- fmap Token $ obj .: "token"
                    aes_key_lst <- obj .: "aes-key"
                    case aes_key_lst of
                        []      -> fail $ "At least one AesKey is required"
                        (x:xs)  ->
                            return $ WxppAppConfig app_id secret token
                                        x
                                        xs


data WxppEvent = WxppEvtSubscribe
                | WxppEvtUnsubscribe
                | WxppEvtSubscribeAtScene WxppSceneID QRTicket
                | WxppEvtScan WxppSceneID QRTicket
                | WxppEvtReportLocation (Double, Double) Double
                    -- ^ (纬度，经度） 精度
                | WxppEvtClickItem Text
                | WxppEvtFollowUrl Text
                deriving (Show, Eq)

data WxppInMsg =  WxppInMsgText Text
                | WxppInMsgImage WxppMediaID Text
                | WxppInMsgVoice WxppMediaID Text (Maybe Text)
                | WxppInMsgVideo WxppMediaID WxppMediaID
                | WxppInMsgLocation (Double, Double) Double Text
                    -- ^ (latitude, longitude) scale label
                | WxppInMsgLink Text Text Text
                    -- ^ url title description
                | WxppInMsgEvent WxppEvent
                deriving (Show, Eq)


data WxppInMsgEntity = WxppInMsgEntity
                        {
                            wxppInToUserName        :: Text
                            , wxppInFromUserName    :: WxppOpenID
                            , wxppInCreatedTime     :: UTCTime
                            , wxppInMessageID       :: WxppInMsgID
                            , wxppInMessage         :: WxppInMsg
                        }
                        deriving (Show, Eq)

-- | 图文信息
data WxppArticle = WxppArticle {
                    wxppArticleTitle    :: Maybe Text    -- ^ title
                    , wxppArticleDesc   :: Maybe Text    -- ^ description
                    , wxppArticlePicUrl :: Maybe Text    -- ^ pic url
                    , wxppArticleUrl    :: Maybe Text    -- ^ url
                    }
                    deriving (Show, Eq)

data WxppOutMsg = WxppOutMsgText Text
                | WxppOutMsgImage WxppMediaID
                | WxppOutMsgVoice WxppMediaID
                | WxppOutMsgVideo WxppMediaID (Maybe Text) (Maybe Text)
                    -- ^ media_id title description
                | WxppOutMsgMusic WxppMediaID (Maybe Text) (Maybe Text) (Maybe Text) (Maybe Text)
                    -- ^ thumb_media_id, title, description, url, hq_url
                | WxppOutMsgArticle [WxppArticle]
                    -- ^ 根据文档，图文总数不可超过10
                        deriving (Show, Eq)

data WxppOutMsgEntity = WxppOutMsgEntity
                        {
                            wxppOutToUserName       :: WxppOpenID
                            , wxppOutFromUserName   :: Text
                            , wxppOutCreatedTime    :: UTCTime
                            , wxppOutMessage        :: WxppOutMsg
                        }
                        deriving (Show, Eq)


-- | 响应收到的服务器信息
-- Left 用于表达错误
-- Right Nothing 代表无需回复一个新信息
type WxppInMsgHandler m = WxppAppConfig
                            -> WxppInMsgEntity
                            -> m (Either String (Maybe WxppOutMsg))

class FromJsonHandler h where
    -- | 假定每个算法的配置段都有一个 name 的字段
    -- 根据这个方法选择出一个指定算法类型，
    -- 然后从 json 数据中反解出相应的值
    isNameOfInMsgHandler :: Monad n => n h -> Text -> Bool

    parseInMsgHandler :: Monad n => n h -> Object -> Parser h

-- | WxppInMsgHandler that can be parsed from JSON value
class FromJsonHandler h => JsonWxppInMsgHandler m h where
    handleInMsg :: h -> WxppInMsgHandler m


data SomeJsonWxppInMsgHandler m =
        forall h. JsonWxppInMsgHandler m h => SomeJsonWxppInMsgHandler h


-- | 可以点击的菜单所携带的数据及菜单的类型
-- 虽然看上去所有菜单都只有个文本作为数据，但概念上这些文本并不相同
-- 例如，有时候它明确地就是一个 URL
data MenuItemData = MenuItemDataClick Text
                        -- ^ key
                    | MenuItemDataView Text
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
menuItemDataToJsonPairs (MenuItemDataView url) =
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
        "view"              -> fmap MenuItemDataView $ obj .: "url"
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
                        Just subs   -> return $ Right subs
                        Nothing     -> fmap Left $ menuItemDataFromJsonObj obj
                    return $ MenuItem name dat_or_subs


newtype WxppUnionID = WxppUnionID { unWxppUnionID :: Text }
                    deriving (Show, Eq, Ord)

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
                        sex <- obj .: "sex"

                        m_gender <- case (sex :: Int) of
                            0   -> return Nothing
                            1   -> return $ Just Male
                            2   -> return $ Just Female
                            _   -> fail $ "unknown sex: " <> show sex

                        city <- obj .: "city"
                        lang <- SimpleLocaleName <$> obj .: "language"
                        province <- obj .: "province"
                        contry <- obj .: "contry"
                        headimgurl <- UrlText <$> obj .: "headimgurl"
                        subs_time <- epochIntToUtcTime <$> obj .: "subscribe_time"
                        m_union_id <- fmap WxppUnionID <$> obj .:? "unionid"
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


--------------------------------------------------------------------------------

utcTimeToEpochInt :: UTCTime -> Int64
utcTimeToEpochInt = round . utcTimeToPOSIXSeconds

epochIntToUtcTime :: Int64 -> UTCTime
epochIntToUtcTime = posixSecondsToUTCTime . (realToFrac :: Int64 -> NominalDiffTime)

wxppLogSource :: IsString a => a
wxppLogSource = "WXPP"
