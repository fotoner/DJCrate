#!/usr/bin/env python3
"""Claude Code Stop 훅: Swift 변경이 있는데 지금 작업 트리의 `--changed`·전체 검사 통과 기록이 없으면 경고만 한다(막지 않는다).

통과 기록은 scripts/check.sh가 쓰는 .build/check-logs/last-pass(한 줄, 탭으로 나눈 `이름=값`: v·mode·filter·head·tree·key·
log·…·scope·base)와 pass-history(같은 형식, 최근 200줄). `mode`가 changed·full이고 `tree`가 지금 작업 트리 해시
(`python3 scripts/affected-tests.py --worktree-tree`)와 같은 기록이 하나라도 있으면 검증된 것으로 본다(quick·coverage·
release·stress는 아님). `scope=none`(빌드·시험 없이 가벼운 검사만 돈 --changed)은 검증으로 보지 않는다. scope 칸이 없는 옛 줄은 본다. last-pass가 없거나 형식이 다르거나, affected-tests.py가 없거나 해시를 못 구하면 조용히 넘어간다.
경고는 systemMessage(사용자에게만 보임)다. 시험을 직접 돌리지 않는다. 시험: scripts/test-harness.py
"""
import json
import os
import subprocess
import sys
from pathlib import Path

VERIFIED_MODES = {"changed", "full"}
EXAMPLES = 3


def parse(line):
    """칸 사전 또는 None(형식이 다름). 탭으로 나눈 `이름=값`이고 mode·tree가 있어야 한다."""
    fields = dict(part.split("=", 1) for part in line.strip().split("\t") if "=" in part)
    return fields if fields.get("mode") and fields.get("tree") else None


def read_lines(path):
    try:
        return path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError):
        return []


def git(root, *arguments):
    result = subprocess.run(["git", "-C", str(root), *arguments], capture_output=True, text=True, timeout=20)
    return result.stdout if result.returncode == 0 else None


def changed_swift(root):
    out = git(root, "status", "--porcelain", "--untracked-files=all", "--", "Sources", "Tests",
              "Package.swift", "Package.resolved")
    if out is None:
        return []
    paths = []
    for line in out.splitlines():
        path = line[3:]
        if " -> " in path:
            path = path.split(" -> ", 1)[1]
        path = path.strip('"')
        if path.endswith(".swift") or path in ("Package.swift", "Package.resolved"):
            paths.append(path)
    return paths


def worktree_tree(root):
    script = root / "scripts/affected-tests.py"
    if not script.is_file():
        return None
    try:
        result = subprocess.run([sys.executable, str(script), "--worktree-tree"], cwd=root, capture_output=True,
                                text=True, timeout=25)
    except (OSError, subprocess.SubprocessError):
        return None
    value = result.stdout.strip()
    return value if result.returncode == 0 and value else None


def main():
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 0
    if data.get("stop_hook_active"):
        return 0
    top = git(Path(data.get("cwd") or "."), "rev-parse", "--show-toplevel")
    if not top:
        return 0
    root = Path(top.strip())
    log_root = Path(os.environ.get("DJC_CHECK_LOG_ROOT") or ".build/check-logs")
    log_root = log_root if log_root.is_absolute() else root / log_root
    last = next((parse(line) for line in read_lines(log_root / "last-pass")[:1]), None)
    if last is None:
        return 0
    changed = changed_swift(root)
    if not changed:
        return 0
    tree = worktree_tree(root)
    if tree is None:
        return 0
    records = [last] + [r for r in map(parse, read_lines(log_root / "pass-history")) if r]
    if any(r["mode"] in VERIFIED_MODES and r.get("scope") != "none" and r["tree"] == tree for r in records):
        return 0
    examples = ", ".join(changed[:EXAMPLES]) + (f" 외 {len(changed) - EXAMPLES}개" if len(changed) > EXAMPLES else "")
    where = last.get("log") or str(log_root / "last-pass")
    message = (f"Swift 변경 {len(changed)}개({examples})가 있는데 지금 작업 트리의 --changed·전체 검사 통과 기록이 없습니다"
               f"(마지막 통과: mode={last['mode']}, {where}). 끝났다고 하기 전에 scripts/check.sh --changed로 확인하세요.")
    print(json.dumps({"systemMessage": message}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
