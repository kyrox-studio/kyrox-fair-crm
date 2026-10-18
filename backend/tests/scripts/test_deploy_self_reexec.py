"""deploy-all.sh restarts once with its new version when the fair-crm pull changes it."""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[3]
SERVER_SCRIPTS_DIR = REPO_ROOT / "scripts" / "server"
COMMON_SH = SERVER_SCRIPTS_DIR / "lib" / "common.sh"
DEPLOY_ALL = SERVER_SCRIPTS_DIR / "deploy-all.sh"

BASH = shutil.which("bash")
GIT = shutil.which("git")

pytestmark = [
    pytest.mark.skipif(BASH is None or GIT is None, reason="bash and git required"),
    # System32\bash.exe is WSL and cannot see the Windows temp paths.
    pytest.mark.skipif(
        sys.platform == "win32" and "system32" in (BASH or "").lower(),
        reason="WSL bash cannot run against Windows paths",
    ),
]

# Same shape as deploy-all.sh main(): fingerprint, pull, re-exec check, then work.
FAKE_DEPLOY = """#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${{BASH_SOURCE[0]}}")" && pwd)"
source "${{SCRIPT_DIR}}/lib/common.sh"
FAIR_CRM_DIR="$(cd "${{SCRIPT_DIR}}/../.." && pwd)"
before="$(deploy_scripts_fingerprint "$FAIR_CRM_DIR")"
git -C "$FAIR_CRM_DIR" pull -q --ff-only origin main
reexec_deploy_if_scripts_changed \\
  "$FAIR_CRM_DIR" "$before" "${{FAIR_CRM_DIR}}/scripts/server/deploy-all.sh" "$@"
echo "WORK version={version} args=$* reexec=${{KYROX_DEPLOY_REEXECED:-0}}"
"""


def _git(cwd: Path, *args: str) -> None:
    subprocess.run([GIT, *args], cwd=cwd, check=True, capture_output=True)


def _write_scripts(root: Path, version: str, common_extra: str = "") -> None:
    lib = root / "scripts" / "server" / "lib"
    lib.mkdir(parents=True, exist_ok=True)
    common = COMMON_SH.read_text(encoding="utf-8") + common_extra
    (lib / "common.sh").write_bytes(common.encode("utf-8"))
    (root / "scripts" / "server" / "deploy-all.sh").write_bytes(
        FAKE_DEPLOY.format(version=version).encode("utf-8")
    )


def _commit_all(cwd: Path, message: str) -> None:
    _git(cwd, "add", "-A")
    _git(cwd, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", message)


@pytest.fixture
def repos(tmp_path: Path) -> tuple[Path, Path]:
    """Return (author checkout that pushes, server checkout that deploys)."""
    origin = tmp_path / "origin.git"
    _git(tmp_path, "init", "-q", "--bare", "-b", "main", origin.as_posix())
    author = tmp_path / "author"
    _git(tmp_path, "clone", "-q", origin.as_posix(), author.as_posix())
    _git(author, "checkout", "-q", "-b", "main")
    _write_scripts(author, "v1")
    _commit_all(author, "v1")
    _git(author, "push", "-q", "origin", "main")
    server = tmp_path / "server"
    _git(tmp_path, "clone", "-q", origin.as_posix(), server.as_posix())
    return author, server


def _run_deploy(server: Path, *args: str, env_extra: dict[str, str] | None = None) -> str:
    env = {k: v for k, v in os.environ.items() if k != "KYROX_DEPLOY_REEXECED"}
    env.update(env_extra or {})
    script = (server / "scripts" / "server" / "deploy-all.sh").as_posix()
    result = subprocess.run(
        [BASH, script, *args], capture_output=True, text=True, env=env, check=False
    )
    assert result.returncode == 0, result.stdout + result.stderr
    return result.stdout + result.stderr


def _push(author: Path, version: str, common_extra: str = "") -> None:
    _write_scripts(author, version, common_extra)
    _commit_all(author, version)
    _git(author, "push", "-q", "origin", "main")


def test_unchanged_scripts_run_once_without_restart(repos: tuple[Path, Path]) -> None:
    _, server = repos
    out = _run_deploy(server, "--flag")
    assert re.findall(r"WORK .*", out) == ["WORK version=v1 args=--flag reexec=0"]
    assert "restarting with the new version" not in out


def test_changed_deploy_script_restarts_once_with_new_version(
    repos: tuple[Path, Path],
) -> None:
    author, server = repos
    _push(author, "v2")
    out = _run_deploy(server, "--flag", "two words")
    # Old version never reaches the work part; new version runs exactly once.
    assert re.findall(r"WORK .*", out) == ["WORK version=v2 args=--flag two words reexec=1"]
    assert out.count("restarting with the new version") == 1


def test_changed_common_sh_also_restarts(repos: tuple[Path, Path]) -> None:
    author, server = repos
    _push(author, "v1", common_extra="\n# helper changed\n")
    out = _run_deploy(server)
    assert re.findall(r"WORK .*", out) == ["WORK version=v1 args= reexec=1"]


def test_guard_prevents_second_restart(repos: tuple[Path, Path]) -> None:
    author, server = repos
    _push(author, "v2")
    out = _run_deploy(server, env_extra={"KYROX_DEPLOY_REEXECED": "1"})
    # Already restarted once: keep running the in-memory version, no loop.
    assert re.findall(r"WORK .*", out) == ["WORK version=v1 args= reexec=1"]
    assert "continuing with the running version" in out


def test_deploy_all_fingerprints_before_restore_and_checks_after_pull() -> None:
    text = DEPLOY_ALL.read_text(encoding="utf-8")
    main_body = text[text.index("main() {") :]
    fingerprint = main_body.index('deploy_scripts_before="$(deploy_scripts_fingerprint')
    restore = main_body.index('restore_safe_fair_crm_deploy_files "$FAIR_CRM_DIR"')
    pull = main_body.index('clone_or_update_repo "$FAIR_CRM_DIR"')
    reexec = main_body.index("reexec_deploy_if_scripts_changed")
    setup = main_body.index("setup_python_project")
    assert fingerprint < restore < pull < reexec < setup
    assert '"$deploy_scripts_before"' in main_body[reexec : reexec + 300]
    assert '"$@"' in main_body[reexec : reexec + 300]
