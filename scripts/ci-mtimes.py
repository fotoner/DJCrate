#!/usr/bin/env python3
"""CI 빌드 캐시와 함께 추적 파일의 수정 시각을 저장하고 되돌린다(.github/workflows/check.yml이 부른다).

체크아웃은 모든 파일의 수정 시각을 새로 매긴다. Swift 빌드는 수정 시각이 바뀐 소스를 다시 컴파일하므로, 받은 .build가
있어도 거의 전부 다시 컴파일했다(실제 저장소: 같은 내용 새 파일 72초 = cold 65초, 수정 시각을 되돌리면 1초).

  save     캐시를 저장하기 직전. 추적 파일의 내용 해시와 수정 시각을 .build/djc-source-mtimes.tsv에 적는다(캐시에 함께 들어간다).
  restore  캐시를 받은 직후. 지금 내용 해시가 기록과 같은 파일만 기록한 시각으로 되돌린다. 바뀐 파일·새 파일은 체크아웃 시각
           그대로 두어 다시 컴파일한다(캐시를 만든 빌드보다 늦은 시각이다). 기록이 없으면 아무것도 바꾸지 않는다.
"""
import os
import subprocess
import sys
from pathlib import Path

MANIFEST = Path(".build/djc-source-mtimes.tsv")


def tracked():
    """추적 파일(링크·하위 모듈 제외) → 작업 트리 내용의 blob 해시."""
    listed = subprocess.run(["git", "ls-files", "-z"], capture_output=True, check=True).stdout.decode().split("\0")
    paths = [p for p in listed if p and os.path.isfile(p) and not os.path.islink(p)]
    if not paths:
        return {}
    hashes = subprocess.run(["git", "hash-object", "--stdin-paths"], input="\n".join(paths) + "\n", capture_output=True,
                            text=True, check=True).stdout.split()
    if len(hashes) != len(paths):
        raise SystemExit("ci-mtimes: 내용 해시 수가 파일 수와 다릅니다")
    return dict(zip(paths, hashes))


def save():
    MANIFEST.parent.mkdir(parents=True, exist_ok=True)
    lines = [f"{blob}\t{os.stat(path).st_mtime_ns}\t{path}" for path, blob in sorted(tracked().items())]
    temporary = MANIFEST.with_suffix(".tmp")
    temporary.write_text("\n".join(lines) + "\n")
    temporary.replace(MANIFEST)
    print(f"ci-mtimes: 수정 시각 기록 {len(lines)}개({MANIFEST})")


def restore():
    if not MANIFEST.exists():
        print(f"ci-mtimes: 기록({MANIFEST})이 없어 수정 시각을 그대로 둡니다")
        return
    recorded = {}
    for line in MANIFEST.read_text().splitlines():
        blob, mtime, path = line.split("\t", 2)
        recorded[path] = (blob, int(mtime))
    restored = changed = 0
    for path, blob in tracked().items():
        if recorded.get(path, (None, 0))[0] != blob:
            changed += 1
            continue
        mtime = recorded[path][1]
        os.utime(path, ns=(mtime, mtime))
        restored += 1
    print(f"ci-mtimes: 되돌림 {restored}개, 바뀌었거나 새 파일 {changed}개(다시 컴파일)")


def main():
    if sys.argv[1:] == ["save"]:
        save()
    elif sys.argv[1:] == ["restore"]:
        restore()
    else:
        print("사용: scripts/ci-mtimes.py save|restore", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
