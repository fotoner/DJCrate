#!/usr/bin/env python3
"""Claude Code PostToolUse(Edit|Write) 훅: Swift 소스·Package.swift·빚 목록을 고치면 모듈 경계 검사를 돌린다.

통과하면 조용히 끝난다. 위반이면 위반 줄만 표준 오류로 내고 종료 코드 2(도구는 이미 실행됨, 모델에게 알림).
빌드는 하지 않는다(같은 checkout 빌드 동시 실행 금지). 시험: scripts/test-harness.py
"""
import json
import subprocess
import sys
from pathlib import Path

WATCHED_SUFFIX = ".swift"
WATCHED_FILES = {"Package.swift", "scripts/import-debt.txt", "scripts/check-imports.py"}
MAX_LINES = 20


def repository_of(file_path):
    """고친 파일이 든 DJCrate 저장소(작업 트리) 뿌리. 다른 워크트리의 파일도 그 워크트리 기준으로 본다."""
    for folder in [file_path.parent, *file_path.parents]:
        if (folder / "scripts/check-imports.py").is_file() and (folder / "Package.swift").is_file():
            return folder
    return None


def watched(relative):
    if relative in WATCHED_FILES:
        return True
    return relative.endswith(WATCHED_SUFFIX) and relative.split("/", 1)[0] in ("Sources", "Tests")


def main():
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 0
    file_path = (data.get("tool_input") or {}).get("file_path")
    if not file_path:
        return 0
    path = Path(file_path)
    root = repository_of(path)
    if root is None:
        return 0
    try:
        relative = path.resolve().relative_to(root.resolve()).as_posix()
    except ValueError:
        return 0
    if not watched(relative):
        return 0
    try:
        result = subprocess.run([sys.executable, str(root / "scripts/check-imports.py")], cwd=root,
                                capture_output=True, text=True, timeout=60)
    except subprocess.TimeoutExpired:
        return 0
    if result.returncode == 0:
        return 0
    lines = [line for line in (result.stdout + result.stderr).splitlines() if line.startswith("✘")]
    if not lines:
        lines = (result.stdout + result.stderr).strip().splitlines()[-3:]
    shown = lines[:MAX_LINES]
    if len(lines) > MAX_LINES:
        shown.append(f"… 외 {len(lines) - MAX_LINES}줄(python3 scripts/check-imports.py)")
    print("모듈 경계 검사(scripts/check-imports.py) 위반:", file=sys.stderr)
    print("\n".join(shown), file=sys.stderr)
    print("새 위반은 빚 목록에 더하지 말고 고치세요. 갚은 빚은 scripts/import-debt.txt에서 그 줄을 지웁니다.", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
