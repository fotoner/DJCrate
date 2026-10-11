#!/bin/bash
# 워크트리 작업 표시. 두 세션이 같은 워크트리를 동시에 고치지 않게 한다(#167 h4b §6).
# 작업자는 시작할 때 take, 끝날 때 drop을 부른다. 표시 파일은 워크트리 뿌리의 .djc-worker.lock이다(.gitignore).
# 사용: scripts/worker-lock.sh take <작업 이름> [세션]   이미 있으면 그 내용을 보이고 종료 코드 1
#       scripts/worker-lock.sh drop <작업 이름>          다른 작업의 표시면 지우지 않고 종료 코드 1
#       scripts/worker-lock.sh show                       표시가 없으면 종료 코드 1
set -u

usage() {
    echo '사용: scripts/worker-lock.sh take <작업 이름> [세션] | drop <작업 이름> | show' >&2
    exit 2
}

root=$(git rev-parse --show-toplevel 2>/dev/null) || { echo 'git 작업 트리 안에서 부르세요.' >&2; exit 2; }
lock="$root/.djc-worker.lock"

case "${1:-}" in
    take)
        [[ -n "${2:-}" ]] || usage
        # noclobber로 만들어야 두 세션이 동시에 불러도 하나만 이긴다
        if ! (set -C; printf '작업: %s\n세션: %s\n시각: %s\n' "$2" "${3:-$PPID}" "$(date '+%Y-%m-%dT%H:%M:%S%z')" > "$lock") 2>/dev/null; then
            echo "이 워크트리에서 다른 작업이 진행 중입니다. 그 작업자에게 확인한 뒤 시작하세요($lock):" >&2
            cat "$lock" >&2 2>/dev/null
            exit 1
        fi
        echo "작업 표시를 만들었습니다: $lock" ;;
    drop)
        [[ -n "${2:-}" ]] || usage
        [[ -f "$lock" ]] || { echo '작업 표시가 없습니다.'; exit 0; }
        if [[ "$(sed -n 's/^작업: //p' "$lock")" != "$2" ]]; then
            echo "다른 작업의 표시라 지우지 않았습니다. 그 작업자에게 확인하세요($lock):" >&2
            cat "$lock" >&2
            exit 1
        fi
        rm -f "$lock"
        echo '작업 표시를 지웠습니다.' ;;
    show)
        [[ -f "$lock" ]] || { echo '작업 표시가 없습니다.'; exit 1; }
        cat "$lock" ;;
    *) usage ;;
esac
