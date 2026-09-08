#!/usr/bin/env python3
import argparse
import posixpath
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlsplit

COMPONENTS = {
    "Header.dc.html",
    "Footer.dc.html",
    "BlogPost.dc.html",
    "InfoPage.dc.html",
    "ProductPage.dc.html",
}


def build_routes(root):
    routes = {}
    for source in root.glob("*.dc.html"):
        if source.name in COMPONENTS:
            continue
        name = source.name[:-8]
        slug = "-".join(part for part in "".join(
            char.lower() if char.isalnum() else " " for char in name
        ).split())
        routes[slug] = source.name
    return routes


def create_handler(root, routes):
    class RouteHandler(SimpleHTTPRequestHandler):
        def translate_path(self, request_path):
            path = unquote(urlsplit(request_path).path)
            path = posixpath.normpath(path).lstrip("/")
            parts = path.split("/") if path else []

            if not parts:
                return str(root)

            if len(parts) == 1 and parts[0] in routes:
                return str(root / routes[parts[0]])

            if len(parts) > 1 and parts[0] in routes:
                nested = root.joinpath(*parts[1:])
                if nested.is_file():
                    return str(nested)

            candidate = root.joinpath(*parts)
            if candidate.is_file():
                return str(candidate)
            return str(root / "__missing_route__")

    return RouteHandler


def main():
    parser = argparse.ArgumentParser(description="Serve the site with clean local routes.")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8000)
    args = parser.parse_args()

    root = Path(__file__).resolve().parent
    routes = build_routes(root)
    handler = create_handler(root, routes)
    server = ThreadingHTTPServer((args.host, args.port), handler)
    print(f"Serving {root} at http://{args.host}:{args.port}/")
    print(f"Loaded {len(routes)} clean routes")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
