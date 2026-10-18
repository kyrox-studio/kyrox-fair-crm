"""Static asset performance rules for the Fair CRM nginx site.

Called by apply-nginx-performance.sh on bootstrap and on every deploy. It only adds
what is missing, so reruns change nothing and hand-written lines stay as they are.

- gzip: JS, CSS, JSON, SVG and 3D models are compressed (Ubuntu ships with only
  text/html compressed). Written to a managed conf.d file in the http context; a
  directive that nginx.conf already sets is left out so nginx does not see it twice.
- cache: Vite output under /assets/ carries a content hash in its file name and stays
  in the browser for a year. index.html is revalidated on every visit so a new deploy
  shows at once. Fair Stand models and textures keep fixed names, so they are
  revalidated with ETag: an unchanged file answers 304 without a body.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

GZIP_MARKER = "# managed by apply-nginx-performance.sh"

GZIP_DIRECTIVES: tuple[tuple[str, str], ...] = (
    ("gzip", "on"),
    ("gzip_vary", "on"),
    ("gzip_proxied", "any"),
    ("gzip_comp_level", "6"),
    ("gzip_min_length", "1024"),
    (
        "gzip_types",
        "text/plain text/css text/javascript application/javascript application/json "
        "application/xml image/svg+xml model/gltf-binary model/gltf+json",
    ),
)

SPA_FALLBACK = re.compile(r"try_files\s+\$uri\s+\$uri/\s+/index\.html\s*;")

# (marker that shows the rule is present, block to insert)
CACHE_BLOCKS: tuple[tuple[str, str], ...] = (
    (
        "location ^~ /assets/",
        """# Vite output: the file name carries a content hash; keep it for a year.
# No "always": a 404 for a missing hash must not be cached for a year.
location ^~ /assets/ {
    add_header Cache-Control "public, max-age=31536000, immutable";
    try_files $uri =404;
}
""",
    ),
    (
        "location = /index.html",
        """# SPA entry: revalidate on every visit so a new deploy shows at once.
location = /index.html {
    add_header Cache-Control "no-cache" always;
}
""",
    ),
    (
        "location ^~ /models/",
        """# Fair Stand models: fixed names, revalidated with ETag (304 when unchanged).
location ^~ /models/ {
    types {
        model/gltf-binary glb;
        model/gltf+json gltf;
        text/plain txt;
    }
    add_header Cache-Control "no-cache" always;
    try_files $uri =404;
}
""",
    ),
    (
        "location ^~ /textures/",
        """# Fair Stand textures: fixed names, revalidated with ETag (304 when unchanged).
location ^~ /textures/ {
    add_header Cache-Control "no-cache" always;
    try_files $uri =404;
}
""",
    ),
)


def _strip_comments(text: str) -> str:
    return "\n".join(line.split("#", 1)[0] for line in text.splitlines())


def active_http_directives(*config_texts: str) -> set[str]:
    """Directive names that are set (not commented out) in the given config texts."""
    names: set[str] = set()
    wanted = {name for name, _ in GZIP_DIRECTIVES}
    for text in config_texts:
        for line in _strip_comments(text).splitlines():
            match = re.match(r"\s*([a-z_]+)\s", line)
            if match and match.group(1) in wanted:
                names.add(match.group(1))
    return names


def render_gzip_conf(already_set: set[str]) -> str:
    lines = [
        GZIP_MARKER,
        "# Compresses JS, CSS, JSON, SVG and 3D models. A directive that nginx.conf",
        "# already sets is left out here.",
    ]
    for name, value in GZIP_DIRECTIVES:
        if name not in already_set:
            lines.append(f"{name} {value};")
    return "\n".join(lines) + "\n"


def _split_servers(src: str) -> tuple[str, list[tuple[str, str, str]]]:
    matches = list(re.finditer(r"^[ \t]*server[ \t]*\{", src, re.M))
    if not matches:
        return src, []
    chunks = []
    cursor = 0
    for match in matches:
        brace = match.end() - 1
        depth = 1
        index = brace + 1
        while index < len(src) and depth:
            if src[index] == "{":
                depth += 1
            elif src[index] == "}":
                depth -= 1
            index += 1
        chunks.append((src[cursor : brace + 1], src[brace + 1 : index - 1], src[index - 1 : index]))
        cursor = index
    return src[cursor:], chunks


def _insert_before_root_location(body: str, block: str) -> str:
    lines = body.splitlines(keepends=True)
    for index, line in enumerate(lines):
        stripped = line.lstrip()
        if not re.match(r"location\s+/\s*\{", stripped):
            continue
        indent = line[: len(line) - len(stripped)]
        piece = "".join(indent + part if part.strip() else part for part in block.splitlines(keepends=True))
        return "".join(lines[:index]) + piece + "\n" + "".join(lines[index:])
    return body


def patch_site(text: str) -> str:
    """Add missing cache rules to every server block that serves the SPA."""
    tail, servers = _split_servers(text)
    if not servers:
        return text
    rebuilt: list[str] = []
    for prefix, body, closer in servers:
        if SPA_FALLBACK.search(_strip_comments(body)):
            active = _strip_comments(body)
            for marker, block in CACHE_BLOCKS:
                if marker not in active:
                    body = _insert_before_root_location(body, block)
        rebuilt.extend((prefix, body, closer))
    rebuilt.append(tail)
    return "".join(rebuilt)


def site_has_cache_rules(text: str) -> bool:
    _, servers = _split_servers(text)
    spa = [body for _, body, _ in servers if SPA_FALLBACK.search(_strip_comments(body))]
    return bool(spa) and all(
        marker in _strip_comments(body) for body in spa for marker, _ in CACHE_BLOCKS
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--site", required=True)
    parser.add_argument("--nginx-conf")
    parser.add_argument("--gzip-conf")
    parser.add_argument("--check-site", action="store_true", help="exit 1 when cache rules are missing; change nothing")
    args = parser.parse_args(argv)

    if args.check_site:
        return 0 if site_has_cache_rules(Path(args.site).read_text(encoding="utf-8")) else 1
    if not args.nginx_conf or not args.gzip_conf:
        parser.error("--nginx-conf and --gzip-conf are required unless --check-site is given")

    site = Path(args.site)
    nginx_conf = Path(args.nginx_conf)
    gzip_conf = Path(args.gzip_conf)

    if site.is_file():
        original = site.read_text(encoding="utf-8")
        patched = patch_site(original)
        if patched != original:
            site.write_text(patched, encoding="utf-8")
            print(f"cache rules added: {site}")

    main_text = nginx_conf.read_text(encoding="utf-8") if nginx_conf.is_file() else ""
    other_texts = [
        path.read_text(encoding="utf-8")
        for path in sorted(gzip_conf.parent.glob("*.conf"))
        if path != gzip_conf and gzip_conf.parent.is_dir()
    ]
    current = gzip_conf.read_text(encoding="utf-8") if gzip_conf.is_file() else None
    if current is not None and not current.startswith(GZIP_MARKER):
        print(f"left as is (not managed here): {gzip_conf}")
        return 0
    rendered = render_gzip_conf(active_http_directives(main_text, *other_texts))
    if rendered != current:
        gzip_conf.parent.mkdir(parents=True, exist_ok=True)
        gzip_conf.write_text(rendered, encoding="utf-8")
        print(f"gzip settings written: {gzip_conf}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
