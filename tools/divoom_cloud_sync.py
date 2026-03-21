#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from io import BytesIO
from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
VENDOR_APIXOO_ROOT = ROOT / "vendor" / "apixoo"

if str(VENDOR_APIXOO_ROOT) not in sys.path:
    sys.path.insert(0, str(VENDOR_APIXOO_ROOT))

from apixoo import APIxoo, GalleryCategory, GalleryDimension, GallerySorting, GalleryType  # type: ignore  # noqa: E402


DEFAULT_OUTPUT_ROOT = ROOT / "assets" / "16x16" / "divoom-cloud"
DEFAULT_MANIFEST_PATH = ROOT / ".cache" / "divoom-cloud" / "manifest.json"
DEFAULT_STORE_FLAG = 0
DEFAULT_BLUE_DEVICE_TYPE = 26
DEFAULT_BLUE_DEVICE_SUBTYPE = 1
DEFAULT_CATEGORY_NAMES = [
    "recommend",
    "top",
    "character",
    "emoji",
    "daily",
    "nature",
    "symbol",
    "creative",
    "festival",
    "plant",
    "animal",
    "food",
]
STORE_ENDPOINTS = {
    "list": "Channel/StoreClockGetList",
    "top20": "Channel/StoreTop20",
    "new20": "Channel/StoreNew20",
}
PREVIEW_IMAGE_SUFFIXES = {".webp", ".png", ".jpg", ".jpeg", ".bmp", ".gif"}


@dataclass
class SyncedItem:
    source: str
    scope: str
    sort: str
    category: str
    cloud_classify: int
    collection: str
    gallery_id: int
    file_id: str
    file_name: str
    file_url: str
    content: str
    file_tags: list[str]
    likes: int
    views: int
    shares: int
    comments: int
    country: str
    user_name: str
    user_id: int | None
    album_id: int | None
    clock_id: int | None
    item_id: str | None
    date: str
    file_type: int
    is_liked: bool
    relative_path: str


@dataclass
class StoreClassifyItem:
    classify_id: int
    classify_name: str
    name: str
    title: str
    image_id: str
    sort_order: int


@dataclass
class StoreBannerClockItem:
    clock_id: int
    clock_name: str
    image_pixel_id: str
    clock_type: int
    add_flag: int


@dataclass
class StoreBannerItem:
    banner_name: str
    banner_image_id: str
    clock_list: list[StoreBannerClockItem]


@dataclass
class PlaylistManifestItem:
    owner: str
    target_user_id: int | None
    play_id: int
    play_name: str
    name: str
    gallery_id: int
    cover_file_id: str
    image_file_id: str
    likes: int
    views: int
    file_count: int


@dataclass
class TimingFields:
    clock_id: int | None = None
    parent_clock_id: int | None = None
    parent_item_id: str | None = None
    lcd_index: int | None = None
    lcd_independence: int | None = None
    lcd_independence_list: list[int] | None = None
    single_gallery_time: int | None = None
    gallery_show_time_flag: int | None = None
    sound_on_off: int | None = None


@dataclass
class AmbientFields:
    on_off: int | None = None
    brightness: int | None = None
    select_light_index: int | None = None
    color: str | None = None
    color_cycle: int | None = None
    key_on_off: int | None = None
    light_list: list | None = None


@dataclass
class RGBFields:
    on_off: int | None = None
    brightness: int | None = None
    select_light_index: int | None = None
    color: str | None = None
    color_cycle: int | None = None
    key_on_off: int | None = None
    light_list: list | None = None


def slugify(value: str, *, allow_unicode: bool = False) -> str:
    if not allow_unicode:
        value = value.encode("ascii", "ignore").decode("ascii")
    cleaned = re.sub(r"[^a-zA-Z0-9._-]+", "-", value.strip().lower())
    cleaned = re.sub(r"-{2,}", "-", cleaned).strip("-")
    return cleaned or "untitled"


def parse_category(name: str) -> GalleryCategory:
    normalized = name.strip().upper().replace("-", "_")
    return GalleryCategory[normalized]


def parse_sort(name: str) -> GallerySorting:
    normalized = name.strip().upper().replace("-", "_")
    return GallerySorting[normalized]


def sync_gallery(
    api: APIxoo,
    info,
    source_scope: str,
    sort_name: str,
    category_name: str,
    collection_name: str,
    output_root: Path,
    redownload: bool,
    album_id: int | None = None,
) -> SyncedItem | None:
    stable_id = int(getattr(info, "gallery_id", 0) or 0) or int(getattr(info, "clock_id", 0) or 0)
    file_name = (
        getattr(info, "file_name", "")
        or getattr(info, "clock_name", "")
        or str(stable_id or "unknown")
    )
    gallery_id = stable_id
    safe_base = slugify(file_name)
    output_dir = output_root / category_name / collection_name
    output_dir.mkdir(parents=True, exist_ok=True)
    output_path = output_dir / f"{safe_base}-{gallery_id}.gif"

    if redownload or not output_path.exists():
        file_token = str(getattr(info, "file_id", "") or getattr(info, "image_pixel_id", "") or "")
        if not materialize_gallery_asset(api, info, output_path, file_token=file_token):
            return None

    return SyncedItem(
        source="divoom-cloud",
        scope=source_scope,
        sort=sort_name,
        category=category_name,
        cloud_classify=int(getattr(info, "category", 0) or 0),
        collection=collection_name,
        gallery_id=gallery_id,
        file_id=str(getattr(info, "file_id", "") or getattr(info, "image_pixel_id", "") or ""),
        file_name=file_name,
        file_url=str(getattr(info, "file_url", "") or ""),
        content=str(getattr(info, "content", "") or ""),
        file_tags=[str(tag) for tag in (getattr(info, "file_tags", None) or []) if str(tag)],
        likes=int(getattr(info, "total_likes", 0) or 0),
        views=int(getattr(info, "total_views", 0) or 0),
        shares=int(getattr(info, "total_shares", 0) or 0),
        comments=int(getattr(info, "total_comments", 0) or 0),
        country=str(getattr(info, "country_iso_code", "") or ""),
        user_name=str(getattr(getattr(info, "user", None), "user_name", "") or ""),
        user_id=int(getattr(getattr(info, "user", None), "user_id", 0) or 0) or None,
        album_id=album_id,
        clock_id=int(getattr(info, "clock_id", 0) or 0) or None,
        item_id=str(getattr(info, "item_id", "") or "") or None,
        date=str(getattr(info, "date", "") or ""),
        file_type=int(getattr(info, "file_type", 0) or 0),
        is_liked=bool(int(getattr(info, "is_like", 0) or 0)),
        relative_path=str(output_path.relative_to(output_root)),
    )


def materialize_gallery_asset(
    api: APIxoo,
    info,
    output_path: Path,
    *,
    file_token: str,
) -> bool:
    suffix = Path(file_token).suffix.lower()

    if suffix in PREVIEW_IMAGE_SUFFIXES:
        return save_preview_image_as_gif(api, info, output_path)

    try:
        pixel_bean = api.download(info)
    except Exception as exc:
        print(
            f"Skipping unsupported cloud asset clock={getattr(info, 'clock_id', 0)} "
            f"name={getattr(info, 'clock_name', '')!r}: {exc}"
        )
        return False

    if pixel_bean is None:
        return False

    pixel_bean.save_to_gif(str(output_path), scale=1)
    return True


def save_preview_image_as_gif(api: APIxoo, info, output_path: Path) -> bool:
    try:
        response = api.download_response(info)
        if response is None:
            return False

        content = response.content
        image = Image.open(BytesIO(content))
        image.load()
        image = image.convert("RGBA")
        image.save(output_path, format="GIF")
        return True
    except Exception as exc:
        print(
            f"Skipping unsupported preview asset clock={getattr(info, 'clock_id', 0)} "
            f"name={getattr(info, 'clock_name', '')!r}: {exc}"
        )
        return False


def sync_categories(
    api: APIxoo,
    category_names: list[str],
    sort_names: list[str],
    per_page: int,
    max_per_category: int,
    output_root: Path,
    redownload: bool,
) -> list[SyncedItem]:
    items: list[SyncedItem] = []

    for category_name in category_names:
        category = parse_category(category_name)
        for sort_name in sort_names:
            sort = parse_sort(sort_name)
            page = 1
            synced_for_category = 0

            while synced_for_category < max_per_category:
                batch = api.get_category_files(
                    category=category,
                    dimension=GalleryDimension.W16H16,
                    sort=sort,
                    file_type=GalleryType.ANIMATION,
                    page=page,
                    per_page=per_page,
                ) or []
                if not batch:
                    break

                for info in batch:
                    if synced_for_category >= max_per_category:
                        break
                    synced = sync_gallery(
                        api=api,
                        info=info,
                        source_scope="category",
                        sort_name=sort_name.lower().replace("_", "-"),
                        category_name=category_name,
                        collection_name="root",
                        output_root=output_root,
                        redownload=redownload,
                    )
                    if synced is not None:
                        items.append(synced)
                        synced_for_category += 1

                page += 1

    return items


def sync_albums(
    api: APIxoo,
    max_albums: int,
    per_album: int,
    output_root: Path,
    redownload: bool,
) -> list[SyncedItem]:
    synced_items: list[SyncedItem] = []
    albums = api.get_album_list(v3=True) or []

    for album in albums[:max_albums]:
        album_name = slugify(getattr(album, "album_name", "") or str(getattr(album, "album_id", "album")))
        files = api.get_album_files(int(getattr(album, "album_id", 0) or 0), page=1, per_page=per_album, v3=True) or []
        for info in files:
            synced = sync_gallery(
                api=api,
                info=info,
                source_scope="album",
                sort_name="album",
                category_name="albums",
                collection_name=album_name,
                output_root=output_root,
                redownload=redownload,
                album_id=int(getattr(album, "album_id", 0) or 0),
            )
            if synced is not None:
                synced_items.append(synced)

    return synced_items


def sync_gallery_ids(
    api: APIxoo,
    gallery_ids: list[int],
    output_root: Path,
    redownload: bool,
) -> list[SyncedItem]:
    synced_items: list[SyncedItem] = []

    for gallery_id in gallery_ids:
        info = api.get_gallery_info(gallery_id)
        if info is None:
            continue
        category_value = getattr(info, "category", None)
        category_name = "gallery-info"
        if category_value is not None:
            try:
                category_name = GalleryCategory(int(category_value)).name.lower().replace("_", "-")
            except Exception:
                category_name = str(category_value)
        synced = sync_gallery(
            api=api,
            info=info,
            source_scope="gallery-id",
            sort_name="gallery-info",
            category_name=category_name,
            collection_name="root",
            output_root=output_root,
            redownload=redownload,
        )
        if synced is not None:
            synced_items.append(synced)

    return synced_items


def sync_search_queries(
    api: APIxoo,
    queries: list[str],
    item_flag: str,
    item_id: str,
    clock_id: int,
    language: str,
    per_page: int,
    max_per_query: int,
    output_root: Path,
    redownload: bool,
) -> list[SyncedItem]:
    synced_items: list[SyncedItem] = []

    for query in queries:
        collection_name = slugify(query, allow_unicode=True)
        batch = collect_search_items(
            api=api,
            query=query,
            item_flag=item_flag,
            item_id=item_id,
            clock_id=clock_id,
            language=language,
            per_page=per_page,
            max_items=max_per_query,
        )
        if batch is None:
            continue

        for info in batch:
            synced = sync_gallery(
                api=api,
                info=info,
                source_scope="search",
                sort_name="search",
                category_name="search",
                collection_name=collection_name,
                output_root=output_root,
                redownload=redownload,
            )
            if synced is not None:
                synced_items.append(synced)

    return synced_items


def collect_search_items(
    api: APIxoo,
    query: str,
    item_flag: str,
    item_id: str,
    clock_id: int,
    language: str,
    per_page: int,
    max_items: int,
):
    items = []
    page = 1
    while len(items) < max_items:
        batch = api.search_items(
            key=query,
            item_flag=item_flag,
            item_id=item_id,
            clock_id=clock_id or None,
            language=language,
            page=page,
            per_page=per_page,
        )
        if batch is None:
            return None if page == 1 else items[:max_items]
        if not batch:
            break
        items.extend(batch)
        page += 1
    return items[:max_items]


def fetch_store_batch(
    api: APIxoo,
    endpoint_name: str,
    type_flag: int | None,
    classify_id: int | None,
    page: int,
    per_page: int,
    page_index: int,
    clock_id: int,
    parent_clock_id: int,
    parent_item_id: str,
    language: str,
    country_iso_code: str,
    lcd_independence: int,
    lcd_index: int,
):
    if endpoint_name == "top20":
        return api.get_store_top20(
            type_flag=type_flag,
            country_iso_code=country_iso_code,
            language=language,
        )
    if endpoint_name == "new20":
        return api.get_store_new20(
            type_flag=type_flag,
            country_iso_code=country_iso_code,
            language=language,
        )
    return api.get_store_clock_list(
        type_flag=type_flag,
        classify_id=classify_id,
        page=page,
        per_page=per_page,
        country_iso_code=country_iso_code,
        language=language,
    )


def collect_store_items(
    api: APIxoo,
    endpoint_name: str,
    type_flag: int | None,
    classify_id: int | None,
    per_page: int,
    max_items: int,
    page_index: int,
    clock_id: int,
    parent_clock_id: int,
    parent_item_id: str,
    language: str,
    country_iso_code: str,
    lcd_independence: int,
    lcd_index: int,
):
    if endpoint_name in {"top20", "new20"}:
        batch = fetch_store_batch(
            api=api,
            endpoint_name=endpoint_name,
            type_flag=type_flag,
            classify_id=classify_id,
            page=1,
            per_page=per_page,
            page_index=page_index,
            clock_id=clock_id,
            parent_clock_id=parent_clock_id,
            parent_item_id=parent_item_id,
            language=language,
            country_iso_code=country_iso_code,
            lcd_independence=lcd_independence,
            lcd_index=lcd_index,
        )
        if batch is None:
            return None
        return batch[:max_items]

    items = []
    page = 1
    while len(items) < max_items:
        batch = fetch_store_batch(
            api=api,
            endpoint_name=endpoint_name,
            type_flag=type_flag,
            classify_id=classify_id,
            page=page,
            per_page=per_page,
            page_index=page_index + (page - 1),
            clock_id=clock_id,
            parent_clock_id=parent_clock_id,
            parent_item_id=parent_item_id,
            language=language,
            country_iso_code=country_iso_code,
            lcd_independence=lcd_independence,
            lcd_index=lcd_index,
        )
        if batch is None:
            return None if page == 1 else items[:max_items]
        if not batch:
            break
        items.extend(batch)
        page += 1
    return items[:max_items]


def sync_store_list(
    api: APIxoo,
    endpoint_name: str,
    type_flag: int | None,
    classify_id: int | None,
    per_page: int,
    max_items: int,
    page_index: int,
    clock_id: int,
    parent_clock_id: int,
    parent_item_id: str,
    language: str,
    country_iso_code: str,
    lcd_independence: int,
    lcd_index: int,
    output_root: Path,
    redownload: bool,
) -> list[SyncedItem]:
    synced_items: list[SyncedItem] = []
    collection_name = endpoint_name if classify_id is None else f"{endpoint_name}-classify-{classify_id}"
    batch = collect_store_items(
        api=api,
        endpoint_name=endpoint_name,
        type_flag=type_flag,
        classify_id=classify_id,
        per_page=per_page,
        max_items=max_items,
        page_index=page_index,
        clock_id=clock_id,
        parent_clock_id=parent_clock_id,
        parent_item_id=parent_item_id,
        language=language,
        country_iso_code=country_iso_code,
        lcd_independence=lcd_independence,
        lcd_index=lcd_index,
    )
    if batch is None:
        return synced_items
    for info in batch:
        synced = sync_gallery(
            api=api,
            info=info,
            source_scope="store-channel",
            sort_name=endpoint_name,
            category_name="store",
            collection_name=collection_name,
            output_root=output_root,
            redownload=redownload,
        )
        if synced is not None:
            synced_items.append(synced)

    return synced_items


def fetch_store_classify(
    api: APIxoo,
    *,
    country_iso_code: str = "",
    language: str = "",
) -> list[StoreClassifyItem] | None:
    classify_items = api.get_store_clock_classify(
        country_iso_code=country_iso_code,
        language=language,
    )
    if classify_items is None:
        return None
    values: list[StoreClassifyItem] = []
    for item in classify_items:
        values.append(
            StoreClassifyItem(
                classify_id=int(getattr(item, "classify_id", 0) or 0),
                classify_name=str(getattr(item, "classify_name", "") or ""),
                name=str(getattr(item, "name", "") or ""),
                title=str(getattr(item, "title", "") or ""),
                image_id=str(getattr(item, "image_id", "") or ""),
                sort_order=int(getattr(item, "sort_order", 0) or 0),
            )
        )
    return values


def fetch_my_playlists(api: APIxoo, per_page: int, gallery_id: int | None = None) -> list[PlaylistManifestItem] | None:
    playlists = api.get_my_list(page=1, per_page=per_page, gallery_id=gallery_id)
    if playlists is None:
        return None
    return build_playlist_manifest_items(playlists, owner="me", target_user_id=None)


def fetch_someone_playlists(api: APIxoo, target_user_ids: list[int], per_page: int) -> list[PlaylistManifestItem] | None:
    items: list[PlaylistManifestItem] = []
    for target_user_id in target_user_ids:
        playlists = api.get_someone_list(target_user_id=target_user_id, page=1, per_page=per_page)
        if playlists is None:
            return None
        items.extend(build_playlist_manifest_items(playlists, owner="someone", target_user_id=target_user_id))
    return items


def build_playlist_manifest_items(playlists, owner: str, target_user_id: int | None) -> list[PlaylistManifestItem]:
    values: list[PlaylistManifestItem] = []
    for item in playlists:
        values.append(
            PlaylistManifestItem(
                owner=owner,
                target_user_id=target_user_id,
                play_id=int(getattr(item, "play_id", 0) or 0),
                play_name=str(getattr(item, "play_name", "") or ""),
                name=str(getattr(item, "name", "") or ""),
                gallery_id=int(getattr(item, "gallery_id", 0) or 0),
                cover_file_id=str(getattr(item, "cover_file_id", "") or ""),
                image_file_id=str(getattr(item, "image_file_id", "") or ""),
                likes=int(getattr(item, "total_likes", 0) or 0),
                views=int(getattr(item, "total_views", 0) or 0),
                file_count=int(getattr(item, "file_count", 0) or 0),
            )
        )
    return values


def dedupe_synced_items(items: list[SyncedItem]) -> list[SyncedItem]:
    unique_items: list[SyncedItem] = []
    seen_gallery_ids: set[int] = set()

    for item in items:
        if item.gallery_id in seen_gallery_ids:
            continue
        seen_gallery_ids.add(item.gallery_id)
        unique_items.append(item)

    return unique_items


def load_existing_manifest(path: Path) -> dict:
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def load_existing_synced_items(path: Path) -> list[SyncedItem]:
    manifest = load_existing_manifest(path)
    values: list[SyncedItem] = []
    for item in manifest.get("items", []):
        try:
            values.append(SyncedItem(**item))
        except TypeError:
            continue
    return values


def load_existing_store_classify(path: Path) -> list[StoreClassifyItem]:
    manifest = load_existing_manifest(path)
    values: list[StoreClassifyItem] = []
    for item in manifest.get("storeClassify", []):
        try:
            values.append(StoreClassifyItem(**item))
        except TypeError:
            continue
    return values


def load_existing_store_banners(path: Path) -> list[StoreBannerItem]:
    manifest = load_existing_manifest(path)
    values: list[StoreBannerItem] = []
    for item in manifest.get("storeBanners", []):
        try:
            clock_list = [
                StoreBannerClockItem(**clock_item)
                for clock_item in item.get("clock_list", [])
            ]
            values.append(
                StoreBannerItem(
                    banner_name=str(item.get("banner_name", "") or ""),
                    banner_image_id=str(item.get("banner_image_id", "") or ""),
                    clock_list=clock_list,
                )
            )
        except TypeError:
            continue
    return values


def load_existing_playlists(path: Path, key: str) -> list[PlaylistManifestItem]:
    manifest = load_existing_manifest(path)
    values: list[PlaylistManifestItem] = []
    for item in manifest.get(key, []):
        try:
            values.append(PlaylistManifestItem(**item))
        except TypeError:
            continue
    return values


def merge_synced_items(existing_items: list[SyncedItem], new_items: list[SyncedItem]) -> list[SyncedItem]:
    merged: dict[int, SyncedItem] = {}
    for item in existing_items:
        merged[item.gallery_id] = item
    for item in new_items:
        merged[item.gallery_id] = item
    return list(merged.values())


def merge_string_lists(existing_values: list[str], new_values: list[str]) -> list[str]:
    merged: list[str] = []
    seen: set[str] = set()
    for value in existing_values + new_values:
        cleaned = str(value).strip()
        if not cleaned or cleaned in seen:
            continue
        seen.add(cleaned)
        merged.append(cleaned)
    return merged


def gallery_dicts(items) -> list[dict]:
    return [dict(item) for item in items]


def build_store_classify_request(args) -> dict:
    return {
        "CountryISOCode": args.store_country_iso_code,
        "Language": args.store_language,
    }


def build_store_list_request(args, page_index: int | None = None) -> dict:
    if args.store_endpoint == "list":
        page = args.store_page_index if page_index is None else page_index
        start_num = ((page - 1) * args.per_page) + 1
        end_num = start_num + args.per_page - 1
        payload = {
            "CountryISOCode": args.store_country_iso_code,
            "Language": args.store_language,
            "Flag": args.store_flag,
            "StartNum": start_num,
            "EndNum": end_num,
        }
        if args.store_classify_id is not None:
            payload["ClassifyId"] = args.store_classify_id
        return payload

    payload = {
        "CountryISOCode": args.store_country_iso_code,
        "Language": args.store_language,
    }
    if args.store_flag is not None:
        payload["Flag"] = args.store_flag
    return payload


def build_search_request(args, query: str, page: int = 1) -> dict:
    start_num = ((page - 1) * args.per_page) + 1
    end_num = start_num + args.per_page - 1
    return {
        "Language": args.search_language,
        "ClockId": args.search_clock_id or 0,
        "ItemId": args.search_item_id,
        "Key": query,
        "StartNum": start_num,
        "EndNum": end_num,
        "ItemFlag": args.search_item_flag,
    }


def compact_dict(payload: dict) -> dict:
    return {key: value for key, value in payload.items() if value is not None}


def apply_requested_device_context(api: APIxoo, args) -> dict | None:
    if args.blue_device_id is not None:
        api.set_device_context(args.blue_device_id, args.blue_device_password)
        return {
            "success": True,
            "mode": "manual",
            "deviceId": args.blue_device_id,
            "devicePassword": args.blue_device_password,
        }

    if args.blue_device_type is None and args.blue_device_subtype is None:
        if not args.auto_store_sync:
            return None
        response = api.register_blue_device(
            type_=DEFAULT_BLUE_DEVICE_TYPE,
            subtype=DEFAULT_BLUE_DEVICE_SUBTYPE,
            attempts=5,
        )
        if not response_success(response):
            cached_context = load_cached_device_context(args.manifest)
            if cached_context is None:
                return response

            api.set_device_context(
                cached_context["device_id"],
                cached_context["device_password"],
            )
            return {
                "success": True,
                "mode": "cached-manifest",
                "type": DEFAULT_BLUE_DEVICE_TYPE,
                "subtype": DEFAULT_BLUE_DEVICE_SUBTYPE,
                "deviceId": cached_context["device_id"],
                "devicePassword": cached_context["device_password"],
                "fallbackResponse": response,
            }
        return {
            "success": True,
            "mode": "registered-default",
            "type": DEFAULT_BLUE_DEVICE_TYPE,
            "subtype": DEFAULT_BLUE_DEVICE_SUBTYPE,
            "deviceId": response.get("BluetoothDeviceId"),
            "devicePassword": response.get("DevicePassword"),
            "response": response,
        }

    if args.blue_device_type is None and args.blue_device_subtype is None:
        return None

    if args.blue_device_type is None or args.blue_device_subtype is None:
        raise ValueError("Provide both --blue-device-type and --blue-device-subtype together.")

    response = api.register_blue_device(
        type_=args.blue_device_type,
        subtype=args.blue_device_subtype,
        attempts=5,
    )
    if not response_success(response):
        return response
    return {
        "success": True,
        "mode": "registered",
        "type": args.blue_device_type,
        "subtype": args.blue_device_subtype,
        "deviceId": response.get("BluetoothDeviceId"),
        "devicePassword": response.get("DevicePassword"),
        "response": response,
    }


def load_cached_device_context(manifest_path: Path) -> dict | None:
    manifest = load_existing_manifest(manifest_path)
    device_context = manifest.get("deviceContext", {})
    device_id = device_context.get("device_id")
    device_password = device_context.get("device_password")
    if device_id is None or device_password is None:
        return None

    return {
        "device_id": int(device_id),
        "device_password": int(device_password),
    }


def timing_fields_from_args(args) -> TimingFields:
    return TimingFields(
        clock_id=args.clock_id,
        parent_clock_id=args.parent_clock_id,
        parent_item_id=args.parent_item_id,
        lcd_index=args.lcd_index,
        lcd_independence=args.lcd_independence,
        lcd_independence_list=args.lcd_independence_list or None,
        single_gallery_time=args.single_gallery_time,
        gallery_show_time_flag=args.gallery_show_time_flag,
        sound_on_off=args.sound_on_off,
    )


def ambient_fields_from_args(args) -> AmbientFields:
    return AmbientFields(
        on_off=args.ambient_on_off,
        brightness=args.ambient_brightness,
        select_light_index=args.ambient_select_light_index,
        color=args.ambient_color,
        color_cycle=args.ambient_color_cycle,
        key_on_off=args.ambient_key_on_off,
        light_list=args.ambient_light_list,
    )


def rgb_fields_from_args(args) -> RGBFields:
    return RGBFields(
        on_off=args.rgb_on_off,
        brightness=args.rgb_brightness,
        select_light_index=args.rgb_select_light_index,
        color=args.rgb_color,
        color_cycle=args.rgb_color_cycle,
        key_on_off=args.rgb_key_on_off,
        light_list=args.rgb_light_list,
    )


def timing_fields_payload(fields: TimingFields) -> dict:
    return compact_dict(asdict(fields))


def ambient_fields_payload(fields: AmbientFields) -> dict:
    return compact_dict(asdict(fields))


def rgb_fields_payload(fields: RGBFields) -> dict:
    return compact_dict(asdict(fields))


def parse_json_value(raw: str | None, *, label: str):
    if raw is None:
        return None
    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ValueError(f"{label} must be valid JSON: {exc}") from exc


def summarized_response_fields(response: dict | None, *keys: str) -> dict:
    if not response:
        return {}
    return {key: response.get(key) for key in keys if key in response}


def print_json(payload: dict) -> int:
    print(json.dumps(payload, indent=2, ensure_ascii=False))
    return 0


def print_status_json(payload: dict, success: bool) -> int:
    print(json.dumps(payload, indent=2, ensure_ascii=False))
    return 0 if success else 1


def error_json(code: str, message: str) -> int:
    print(json.dumps({"error": code, "message": message}, indent=2, ensure_ascii=False), file=sys.stderr)
    return 2


def response_success(response: dict | None) -> bool:
    if not response:
        return False
    try:
        return int(response.get("ReturnCode", 1)) == 0
    except (TypeError, ValueError):
        return False


def print_response_json(payload: dict, response: dict | None) -> int:
    return print_status_json(payload, response_success(response))


def build_store_classify_items(response: dict | None) -> list[StoreClassifyItem]:
    if not response_success(response):
        return []

    values: list[StoreClassifyItem] = []
    for item in response.get("ClassifyList", []) or []:
        values.append(
            StoreClassifyItem(
                classify_id=int(item.get("ClassifyId", 0) or 0),
                classify_name=str(item.get("ClassifyName", "") or ""),
                name=str(item.get("Name", "") or ""),
                title=str(item.get("Title", "") or ""),
                image_id=str(item.get("ImageId", "") or ""),
                sort_order=int(item.get("Sort", 0) or 0),
            )
        )
    return values


def build_store_banner_items(response: dict | None) -> list[StoreBannerItem]:
    if not response_success(response):
        return []

    values: list[StoreBannerItem] = []
    for item in response.get("BannerList", []) or []:
        clock_list = [
            StoreBannerClockItem(
                clock_id=int(clock.get("ClockId", 0) or 0),
                clock_name=str(clock.get("ClockName", "") or ""),
                image_pixel_id=str(clock.get("ImagePixelId", "") or ""),
                clock_type=int(clock.get("ClockType", 0) or 0),
                add_flag=int(clock.get("AddFlag", 0) or 0),
            )
            for clock in (item.get("ClockList", []) or [])
        ]
        values.append(
            StoreBannerItem(
                banner_name=str(item.get("BannerName", "") or ""),
                banner_image_id=str(item.get("BannerImageId", "") or ""),
                clock_list=clock_list,
            )
        )
    return values


def fetch_store_banner(
    api: APIxoo,
    *,
    per_page: int,
    country_iso_code: str,
    language: str,
) -> list[StoreBannerItem]:
    response = api.get_store_banner_response(
        page=1,
        per_page=per_page,
        country_iso_code=country_iso_code,
        language=language,
    )
    return build_store_banner_items(response)


def response_items(response: dict | None, key: str) -> list[dict]:
    if not response_success(response):
        return []
    return list(response.get(key, []) or [])


def execute_store_request(api: APIxoo, args, page_index: int | None = None) -> tuple[dict, dict | None]:
    request = build_store_list_request(args, page_index=page_index)

    if args.store_endpoint == "top20":
        response = api.get_store_top20_response(
            type_flag=args.store_flag,
            country_iso_code=args.store_country_iso_code,
            language=args.store_language,
        )
        return request, response

    if args.store_endpoint == "new20":
        response = api.get_store_new20_response(
            type_flag=args.store_flag,
            country_iso_code=args.store_country_iso_code,
            language=args.store_language,
        )
        return request, response

    response = api.get_store_clock_list_response(
        type_flag=args.store_flag,
        classify_id=args.store_classify_id,
        page=args.store_page_index if page_index is None else page_index,
        per_page=args.per_page,
        country_iso_code=args.store_country_iso_code,
        language=args.store_language,
    )
    return request, response


def action_flags(args) -> list[str]:
    flags: list[str] = []
    if args.print_device_list:
        flags.append("print-device-list")
    if args.register_blue_device:
        flags.append("register-blue-device")
    if args.print_store_classify:
        flags.append("print-store-classify")
    if args.print_store_list:
        flags.append("print-store-list")
    if args.print_search_results:
        flags.append("print-search-results")
    if args.print_my_list:
        flags.append("print-my-list")
    if args.print_someone_list:
        flags.append("print-someone-list")
    if args.like_gallery_id is not None:
        flags.append("gallery-like")
    if args.like_clock_id is not None:
        flags.append("clock-like")
    if args.print_custom_gallery_time is not None:
        flags.append("print-custom-gallery-time")
    if args.print_subscribe_time is not None:
        flags.append("print-subscribe-time")
    if args.print_album_time is not None:
        flags.append("print-album-time")
    if args.set_custom_gallery_time is not None:
        flags.append("set-custom-gallery-time")
    if args.set_subscribe_time:
        flags.append("set-subscribe-time")
    if args.set_album_time:
        flags.append("set-album-time")
    if args.print_rgb_info:
        flags.append("print-rgb-info")
    if args.set_rgb_info:
        flags.append("set-rgb-info")
    if args.playlist_create is not None:
        flags.append("playlist-create")
    if args.playlist_hide is not None:
        flags.append("playlist-hide")
    if args.playlist_unhide is not None:
        flags.append("playlist-unhide")
    if args.playlist_rename is not None:
        flags.append("playlist-rename")
    if args.playlist_set_describe is not None:
        flags.append("playlist-set-describe")
    if args.playlist_set_cover is not None:
        flags.append("playlist-set-cover")
    if args.playlist_delete is not None:
        flags.append("playlist-delete")
    if args.playlist_add_gallery is not None:
        flags.append("playlist-add-gallery")
    if args.playlist_remove_gallery is not None:
        flags.append("playlist-remove-gallery")
    if args.playlist_send is not None:
        flags.append("playlist-send")
    if args.print_ambient_light:
        flags.append("print-ambient-light")
    if args.set_ambient_light:
        flags.append("set-ambient-light")
    if args.set_brightness is not None:
        flags.append("set-brightness")
    if args.print_on_off_screen:
        flags.append("print-on-off-screen")
    if args.on_off_screen is not None:
        flags.append("on-off-screen")
    if args.print_on_off:
        flags.append("print-on-off")
    if args.set_on_off is not None:
        flags.append("set-on-off")
    return flags


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Sync 16x16 animations from Divoom's cloud into the native library.")
    parser.add_argument("--email", default=os.environ.get("DIVOOM_EMAIL"))
    parser.add_argument("--password", default=os.environ.get("DIVOOM_PASSWORD"))
    parser.add_argument("--md5-password", default=os.environ.get("DIVOOM_MD5_PASSWORD"))
    parser.add_argument("--print-device-list", action="store_true", help="Print Device/GetListV2 and exit.")
    parser.add_argument("--register-blue-device", action="store_true", help="Call APP/GetServerUTC plus BlueDevice/NewDevice and exit.")
    parser.add_argument("--blue-device-type", type=int, help="Type for BlueDevice/NewDevice, derived from the vendor device table.")
    parser.add_argument("--blue-device-subtype", type=int, help="SubType for BlueDevice/NewDevice.")
    parser.add_argument("--blue-device-id", type=int, help="Manually inject DeviceId into channel/store requests.")
    parser.add_argument("--blue-device-password", type=int, help="Manually inject DevicePassword into channel/store requests.")
    parser.add_argument("--auto-store-sync", action="store_true", help="Register the Ditoo Pro cloud channel context and sync Top20, New20, and live store classify buckets.")
    parser.add_argument("--category", action="append", dest="categories", help="Category name such as recommend, top, emoji, animal")
    parser.add_argument("--sort", action="append", dest="sorts", choices=["most-liked", "new-upload"], help="Category sort order to sync. Default is both.")
    parser.add_argument("--gallery-id", action="append", dest="gallery_ids", type=int, help="Fetch and decode a specific gallery ID using the direct GalleryInfo endpoint.")
    parser.add_argument("--per-page", type=int, default=40)
    parser.add_argument("--max-per-category", type=int, default=80)
    parser.add_argument("--max-albums", type=int, default=8)
    parser.add_argument("--per-album", type=int, default=24)
    parser.add_argument("--search-query", action="append", dest="search_queries", help="Run an iOS ItemSearch query and sync the returned 16x16 items.")
    parser.add_argument("--search-item-flag", default="", help="Raw ItemFlag value for Channel/ItemSearch. Empty matches the nil-to-empty-string iOS default.")
    parser.add_argument("--search-item-id", default="", help="ItemId is a string in the native channel search request.")
    parser.add_argument("--search-clock-id", type=int, default=0)
    parser.add_argument("--search-language", default="")
    parser.add_argument("--max-per-search", type=int, default=60)
    parser.add_argument("--include-my-list", action="store_true", help="Fetch Playlist/GetMyList metadata into the manifest.")
    parser.add_argument("--my-list-gallery-id", type=int, help="Optional GalleryId filter for Playlist/GetMyList.")
    parser.add_argument("--target-user-id", action="append", dest="target_user_ids", type=int, help="Fetch Playlist/GetSomeOneList metadata for a specific user ID.")
    parser.add_argument("--include-store-classify", action="store_true", help="Fetch Channel/StoreClockGetClassify metadata into the manifest.")
    parser.add_argument("--store-endpoint", choices=sorted(STORE_ENDPOINTS.keys()), default="list", help="Channel store endpoint family to sync when --store-flag is set.")
    parser.add_argument("--store-flag", type=int, help="Raw Flag value for the iOS store request shape. No guessed defaults are applied.")
    parser.add_argument("--store-classify-id", type=int)
    parser.add_argument("--store-page-index", type=int, default=1, help="Legacy manual probe field. The current iOS Top20/New20 path does not serialize PageIndex.")
    parser.add_argument("--store-clock-id", type=int, default=0, help="Legacy manual probe field. The current iOS Top20/New20 path does not serialize ClockId.")
    parser.add_argument("--store-parent-clock-id", type=int, default=0, help="Legacy manual probe field. The current iOS Top20/New20 path does not serialize ParentClockId.")
    parser.add_argument("--store-parent-item-id", default="", help="Legacy manual probe field. The current iOS Top20/New20 path does not serialize ParentItemId.")
    parser.add_argument("--store-language", default="", help="Language passed to store endpoints.")
    parser.add_argument("--store-country-iso-code", default="", help="CountryISOCode passed to Channel/StoreClockGetList and StoreClockGetClassify.")
    parser.add_argument("--store-lcd-independence", type=int, default=0, help="Legacy manual probe field. The current iOS Top20/New20 path does not serialize LcdIndependence.")
    parser.add_argument("--store-lcd-index", type=int, default=0, help="Legacy manual probe field. The current iOS Top20/New20 path does not serialize LcdIndex.")
    parser.add_argument("--print-store-classify", action="store_true", help="Print Channel/StoreClockGetClassify results as JSON and exit.")
    parser.add_argument("--print-store-list", action="store_true", help="Print store/channel clock results as JSON and exit.")
    parser.add_argument("--print-search-results", action="store_true", help="Print Channel/ItemSearch results as JSON and exit.")
    parser.add_argument("--print-my-list", action="store_true", help="Print Playlist/GetMyList results as JSON and exit.")
    parser.add_argument("--print-someone-list", action="store_true", help="Print Playlist/GetSomeOneList results for --target-user-id values as JSON and exit.")
    parser.add_argument("--like-gallery-id", type=int, help="Like or unlike a gallery via GalleryLikeV2 and exit.")
    parser.add_argument("--like-clock-id", type=int, help="Like or unlike a clock via Channel/LikeClock and exit.")
    parser.add_argument("--like-classify", type=int)
    parser.add_argument("--like-file-type", type=int)
    parser.add_argument("--unlike", action="store_true")
    parser.add_argument("--print-custom-gallery-time", type=int, metavar="CLOCK_ID", help="Print Channel/GetCustomGalleryTime for a ClockId and exit.")
    parser.add_argument("--print-subscribe-time", "--print-subscribe-gallery-time", dest="print_subscribe_time", type=int, metavar="CLOCK_ID", help="Print Channel/GetSubscribeTime for a ClockId and exit.")
    parser.add_argument("--print-album-time", type=int, metavar="CLOCK_ID", help="Print Channel/GetAlbumTime for a ClockId and exit.")
    parser.add_argument("--set-custom-gallery-time", type=int, metavar="CLOCK_ID", help="Call Channel/SetCustomGalleryTime for a ClockId and exit.")
    parser.add_argument("--set-subscribe-time", action="store_true", help="Call Channel/SetSubscribeTime using the IPA-proven timing fields and exit.")
    parser.add_argument("--set-album-time", action="store_true", help="Call Channel/SetAlbumTime using the IPA-proven timing fields and exit.")
    parser.add_argument("--custom-id", type=int, help="CustomId for Channel/SetCustomGalleryTime.")
    parser.add_argument("--single-gallery-time", type=int, help="SingleGalleyTime for Channel/SetCustomGalleryTime.")
    parser.add_argument("--gallery-show-time-flag", type=int, help="GalleryShowTimeFlag for Channel/SetCustomGalleryTime.")
    parser.add_argument("--sound-on-off", type=int, help="SoundOnOff for Channel/SetCustomGalleryTime.")
    parser.add_argument("--clock-id", type=int, help="ClockId for timing actions when the endpoint is not already encoded by the primary flag.")
    parser.add_argument("--parent-clock-id", type=int, help="ParentClockId for custom gallery calls when needed.")
    parser.add_argument("--parent-item-id", help="ParentItemId for custom gallery calls when needed.")
    parser.add_argument("--lcd-index", type=int, help="LcdIndex for Channel/SetCustomGalleryTime when present.")
    parser.add_argument("--lcd-independence", type=int, help="LcdIndependence for Channel/SetCustomGalleryTime when present.")
    parser.add_argument("--lcd-independence-list", action="append", type=int, help="Repeat to send LcdIndependenceList values when the endpoint/model supports it.")
    parser.add_argument("--playlist-create", metavar="NAME", help="Create a playlist via Playlist/NewList and exit.")
    parser.add_argument("--playlist-hide", type=int, metavar="PLAY_ID", help="Hide a playlist via Playlist/Hide and exit.")
    parser.add_argument("--playlist-unhide", type=int, metavar="PLAY_ID", help="Unhide a playlist via Playlist/Hide and exit.")
    parser.add_argument("--playlist-rename", nargs=2, metavar=("PLAY_ID", "NAME"), help="Rename a playlist via Playlist/Rename and exit.")
    parser.add_argument("--playlist-set-describe", nargs=2, metavar=("PLAY_ID", "TEXT"), help="Set playlist description via Playlist/SetDescribe and exit.")
    parser.add_argument("--playlist-set-cover", nargs=2, metavar=("PLAY_ID", "COVER_FILE_ID"), help="Set playlist cover via Playlist/SetCover and exit.")
    parser.add_argument("--playlist-delete", type=int, metavar="PLAY_ID", help="Delete a playlist via Playlist/DeleteList and exit.")
    parser.add_argument("--playlist-add-gallery", nargs=2, metavar=("PLAY_ID", "GALLERY_ID"), help="Add a gallery to a playlist via Playlist/AddImageToList and exit.")
    parser.add_argument("--playlist-remove-gallery", nargs=2, metavar=("PLAY_ID", "GALLERY_ID"), help="Remove a gallery from a playlist via Playlist/RemoveImage and exit.")
    parser.add_argument("--playlist-send", "--playlist-send-device", dest="playlist_send", type=int, metavar="PLAY_ID", help="Send a playlist to the device via Playlist/SendDevice and exit.")
    parser.add_argument("--print-rgb-info", action="store_true", help="Print Channel/GetRGBInfo and exit.")
    parser.add_argument("--set-rgb-info", action="store_true", help="Call Channel/SetRGBInfo and exit.")
    parser.add_argument("--print-ambient-light", action="store_true", help="Print Channel/GetAmbientLight and exit.")
    parser.add_argument("--set-ambient-light", action="store_true", help="Call Channel/SetAmbientLight and exit.")
    parser.add_argument("--set-brightness", type=int, metavar="BRIGHTNESS", help="Call Channel/SetBrightness and exit.")
    parser.add_argument("--print-on-off-screen", action="store_true", help="Print Channel/GetOnOffScreen and exit.")
    parser.add_argument("--on-off-screen", type=int, metavar="ON_OFF", help="Call Channel/OnOffScreen with OnOff and exit.")
    parser.add_argument("--print-on-off", action="store_true", help="Print Channel/GetOnOff and exit.")
    parser.add_argument("--set-on-off", type=int, metavar="ON_OFF", help="Call Channel/SetOnOff with OnOff and exit.")
    parser.add_argument("--rgb-on-off", type=int, help="OnOff for Channel/SetRGBInfo.")
    parser.add_argument("--rgb-brightness", type=int, help="Brightness for Channel/SetRGBInfo.")
    parser.add_argument("--rgb-select-light-index", type=int, help="SelectLightIndex for Channel/SetRGBInfo.")
    parser.add_argument("--rgb-color", help="Color string for Channel/SetRGBInfo.")
    parser.add_argument("--rgb-color-cycle", type=int, help="ColorCycle for Channel/SetRGBInfo.")
    parser.add_argument("--rgb-key-on-off", type=int, help="KeyOnOff for Channel/SetRGBInfo.")
    parser.add_argument("--rgb-light-list-json", help="Raw JSON array/object to send as LightList for Channel/SetRGBInfo.")
    parser.add_argument("--ambient-on-off", type=int, help="OnOff for Channel/SetAmbientLight.")
    parser.add_argument("--ambient-brightness", type=int, help="Brightness for Channel/SetAmbientLight.")
    parser.add_argument("--ambient-select-light-index", type=int, help="SelectLightIndex for Channel/SetAmbientLight.")
    parser.add_argument("--ambient-color", help="Color string for Channel/SetAmbientLight.")
    parser.add_argument("--ambient-color-cycle", type=int, help="ColorCycle for Channel/SetAmbientLight.")
    parser.add_argument("--ambient-key-on-off", type=int, help="KeyOnOff for Channel/SetAmbientLight.")
    parser.add_argument("--ambient-light-list-json", help="Raw JSON array/object to send as LightList for Channel/SetAmbientLight.")
    parser.add_argument("--skip-albums", action="store_true")
    parser.add_argument("--redownload", action="store_true")
    parser.add_argument("--output-root", type=Path, default=DEFAULT_OUTPUT_ROOT)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST_PATH)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    categories = args.categories or DEFAULT_CATEGORY_NAMES
    sorts = [value.upper().replace("-", "_") for value in (args.sorts or ["most-liked", "new-upload"])]
    gallery_ids = args.gallery_ids or []
    search_queries = [value.strip() for value in (args.search_queries or []) if value.strip()]
    target_user_ids = args.target_user_ids or []
    selected_actions = action_flags(args)

    try:
        args.rgb_light_list = parse_json_value(args.rgb_light_list_json, label="--rgb-light-list-json")
    except ValueError as exc:
        return error_json("invalid_json", str(exc))

    try:
        args.ambient_light_list = parse_json_value(args.ambient_light_list_json, label="--ambient-light-list-json")
    except ValueError as exc:
        return error_json("invalid_json", str(exc))

    if len(selected_actions) > 1:
        return error_json(
            "conflicting_actions",
            "Run only one explicit action flag at a time: " + ", ".join(selected_actions),
        )

    if not args.email:
        return error_json(
            "missing_credentials",
            "Set DIVOOM_EMAIL plus DIVOOM_PASSWORD or DIVOOM_MD5_PASSWORD before syncing.",
        )

    if not args.password and not args.md5_password:
        return error_json(
            "missing_credentials",
            "Set DIVOOM_PASSWORD or DIVOOM_MD5_PASSWORD before syncing.",
        )

    api = APIxoo(
        email=args.email,
        password=args.password,
        md5_password=args.md5_password,
    )
    if not api.log_in():
        return error_json("login_failed", "Divoom cloud login failed. Check credentials.")

    try:
        device_context_result = apply_requested_device_context(api, args)
    except ValueError as exc:
        return error_json("invalid_blue_device_args", str(exc))

    if (
        (args.blue_device_type is not None or args.blue_device_subtype is not None or args.auto_store_sync)
        and not args.register_blue_device
        and not (isinstance(device_context_result, dict) and device_context_result.get("success"))
    ):
        return print_response_json(
            {
                "success": False,
                "endpoint": "BlueDevice/NewDevice",
                "type": args.blue_device_type,
                "subtype": args.blue_device_subtype,
                "response": device_context_result,
            },
            device_context_result if isinstance(device_context_result, dict) else None,
        )

    if args.print_device_list:
        response = api.get_device_list_v2_response()
        return print_response_json(
            {
                "success": response_success(response),
                "endpoint": "Device/GetListV2",
                "response": response,
            },
            response,
        )

    if args.register_blue_device:
        if args.blue_device_type is None or args.blue_device_subtype is None:
            return error_json(
                "missing_blue_device_args",
                "Provide --blue-device-type plus --blue-device-subtype with --register-blue-device.",
            )
        response = device_context_result
        if isinstance(device_context_result, dict) and "response" in device_context_result:
            response = device_context_result["response"]
        return print_response_json(
            {
                "success": response_success(response),
                "endpoint": "BlueDevice/NewDevice",
                "type": args.blue_device_type,
                "subtype": args.blue_device_subtype,
                "response": response,
                "deviceContext": api.get_device_context(),
            },
            response,
        )

    if args.print_store_classify:
        request = build_store_classify_request(args)
        response = api.get_store_clock_classify_response(
            country_iso_code=args.store_country_iso_code,
            language=args.store_language,
        )
        classify_items = build_store_classify_items(response)
        return print_response_json(
            {
                "success": response_success(response),
                "endpoint": "Channel/StoreClockGetClassify",
                "request": request,
                "response": response,
                "deviceContext": api.get_device_context(),
                "itemCount": len(classify_items),
                "items": [asdict(item) for item in classify_items],
            },
            response,
        )

    if args.print_store_list:
        if args.store_endpoint == "list" and args.store_flag is None:
            return error_json("missing_store_flag", "Provide --store-flag when probing Channel/StoreClockGetList.")
        request, response = execute_store_request(api, args)
        items = response_items(response, "ClockList")
        return print_response_json(
            {
                "success": response_success(response),
                "endpoint": STORE_ENDPOINTS[args.store_endpoint],
                "request": request,
                "response": response,
                "deviceContext": api.get_device_context(),
                "itemCount": len(items),
                "items": items,
            },
            response,
        )

    if args.print_search_results:
        if not search_queries:
            return error_json("missing_search_query", "Provide at least one --search-query with --print-search-results.")
        results = []
        all_succeeded = True
        for query in search_queries:
            request = build_search_request(args, query=query, page=1)
            response = api.search_items_response(
                key=query,
                item_flag=args.search_item_flag,
                item_id=args.search_item_id,
                clock_id=args.search_clock_id or None,
                language=args.search_language,
                page=1,
                per_page=args.per_page,
            )
            items = response_items(response, "SearchList")
            all_succeeded = all_succeeded and response_success(response)
            results.append({
                "query": query,
                "request": request,
                "response": response,
                "itemCount": len(items),
                "items": items,
            })
        return print_status_json(
            {
                "success": all_succeeded,
                "endpoint": "Channel/ItemSearch",
                "itemFlag": args.search_item_flag,
                "itemId": args.search_item_id,
                "clockId": args.search_clock_id,
                "language": args.search_language,
                "results": results,
            },
            all_succeeded,
        )

    if args.print_my_list:
        items = fetch_my_playlists(api, per_page=args.per_page, gallery_id=args.my_list_gallery_id)
        if items is None:
            return error_json("my_list_failed", "Playlist/GetMyList did not return a usable response.")
        return print_json({
            "success": True,
            "galleryId": args.my_list_gallery_id,
            "itemCount": len(items),
            "items": [asdict(item) for item in items],
        })

    if args.print_someone_list:
        if not target_user_ids:
            return error_json("missing_target_user_id", "Provide at least one --target-user-id with --print-someone-list.")
        grouped = []
        for target_user_id in target_user_ids:
            raw_items = api.get_someone_list(target_user_id=target_user_id, page=1, per_page=args.per_page)
            if raw_items is None:
                return error_json("someone_list_failed", f"Playlist/GetSomeOneList did not return a usable response for target user {target_user_id}.")
            items = build_playlist_manifest_items(raw_items, owner="someone", target_user_id=target_user_id)
            grouped.append({
                "targetUserId": target_user_id,
                "itemCount": len(items),
                "items": [asdict(item) for item in items],
            })
        return print_json({
            "success": True,
            "targets": grouped,
        })

    if args.like_gallery_id is not None:
        if args.like_classify is None or args.like_file_type is None:
            return error_json(
                "missing_like_arguments",
                "Provide --like-classify and --like-file-type together with --like-gallery-id.",
            )
        response = api.gallery_like(
            gallery_id=args.like_gallery_id,
            is_like=not args.unlike,
            classify=args.like_classify,
            type_=args.like_file_type,
        )
        if not response:
            return error_json("like_failed", "GalleryLikeV2 did not return a usable response.")
        return print_response_json({
            "success": bool(response.get("ReturnCode", 1) == 0),
            "liked": not args.unlike,
            "galleryId": args.like_gallery_id,
            "response": response,
        }, response)

    if args.like_clock_id is not None:
        response = api.like_clock(clock_id=args.like_clock_id, is_like=not args.unlike)
        if not response:
            return error_json("like_failed", "Channel/LikeClock did not return a usable response.")
        return print_response_json({
            "success": response_success(response),
            "liked": not args.unlike,
            "clockId": args.like_clock_id,
            "response": response,
        }, response)

    if args.print_custom_gallery_time is not None:
        timing_fields = timing_fields_from_args(args)
        response = api.get_custom_gallery_time(
            clock_id=args.print_custom_gallery_time,
            parent_clock_id=args.parent_clock_id,
            parent_item_id=args.parent_item_id,
        )
        if not response:
            return error_json("custom_gallery_time_failed", "Channel/GetCustomGalleryTime did not return a usable response.")
        return print_response_json({
            "success": response_success(response),
            "endpoint": "Channel/GetCustomGalleryTime",
            "request": compact_dict({
                "clockId": args.print_custom_gallery_time,
                "parentClockId": timing_fields.parent_clock_id,
                "parentItemId": timing_fields.parent_item_id,
            }),
            "timing": summarized_response_fields(
                response,
                "ClockId",
                "ParentClockId",
                "ParentItemId",
                "LcdIndex",
                "LcdIndependence",
                "LcdIndependenceList",
                "SingleGalleyTime",
                "GalleryShowTimeFlag",
                "SoundOnOff",
            ),
            "response": response,
        }, response)

    if args.print_subscribe_time is not None:
        response = api.get_subscribe_time_response(
            clock_id=args.print_subscribe_time,
            parent_clock_id=args.parent_clock_id,
            parent_item_id=args.parent_item_id,
        )
        if not response:
            return error_json("subscribe_time_failed", "Channel/GetSubscribeTime did not return a usable response.")
        return print_response_json({
            "success": response_success(response),
            "endpoint": "Channel/GetSubscribeTime",
            "request": compact_dict({
                "clockId": args.print_subscribe_time,
                "parentClockId": args.parent_clock_id,
                "parentItemId": args.parent_item_id,
            }),
            "timing": summarized_response_fields(
                response,
                "ClockId",
                "ParentClockId",
                "ParentItemId",
                "LcdIndex",
                "LcdIndependence",
                "LcdIndependenceList",
                "PlayId",
                "PlayName",
                "SubscribeType",
            ),
            "response": response,
        }, response)

    if args.print_album_time is not None:
        response = api.get_album_time_response(clock_id=args.print_album_time)
        if not response:
            return error_json("album_time_failed", "Channel/GetAlbumTime did not return a usable response.")
        return print_response_json({
            "success": response_success(response),
            "endpoint": "Channel/GetAlbumTime",
            "request": {"clockId": args.print_album_time},
            "timing": summarized_response_fields(
                response,
                "ClockId",
                "AlbumId",
                "AlbumName",
                "LcdIndex",
                "LcdIndependence",
                "LcdIndependenceList",
            ),
            "response": response,
        }, response)

    if args.set_custom_gallery_time is not None:
        timing_fields = timing_fields_from_args(args)
        missing_fields = []
        if args.custom_id is None:
            missing_fields.append("--custom-id")
        if args.single_gallery_time is None:
            missing_fields.append("--single-gallery-time")
        if args.gallery_show_time_flag is None:
            missing_fields.append("--gallery-show-time-flag")
        if args.sound_on_off is None:
            missing_fields.append("--sound-on-off")
        if missing_fields:
            return error_json(
                "missing_custom_gallery_arguments",
                "Provide " + ", ".join(missing_fields) + " with --set-custom-gallery-time.",
            )
        response = api.set_custom_gallery_time(
            clock_id=args.set_custom_gallery_time,
            single_gallery_time=args.single_gallery_time,
            gallery_show_time_flag=args.gallery_show_time_flag,
            sound_on_off=args.sound_on_off,
            custom_id=args.custom_id,
            parent_clock_id=args.parent_clock_id,
            parent_item_id=args.parent_item_id,
            lcd_index=args.lcd_index,
            lcd_independence=args.lcd_independence,
            lcd_independence_list=args.lcd_independence_list,
        )
        if not response:
            return error_json("set_custom_gallery_time_failed", "Channel/SetCustomGalleryTime did not return a usable response.")
        return print_response_json({
            "success": response_success(response),
            "endpoint": "Channel/SetCustomGalleryTime",
            "request": compact_dict({
                "clockId": args.set_custom_gallery_time,
                "parentClockId": timing_fields.parent_clock_id,
                "parentItemId": timing_fields.parent_item_id,
                "lcdIndex": timing_fields.lcd_index,
                "lcdIndependence": timing_fields.lcd_independence,
                "lcdIndependenceList": timing_fields.lcd_independence_list,
                "singleGalleyTime": timing_fields.single_gallery_time,
                "galleryShowTimeFlag": timing_fields.gallery_show_time_flag,
                "soundOnOff": timing_fields.sound_on_off,
                "customId": args.custom_id,
            }),
            "clockId": args.set_custom_gallery_time,
            "response": response,
        }, response)

    if args.set_subscribe_time:
        timing_fields = timing_fields_from_args(args)
        if timing_fields.clock_id is None:
            return error_json("missing_subscribe_time_arguments", "Provide --clock-id with --set-subscribe-time.")
        response = api.set_subscribe_time(
            clock_id=timing_fields.clock_id,
            parent_clock_id=timing_fields.parent_clock_id,
            parent_item_id=timing_fields.parent_item_id,
            lcd_index=timing_fields.lcd_index,
            lcd_independence=timing_fields.lcd_independence,
            lcd_independence_list=timing_fields.lcd_independence_list,
        )
        if not response:
            return error_json("set_subscribe_time_failed", "Channel/SetSubscribeTime did not return a usable response.")
        return print_response_json({
            "success": response_success(response),
            "endpoint": "Channel/SetSubscribeTime",
            "request": timing_fields_payload(timing_fields),
            "response": response,
        }, response)

    if args.set_album_time:
        timing_fields = timing_fields_from_args(args)
        if timing_fields.clock_id is None:
            return error_json("missing_album_time_arguments", "Provide --clock-id with --set-album-time.")
        response = api.set_album_time(clock_id=timing_fields.clock_id)
        if not response:
            return error_json("set_album_time_failed", "Channel/SetAlbumTime did not return a usable response.")
        return print_response_json({
            "success": response_success(response),
            "endpoint": "Channel/SetAlbumTime",
            "request": {"clockId": timing_fields.clock_id},
            "response": response,
        }, response)

    if args.print_rgb_info:
        response = api.get_rgb_info_response()
        if not response:
            return error_json("rgb_info_failed", "Channel/GetRGBInfo did not return a usable response.")
        return print_response_json({
            "success": response_success(response),
            "endpoint": "Channel/GetRGBInfo",
            "rgb": summarized_response_fields(
                response,
                "OnOff",
                "Brightness",
                "SelectLightIndex",
                "Color",
                "ColorCycle",
                "KeyOnOff",
                "LightList",
            ),
            "response": response,
        }, response)

    if args.set_rgb_info:
        rgb_fields = rgb_fields_from_args(args)
        request = rgb_fields_payload(rgb_fields)
        if not request:
            return error_json("missing_rgb_arguments", "Provide at least one --rgb-* field with --set-rgb-info.")
        response = api.set_rgb_info(
            on_off=rgb_fields.on_off,
            brightness=rgb_fields.brightness,
            select_light_index=rgb_fields.select_light_index,
            color=rgb_fields.color,
            color_cycle=rgb_fields.color_cycle,
            key_on_off=rgb_fields.key_on_off,
            light_list=rgb_fields.light_list,
        )
        if not response:
            return error_json("set_rgb_info_failed", "Channel/SetRGBInfo did not return a usable response.")
        return print_response_json({
            "success": response_success(response),
            "endpoint": "Channel/SetRGBInfo",
            "request": request,
            "response": response,
        }, response)

    if args.playlist_create is not None:
        response = api.create_playlist(args.playlist_create)
        if not response:
            return error_json("playlist_create_failed", "Playlist/NewList did not return a usable response.")
        return print_response_json({
            "success": response_success(response),
            "name": args.playlist_create,
            "response": response,
        }, response)

    if args.playlist_hide is not None:
        response = api.set_playlist_hidden(play_id=args.playlist_hide, hide=True)
        if not response:
            return error_json("playlist_hide_failed", "Playlist/Hide did not return a usable response.")
        return print_response_json({
            "success": response_success(response),
            "playId": args.playlist_hide,
            "hidden": True,
            "response": response,
        }, response)

    if args.playlist_unhide is not None:
        response = api.set_playlist_hidden(play_id=args.playlist_unhide, hide=False)
        if not response:
            return error_json("playlist_hide_failed", "Playlist/Hide did not return a usable response.")
        return print_response_json({
            "success": response_success(response),
            "playId": args.playlist_unhide,
            "hidden": False,
            "response": response,
        }, response)

    if args.playlist_rename is not None:
        play_id_raw, name = args.playlist_rename
        response = api.rename_playlist(play_id=int(play_id_raw), name=name)
        if not response:
            return error_json("playlist_rename_failed", "Playlist/Rename did not return a usable response.")
        return print_response_json({
            "success": response_success(response),
            "playId": int(play_id_raw),
            "name": name,
            "response": response,
        }, response)

    if args.playlist_set_describe is not None:
        play_id_raw, describe = args.playlist_set_describe
        response = api.set_playlist_description(play_id=int(play_id_raw), describe=describe)
        if not response:
            return error_json("playlist_set_describe_failed", "Playlist/SetDescribe did not return a usable response.")
        return print_response_json({
            "success": response_success(response),
            "playId": int(play_id_raw),
            "describe": describe,
            "response": response,
        }, response)

    if args.playlist_set_cover is not None:
        play_id_raw, cover_file_id = args.playlist_set_cover
        response = api.set_playlist_cover(play_id=int(play_id_raw), cover_file_id=cover_file_id)
        if not response:
            return error_json("playlist_set_cover_failed", "Playlist/SetCover did not return a usable response.")
        return print_response_json({
            "success": response_success(response),
            "playId": int(play_id_raw),
            "coverFileId": cover_file_id,
            "response": response,
        }, response)

    if args.playlist_delete is not None:
        response = api.delete_playlist(play_id=args.playlist_delete)
        if not response:
            return error_json("playlist_delete_failed", "Playlist/DeleteList did not return a usable response.")
        return print_response_json({
            "success": response_success(response),
            "playId": args.playlist_delete,
            "response": response,
        }, response)

    if args.playlist_add_gallery is not None:
        play_id_raw, gallery_id_raw = args.playlist_add_gallery
        response = api.add_gallery_to_playlist(gallery_id=int(gallery_id_raw), play_id=int(play_id_raw))
        if not response:
            return error_json("playlist_add_gallery_failed", "Playlist/AddImageToList did not return a usable response.")
        return print_response_json({
            "success": response_success(response),
            "playId": int(play_id_raw),
            "galleryId": int(gallery_id_raw),
            "response": response,
        }, response)

    if args.playlist_remove_gallery is not None:
        play_id_raw, gallery_id_raw = args.playlist_remove_gallery
        response = api.remove_gallery_from_playlist(gallery_id=int(gallery_id_raw), play_id=int(play_id_raw))
        if not response:
            return error_json("playlist_remove_gallery_failed", "Playlist/RemoveImage did not return a usable response.")
        return print_response_json({
            "success": response_success(response),
            "playId": int(play_id_raw),
            "galleryId": int(gallery_id_raw),
            "response": response,
        }, response)

    if args.playlist_send is not None:
        response = api.send_playlist_to_device(play_id=args.playlist_send)
        if not response:
            return error_json("playlist_send_failed", "Playlist/SendDevice did not return a usable response.")
        return print_response_json({
            "success": response_success(response),
            "endpoint": "Playlist/SendDevice",
            "request": {"playId": args.playlist_send},
            "playId": args.playlist_send,
            "response": response,
        }, response)

    if args.print_ambient_light:
        response = api.get_ambient_light_response()
        if not response:
            return error_json("ambient_light_failed", "Channel/GetAmbientLight did not return a usable response.")
        return print_response_json({
            "success": response_success(response),
            "endpoint": "Channel/GetAmbientLight",
            "ambient": summarized_response_fields(
                response,
                "OnOff",
                "Brightness",
                "SelectLightIndex",
                "Color",
                "ColorCycle",
                "KeyOnOff",
                "LightList",
            ),
            "response": response,
        }, response)

    if args.set_ambient_light:
        ambient_fields = ambient_fields_from_args(args)
        request = ambient_fields_payload(ambient_fields)
        if not request:
            return error_json("missing_ambient_arguments", "Provide at least one --ambient-* field with --set-ambient-light.")
        response = api.set_ambient_light(
            on_off=ambient_fields.on_off,
            brightness=ambient_fields.brightness,
            select_light_index=ambient_fields.select_light_index,
            color=ambient_fields.color,
            color_cycle=ambient_fields.color_cycle,
            key_on_off=ambient_fields.key_on_off,
            light_list=ambient_fields.light_list,
        )
        if not response:
            return error_json("set_ambient_light_failed", "Channel/SetAmbientLight did not return a usable response.")
        return print_response_json({
            "success": response_success(response),
            "endpoint": "Channel/SetAmbientLight",
            "request": request,
            "response": response,
        }, response)

    if args.set_brightness is not None:
        response = api.set_brightness(args.set_brightness)
        if not response:
            return error_json("set_brightness_failed", "Channel/SetBrightness did not return a usable response.")
        return print_response_json({
            "success": response_success(response),
            "endpoint": "Channel/SetBrightness",
            "request": {"brightness": args.set_brightness},
            "response": response,
        }, response)

    if args.print_on_off_screen:
        response = api.get_on_off_screen()
        if not response:
            return error_json("on_off_screen_failed", "Channel/GetOnOffScreen did not return a usable response.")
        return print_response_json({
            "success": response_success(response),
            "endpoint": "Channel/GetOnOffScreen",
            "state": summarized_response_fields(response, "OnOff"),
            "response": response,
        }, response)

    if args.on_off_screen is not None:
        response = api.on_off_screen(args.on_off_screen)
        if not response:
            return error_json("set_on_off_screen_failed", "Channel/OnOffScreen did not return a usable response.")
        return print_response_json({
            "success": response_success(response),
            "endpoint": "Channel/OnOffScreen",
            "request": {"onOff": args.on_off_screen},
            "response": response,
        }, response)

    if args.print_on_off:
        response = api.get_on_off()
        if not response:
            return error_json("on_off_failed", "Channel/GetOnOff did not return a usable response.")
        return print_response_json({
            "success": response_success(response),
            "endpoint": "Channel/GetOnOff",
            "state": summarized_response_fields(response, "OnOff", "KeyOnOff"),
            "response": response,
        }, response)

    if args.set_on_off is not None:
        response = api.set_on_off(args.set_on_off)
        if not response:
            return error_json("set_on_off_failed", "Channel/SetOnOff did not return a usable response.")
        return print_response_json({
            "success": response_success(response),
            "endpoint": "Channel/SetOnOff",
            "request": {"onOff": args.set_on_off},
            "response": response,
        }, response)

    args.output_root.mkdir(parents=True, exist_ok=True)
    args.manifest.parent.mkdir(parents=True, exist_ok=True)

    synced_items = sync_categories(
        api=api,
        category_names=categories,
        sort_names=sorts,
        per_page=args.per_page,
        max_per_category=args.max_per_category,
        output_root=args.output_root,
        redownload=args.redownload,
    )
    if not args.skip_albums:
        synced_items.extend(
            sync_albums(
                api=api,
                max_albums=args.max_albums,
                per_album=args.per_album,
                output_root=args.output_root,
                redownload=args.redownload,
            )
        )
    if gallery_ids:
        synced_items.extend(
            sync_gallery_ids(
                api=api,
                gallery_ids=gallery_ids,
                output_root=args.output_root,
                redownload=args.redownload,
            )
        )
    if search_queries:
        synced_items.extend(
            sync_search_queries(
                api=api,
                queries=search_queries,
                item_flag=args.search_item_flag,
                item_id=args.search_item_id,
                clock_id=args.search_clock_id,
                language=args.search_language,
                per_page=args.per_page,
                max_per_query=args.max_per_search,
                output_root=args.output_root,
                redownload=args.redownload,
            )
        )
    auto_store_classify: list[StoreClassifyItem] | None = None
    auto_store_banners: list[StoreBannerItem] | None = None
    if args.auto_store_sync:
        auto_store_classify = fetch_store_classify(
            api,
            country_iso_code=args.store_country_iso_code,
            language=args.store_language,
        ) or []
        auto_store_banners = fetch_store_banner(
            api,
            per_page=args.per_page,
            country_iso_code=args.store_country_iso_code,
            language=args.store_language,
        ) or []
        synced_items.extend(
            sync_store_list(
                api=api,
                endpoint_name="top20",
                type_flag=DEFAULT_STORE_FLAG,
                classify_id=None,
                per_page=args.per_page,
                max_items=args.max_per_category,
                page_index=1,
                clock_id=0,
                parent_clock_id=0,
                parent_item_id="",
                language=args.store_language,
                country_iso_code=args.store_country_iso_code,
                lcd_independence=0,
                lcd_index=0,
                output_root=args.output_root,
                redownload=args.redownload,
            )
        )
        synced_items.extend(
            sync_store_list(
                api=api,
                endpoint_name="new20",
                type_flag=DEFAULT_STORE_FLAG,
                classify_id=None,
                per_page=args.per_page,
                max_items=args.max_per_category,
                page_index=1,
                clock_id=0,
                parent_clock_id=0,
                parent_item_id="",
                language=args.store_language,
                country_iso_code=args.store_country_iso_code,
                lcd_independence=0,
                lcd_index=0,
                output_root=args.output_root,
                redownload=args.redownload,
            )
        )
        for classify in auto_store_classify:
            synced_items.extend(
                sync_store_list(
                    api=api,
                    endpoint_name="list",
                    type_flag=DEFAULT_STORE_FLAG,
                    classify_id=classify.classify_id,
                    per_page=args.per_page,
                    max_items=args.max_per_category,
                    page_index=1,
                    clock_id=0,
                    parent_clock_id=0,
                    parent_item_id="",
                    language=args.store_language,
                    country_iso_code=args.store_country_iso_code,
                    lcd_independence=0,
                    lcd_index=0,
                    output_root=args.output_root,
                    redownload=args.redownload,
                )
            )
    if args.store_endpoint != "list" or args.store_flag is not None:
        synced_items.extend(
            sync_store_list(
                api=api,
                endpoint_name=args.store_endpoint,
                type_flag=args.store_flag,
                classify_id=args.store_classify_id,
                per_page=args.per_page,
                max_items=args.max_per_category,
                page_index=args.store_page_index,
                clock_id=args.store_clock_id,
                parent_clock_id=args.store_parent_clock_id,
                parent_item_id=args.store_parent_item_id,
                language=args.store_language,
                country_iso_code=args.store_country_iso_code,
                lcd_independence=args.store_lcd_independence,
                lcd_index=args.store_lcd_index,
                output_root=args.output_root,
                redownload=args.redownload,
            )
        )
    existing_manifest = load_existing_manifest(args.manifest)
    existing_synced_items = load_existing_synced_items(args.manifest)
    synced_items = merge_synced_items(existing_synced_items, dedupe_synced_items(synced_items))
    store_classify = auto_store_classify if auto_store_classify is not None else (
        fetch_store_classify(
        api,
        country_iso_code=args.store_country_iso_code,
        language=args.store_language,
    ) if args.include_store_classify else [])
    my_playlists = fetch_my_playlists(
        api,
        per_page=args.per_page,
        gallery_id=args.my_list_gallery_id,
    ) if args.include_my_list else []
    someone_playlists = fetch_someone_playlists(api, target_user_ids=target_user_ids, per_page=args.per_page) if target_user_ids else []
    store_classify = store_classify or load_existing_store_classify(args.manifest)
    store_banners = auto_store_banners or load_existing_store_banners(args.manifest)
    my_playlists = my_playlists or load_existing_playlists(args.manifest, "myPlaylists")
    someone_playlists = someone_playlists or load_existing_playlists(args.manifest, "someonePlaylists")
    previous_categories = [str(value) for value in existing_manifest.get("categories", []) if str(value).strip()]
    previous_sorts = [str(value) for value in existing_manifest.get("sorts", []) if str(value).strip()]
    previous_queries = [str(value) for value in existing_manifest.get("searchQueries", []) if str(value).strip()]
    manifest_categories = merge_string_lists(previous_categories, categories)
    manifest_sorts = merge_string_lists(previous_sorts, [value.lower().replace("_", "-") for value in sorts])
    manifest_queries = merge_string_lists(previous_queries, search_queries)

    manifest = {
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "source": "divoom-cloud",
        "apiClient": "redphx/apixoo",
        "apiCoverage": [
            "APP/GetServerUTC",
            "BlueDevice/NewDevice",
            "Device/GetListV2",
            "UserLogin",
            "Cloud/GalleryInfo",
            "GetCategoryFileListV2",
            "Discover/GetAlbumListV3",
            "Discover/GetAlbumImageListV3",
            "Channel/ItemSearch",
            "GalleryLikeV2",
            "Channel/LikeClock",
            "Playlist/GetMyList",
            "Playlist/GetSomeOneList",
            "Channel/GetCustomGalleryTime",
            "Channel/GetSubscribeTime",
            "Channel/GetAlbumTime",
            "Channel/SetCustomGalleryTime",
            "Channel/SetSubscribeTime",
            "Channel/SetAlbumTime",
            "Playlist/NewList",
            "Playlist/Hide",
            "Playlist/Rename",
            "Playlist/SetDescribe",
            "Playlist/SetCover",
            "Playlist/DeleteList",
            "Playlist/AddImageToList",
            "Playlist/RemoveImage",
            "Playlist/SendDevice",
            "Channel/GetRGBInfo",
            "Channel/SetRGBInfo",
            "Channel/GetAmbientLight",
            "Channel/SetAmbientLight",
            "Channel/SetBrightness",
            "Channel/GetOnOffScreen",
            "Channel/OnOffScreen",
            "Channel/GetOnOff",
            "Channel/SetOnOff",
            "Channel/StoreClockGetClassify",
            "Channel/StoreClockGetList",
            "Channel/StoreTop20",
            "Channel/StoreNew20",
            "Channel/StoreGetBanner",
            "download",
        ],
        "outputRoot": str(args.output_root),
        "itemCount": len(synced_items),
        "categories": manifest_categories,
        "sorts": manifest_sorts,
        "includesAlbums": not args.skip_albums,
        "galleryIdsRequested": gallery_ids,
        "searchQueries": manifest_queries,
        "storeEndpoint": args.store_endpoint if args.store_flag is not None else "",
        "storeFlag": args.store_flag,
        "storeAutoSync": args.auto_store_sync,
        "storeClassifyId": args.store_classify_id,
        "deviceContext": api.get_device_context(),
        "storeClassify": [asdict(item) for item in store_classify],
        "storeBanners": [asdict(item) for item in store_banners],
        "myPlaylists": [asdict(item) for item in my_playlists],
        "someonePlaylists": [asdict(item) for item in someone_playlists],
        "items": [asdict(item) for item in synced_items],
    }
    args.manifest.write_text(json.dumps(manifest, indent=2, ensure_ascii=False), encoding="utf-8")
    print(json.dumps({
        "success": True,
        "itemCount": len(synced_items),
        "storeClassifyCount": len(store_classify),
        "storeBannerCount": len(store_banners),
        "myPlaylistCount": len(my_playlists),
        "someonePlaylistCount": len(someone_playlists),
        "outputRoot": str(args.output_root),
        "manifest": str(args.manifest),
    }, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
