"""nginx static asset performance rules: added when missing, never duplicated."""

from __future__ import annotations

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
SERVER_SCRIPTS_DIR = REPO_ROOT / "scripts" / "server"
if str(SERVER_SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SERVER_SCRIPTS_DIR))

import nginx_performance as perf  # noqa: E402

# Shape of the live site after certbot: an HTTP redirect block and the HTTPS SPA block.
LIVE_SITE = """map $http_upgrade $fair_stand_connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    if ($host = fuar.kyrox.studio) {
        return 301 https://$host$request_uri;
    } # managed by Certbot
    listen 80;
    server_name fuar.kyrox.studio;
    return 404; # managed by Certbot
}

server {
    server_name fuar.kyrox.studio; # managed by Certbot
    root /opt/kyrox/kyrox-fair-crm/frontend/dist;
    index index.html;

    location /api/ {
        proxy_pass http://127.0.0.1:8001;
    }

    location / {
        try_files $uri $uri/ /index.html;
    }

    listen 443 ssl; # managed by Certbot
    include /etc/letsencrypt/options-ssl-nginx.conf; # managed by Certbot
}
"""

# Ubuntu's stock gzip section: only `gzip on` is active.
UBUNTU_NGINX_CONF = """http {
    gzip on;

    # gzip_vary on;
    # gzip_proxied any;
    # gzip_comp_level 6;
    # gzip_types text/plain text/css application/json application/javascript;

    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
"""


def _spa_block(text: str) -> str:
    return text[text.index("server_name fuar.kyrox.studio; # managed by Certbot") :]


def test_live_site_gets_every_cache_rule_once_in_the_spa_block_only() -> None:
    patched = perf.patch_site(LIVE_SITE)

    spa = _spa_block(patched)
    for marker, _ in perf.CACHE_BLOCKS:
        assert patched.count(marker) == 1, marker
        assert marker in spa, marker
    # The certbot redirect block has no SPA fallback and stays as it was.
    redirect_block = patched[: patched.index("server_name fuar.kyrox.studio; # managed by Certbot")]
    assert redirect_block == LIVE_SITE[: LIVE_SITE.index("server_name fuar.kyrox.studio; # managed by Certbot")]
    # Rules sit before the SPA fallback; existing lines stay.
    assert spa.index("location ^~ /assets/") < spa.index("location / {")
    assert "proxy_pass http://127.0.0.1:8001;" in patched
    assert "include /etc/letsencrypt/options-ssl-nginx.conf;" in patched
    assert perf.site_has_cache_rules(patched)
    assert not perf.site_has_cache_rules(LIVE_SITE)


def test_cache_values_match_the_file_naming() -> None:
    patched = perf.patch_site(LIVE_SITE)
    assets = patched[patched.index("location ^~ /assets/") :]
    assert 'Cache-Control "public, max-age=31536000, immutable";' in assets.split("}", 1)[0]
    # No "always": a 404 for a missing hash must not be cached for a year.
    assert "always" not in assets.split("}", 1)[0]
    index_html = patched[patched.index("location = /index.html") :]
    assert 'Cache-Control "no-cache" always;' in index_html.split("}", 1)[0]
    models = patched[patched.index("location ^~ /models/") :]
    assert "model/gltf-binary glb;" in models
    assert 'Cache-Control "no-cache" always;' in models
    assert "immutable" not in models.split("location ^~ /textures/", 1)[0]


def test_rerun_changes_nothing() -> None:
    once = perf.patch_site(LIVE_SITE)
    assert perf.patch_site(once) == once


def test_hand_written_assets_location_is_kept_and_not_duplicated() -> None:
    custom = LIVE_SITE.replace(
        "    location / {",
        "    location ^~ /assets/ {\n        expires 7d;\n    }\n\n    location / {",
    )
    patched = perf.patch_site(custom)
    assert patched.count("location ^~ /assets/") == 1
    assert "expires 7d;" in patched
    assert "location = /index.html" in patched


def test_commented_out_rule_does_not_count_as_present() -> None:
    commented = LIVE_SITE.replace("    location / {", "    # location ^~ /assets/ {}\n    location / {")
    patched = perf.patch_site(commented)
    assert "\n    location ^~ /assets/ {" in patched


def test_template_already_carries_the_rules() -> None:
    template = (SERVER_SCRIPTS_DIR / "nginx" / "fair-crm.conf").read_text(encoding="utf-8").replace("\r\n", "\n")
    assert perf.site_has_cache_rules(template)
    assert perf.patch_site(template) == template


def test_gzip_conf_leaves_out_directives_nginx_conf_already_sets() -> None:
    rendered = perf.render_gzip_conf(perf.active_http_directives(UBUNTU_NGINX_CONF))
    assert rendered.startswith(perf.GZIP_MARKER)
    assert "\ngzip on;" not in rendered
    for directive in ("gzip_vary on;", "gzip_proxied any;", "gzip_comp_level 6;", "gzip_min_length 1024;"):
        assert directive in rendered
    types_line = next(line for line in rendered.splitlines() if line.startswith("gzip_types "))
    for mime in ("application/javascript", "text/css", "application/json", "model/gltf-binary"):
        assert mime in types_line
    # text/html is always compressed; listing it again makes nginx warn.
    assert "text/html" not in types_line

    tuned = UBUNTU_NGINX_CONF.replace("# gzip_vary on;", "gzip_vary on;")
    assert "gzip_vary" not in perf.render_gzip_conf(perf.active_http_directives(tuned))


def test_main_writes_site_and_gzip_conf_then_is_a_no_op(tmp_path: Path) -> None:
    site = tmp_path / "fair-crm"
    nginx_conf = tmp_path / "nginx.conf"
    conf_d = tmp_path / "conf.d"
    gzip_conf = conf_d / "kyrox-gzip.conf"
    site.write_text(LIVE_SITE, encoding="utf-8")
    nginx_conf.write_text(UBUNTU_NGINX_CONF, encoding="utf-8")
    args = ["--site", str(site), "--nginx-conf", str(nginx_conf), "--gzip-conf", str(gzip_conf)]

    assert perf.main(["--site", str(site), "--check-site"]) == 1
    assert perf.main(args) == 0
    assert perf.main(["--site", str(site), "--check-site"]) == 0
    first_site = site.read_text(encoding="utf-8")
    first_gzip = gzip_conf.read_text(encoding="utf-8")
    assert "gzip_types" in first_gzip

    assert perf.main(args) == 0
    assert site.read_text(encoding="utf-8") == first_site
    assert gzip_conf.read_text(encoding="utf-8") == first_gzip


def test_gzip_conf_written_by_hand_is_left_alone(tmp_path: Path) -> None:
    site = tmp_path / "fair-crm"
    nginx_conf = tmp_path / "nginx.conf"
    gzip_conf = tmp_path / "conf.d" / "kyrox-gzip.conf"
    gzip_conf.parent.mkdir()
    site.write_text(LIVE_SITE, encoding="utf-8")
    nginx_conf.write_text(UBUNTU_NGINX_CONF, encoding="utf-8")
    gzip_conf.write_text("gzip_comp_level 4;\n", encoding="utf-8")

    perf.main(["--site", str(site), "--nginx-conf", str(nginx_conf), "--gzip-conf", str(gzip_conf)])
    assert gzip_conf.read_text(encoding="utf-8") == "gzip_comp_level 4;\n"


def test_other_conf_d_file_setting_gzip_types_is_respected(tmp_path: Path) -> None:
    site = tmp_path / "fair-crm"
    nginx_conf = tmp_path / "nginx.conf"
    conf_d = tmp_path / "conf.d"
    conf_d.mkdir()
    (conf_d / "other.conf").write_text("gzip_types text/css;\n", encoding="utf-8")
    gzip_conf = conf_d / "kyrox-gzip.conf"
    site.write_text(LIVE_SITE, encoding="utf-8")
    nginx_conf.write_text(UBUNTU_NGINX_CONF, encoding="utf-8")

    perf.main(["--site", str(site), "--nginx-conf", str(nginx_conf), "--gzip-conf", str(gzip_conf)])
    assert "gzip_types" not in gzip_conf.read_text(encoding="utf-8")
