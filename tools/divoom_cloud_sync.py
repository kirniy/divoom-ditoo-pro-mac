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


@dataclass
class SyncedItem:
    source: str
    scope: str
    category: str
    collection: str
    gallery_id: int
    file_id: str
    file_name: str
    likes: int
    views: int
    shares: int
    comments: int
    country: str
    user_name: str
    relative_path: str


def slugify(value: str) -> str:
    cleaned = re.sub(r"[^a-zA-Z0-9._-]+", "-", value.strip().lower())
    cleaned = re.sub(r"-{2,}", "-", cleaned).strip("-")
    return cleaned or "untitled"


def parse_category(name: str) -> GalleryCategory:
    normalized = name.strip().upper().replace("-", "_")
    return GalleryCategory[normalized]


def sync_gallery(
    api: APIxoo,
    info,
    source_scope: str,
    category_name: str,
    collection_name: str,
    output_root: Path,
    redownload: bool,
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
        category=category_name,
        collection=collection_name,
        gallery_id=gallery_id,
        file_id=str(getattr(info, "file_id", "")),
        file_name=file_name,
        likes=int(getattr(info, "total_likes", 0) or 0),
        views=int(getattr(info, "total_views", 0) or 0),
        shares=int(getattr(info, "total_shares", 0) or 0),
        comments=int(getattr(info, "total_comments", 0) or 0),
        country=str(getattr(info, "country_iso_code", "") or ""),
        user_name=str(getattr(getattr(info, "user", None), "user_name", "") or ""),
        relative_path=str(output_path.relative_to(output_root)),
    )


def sync_categories(
    api: APIxoo,
    category_names: list[str],
    per_page: int,
    max_per_category: int,
    output_root: Path,
    redownload: bool,
) -> list[SyncedItem]:
    items: list[SyncedItem] = []

    for category_name in category_names:
        category = parse_category(category_name)
        page = 1
        synced_for_category = 0

        while synced_for_category < max_per_category:
            batch = api.get_category_files(
                category=category,
                dimension=GalleryDimension.W16H16,
                sort=GallerySorting.MOST_LIKED,
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
    albums = api.get_album_list() or []

    for album in albums[:max_albums]:
        album_name = slugify(getattr(album, "album_name", "") or str(getattr(album, "album_id", "album")))
        files = api.get_album_files(int(getattr(album, "album_id", 0) or 0), page=1, per_page=per_album) or []
        for info in files:
            synced = sync_gallery(
                api=api,
                info=info,
                source_scope="album",
                category_name="albums",
                collection_name=album_name,
                output_root=output_root,
                redownload=redownload,
            )
            if synced is not None:
                synced_items.append(synced)

    return synced_items


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Sync 16x16 animations from Divoom's cloud into the native library.")
    parser.add_argument("--email", default=os.environ.get("DIVOOM_EMAIL"))
    parser.add_argument("--password", default=os.environ.get("DIVOOM_PASSWORD"))
    parser.add_argument("--md5-password", default=os.environ.get("DIVOOM_MD5_PASSWORD"))
    parser.add_argument("--category", action="append", dest="categories", help="Category name such as recommend, top, emoji, animal")
    parser.add_argument("--per-page", type=int, default=40)
    parser.add_argument("--max-per-category", type=int, default=80)
    parser.add_argument("--max-albums", type=int, default=8)
    parser.add_argument("--per-album", type=int, default=24)
    parser.add_argument("--skip-albums", action="store_true")
    parser.add_argument("--redownload", action="store_true")
    parser.add_argument("--output-root", type=Path, default=DEFAULT_OUTPUT_ROOT)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST_PATH)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    categories = args.categories or DEFAULT_CATEGORY_NAMES

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

    args.output_root.mkdir(parents=True, exist_ok=True)
    args.manifest.parent.mkdir(parents=True, exist_ok=True)

    synced_items = sync_categories(
        api=api,
        category_names=categories,
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

    manifest = {
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "source": "divoom-cloud",
        "outputRoot": str(args.output_root),
        "itemCount": len(synced_items),
        "categories": categories,
        "includesAlbums": not args.skip_albums,
        "items": [asdict(item) for item in synced_items],
    }
    args.manifest.write_text(json.dumps(manifest, indent=2, ensure_ascii=False), encoding="utf-8")
    print(json.dumps({
        "success": True,
        "itemCount": len(synced_items),
        "outputRoot": str(args.output_root),
        "manifest": str(args.manifest),
    }, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
