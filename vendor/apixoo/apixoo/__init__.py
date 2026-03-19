import hashlib
from typing import Union

import requests

from .const import (
    AlbumInfo,
    ApiEndpoint,
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
            md5_password = hashlib.md5(password).hexdigest()

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

        start_num = ((page - 1) * per_page) + 1
        end_num = start_num + per_page - 1

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
        start_num = ((page - 1) * per_page) + 1
        end_num = start_num + per_page - 1

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

    def get_store_clock_classify(self) -> list:
        """Get channel/store classifications exposed by the iOS app"""
        if not self.is_logged_in():
            raise Exception('Not logged in!')

        try:
            resp_json = self._send_request(ApiEndpoint.STORE_CLOCK_GET_CLASSIFY)
            if resp_json['ReturnCode'] != 0:
                return None

            return [CloudClassifyInfo(item) for item in resp_json.get('ClassifyList', [])]
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
        if not self.is_logged_in():
            raise Exception('Not logged in!')

        start_num = ((page - 1) * per_page) + 1
        end_num = start_num + per_page - 1
        payload = {
            'CountryISOCode': country_iso_code,
            'Language': language,
            'Flag': type_flag,
            'StartNum': start_num,
            'EndNum': end_num,
        }
        if classify_id is not None:
            payload['ClassifyId'] = classify_id

        try:
            resp_json = self._send_request(endpoint, payload)
            if resp_json['ReturnCode'] != 0:
                return None

            return [GalleryInfo(item) for item in resp_json.get('ClockList', [])]
        except Exception:
            return None

    def search_items(
        self,
        key: str,
        item_flag: Union[int, str],
        item_id: int = None,
        clock_id: int = None,
        language: str = '',
        page: int = 1,
        per_page: int = 20,
    ) -> list:
        """Search Divoom cloud items using the iOS app ItemSearch endpoint"""
        if not self.is_logged_in():
            raise Exception('Not logged in!')

        start_num = ((page - 1) * per_page) + 1
        end_num = start_num + per_page - 1
        payload = {
            'Language': language,
            'ClockId': clock_id or 0,
            'ItemId': item_id or 0,
            'Key': key,
            'StartNum': start_num,
            'EndNum': end_num,
            'ItemFlag': item_flag,
        }

        try:
            resp_json = self._send_request(ApiEndpoint.ITEM_SEARCH, payload)
            if resp_json['ReturnCode'] != 0:
                return None

            return [GalleryInfo(item) for item in resp_json.get('SearchList', [])]
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

        start_num = ((page - 1) * per_page) + 1
        end_num = start_num + per_page - 1
        payload = {
            'StartNum': start_num,
            'EndNum': end_num,
        }
        if gallery_id is not None:
            payload['GalleryId'] = gallery_id

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

        start_num = ((page - 1) * per_page) + 1
        end_num = start_num + per_page - 1
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

    def download(self, gallery_info: GalleryInfo) -> PixelBean:
        """Download and decode animation"""
        url = self._full_url(gallery_info.file_id, server=Server.FILE)
        resp = requests.get(
            url, headers=self.HEADERS, stream=True, timeout=self._request_timeout
        )
        return PixelBeanDecoder.decode_stream(resp.raw)
