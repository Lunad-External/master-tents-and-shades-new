#!/usr/bin/env python3
"""Render every current DC page to static HTML using a real browser."""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import time
from pathlib import Path
from urllib.parse import quote

from playwright.sync_api import Error as PlaywrightError
from playwright.sync_api import sync_playwright


COMPONENTS = {
    "Header.dc.html",
    "Footer.dc.html",
    "BlogPost.dc.html",
    "InfoPage.dc.html",
    "ProductPage.dc.html",
}
STATIC_NAMES = {".git", "__pycache__", "dist", "prerendered"}


def slug_for(source: Path) -> str:
    name = source.name[:-8]
    slug = "-".join(
        "".join(char.lower() if char.isalnum() else " " for char in name).split()
    )
    return slug


def routes_for(root: Path) -> list[tuple[str, Path]]:
    routes = [("", root / "index.html")]
    for source in sorted(root.glob("*.dc.html")):
        if source.name not in COMPONENTS:
            routes.append((slug_for(source), source))
    return routes


def copy_static_files(root: Path, output: Path) -> None:
    for source in root.iterdir():
        if source.name in STATIC_NAMES or source.name in {"index.html"}:
            continue
        if source.name.endswith(".dc.html"):
            continue
        destination = output / source.name
        if source.is_dir():
            shutil.copytree(
                source,
                destination,
                dirs_exist_ok=True,
                ignore=shutil.ignore_patterns("index.html"),
            )
        else:
            shutil.copy2(source, destination)


def write_rendered_page(output: Path, slug: str, html: str) -> None:
    destination = output / "index.html" if not slug else output / slug / "index.html"
    destination.parent.mkdir(parents=True, exist_ok=True)
    base_tag = '<base href="/">'
    if "<base " not in html.lower():
        html = html.replace("<head>", f"<head>{base_tag}", 1)
    destination.write_text(html, encoding="utf-8")


def prerender(root: Path, output: Path, port: int) -> None:
    server = subprocess.Popen(
        [sys.executable, "-m", "http.server", str(port), "--bind", "127.0.0.1"],
        cwd=root,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        time.sleep(0.5)
        if server.poll() is not None:
            raise RuntimeError("The local static server exited before rendering pages")

        if output.exists():
            shutil.rmtree(output)
        output.mkdir(parents=True)
        copy_static_files(root, output)

        with sync_playwright() as playwright:
            failures: list[str] = []
            for slug, source in routes_for(root):
                route = "/" if not slug else f"/{slug}/"
                source_url = "/" if not slug else f"/{quote(source.name)}"
                browser = playwright.chromium.launch(headless=True)
                page = browser.new_page()
                try:
                    print(f"Rendering {route}", flush=True)
                    page.goto(f"http://127.0.0.1:{port}{source_url}", wait_until="commit", timeout=10_000)
                    page.wait_for_function(
                        "document.querySelector('#dc-root') && document.body.innerText.trim().length > 80",
                        timeout=15_000,
                    )
                    html = page.content()
                    if "<x-dc" in html.lower() or "#dc-root" not in html:
                        raise RuntimeError("the browser still contains the unrendered DC shell")
                    write_rendered_page(output, slug, html)
                    print(f"Rendered {route} from {source.name}")
                except (PlaywrightError, RuntimeError) as error:
                    failures.append(f"{route}: {error}")
                finally:
                    page.close()
                    browser.close()

        if failures:
            raise RuntimeError("Some pages could not be prerendered:\n" + "\n".join(failures))
    finally:
        server.terminate()
        try:
            server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server.kill()


def main() -> None:
    parser = argparse.ArgumentParser(description="Prerender all DC pages to static HTML.")
    parser.add_argument("--output", type=Path, default=Path("dist"))
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent
    output = args.output if args.output.is_absolute() else root / args.output
    prerender(root, output, args.port)
    print(f"Prerendered {len(routes_for(root))} pages into {output}")


if __name__ == "__main__":
    main()