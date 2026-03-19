#!/usr/bin/env python3
from __future__ import annotations

import html
import json
import os
import re
from collections import Counter
from pathlib import Path
from urllib.parse import quote

ROOT = Path("/Users/kirniy/dev/divoom")
CURATED_ROOT = ROOT / "assets/16x16/curated"
OUTPUT_PATH = ROOT / "docs/animation-gallery/index.html"


def quoted_relative_url(target: Path, base: Path) -> str:
    relative = Path(os.path.relpath(target, base))
    return "/".join(quote(part) for part in relative.parts)


def prettify_name(path: Path) -> str:
    stem = path.stem
    stem = re.sub(r"[_-]\d{4,}$", "", stem)
    stem = stem.replace("_", " ").replace("-", " ")
    stem = re.sub(r"\s+", " ", stem).strip()
    return stem or path.name


def build_manifest() -> list[dict[str, str]]:
    manifest: list[dict[str, str]] = []
    for asset_path in sorted(CURATED_ROOT.rglob("*")):
        if not asset_path.is_file():
            continue
        if asset_path.suffix.lower() != ".gif":
            continue

        relative = asset_path.relative_to(CURATED_ROOT)
        parts = relative.parts
        if not parts:
            continue

        category = parts[0]
        collection = parts[1] if len(parts) > 2 else (parts[1] if len(parts) == 2 else "")
        title = prettify_name(asset_path)

        manifest.append(
            {
                "id": relative.as_posix(),
                "title": title,
                "category": category,
                "collection": collection,
                "relativePath": relative.as_posix(),
                "previewURL": quoted_relative_url(asset_path, OUTPUT_PATH.parent),
                "sourceURL": quoted_relative_url(asset_path, OUTPUT_PATH.parent),
                "absolutePath": str(asset_path),
            }
        )

    return manifest


def build_html(manifest: list[dict[str, str]]) -> str:
    total_assets = len(manifest)
    counts = Counter(entry["category"] for entry in manifest)
    category_summary = " · ".join(
        f"{category.replace('-', ' ').title()} {count}"
        for category, count in counts.most_common()
    )
    manifest_json = json.dumps(manifest, ensure_ascii=False).replace("</", "<\\/")
    subtitle = (
        f"{total_assets} curated 16x16 animated GIFs. "
        f"Search, favorite, reveal, and send directly to the Ditoo from this page."
    )

    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Ditoo Motion Library</title>
  <style>
    :root {{
      --bg: #f3eee6;
      --panel: rgba(255, 251, 246, 0.82);
      --panel-strong: rgba(255, 248, 239, 0.96);
      --line: rgba(48, 35, 23, 0.12);
      --text: #1e1711;
      --muted: #6f5f50;
      --accent: #f06b27;
      --accent-2: #0b8f7a;
      --shadow: 0 18px 60px rgba(72, 47, 24, 0.12);
      --radius: 24px;
    }}

    * {{
      box-sizing: border-box;
    }}

    html, body {{
      margin: 0;
      min-height: 100%;
      background:
        radial-gradient(circle at top left, rgba(240, 107, 39, 0.16), transparent 32%),
        radial-gradient(circle at top right, rgba(11, 143, 122, 0.12), transparent 30%),
        linear-gradient(180deg, #f7f2eb 0%, #efe6da 100%);
      color: var(--text);
      font-family: "Avenir Next", "Neue Haas Grotesk Text Pro", "Helvetica Neue", sans-serif;
    }}

    body {{
      padding: 32px;
    }}

    .shell {{
      max-width: 1560px;
      margin: 0 auto;
      display: grid;
      gap: 24px;
    }}

    .hero {{
      display: grid;
      gap: 16px;
      grid-template-columns: 1.2fr 0.8fr;
      align-items: stretch;
    }}

    .hero-card, .toolbar, .sidebar, .gallery-card {{
      background: var(--panel);
      backdrop-filter: blur(16px);
      border: 1px solid var(--line);
      border-radius: var(--radius);
      box-shadow: var(--shadow);
    }}

    .hero-main {{
      padding: 28px;
      background:
        linear-gradient(135deg, rgba(255, 255, 255, 0.86), rgba(255, 245, 234, 0.82)),
        linear-gradient(120deg, rgba(240, 107, 39, 0.18), rgba(11, 143, 122, 0.10));
    }}

    .eyebrow {{
      display: inline-flex;
      align-items: center;
      gap: 8px;
      padding: 8px 12px;
      border-radius: 999px;
      background: rgba(255, 255, 255, 0.75);
      border: 1px solid rgba(0, 0, 0, 0.06);
      color: var(--muted);
      font-size: 12px;
      letter-spacing: 0.08em;
      text-transform: uppercase;
      font-weight: 700;
    }}

    h1 {{
      margin: 14px 0 10px;
      font-size: clamp(36px, 5vw, 60px);
      line-height: 0.95;
      letter-spacing: -0.04em;
    }}

    .subtitle {{
      margin: 0;
      max-width: 60ch;
      font-size: 16px;
      line-height: 1.5;
      color: var(--muted);
    }}

    .summary-grid {{
      display: grid;
      grid-template-columns: repeat(3, minmax(0, 1fr));
      gap: 14px;
      margin-top: 22px;
    }}

    .metric {{
      padding: 16px 18px;
      border-radius: 18px;
      background: rgba(255, 255, 255, 0.72);
      border: 1px solid rgba(0, 0, 0, 0.06);
    }}

    .metric strong {{
      display: block;
      font-size: 26px;
      line-height: 1;
      letter-spacing: -0.04em;
      margin-bottom: 6px;
    }}

    .metric span {{
      color: var(--muted);
      font-size: 13px;
    }}

    .hero-side {{
      padding: 24px;
      display: grid;
      gap: 12px;
      align-content: start;
    }}

    .hero-side h2 {{
      margin: 0;
      font-size: 15px;
      letter-spacing: 0.08em;
      text-transform: uppercase;
      color: var(--muted);
    }}

    .category-strip {{
      margin: 0;
      color: var(--muted);
      font-size: 14px;
      line-height: 1.6;
    }}

    .layout {{
      display: grid;
      grid-template-columns: 290px minmax(0, 1fr);
      gap: 24px;
      align-items: start;
    }}

    .sidebar {{
      position: sticky;
      top: 24px;
      padding: 20px;
      display: grid;
      gap: 18px;
    }}

    .sidebar h3, .toolbar h3 {{
      margin: 0;
      font-size: 14px;
      letter-spacing: 0.08em;
      text-transform: uppercase;
      color: var(--muted);
    }}

    .toolbar {{
      padding: 18px;
      display: grid;
      gap: 16px;
      margin-bottom: 18px;
    }}

    .search-input {{
      width: 100%;
      padding: 15px 16px;
      border-radius: 16px;
      border: 1px solid rgba(0, 0, 0, 0.09);
      background: rgba(255, 255, 255, 0.9);
      color: var(--text);
      font-size: 15px;
      outline: none;
    }}

    .search-input:focus {{
      border-color: rgba(240, 107, 39, 0.6);
      box-shadow: 0 0 0 4px rgba(240, 107, 39, 0.12);
    }}

    .toggle-row, .stats-row {{
      display: flex;
      flex-wrap: wrap;
      gap: 10px;
      align-items: center;
    }}

    .pill,
    .ghost-button,
    .send-button,
    .reveal-button,
    .favorite-button {{
      appearance: none;
      border: 0;
      cursor: pointer;
      transition: transform 140ms ease, box-shadow 140ms ease, background 140ms ease, color 140ms ease;
      font: inherit;
    }}

    .pill {{
      display: inline-flex;
      align-items: center;
      justify-content: space-between;
      gap: 8px;
      width: 100%;
      padding: 11px 12px;
      border-radius: 14px;
      background: rgba(255, 255, 255, 0.72);
      color: var(--text);
      text-align: left;
      border: 1px solid rgba(0, 0, 0, 0.06);
    }}

    .pill.active {{
      background: linear-gradient(135deg, rgba(240, 107, 39, 0.92), rgba(241, 145, 62, 0.95));
      color: white;
      box-shadow: 0 14px 30px rgba(240, 107, 39, 0.28);
    }}

    .pill small {{
      opacity: 0.75;
      font-size: 12px;
    }}

    .ghost-button {{
      padding: 10px 14px;
      border-radius: 999px;
      background: rgba(255, 255, 255, 0.74);
      color: var(--text);
      border: 1px solid rgba(0, 0, 0, 0.06);
    }}

    .ghost-button.active {{
      background: rgba(11, 143, 122, 0.14);
      color: #065f52;
      border-color: rgba(11, 143, 122, 0.22);
    }}

    .results {{
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(250px, 1fr));
      gap: 18px;
    }}

    .gallery-card {{
      padding: 16px;
      display: grid;
      gap: 14px;
    }}

    .preview-shell {{
      aspect-ratio: 1 / 1;
      border-radius: 18px;
      overflow: hidden;
      display: grid;
      place-items: center;
      background:
        radial-gradient(circle at 20% 20%, rgba(255, 255, 255, 0.78), transparent 22%),
        linear-gradient(145deg, rgba(255, 202, 172, 0.56), rgba(255, 255, 255, 0.88));
      border: 1px solid rgba(0, 0, 0, 0.06);
    }}

    .preview-shell img {{
      width: 100%;
      height: 100%;
      object-fit: contain;
      image-rendering: pixelated;
      image-rendering: crisp-edges;
      filter: saturate(1.06) contrast(1.02);
    }}

    .card-top {{
      display: grid;
      gap: 8px;
    }}

    .badge-row {{
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
    }}

    .badge {{
      display: inline-flex;
      align-items: center;
      gap: 6px;
      padding: 6px 9px;
      border-radius: 999px;
      background: rgba(0, 0, 0, 0.05);
      color: var(--muted);
      font-size: 11px;
      font-weight: 700;
      letter-spacing: 0.04em;
      text-transform: uppercase;
    }}

    .card-title {{
      margin: 0;
      font-size: 20px;
      line-height: 1.05;
      letter-spacing: -0.03em;
    }}

    .card-meta {{
      color: var(--muted);
      font-size: 13px;
      line-height: 1.45;
      min-height: 36px;
    }}

    .card-actions {{
      display: grid;
      grid-template-columns: 1fr auto auto;
      gap: 8px;
    }}

    .send-button {{
      padding: 12px 14px;
      border-radius: 14px;
      background: linear-gradient(135deg, #111111, #3f352c);
      color: white;
      font-weight: 700;
      letter-spacing: 0.01em;
      box-shadow: 0 14px 26px rgba(17, 17, 17, 0.18);
    }}

    .reveal-button,
    .favorite-button {{
      min-width: 46px;
      padding: 12px;
      border-radius: 14px;
      background: rgba(255, 255, 255, 0.86);
      color: var(--text);
      border: 1px solid rgba(0, 0, 0, 0.08);
      font-weight: 700;
    }}

    .favorite-button.active {{
      background: rgba(240, 107, 39, 0.12);
      color: #b2450e;
      border-color: rgba(240, 107, 39, 0.2);
    }}

    .empty-state {{
      padding: 38px;
      border-radius: 22px;
      background: rgba(255, 255, 255, 0.7);
      border: 1px dashed rgba(0, 0, 0, 0.12);
      color: var(--muted);
      text-align: center;
      font-size: 15px;
    }}

    .microcopy {{
      color: var(--muted);
      font-size: 13px;
      line-height: 1.5;
    }}

    @media (max-width: 1080px) {{
      .hero,
      .layout {{
        grid-template-columns: 1fr;
      }}

      .sidebar {{
        position: static;
      }}
    }}
  </style>
</head>
<body>
  <div class="shell">
    <section class="hero">
      <div class="hero-card hero-main">
        <div class="eyebrow">Ditoo Motion Library</div>
        <h1>Curated motion, actually usable.</h1>
        <p class="subtitle">{html.escape(subtitle)}</p>
        <div class="summary-grid">
          <div class="metric">
            <strong>{total_assets}</strong>
            <span>animated GIFs, all 16x16 and ready for browsing</span>
          </div>
          <div class="metric">
            <strong>{len(counts)}</strong>
            <span>top-level categories to filter and explore</span>
          </div>
          <div class="metric">
            <strong>Send</strong>
            <span>every card can trigger the working Mac-native Ditoo pipeline</span>
          </div>
        </div>
      </div>
      <div class="hero-card hero-side">
        <h2>Collection Split</h2>
        <p class="category-strip">{html.escape(category_summary)}</p>
        <p class="microcopy">
          Favorites stay local in your browser. “Send” uses the custom <code>divoom-menubar://</code> URL scheme to hand the asset off to the running menu bar app.
        </p>
      </div>
    </section>

    <section class="layout">
      <aside class="sidebar">
        <div>
          <h3>Categories</h3>
          <div id="category-list" style="display:grid;gap:8px;margin-top:12px;"></div>
        </div>
        <div>
          <h3>Organize</h3>
          <div class="toggle-row" style="margin-top:12px;">
            <button class="ghost-button" id="favorites-toggle" type="button">Favorites Only</button>
            <button class="ghost-button" id="clear-search" type="button">Clear Search</button>
          </div>
        </div>
        <div>
          <h3>Tips</h3>
          <p class="microcopy" style="margin-top:12px;">
            Click the star to pin favorites. Click the folder to reveal the original file in Finder. Search matches title, category, collection, and path.
          </p>
        </div>
      </aside>

      <main>
        <section class="toolbar">
          <h3>Browse</h3>
          <input id="search" class="search-input" type="search" placeholder="Search nyan, bunny, weather, retro, cute, crab..." autocomplete="off">
          <div class="stats-row">
            <span class="badge" id="results-count">0 visible</span>
            <span class="badge" id="favorites-count">0 favorites</span>
            <span class="badge" id="active-category">All categories</span>
          </div>
        </section>
        <section id="results" class="results"></section>
      </main>
    </section>
  </div>

  <script id="manifest" type="application/json">{manifest_json}</script>
  <script>
    const LIBRARY = JSON.parse(document.getElementById("manifest").textContent);
    const FAVORITES_KEY = "divoom-animation-favorites";
    const state = {{
      query: "",
      category: "all",
      favoritesOnly: false,
    }};

    const searchInput = document.getElementById("search");
    const resultsNode = document.getElementById("results");
    const categoryList = document.getElementById("category-list");
    const resultsCount = document.getElementById("results-count");
    const favoritesCount = document.getElementById("favorites-count");
    const activeCategory = document.getElementById("active-category");
    const favoritesToggle = document.getElementById("favorites-toggle");
    const clearSearch = document.getElementById("clear-search");

    function readFavorites() {{
      try {{
        return new Set(JSON.parse(localStorage.getItem(FAVORITES_KEY) || "[]"));
      }} catch (_error) {{
        return new Set();
      }}
    }}

    function writeFavorites(favorites) {{
      localStorage.setItem(FAVORITES_KEY, JSON.stringify([...favorites].sort()));
    }}

    function titleCaseCategory(value) {{
      return value.replace(/[-_]/g, " ").replace(/\\b\\w/g, match => match.toUpperCase());
    }}

    function renderCategories() {{
      const favorites = readFavorites();
      const counts = new Map();
      counts.set("all", LIBRARY.length);
      for (const item of LIBRARY) {{
        counts.set(item.category, (counts.get(item.category) || 0) + 1);
      }}

      const ordered = ["all", ...[...counts.keys()].filter(key => key !== "all").sort()];
      categoryList.innerHTML = ordered.map(category => {{
        const label = category === "all" ? "All Categories" : titleCaseCategory(category);
        const active = state.category === category ? " active" : "";
        return `
          <button class="pill${{active}}" type="button" data-category="${{category}}">
            <span>${{label}}</span>
            <small>${{counts.get(category) || 0}}</small>
          </button>
        `;
      }}).join("");

      favoritesCount.textContent = `${{favorites.size}} favorites`;
      activeCategory.textContent = state.category === "all" ? "All categories" : titleCaseCategory(state.category);
      favoritesToggle.classList.toggle("active", state.favoritesOnly);
    }}

    function filteredLibrary() {{
      const favorites = readFavorites();
      const needle = state.query.trim().toLowerCase();

      return LIBRARY.filter(item => {{
        if (state.category !== "all" && item.category !== state.category) {{
          return false;
        }}
        if (state.favoritesOnly && !favorites.has(item.id)) {{
          return false;
        }}
        if (!needle) {{
          return true;
        }}
        const haystack = [
          item.title,
          item.category,
          item.collection,
          item.relativePath,
        ].join(" ").toLowerCase();
        return haystack.includes(needle);
      }});
    }}

    function renderResults() {{
      const favorites = readFavorites();
      const visible = filteredLibrary();
      resultsCount.textContent = `${{visible.length}} visible`;

      if (!visible.length) {{
        resultsNode.innerHTML = `<div class="empty-state">No animations matched the current filters.</div>`;
        return;
      }}

      resultsNode.innerHTML = visible.map(item => {{
        const collection = item.collection ? titleCaseCategory(item.collection) : "Root";
        const isFavorite = favorites.has(item.id);
        const star = isFavorite ? "★" : "☆";
        const favoriteClass = isFavorite ? " active" : "";

        return `
          <article class="gallery-card">
            <div class="preview-shell">
              <img src="${{item.previewURL}}" alt="${{item.title}}">
            </div>
            <div class="card-top">
              <div class="badge-row">
                <span class="badge">${{titleCaseCategory(item.category)}}</span>
                <span class="badge">${{collection}}</span>
              </div>
              <h2 class="card-title">${{item.title}}</h2>
              <div class="card-meta">${{item.relativePath}}</div>
            </div>
            <div class="card-actions">
              <button class="send-button" type="button" data-send="${{encodeURIComponent(item.absolutePath)}}">Send to Ditoo</button>
              <button class="favorite-button${{favoriteClass}}" type="button" title="Toggle favorite" data-favorite="${{encodeURIComponent(item.id)}}">${{star}}</button>
              <button class="reveal-button" type="button" title="Reveal in Finder" data-reveal="${{encodeURIComponent(item.absolutePath)}}">↗</button>
            </div>
          </article>
        `;
      }}).join("");
    }}

    document.addEventListener("click", event => {{
      const categoryButton = event.target.closest("[data-category]");
      if (categoryButton) {{
        state.category = categoryButton.dataset.category;
        renderCategories();
        renderResults();
        return;
      }}

      const sendButton = event.target.closest("[data-send]");
      if (sendButton) {{
        const path = decodeURIComponent(sendButton.dataset.send);
        window.location.href = `divoom-menubar://send-gif?path=${{encodeURIComponent(path)}}`;
        return;
      }}

      const revealButton = event.target.closest("[data-reveal]");
      if (revealButton) {{
        const path = decodeURIComponent(revealButton.dataset.reveal);
        window.location.href = `divoom-menubar://reveal?path=${{encodeURIComponent(path)}}`;
        return;
      }}

      const favoriteButton = event.target.closest("[data-favorite]");
      if (favoriteButton) {{
        const id = decodeURIComponent(favoriteButton.dataset.favorite);
        const favorites = readFavorites();
        if (favorites.has(id)) {{
          favorites.delete(id);
        }} else {{
          favorites.add(id);
        }}
        writeFavorites(favorites);
        renderCategories();
        renderResults();
      }}
    }});

    searchInput.addEventListener("input", () => {{
      state.query = searchInput.value;
      renderResults();
    }});

    favoritesToggle.addEventListener("click", () => {{
      state.favoritesOnly = !state.favoritesOnly;
      renderCategories();
      renderResults();
    }});

    clearSearch.addEventListener("click", () => {{
      searchInput.value = "";
      state.query = "";
      renderResults();
    }});

    renderCategories();
    renderResults();
  </script>
</body>
</html>
"""


def main() -> int:
    manifest = build_manifest()
    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT_PATH.write_text(build_html(manifest), encoding="utf-8")
    print(f"Wrote {OUTPUT_PATH} with {len(manifest)} entries")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
