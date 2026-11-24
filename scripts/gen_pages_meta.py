#!/usr/bin/env python3
"""Generate crawler/SEO artifacts for the Pages site (additive).

Produces llms.txt, robots.txt, sitemap.xml in the examples/ output dir.
"""
import pathlib, datetime

ROOT = pathlib.Path("examples")
BASE = "https://prompt-cult.github.io/json-type-definition-RFC-8927/"

# Collect HTML pages
pages = sorted(p.name for p in ROOT.glob("*.html"))
# include subdirs? keep top-level examples pages
extra = []
for sub in ROOT.iterdir():
    if sub.is_dir() and (sub / "index.html").exists():
        extra.append(f"{sub.name}/")

all_pages = pages + extra

# sitemap.xml
lines = ['<?xml version="1.0" encoding="UTF-8"?>',
         '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">']
for p in all_pages:
    loc = BASE + p
    lines.append("  <url>")
    lines.append(f"    <loc>{loc}</loc>")
    lines.append("  </url>")
lines.append("</urlset>")
(ROOT / "sitemap.xml").write_text("\n".join(lines) + "\n", encoding="utf-8")

# robots.txt
(ROOT / "robots.txt").write_text(
    "User-agent: *\nAllow: /\n\nSitemap: " + BASE + "sitemap.xml\n", encoding="utf-8")

# llms.txt
ll = ["# JSON Type Definition (RFC 8927) — jtd-wasm",
      "",
      "> Ahead-of-time validator code generator for JSON Type Definition schemas.",
      "",
      "Examples and generated validators:",
      ""]
for p in all_pages:
    ll.append(f"- {BASE}{p}")
(ROOT / "llms.txt").write_text("\n".join(ll) + "\n", encoding="utf-8")

print("generated llms.txt, robots.txt, sitemap.xml")
