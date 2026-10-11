#!/bin/zsh
# 단위 테스트를 커버리지와 함께 돌리고 파일별 줄 커버리지를 보여 준다.
# 사용: scripts/coverage.sh [파일 경로 필터(정규식)]
set -euo pipefail
cd "${0:A:h}/.."
swift test --enable-code-coverage > /dev/null 2>&1
PROF=.build/out/Products/Debug/codecov/default.profdata
bundles=(.build/out/Products/Debug/*Tests.xctest)
first="${bundles[1]}/Contents/MacOS/$(basename ${bundles[1]} .xctest)"
rest=()
for b in "${bundles[@]:1}"; do rest+=(-object "$b/Contents/MacOS/$(basename $b .xctest)"); done
xcrun llvm-cov report "$first" "${rest[@]}" -instr-profile "$PROF" -ignore-filename-regex='(checkouts|Tests|\.build)/' 2>/dev/null \
    | awk 'NF>=10 && $1 != "Filename" && $1 !~ /^-/ {printf "%-58s %s\n", $1, $10}' \
    | sed 's|.*/Sources/||' | grep -E "${1:-.}"
