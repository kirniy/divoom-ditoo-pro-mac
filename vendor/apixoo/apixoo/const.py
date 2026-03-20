from enum import Enum


class GalleryCategory(int, Enum):
    NEW = 0
    DEFAULT = 1
    # LED_TEXT = 2
    CHARACTER = 3
    EMOJI = 4
    DAILY = 5
    NATURE = 6
    SYMBOL = 7
    PATTERN = 8
    CREATIVE = 9
    PHOTO = 12
    TOP = 14
    GADGET = 15
    BUSINESS = 16
    FESTIVAL = 17
    RECOMMEND = 18
    # PLANET = 19
    FOLLOW = 20
    # REVIEW_PHOTOS = 21
    # REVIEW_STOLEN_PHOTOS = 22
    # FILL_GAME = 29
    PIXEL_MATCH = 30  # Current event
    PLANT = 31
    ANIMAL = 32
    PERSON = 33
    EMOJI_2 = 34
    FOOD = 35
    # OTHERS = 36
    # REPORT_PHOTO = 254
    # CREATION_ALBUM = 255


class GalleryType(int, Enum):
    PICTURE = 0
    ANIMATION = 1
    MULTI_PICTURE = 2
    MULTI_ANIMATION = 3
    LED = 4
    ALL = 5
    SAND = 6
    DESIGN_HEAD_DEVICE = 101
    DESIGN_IMPORT = 103
    DESIGN_CHANNEL_DEVICE = 104


class GallerySorting(int, Enum):
    NEW_UPLOAD = 0
    MOST_LIKED = 1


class GalleryDimension(int, Enum):
    W16H16 = 1
    W32H32 = 2
    W64H64 = 4
    ALL = 15


class Server(str, Enum):
    API = 'app.divoom-gz.com'
    FILE = 'f.divoom-gz.com'


class ApiEndpoint(str, Enum):
    GET_ALBUM_LIST = '/Discover/GetAlbumList'
    GET_ALBUM_LIST_V3 = '/Discover/GetAlbumListV3'
    GET_ALBUM_FILES = '/Discover/GetAlbumImageList'
    GET_ALBUM_FILES_V3 = '/Discover/GetAlbumImageListV3'
    GET_CATEGORY_FILES = '/GetCategoryFileListV2'
    GET_GALLERY_INFO = '/Cloud/GalleryInfo'
    GET_CUSTOM_GALLERY_TIME = '/Channel/GetCustomGalleryTime'
    GET_SUBSCRIBE_TIME = '/Channel/GetSubscribeTime'
    GET_SUBSCRIBE_GALLERY_TIME = '/Channel/GetSubscribeTime'
    GET_ALBUM_TIME = '/Channel/GetAlbumTime'
    SET_CUSTOM_GALLERY_TIME = '/Channel/SetCustomGalleryTime'
    SET_SUBSCRIBE_TIME = '/Channel/SetSubscribeTime'
    SET_ALBUM_TIME = '/Channel/SetAlbumTime'
    GET_MY_LIST = '/Playlist/GetMyList'
    GET_SOMEONE_LIST = '/Playlist/GetSomeOneList'
    PLAYLIST_NEW_LIST = '/Playlist/NewList'
    PLAYLIST_HIDE = '/Playlist/Hide'
    PLAYLIST_RENAME = '/Playlist/Rename'
    PLAYLIST_SET_DESCRIBE = '/Playlist/SetDescribe'
    PLAYLIST_SET_COVER = '/Playlist/SetCover'
    PLAYLIST_DELETE_LIST = '/Playlist/DeleteList'
    PLAYLIST_ADD_IMAGE = '/Playlist/AddImageToList'
    PLAYLIST_REMOVE_IMAGE = '/Playlist/RemoveImage'
    PLAYLIST_SEND_DEVICE = '/Playlist/SendDevice'
    GALLERY_LIKE = '/GalleryLikeV2'
    ITEM_SEARCH = '/Channel/ItemSearch'
    STORE_CLOCK_GET_CLASSIFY = '/Channel/StoreClockGetClassify'
    STORE_CLOCK_GET_LIST = '/Channel/StoreClockGetList'
    STORE_TOP20 = '/Channel/StoreTop20'
    STORE_NEW20 = '/Channel/StoreNew20'
    LIKE_CLOCK = '/Channel/LikeClock'
    GET_RGB_INFO = '/Channel/GetRGBInfo'
    SET_RGB_INFO = '/Channel/SetRGBInfo'
    GET_AMBIENT_LIGHT = '/Channel/GetAmbientLight'
    SET_AMBIENT_LIGHT = '/Channel/SetAmbientLight'
    SET_BRIGHTNESS = '/Channel/SetBrightness'
    GET_ON_OFF_SCREEN = '/Channel/GetOnOffScreen'
    ON_OFF_SCREEN = '/Channel/OnOffScreen'
    GET_ON_OFF = '/Channel/GetOnOff'
    SET_ON_OFF = '/Channel/SetOnOff'
    USER_LOGIN = '/UserLogin'


class BaseDictInfo(dict):
    _KEYS_MAP = {}

    def __init__(self, info: dict):
        # Rename keys
        for key in self._KEYS_MAP:
            self.__dict__[self._KEYS_MAP[key]] = info.get(key)

        # Make this object JSON serializable
        dict.__init__(self, **self.__dict__)

    def __setattr__(self, name, value):
        raise Exception('%s object is read only!' % (type(self).__name__))


class AlbumInfo(BaseDictInfo):
    _KEYS_MAP = {
        'AlbumId': 'album_id',
        'AlbumName': 'album_name',
        'AlbumImageId': 'album_image_id',
        'AlbumBigImageId': 'album_big_image_id',
        'AlbumDescribe': 'album_describe',
    }


class UserInfo(BaseDictInfo):
    _KEYS_MAP = {
        'UserId': 'user_id',
        'UserName': 'user_name',
    }


class GalleryInfo(BaseDictInfo):
    _KEYS_MAP = {
        'AddFlag': 'add_flag',
        'ClockId': 'clock_id',
        'ClockName': 'clock_name',
        'ClockType': 'clock_type',
        'Classify': 'category',
        'ClassifyId': 'classify_id',
        'CommentCnt': 'total_comments',
        'Content': 'content',
        'CopyrightFlag': 'copyright_flag',
        'CountryISOCode': 'country_iso_code',
        'Date': 'date',
        'FileId': 'file_id',
        'FileName': 'file_name',
        'FileTagArray': 'file_tags',
        'FileType': 'file_type',
        'FileURL': 'file_url',
        'Flag': 'flag',
        'GalleryId': 'gallery_id',
        'ImagePixelId': 'image_pixel_id',
        'IsLike': 'is_like',
        'IsMyLike': 'is_my_like',
        'ItemId': 'item_id',
        'LikeCnt': 'total_likes',
        'ShareCnt': 'total_shares',
        'WatchCnt': 'total_views',
        # 'AtList': [],
        # 'CheckConfirm': 2,
        # 'CommentUTC': 0,
        # 'FillGameIsFinish': 0,
        # 'FillGameScore': 0,
        # 'HideFlag': 0,
        # 'IsAddNew': 1,
        # 'IsAddRecommend': 0,
        # 'IsDel': 0,
        # 'IsFollow': 0,
        # 'IsLike': 0,
        # 'LayerFileId': '',
        # 'Level': 7,
        # 'LikeUTC': 1682836986,
        # 'MusicFileId': '',
        # 'OriginalGalleryId': 0,
        # 'PixelAmbId': '',
        # 'PixelAmbName': '',
        # 'PrivateFlag': 0,
        # 'RegionId': '55',
        # 'UserHeaderId': 'group1/M00/1B/BF/...',
    }

    def __init__(self, info: dict):
        super().__init__(info)

        # Parse user info
        self.__dict__['user'] = None
        if 'UserId' in info:
            self.__dict__['user'] = UserInfo(info)

        # Update dict
        dict.__init__(self, **self.__dict__)


class CloudClassifyInfo(BaseDictInfo):
    _KEYS_MAP = {
        'ClassifyId': 'classify_id',
        'ClassifyName': 'classify_name',
        'ImageId': 'image_id',
        'Name': 'name',
        'Sort': 'sort_order',
        'Title': 'title',
    }


class PlaylistInfo(BaseDictInfo):
    _KEYS_MAP = {
        'AddFlag': 'add_flag',
        'Count': 'file_count',
        'CoverFileId': 'cover_file_id',
        'Describe': 'describe',
        'FileCnt': 'file_count',
        'GalleryId': 'gallery_id',
        'HideFlag': 'hide_flag',
        'ImageFileId': 'image_file_id',
        'LikeCnt': 'total_likes',
        'Name': 'name',
        'PlayId': 'play_id',
        'PlayName': 'play_name',
        'WatchCnt': 'total_views',
    }


class ChannelTimingInfo(BaseDictInfo):
    _KEYS_MAP = {
        'AlbumId': 'album_id',
        'AlbumName': 'album_name',
        'AuthorType': 'author_type',
        'ClockId': 'clock_id',
        'CustomId': 'custom_id',
        'GalleryShowTimeFlag': 'gallery_show_time_flag',
        'LcdIndex': 'lcd_index',
        'LcdIndependence': 'lcd_independence',
        'LcdIndependenceList': 'lcd_independence_list',
        'ParentClockId': 'parent_clock_id',
        'ParentItemId': 'parent_item_id',
        'PlayId': 'play_id',
        'PlayName': 'play_name',
        'SingleGalleyTime': 'single_gallery_time',
        'SoundOnOff': 'sound_on_off',
        'StartUpClockId': 'startup_clock_id',
        'SubscribeType': 'subscribe_type',
        'UserList': 'user_list',
    }


class AmbientLightColorInfo(BaseDictInfo):
    _KEYS_MAP = {
        'SelectEffect': 'select_effect',
    }


class FiveLCDRGBColorInfo(AmbientLightColorInfo):
    pass


class AmbientLightInfo(BaseDictInfo):
    _KEYS_MAP = {
        'Brightness': 'brightness',
        'Color': 'color',
        'ColorCycle': 'color_cycle',
        'KeyOnOff': 'key_on_off',
        'LightList': 'light_list',
        'OnOff': 'on_off',
        'SelectLightIndex': 'select_light_index',
    }

    def __init__(self, info: dict):
        super().__init__(info)
        self.__dict__['light_list'] = [
            AmbientLightColorInfo(item) if isinstance(item, dict) else item
            for item in (info.get('LightList') or [])
        ]
        dict.__init__(self, **self.__dict__)


class FiveLCDRGBInfo(AmbientLightInfo):
    def __init__(self, info: dict):
        super().__init__(info)
        self.__dict__['light_list'] = [
            FiveLCDRGBColorInfo(item) if isinstance(item, dict) else item
            for item in (info.get('LightList') or [])
        ]
        dict.__init__(self, **self.__dict__)
