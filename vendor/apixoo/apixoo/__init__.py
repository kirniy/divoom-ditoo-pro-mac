import hashlib
from typing import Union

import requests

from .const import (
    AlbumInfo,
    AmbientLightInfo,
    ApiEndpoint,
    ChannelTimingInfo,
    CloudClassifyInfo,
    GalleryCategory,
    GalleryDimension,
    GalleryInfo,
    GallerySorting,
    GalleryType,
    PlaylistInfo,
    Server,
)
from .pixel_bean import PixelBean
from .pixel_bean_decoder import PixelBeanDecoder


class APIxoo(object):
    HEADERS = {
        'User-Agent': 'Aurabox/3.1.10 (iPad; iOS 14.8; Scale/2.00)',
    }

    def __init__(
        self, email: str, password: str = None, md5_password: str = None, is_secure=True
    ):
        # Make sure at least one password param is passed
        if not any([password, md5_password]):
            raise Exception('Empty password!')

        # Get MD5 hash of password
        if password:
            password_bytes = password.encode('utf-8') if isinstance(password, str) else password
            md5_password = hashlib.md5(password_bytes).hexdigest()

        self._email = email
        self._md5_password = md5_password
        self._user = None
        self._request_timeout = 10
        self._is_secure = is_secure

    def _full_url(self, path: str, server: Server = Server.API) -> str:
        """Generate full URL from path"""
        if not path.startswith('/'):
            path = '/' + path

        protocol = 'https://' if self._is_secure else 'http://'
        return '%s%s%s' % (protocol, server.value, path)

    def _send_request(self, endpoint: Union[ApiEndpoint, str], payload: dict | None = None):
        """Send request to API server"""
        payload = dict(payload or {})
        endpoint_path = endpoint.value if isinstance(endpoint, ApiEndpoint) else str(endpoint)

        if endpoint != ApiEndpoint.USER_LOGIN:
            payload.update(
                {
                    'Token': self._user['token'],
                    'UserId': self._user['user_id'],
                }
            )

        full_url = self._full_url(endpoint_path, Server.API)
        resp = requests.post(
            full_url,
            headers=self.HEADERS,
            json=payload,
            timeout=self._request_timeout,
        )
        return resp.json()

    def set_timeout(self, timeout: int):
        """Set request timeout"""
        self._request_timeout = timeout

    def is_logged_in(self) -> bool:
        """Check if logged in or not"""
        return self._user is not None

    @staticmethod
    def _page_bounds(page: int, per_page: int) -> tuple[int, int]:
        start_num = ((page - 1) * per_page) + 1
        end_num = start_num + per_page - 1
        return start_num, end_num

    @staticmethod
    def _clean_payload(payload: dict) -> dict:
        return {key: value for key, value in payload.items() if value is not None}

    def _build_store_clock_classify_payload(
        self,
        country_iso_code: str = '',
        language: str = '',
    ) -> dict:
        # Android posts the bare BaseLoadMoreRequest here: locale + country only.
        return {
            'CountryISOCode': country_iso_code,
            'Language': language,
        }

    def _build_store_clock_list_payload(
        self,
        type_flag: int,
        classify_id: int = None,
        page: int = 1,
        per_page: int = 20,
        country_iso_code: str = '',
        language: str = '',
    ) -> dict:
        start_num, end_num = self._page_bounds(page, per_page)
        return self._clean_payload({
            'CountryISOCode': country_iso_code,
            'Language': language,
            'Flag': type_flag,
            'StartNum': start_num,
            'EndNum': end_num,
            'ClassifyId': classify_id,
        })

    def _build_store_rank_payload(
        self,
        type_flag: int = None,
        page_index: int = 1,
        clock_id: int = 0,
        parent_clock_id: int = 0,
        parent_item_id: str = '',
        language: str = '',
        lcd_independence: int = 0,
        lcd_index: int = 0,
    ) -> dict:
        payload = {
            'PageIndex': page_index,
            'ClockId': clock_id,
            'ParentClockId': parent_clock_id,
            'ParentItemId': parent_item_id,
            'Language': language,
            'LcdIndependence': lcd_independence,
            'LcdIndex': lcd_index,
        }
        if type_flag is not None:
            payload['Flag'] = type_flag
        return payload

    def _build_item_search_payload(
        self,
        key: str,
        item_flag: Union[int, str, None] = '',
        item_id: Union[int, str, None] = '',
        clock_id: int = None,
        language: str = '',
        page: int = 1,
        per_page: int = 20,
    ) -> dict:
        start_num, end_num = self._page_bounds(page, per_page)
        return {
            'Language': language,
            'ClockId': clock_id or 0,
            'ItemId': '' if item_id is None else str(item_id),
            'Key': key,
            'StartNum': start_num,
            'EndNum': end_num,
            'ItemFlag': '' if item_flag is None else str(item_flag),
        }

    def _build_channel_timing_payload(
        self,
        clock_id: int = None,
        parent_clock_id: int = None,
        parent_item_id: Union[int, str] = None,
        lcd_index: int = None,
        lcd_independence: int = None,
        lcd_independence_list: list[int] = None,
        single_gallery_time: int = None,
        gallery_show_time_flag: int = None,
        sound_on_off: int = None,
        custom_id: int = None,
    ) -> dict:
        return self._clean_payload({
            'ClockId': clock_id,
            'ParentClockId': parent_clock_id,
            'ParentItemId': str(parent_item_id) if parent_item_id is not None else None,
            'LcdIndex': lcd_index,
            'LcdIndependence': lcd_independence,
            'LcdIndependenceList': lcd_independence_list,
            'SingleGalleyTime': single_gallery_time,
            'GalleryShowTimeFlag': gallery_show_time_flag,
            'SoundOnOff': sound_on_off,
            'CustomId': custom_id,
        })

    def _build_ambient_light_payload(
        self,
        on_off: int = None,
        brightness: int = None,
        select_light_index: int = None,
        color: str = None,
        color_cycle: int = None,
        key_on_off: int = None,
        light_list: list | None = None,
    ) -> dict:
        return self._clean_payload({
            'OnOff': on_off,
            'Brightness': brightness,
            'SelectLightIndex': select_light_index,
            'Color': color,
            'ColorCycle': color_cycle,
            'KeyOnOff': key_on_off,
            'LightList': light_list,
        })

    def log_in(self) -> bool:
        """Log in to API server"""
        if self.is_logged_in():
            return True

        payload = {
            'Email': self._email,
            'Password': self._md5_password,
        }

        try:
            resp_json = self._send_request(ApiEndpoint.USER_LOGIN, payload)
            self._user = {
                'user_id': resp_json['UserId'],
                'token': resp_json['Token'],
            }
            return True
        except Exception:
            pass

        return False

    def get_gallery_info(self, gallery_id: int) -> GalleryInfo:
        """Get gallery info by ID"""
        if not self.is_logged_in():
            raise Exception('Not logged in!')

        payload = {
            'GalleryId': gallery_id,
        }

        try:
            resp_json = self._send_request(ApiEndpoint.GET_GALLERY_INFO, payload)
            if resp_json['ReturnCode'] != 0:
                return None

            # Add gallery ID since it isn't included in the response
            resp_json['GalleryId'] = gallery_id
            return GalleryInfo(resp_json)
        except Exception:
            return None

    def get_category_files(
        self,
        category: Union[int, GalleryCategory],
        dimension: GalleryDimension = GalleryDimension.W32H32,
        sort: GallerySorting = GallerySorting.MOST_LIKED,
        file_type: GalleryType = GalleryType.ALL,
        page: int = 1,
        per_page: int = 20,
    ) -> list:
        """Get a list of galleries by Category"""
        if not self.is_logged_in():
            raise Exception('Not logged in!')

        start_num, end_num = self._page_bounds(page, per_page)

        payload = {
            'StartNum': start_num,
            'EndNum': end_num,
            'Classify': category,
            'FileSize': dimension,
            'FileType': file_type,
            'FileSort': sort,
            'Version': 12,
            'RefreshIndex': 0,
        }

        try:
            resp_json = self._send_request(ApiEndpoint.GET_CATEGORY_FILES, payload)

            lst = []
            for item in resp_json['FileList']:
                lst.append(GalleryInfo(item))

            return lst
        except Exception:
            return None

    def get_album_list(self, v3: bool = False) -> list:
        """Get Album list in Discover tab"""
        if not self.is_logged_in():
            raise Exception('Not logged in!')

        try:
            endpoint = ApiEndpoint.GET_ALBUM_LIST_V3 if v3 else ApiEndpoint.GET_ALBUM_LIST
            resp_json = self._send_request(endpoint)
            if resp_json['ReturnCode'] != 0:
                return None

            lst = []
            for item in resp_json['AlbumList']:
                lst.append(AlbumInfo(item))

            return lst
        except Exception:
            return None

    def get_album_files(
        self, album_id: int, page: int = 1, per_page: int = 20, v3: bool = False
    ):
        """Get a list of galleries by Album"""
        start_num, end_num = self._page_bounds(page, per_page)

        payload = {
            'AlbumId': album_id,
            'StartNum': start_num,
            'EndNum': end_num,
        }

        try:
            endpoint = ApiEndpoint.GET_ALBUM_FILES_V3 if v3 else ApiEndpoint.GET_ALBUM_FILES
            resp_json = self._send_request(endpoint, payload)

            lst = []
            for item in resp_json['FileList']:
                lst.append(GalleryInfo(item))

            return lst
        except Exception:
            return None

    def get_store_clock_classify_response(
        self,
        country_iso_code: str = '',
        language: str = '',
    ) -> dict:
        """Get the raw store classify response."""
        if not self.is_logged_in():
            raise Exception('Not logged in!')

        try:
            payload = self._build_store_clock_classify_payload(
                country_iso_code=country_iso_code,
                language=language,
            )
            return self._send_request(ApiEndpoint.STORE_CLOCK_GET_CLASSIFY, payload)
        except Exception:
            return None

    def get_store_clock_classify(
        self,
        country_iso_code: str = '',
        language: str = '',
    ) -> list:
        """Get channel/store classifications exposed by the iOS app."""
        try:
            resp_json = self.get_store_clock_classify_response(
                country_iso_code=country_iso_code,
                language=language,
            )
            if not resp_json or resp_json['ReturnCode'] != 0:
                return None

            return [CloudClassifyInfo(item) for item in resp_json.get('ClassifyList', [])]
        except Exception:
            return None

    def get_store_clock_list_response(
        self,
        type_flag: int,
        classify_id: int = None,
        page: int = 1,
        per_page: int = 20,
        country_iso_code: str = '',
        language: str = '',
        endpoint: Union[ApiEndpoint, str] = ApiEndpoint.STORE_CLOCK_GET_LIST,
    ) -> dict:
        """Get the raw store clock list response."""
        if not self.is_logged_in():
            raise Exception('Not logged in!')

        payload = self._build_store_clock_list_payload(
            type_flag=type_flag,
            classify_id=classify_id,
            page=page,
            per_page=per_page,
            country_iso_code=country_iso_code,
            language=language,
        )

        try:
            return self._send_request(endpoint, payload)
        except Exception:
            return None

    def get_store_clock_list(
        self,
        type_flag: int,
        classify_id: int = None,
        page: int = 1,
        per_page: int = 20,
        country_iso_code: str = '',
        language: str = '',
        endpoint: Union[ApiEndpoint, str] = ApiEndpoint.STORE_CLOCK_GET_LIST,
    ) -> list:
        """Get channel/store gallery items using iOS app request shape"""
        try:
            resp_json = self.get_store_clock_list_response(
                type_flag=type_flag,
                classify_id=classify_id,
                page=page,
                per_page=per_page,
                country_iso_code=country_iso_code,
                language=language,
                endpoint=endpoint,
            )
            if not resp_json or resp_json['ReturnCode'] != 0:
                return None

            return [GalleryInfo(item) for item in resp_json.get('ClockList', [])]
        except Exception:
            return None

    def get_store_top20(
        self,
        type_flag: int = None,
        page_index: int = 1,
        clock_id: int = 0,
        parent_clock_id: int = 0,
        parent_item_id: str = '',
        language: str = '',
        lcd_independence: int = 0,
        lcd_index: int = 0,
    ) -> list:
        """Get store Top20 items using the dedicated channel endpoint."""
        try:
            resp_json = self.get_store_top20_response(
                type_flag=type_flag,
                page_index=page_index,
                clock_id=clock_id,
                parent_clock_id=parent_clock_id,
                parent_item_id=parent_item_id,
                language=language,
                lcd_independence=lcd_independence,
                lcd_index=lcd_index,
            )
            if not resp_json or resp_json['ReturnCode'] != 0:
                return None

            return [GalleryInfo(item) for item in resp_json.get('ClockList', [])]
        except Exception:
            return None

    def get_store_top20_response(
        self,
        type_flag: int = None,
        page_index: int = 1,
        clock_id: int = 0,
        parent_clock_id: int = 0,
        parent_item_id: str = '',
        language: str = '',
        lcd_independence: int = 0,
        lcd_index: int = 0,
    ) -> dict:
        """Get the raw Top20 store response using the channel request family."""
        if not self.is_logged_in():
            raise Exception('Not logged in!')

        payload = self._build_store_rank_payload(
            type_flag=type_flag,
            page_index=page_index,
            clock_id=clock_id,
            parent_clock_id=parent_clock_id,
            parent_item_id=parent_item_id,
            language=language,
            lcd_independence=lcd_independence,
            lcd_index=lcd_index,
        )

        try:
            return self._send_request(ApiEndpoint.STORE_TOP20, payload)
        except Exception:
            return None

    def get_store_new20(
        self,
        type_flag: int = None,
        page_index: int = 1,
        clock_id: int = 0,
        parent_clock_id: int = 0,
        parent_item_id: str = '',
        language: str = '',
        lcd_independence: int = 0,
        lcd_index: int = 0,
    ) -> list:
        """Get store New20 items using the dedicated channel endpoint."""
        try:
            resp_json = self.get_store_new20_response(
                type_flag=type_flag,
                page_index=page_index,
                clock_id=clock_id,
                parent_clock_id=parent_clock_id,
                parent_item_id=parent_item_id,
                language=language,
                lcd_independence=lcd_independence,
                lcd_index=lcd_index,
            )
            if not resp_json or resp_json['ReturnCode'] != 0:
                return None

            return [GalleryInfo(item) for item in resp_json.get('ClockList', [])]
        except Exception:
            return None

    def get_store_new20_response(
        self,
        type_flag: int = None,
        page_index: int = 1,
        clock_id: int = 0,
        parent_clock_id: int = 0,
        parent_item_id: str = '',
        language: str = '',
        lcd_independence: int = 0,
        lcd_index: int = 0,
    ) -> dict:
        """Get the raw New20 store response using the channel request family."""
        if not self.is_logged_in():
            raise Exception('Not logged in!')

        payload = self._build_store_rank_payload(
            type_flag=type_flag,
            page_index=page_index,
            clock_id=clock_id,
            parent_clock_id=parent_clock_id,
            parent_item_id=parent_item_id,
            language=language,
            lcd_independence=lcd_independence,
            lcd_index=lcd_index,
        )

        try:
            return self._send_request(ApiEndpoint.STORE_NEW20, payload)
        except Exception:
            return None

    def search_items(
        self,
        key: str,
        item_flag: Union[int, str, None] = '',
        item_id: Union[int, str, None] = '',
        clock_id: int = None,
        language: str = '',
        page: int = 1,
        per_page: int = 20,
    ) -> list:
        """Search Divoom cloud items using the channel ItemSearch endpoint."""
        try:
            resp_json = self.search_items_response(
                key=key,
                item_flag=item_flag,
                item_id=item_id,
                clock_id=clock_id,
                language=language,
                page=page,
                per_page=per_page,
            )
            if not resp_json or resp_json['ReturnCode'] != 0:
                return None

            return [GalleryInfo(item) for item in resp_json.get('SearchList', [])]
        except Exception:
            return None

    def search_items_response(
        self,
        key: str,
        item_flag: Union[int, str, None] = '',
        item_id: Union[int, str, None] = '',
        clock_id: int = None,
        language: str = '',
        page: int = 1,
        per_page: int = 20,
    ) -> dict:
        """Get the raw ItemSearch response."""
        if not self.is_logged_in():
            raise Exception('Not logged in!')

        payload = self._build_item_search_payload(
            key=key,
            item_flag=item_flag,
            item_id=item_id,
            clock_id=clock_id,
            language=language,
            page=page,
            per_page=per_page,
        )

        try:
            return self._send_request(ApiEndpoint.ITEM_SEARCH, payload)
        except Exception:
            return None

    def like_clock(self, clock_id: int, is_like: bool) -> dict:
        """Like or unlike a store/channel clock using Channel/LikeClock."""
        if not self.is_logged_in():
            raise Exception('Not logged in!')

        payload = {
            'ClockId': clock_id,
            'LikeFlag': 1 if is_like else 0,
        }

        try:
            return self._send_request(ApiEndpoint.LIKE_CLOCK, payload)
        except Exception:
            return None

    def gallery_like(
        self,
        gallery_id: int,
        is_like: bool,
        classify: int,
        type_: int,
    ) -> dict:
        """Like or unlike a gallery using GalleryLikeV2"""
        if not self.is_logged_in():
            raise Exception('Not logged in!')

        payload = {
            'GalleryId': gallery_id,
            'IsLike': 1 if is_like else 0,
            'Classify': classify,
            'Type': type_,
        }

        try:
            return self._send_request(ApiEndpoint.GALLERY_LIKE, payload)
        except Exception:
            return None

    def get_my_list(self, page: int = 1, per_page: int = 20, gallery_id: int = None):
        """Get playlist/channel list owned by the current user"""
        if not self.is_logged_in():
            raise Exception('Not logged in!')

        start_num, end_num = self._page_bounds(page, per_page)
        payload = self._clean_payload({
            'StartNum': start_num,
            'EndNum': end_num,
            'GalleryId': gallery_id,
        })

        try:
            resp_json = self._send_request(ApiEndpoint.GET_MY_LIST, payload)
            if resp_json['ReturnCode'] != 0:
                return None

            return [PlaylistInfo(item) for item in resp_json.get('PlayList', [])]
        except Exception:
            return None

    def get_someone_list(self, target_user_id: int, page: int = 1, per_page: int = 20):
        """Get playlist/channel list owned by another user"""
        if not self.is_logged_in():
            raise Exception('Not logged in!')

        start_num, end_num = self._page_bounds(page, per_page)
        payload = {
            'StartNum': start_num,
            'EndNum': end_num,
            'TargetUserId': target_user_id,
        }

        try:
            resp_json = self._send_request(ApiEndpoint.GET_SOMEONE_LIST, payload)
            if resp_json['ReturnCode'] != 0:
                return None

            return [PlaylistInfo(item) for item in resp_json.get('PlayList', [])]
        except Exception:
            return None

    def get_custom_gallery_time(
        self,
        clock_id: int,
        parent_clock_id: int = None,
        parent_item_id: Union[int, str] = None,
    ) -> dict:
        """Fetch custom-gallery timing/config state using Channel/GetCustomGalleryTime."""
        if not self.is_logged_in():
            raise Exception('Not logged in!')

        payload = self._clean_payload({
            'ClockId': clock_id,
            'ParentClockId': parent_clock_id,
            'ParentItemId': parent_item_id,
        })

        try:
            return self._send_request(ApiEndpoint.GET_CUSTOM_GALLERY_TIME, payload)
        except Exception:
            return None

    def get_subscribe_time_response(
        self,
        clock_id: int,
        parent_clock_id: int = None,
        parent_item_id: Union[int, str] = None,
    ) -> dict:
        """Fetch subscribe timing using Channel/GetSubscribeTime."""
        if not self.is_logged_in():
            raise Exception('Not logged in!')

        payload = self._build_channel_timing_payload(
            clock_id=clock_id,
            parent_clock_id=parent_clock_id,
            parent_item_id=parent_item_id,
        )

        try:
            return self._send_request(ApiEndpoint.GET_SUBSCRIBE_TIME, payload)
        except Exception:
            return None

    def get_subscribe_time(
        self,
        clock_id: int,
        parent_clock_id: int = None,
        parent_item_id: Union[int, str] = None,
    ) -> ChannelTimingInfo:
        """Fetch parsed subscribe timing using Channel/GetSubscribeTime."""
        try:
            resp_json = self.get_subscribe_time_response(
                clock_id=clock_id,
                parent_clock_id=parent_clock_id,
                parent_item_id=parent_item_id,
            )
            if not resp_json or resp_json['ReturnCode'] != 0:
                return None

            return ChannelTimingInfo(resp_json)
        except Exception:
            return None

    def get_subscribe_gallery_time(
        self,
        clock_id: int,
        parent_clock_id: int = None,
        parent_item_id: Union[int, str] = None,
    ) -> dict:
        """Backward-compatible alias for subscribe timing reads."""
        return self.get_subscribe_time_response(
            clock_id=clock_id,
            parent_clock_id=parent_clock_id,
            parent_item_id=parent_item_id,
        )

    def get_album_time_response(self, clock_id: int) -> dict:
        """Fetch album timing using Channel/GetAlbumTime."""
        if not self.is_logged_in():
            raise Exception('Not logged in!')

        payload = self._build_channel_timing_payload(clock_id=clock_id)

        try:
            return self._send_request(ApiEndpoint.GET_ALBUM_TIME, payload)
        except Exception:
            return None

    def get_album_time(self, clock_id: int) -> ChannelTimingInfo:
        """Fetch parsed album timing using Channel/GetAlbumTime."""
        try:
            resp_json = self.get_album_time_response(clock_id=clock_id)
            if not resp_json or resp_json['ReturnCode'] != 0:
                return None

            return ChannelTimingInfo(resp_json)
        except Exception:
            return None

    def set_custom_gallery_time(
        self,
        clock_id: int,
        single_gallery_time: int,
        gallery_show_time_flag: int,
        sound_on_off: int,
        custom_id: int,
        parent_clock_id: int = None,
        parent_item_id: Union[int, str] = None,
        lcd_index: int = None,
        lcd_independence: int = None,
        lcd_independence_list: list[int] = None,
    ) -> dict:
        """Write custom-gallery timing/config using Channel/SetCustomGalleryTime."""
        if not self.is_logged_in():
            raise Exception('Not logged in!')

        payload = self._build_channel_timing_payload(
            clock_id=clock_id,
            parent_clock_id=parent_clock_id,
            parent_item_id=parent_item_id,
            lcd_index=lcd_index,
            lcd_independence=lcd_independence,
            lcd_independence_list=lcd_independence_list,
            single_gallery_time=single_gallery_time,
            gallery_show_time_flag=gallery_show_time_flag,
            sound_on_off=sound_on_off,
            custom_id=custom_id,
        )

        try:
            return self._send_request(ApiEndpoint.SET_CUSTOM_GALLERY_TIME, payload)
        except Exception:
            return None

    def set_subscribe_time(
        self,
        clock_id: int = None,
        parent_clock_id: int = None,
        parent_item_id: Union[int, str] = None,
        lcd_index: int = None,
        lcd_independence: int = None,
        lcd_independence_list: list[int] = None,
    ) -> dict:
        """Write subscribe timing using the IPA-proven Channel/SetSubscribeTime fields."""
        if not self.is_logged_in():
            raise Exception('Not logged in!')

        payload = self._build_channel_timing_payload(
            clock_id=clock_id,
            parent_clock_id=parent_clock_id,
            parent_item_id=parent_item_id,
            lcd_index=lcd_index,
            lcd_independence=lcd_independence,
            lcd_independence_list=lcd_independence_list,
        )

        try:
            return self._send_request(ApiEndpoint.SET_SUBSCRIBE_TIME, payload)
        except Exception:
            return None

    def set_album_time(self, clock_id: int = None) -> dict:
        """Write album timing using the IPA-proven Channel/SetAlbumTime ClockId field."""
        if not self.is_logged_in():
            raise Exception('Not logged in!')

        payload = self._build_channel_timing_payload(clock_id=clock_id)

        try:
            return self._send_request(ApiEndpoint.SET_ALBUM_TIME, payload)
        except Exception:
            return None

    def create_playlist(self, name: str) -> dict:
        """Create a playlist using Playlist/NewList."""
        if not self.is_logged_in():
            raise Exception('Not logged in!')

        try:
            return self._send_request(ApiEndpoint.PLAYLIST_NEW_LIST, {'Name': name})
        except Exception:
            return None

    def set_playlist_hidden(self, play_id: int, hide: bool) -> dict:
        """Hide or unhide a playlist using Playlist/Hide."""
        if not self.is_logged_in():
            raise Exception('Not logged in!')

        payload = {
            'Hide': 1 if hide else 0,
            'PlayId': play_id,
        }

        try:
            return self._send_request(ApiEndpoint.PLAYLIST_HIDE, payload)
        except Exception:
            return None

    def rename_playlist(self, play_id: int, name: str) -> dict:
        """Rename a playlist using Playlist/Rename."""
        if not self.is_logged_in():
            raise Exception('Not logged in!')

        payload = {
            'Name': name,
            'PlayId': play_id,
        }

        try:
            return self._send_request(ApiEndpoint.PLAYLIST_RENAME, payload)
        except Exception:
            return None

    def set_playlist_description(self, play_id: int, describe: str) -> dict:
        """Set a playlist description using Playlist/SetDescribe."""
        if not self.is_logged_in():
            raise Exception('Not logged in!')

        payload = {
            'Describe': describe,
            'PlayId': play_id,
        }

        try:
            return self._send_request(ApiEndpoint.PLAYLIST_SET_DESCRIBE, payload)
        except Exception:
            return None

    def set_playlist_cover(self, play_id: int, cover_file_id: str) -> dict:
        """Set a playlist cover using Playlist/SetCover."""
        if not self.is_logged_in():
            raise Exception('Not logged in!')

        payload = {
            'CoverFileId': cover_file_id,
            'PlayId': play_id,
        }

        try:
            return self._send_request(ApiEndpoint.PLAYLIST_SET_COVER, payload)
        except Exception:
            return None

    def delete_playlist(self, play_id: int) -> dict:
        """Delete a playlist using Playlist/DeleteList."""
        if not self.is_logged_in():
            raise Exception('Not logged in!')

        try:
            return self._send_request(ApiEndpoint.PLAYLIST_DELETE_LIST, {'PlayId': play_id})
        except Exception:
            return None

    def add_gallery_to_playlist(self, gallery_id: int, play_id: int) -> dict:
        """Add a gallery to a playlist using Playlist/AddImageToList."""
        if not self.is_logged_in():
            raise Exception('Not logged in!')

        payload = {
            'GalleryId': gallery_id,
            'PlayId': play_id,
        }

        try:
            return self._send_request(ApiEndpoint.PLAYLIST_ADD_IMAGE, payload)
        except Exception:
            return None

    def remove_gallery_from_playlist(self, gallery_id: int, play_id: int) -> dict:
        """Remove a gallery from a playlist using Playlist/RemoveImage."""
        if not self.is_logged_in():
            raise Exception('Not logged in!')

        payload = {
            'GalleryId': gallery_id,
            'PlayId': play_id,
        }

        try:
            return self._send_request(ApiEndpoint.PLAYLIST_REMOVE_IMAGE, payload)
        except Exception:
            return None

    def send_playlist_to_device(self, play_id: int) -> dict:
        """Send a playlist to the device using Playlist/SendDevice."""
        if not self.is_logged_in():
            raise Exception('Not logged in!')

        try:
            return self._send_request(ApiEndpoint.PLAYLIST_SEND_DEVICE, {'PlayId': play_id})
        except Exception:
            return None

    def get_ambient_light_response(self) -> dict:
        """Fetch the persisted ambient-light model using Channel/GetAmbientLight."""
        if not self.is_logged_in():
            raise Exception('Not logged in!')

        try:
            return self._send_request(ApiEndpoint.GET_AMBIENT_LIGHT, {})
        except Exception:
            return None

    def get_ambient_light(self) -> AmbientLightInfo:
        """Fetch parsed ambient-light state using Channel/GetAmbientLight."""
        try:
            resp_json = self.get_ambient_light_response()
            if not resp_json or resp_json['ReturnCode'] != 0:
                return None

            return AmbientLightInfo(resp_json)
        except Exception:
            return None

    def set_ambient_light(
        self,
        on_off: int = None,
        brightness: int = None,
        select_light_index: int = None,
        color: str = None,
        color_cycle: int = None,
        key_on_off: int = None,
        light_list: list | None = None,
    ) -> dict:
        """Write persisted ambient-light state using Channel/SetAmbientLight."""
        if not self.is_logged_in():
            raise Exception('Not logged in!')

        payload = self._build_ambient_light_payload(
            on_off=on_off,
            brightness=brightness,
            select_light_index=select_light_index,
            color=color,
            color_cycle=color_cycle,
            key_on_off=key_on_off,
            light_list=light_list,
        )

        try:
            return self._send_request(ApiEndpoint.SET_AMBIENT_LIGHT, payload)
        except Exception:
            return None

    def set_brightness(self, brightness: int) -> dict:
        """Write brightness using Channel/SetBrightness."""
        if not self.is_logged_in():
            raise Exception('Not logged in!')

        try:
            return self._send_request(ApiEndpoint.SET_BRIGHTNESS, {'Brightness': brightness})
        except Exception:
            return None

    def get_on_off_screen(self) -> dict:
        """Fetch screen on/off state using Channel/GetOnOffScreen."""
        if not self.is_logged_in():
            raise Exception('Not logged in!')

        try:
            return self._send_request(ApiEndpoint.GET_ON_OFF_SCREEN, {})
        except Exception:
            return None

    def on_off_screen(self, on_off: int) -> dict:
        """Set screen on/off state using Channel/OnOffScreen."""
        if not self.is_logged_in():
            raise Exception('Not logged in!')

        try:
            return self._send_request(ApiEndpoint.ON_OFF_SCREEN, {'OnOff': on_off})
        except Exception:
            return None

    def get_on_off(self) -> dict:
        """Fetch ambient on/off state using Channel/GetOnOff."""
        if not self.is_logged_in():
            raise Exception('Not logged in!')

        try:
            return self._send_request(ApiEndpoint.GET_ON_OFF, {})
        except Exception:
            return None

    def set_on_off(self, on_off: int) -> dict:
        """Set ambient on/off state using Channel/SetOnOff."""
        if not self.is_logged_in():
            raise Exception('Not logged in!')

        try:
            return self._send_request(ApiEndpoint.SET_ON_OFF, {'OnOff': on_off})
        except Exception:
            return None

    def download(self, gallery_info: GalleryInfo) -> PixelBean:
        """Download and decode animation"""
        file_id = getattr(gallery_info, 'file_id', '') or getattr(gallery_info, 'image_pixel_id', '')
        if not file_id:
            return None

        url = self._full_url(file_id, server=Server.FILE)
        resp = requests.get(
            url, headers=self.HEADERS, stream=True, timeout=self._request_timeout
        )
        return PixelBeanDecoder.decode_stream(resp.raw)
