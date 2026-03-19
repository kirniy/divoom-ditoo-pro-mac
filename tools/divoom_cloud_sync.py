#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
VENDOR_APIXOO_ROOT = ROOT / "vendor" / "apixoo"

if str(VENDOR_APIXOO_ROOT) not in sys.path:
    sys.path.insert(0, str(VENDOR_APIXOO_ROOT))

from apixoo import APIxoo, GalleryCategory, GalleryDimension, GallerySorting, GalleryType  # type: ignore  # noqa: E402


DEFAULT_OUTPUT_ROOT = ROOT / "assets" / "16x16" / "divoom-cloud"
DEFAULT_MANIFEST_PATH = ROOT / ".cache" / "divoom-cloud" / "manifest.json"
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
    item_id: int | None
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
    file_name = getattr(info, "file_name", "") or str(getattr(info, "gallery_id", "unknown"))
    gallery_id = int(getattr(info, "gallery_id", 0) or 0)
    safe_base = slugify(file_name)
    output_dir = output_root / category_name / collection_name
    output_dir.mkdir(parents=True, exist_ok=True)
    output_path = output_dir / f"{safe_base}-{gallery_id}.gif"

    if redownload or not output_path.exists():
        pixel_bean = api.download(info)
        if pixel_bean is None:
            return None
        pixel_bean.save_to_gif(str(output_path), scale=1)

    return SyncedItem(
        source="divoom-cloud",
        scope=source_scope,
        sort=sort_name,
        category=category_name,
        cloud_classify=int(getattr(info, "category", 0) or 0),
        collection=collection_name,
        gallery_id=gallery_id,
        file_id=str(getattr(info, "file_id", "")),
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
        item_id=int(getattr(info, "item_id", 0) or 0) or None,
        date=str(getattr(info, "date", "") or ""),
        file_type=int(getattr(info, "file_type", 0) or 0),
        is_liked=bool(int(getattr(info, "is_like", 0) or 0)),
        relative_path=str(output_path.relative_to(output_root)),
    )


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
    item_id: int,
    clock_id: int,
    language: str,
    per_page: int,
    max_per_query: int,
    output_root: Path,
    redownload: bool,
) -> list[SyncedItem]:
    synced_items: list[SyncedItem] = []

    for query in queries:
        page = 1
        synced_for_query = 0
        collection_name = slugify(query, allow_unicode=True)
        while synced_for_query < max_per_query:
            batch = api.search_items(
                key=query,
                item_flag=item_flag,
                item_id=item_id or None,
                clock_id=clock_id or None,
                language=language,
                page=page,
                per_page=per_page,
            ) or []
            if not batch:
                break

            for info in batch:
                if synced_for_query >= max_per_query:
                    break
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
                    synced_for_query += 1

            page += 1

    return synced_items


def sync_store_list(
    api: APIxoo,
    endpoint_name: str,
    type_flag: int,
    classify_id: int | None,
    per_page: int,
    max_items: int,
    output_root: Path,
    redownload: bool,
) -> list[SyncedItem]:
    synced_items: list[SyncedItem] = []
    endpoint = STORE_ENDPOINTS[endpoint_name]
    page = 1
    synced_total = 0
    collection_name = endpoint_name if classify_id is None else f"{endpoint_name}-classify-{classify_id}"

    while synced_total < max_items:
        batch = api.get_store_clock_list(
            type_flag=type_flag,
            classify_id=classify_id,
            page=page,
            per_page=per_page,
            endpoint=endpoint,
        ) or []
        if not batch:
            break

        for info in batch:
            if synced_total >= max_items:
                break
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
                synced_total += 1

        page += 1

    return synced_items


def fetch_store_classify(api: APIxoo) -> list[StoreClassifyItem]:
    classify_items = api.get_store_clock_classify() or []
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


def fetch_my_playlists(api: APIxoo, per_page: int) -> list[PlaylistManifestItem]:
    playlists = api.get_my_list(page=1, per_page=per_page) or []
    return build_playlist_manifest_items(playlists, owner="me", target_user_id=None)


def fetch_someone_playlists(api: APIxoo, target_user_ids: list[int], per_page: int) -> list[PlaylistManifestItem]:
    items: list[PlaylistManifestItem] = []
    for target_user_id in target_user_ids:
        playlists = api.get_someone_list(target_user_id=target_user_id, page=1, per_page=per_page) or []
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


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Sync 16x16 animations from Divoom's cloud into the native library.")
    parser.add_argument("--email", default=os.environ.get("DIVOOM_EMAIL"))
    parser.add_argument("--password", default=os.environ.get("DIVOOM_PASSWORD"))
    parser.add_argument("--md5-password", default=os.environ.get("DIVOOM_MD5_PASSWORD"))
    parser.add_argument("--category", action="append", dest="categories", help="Category name such as recommend, top, emoji, animal")
    parser.add_argument("--sort", action="append", dest="sorts", choices=["most-liked", "new-upload"], help="Category sort order to sync. Default is both.")
    parser.add_argument("--gallery-id", action="append", dest="gallery_ids", type=int, help="Fetch and decode a specific gallery ID using the direct GalleryInfo endpoint.")
    parser.add_argument("--per-page", type=int, default=40)
    parser.add_argument("--max-per-category", type=int, default=80)
    parser.add_argument("--max-albums", type=int, default=8)
    parser.add_argument("--per-album", type=int, default=24)
    parser.add_argument("--search-query", action="append", dest="search_queries", help="Run an iOS ItemSearch query and sync the returned 16x16 items.")
    parser.add_argument("--search-item-flag", default="0", help="Raw ItemFlag value for Channel/ItemSearch. Uses the exact iOS request key, not a guessed enum.")
    parser.add_argument("--search-item-id", type=int, default=0)
    parser.add_argument("--search-clock-id", type=int, default=0)
    parser.add_argument("--search-language", default="")
    parser.add_argument("--max-per-search", type=int, default=60)
    parser.add_argument("--include-my-list", action="store_true", help="Fetch Playlist/GetMyList metadata into the manifest.")
    parser.add_argument("--target-user-id", action="append", dest="target_user_ids", type=int, help="Fetch Playlist/GetSomeOneList metadata for a specific user ID.")
    parser.add_argument("--include-store-classify", action="store_true", help="Fetch Channel/StoreClockGetClassify metadata into the manifest.")
    parser.add_argument("--store-endpoint", choices=sorted(STORE_ENDPOINTS.keys()), default="list", help="Channel store endpoint family to sync when --store-flag is set.")
    parser.add_argument("--store-flag", type=int, help="Raw Flag value for the iOS store request shape. No guessed defaults are applied.")
    parser.add_argument("--store-classify-id", type=int)
    parser.add_argument("--like-gallery-id", type=int, help="Like or unlike a gallery via GalleryLikeV2 and exit.")
    parser.add_argument("--like-classify", type=int)
    parser.add_argument("--like-file-type", type=int)
    parser.add_argument("--unlike", action="store_true")
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

    if not args.email:
        print(json.dumps({
            "error": "missing_credentials",
            "message": "Set DIVOOM_EMAIL plus DIVOOM_PASSWORD or DIVOOM_MD5_PASSWORD before syncing.",
        }, indent=2), file=sys.stderr)
        return 2

    if not args.password and not args.md5_password:
        print(json.dumps({
            "error": "missing_credentials",
            "message": "Set DIVOOM_PASSWORD or DIVOOM_MD5_PASSWORD before syncing.",
        }, indent=2), file=sys.stderr)
        return 2

    api = APIxoo(
        email=args.email,
        password=args.password,
        md5_password=args.md5_password,
    )
    if not api.log_in():
        print(json.dumps({
            "error": "login_failed",
            "message": "Divoom cloud login failed. Check credentials.",
        }, indent=2), file=sys.stderr)
        return 1

    if args.like_gallery_id is not None:
        if args.like_classify is None or args.like_file_type is None:
            print(json.dumps({
                "error": "missing_like_arguments",
                "message": "Provide --like-classify and --like-file-type together with --like-gallery-id.",
            }, indent=2), file=sys.stderr)
            return 2
        response = api.gallery_like(
            gallery_id=args.like_gallery_id,
            is_like=not args.unlike,
            classify=args.like_classify,
            type_=args.like_file_type,
        )
        if not response:
            print(json.dumps({
                "error": "like_failed",
                "message": "GalleryLikeV2 did not return a usable response.",
            }, indent=2), file=sys.stderr)
            return 1
        print(json.dumps({
            "success": bool(response.get("ReturnCode", 1) == 0),
            "liked": not args.unlike,
            "galleryId": args.like_gallery_id,
            "response": response,
        }, indent=2, ensure_ascii=False))
        return 0 if response.get("ReturnCode", 1) == 0 else 1

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
    if args.store_flag is not None:
        synced_items.extend(
            sync_store_list(
                api=api,
                endpoint_name=args.store_endpoint,
                type_flag=args.store_flag,
                classify_id=args.store_classify_id,
                per_page=args.per_page,
                max_items=args.max_per_category,
                output_root=args.output_root,
                redownload=args.redownload,
            )
        )
    synced_items = dedupe_synced_items(synced_items)
    store_classify = fetch_store_classify(api) if args.include_store_classify else []
    my_playlists = fetch_my_playlists(api, per_page=args.per_page) if args.include_my_list else []
    someone_playlists = fetch_someone_playlists(api, target_user_ids=target_user_ids, per_page=args.per_page) if target_user_ids else []

    manifest = {
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "source": "divoom-cloud",
        "apiClient": "redphx/apixoo",
        "apiCoverage": [
            "UserLogin",
            "Cloud/GalleryInfo",
            "GetCategoryFileListV2",
            "Discover/GetAlbumListV3",
            "Discover/GetAlbumImageListV3",
            "Channel/ItemSearch",
            "GalleryLikeV2",
            "Playlist/GetMyList",
            "Playlist/GetSomeOneList",
            "Channel/StoreClockGetClassify",
            "Channel/StoreClockGetList",
            "Channel/StoreTop20",
            "Channel/StoreNew20",
            "download",
        ],
        "outputRoot": str(args.output_root),
        "itemCount": len(synced_items),
        "categories": categories,
        "sorts": [value.lower().replace("_", "-") for value in sorts],
        "includesAlbums": not args.skip_albums,
        "galleryIdsRequested": gallery_ids,
        "searchQueries": search_queries,
        "storeEndpoint": args.store_endpoint if args.store_flag is not None else "",
        "storeFlag": args.store_flag,
        "storeClassifyId": args.store_classify_id,
        "storeClassify": [asdict(item) for item in store_classify],
        "myPlaylists": [asdict(item) for item in my_playlists],
        "someonePlaylists": [asdict(item) for item in someone_playlists],
        "items": [asdict(item) for item in synced_items],
    }
    args.manifest.write_text(json.dumps(manifest, indent=2, ensure_ascii=False), encoding="utf-8")
    print(json.dumps({
        "success": True,
        "itemCount": len(synced_items),
        "storeClassifyCount": len(store_classify),
        "myPlaylistCount": len(my_playlists),
        "someonePlaylistCount": len(someone_playlists),
        "outputRoot": str(args.output_root),
        "manifest": str(args.manifest),
    }, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
