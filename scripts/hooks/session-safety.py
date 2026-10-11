#!/usr/bin/env python3
"""Claude Code SessionStart(compact) 훅: 대화를 압축한 뒤 AGENTS.md의 안전 불변식 절을 다시 싣는다.

글은 AGENTS.md의 `## 안전 불변식` 절(다음 `## ` 앞까지)을 그대로 읽어 표준 출력으로 낸다(맥락에 더해진다).
같은 글을 두 곳에 두지 않으려고 여기에는 글을 적지 않는다. 절을 찾지 못하면 아무것도 내지 않는다.
시험: scripts/test-harness.py
"""
import json
import os
import sys
from pathlib import Path

HEADING = "## 안전 불변식"
LIMIT = 9000  # SessionStart 맥락 한 덩이 상한(10,000자) 안


def section(text):
    lines, found = [], False
    for line in text.splitlines():
        if line.startswith(HEADING):
            found = True
        elif found and line.startswith("## "):
            break
        if found:
            lines.append(line)
    return "\n".join(lines).strip() if found else ""


def main():
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        data = {}
    roots = [os.environ.get("CLAUDE_PROJECT_DIR"), data.get("cwd")]
    for root in filter(None, roots):
        agents = Path(root) / "AGENTS.md"
        if agents.is_file():
            body = section(agents.read_text(encoding="utf-8"))
            if body:
                print("대화를 압축했습니다. AGENTS.md의 안전 불변식을 다시 싣습니다(늘 지킨다):\n")
                print(body[:LIMIT])
            return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
