#!/bin/zsh
# 검사: 모듈 경계 규칙·문서·훅·시험 지도, 디버그·릴리스 앱, 번역, 시험, 쓰기 80%·코어 60% 커버리지. 인자가 없으면 전체 검사.
# 작업 끝·dev 합치기·PR CI는 --changed(바꾼 파일에서 고른 시험), 릴리스·요청은 전체를 쓴다(docs/ci.md).
set -euo pipefail
cd "${0:A:h}/.."

usage='사용: scripts/check.sh [--coverage|--release|--quick --filter <정규식>|--stress|--changed [--base <rev>]] [--no-reuse]'
# --no-reuse는 어느 모드에나 한 번 붙일 수 있다: 같은 작업 트리의 통과 기록이 있어도 다시 돌린다.
no_reuse=0
remaining=()
for argument in "$@"; do
    if [[ "$argument" == --no-reuse ]]; then (( ++no_reuse )); else remaining+=("$argument"); fi
done
if (( no_reuse > 1 )); then echo "$usage" >&2; exit 2; fi
set -- "${remaining[@]}"

# CI의 두 묶음과 개발 중 부분 검사를 나누되, 인자가 없으면 전체 검사를 유지한다.
test_filter=""
changed_base=""
case "$#:${1:-}" in
    0:) mode=full ;;
    1:--coverage) mode=coverage ;;
    1:--release) mode=release ;;
    1:--stress) mode=stress; test_filter=CipherColdOpenTests ;;
    1:--changed) mode=changed ;;
    3:--changed)
        if [[ "$2" != --base || -z "${3//[[:space:]]/}" || "$3" == --* ]]; then
            echo '--changed에는 --base <rev>만 더할 수 있습니다.' >&2
            echo "$usage" >&2
            exit 2
        fi
        mode=changed; changed_base=$3 ;;
    3:--quick)
        if [[ "$2" != --filter || -z "${3//[[:space:]]/}" || "$3" == --* ]]; then
            echo '--quick에는 --filter <비어 있지 않은 정규식>이 필요합니다.' >&2
            exit 2
        fi
        mode=quick; test_filter=$3 ;;
    *) echo "$usage" >&2; exit 2 ;;
esac
case "${DJC_CIPHER_STRESS-0}" in
    0|1) ;;
    *) echo 'DJC_CIPHER_STRESS는 미설정·0·1만 허용합니다.' >&2; exit 2 ;;
esac
if [[ "$mode" == stress ]]; then export DJC_CIPHER_STRESS=1; fi
# 시험 단계 멈춤 감시: 이 초 동안 시험 출력이 없으면 끝나지 않은 시험과 스택을 남기고 종료 코드 124로 끝낸다(0이면 끈다).
# CI 정상 실행의 가장 긴 출력 공백은 약 2분이었다. 멈춘 실행은 11분 동안 출력 없이 있다가 잡 제한(30분)으로 취소됐다.
stall_seconds=${DJC_CHECK_STALL_SECONDS-300}
if [[ "$stall_seconds" != <-> ]]; then
    echo 'DJC_CHECK_STALL_SECONDS는 0 이상의 정수(초)만 허용합니다. 0이면 멈춤 감시를 끕니다.' >&2
    exit 2
fi
requested_mode=$mode
# 릴리스 앱 빌드는 릴리스 검사(인자 없음·--release)에만 둔다. 넓힌 --changed는 전체 시험까지 돌되 이것은 뺀다.
release_build=0
if [[ "$mode" == full || "$mode" == release ]]; then release_build=1; fi

# --changed: 바꾼 파일에서 시험을 고른다(scripts/affected-tests.py). 고른 범위·이유를 먼저 보인다.
plan_scope="" plan_filter="" plan_targets="" plan_products="" plan_checks="" plan_widen="" plan_base=""
plan_suites="" plan_total_suites="" plan_text="" plan_json="" plan_required=""
if [[ "$mode" == changed ]]; then
    plan_arguments=(--shell)
    if [[ -n "$changed_base" ]]; then plan_arguments+=(--base "$changed_base"); fi
    if ! plan_output=$(python3 scripts/affected-tests.py "${plan_arguments[@]}"); then
        echo '바꾼 파일에서 시험을 고르지 못했습니다(위 오류). 전체가 필요하면 scripts/check.sh를 쓰세요.' >&2
        exit 2
    fi
    eval "$plan_output"
    print -r -- "$plan_text"
    if [[ "$plan_scope" == full ]]; then
        echo "▸ 전체 검사로 넓힙니다(릴리스 앱 빌드 뺌): $plan_widen"
        mode=full
    else
        test_filter=$plan_filter
    fi
fi

# 통과 기록 재사용: 같은 작업 트리(추적 안 된 파일 포함)·모드·필터·기준·툴체인·DJC_ 환경 변수의 통과 기록이 있으면
# 다시 돌리지 않는다. 같은 작업 트리의 전체 검사 통과는 --changed만 대신한다. --quick은 필터가 1개 이상 맞는지 봐야 하므로
# 같은 모드·필터의 기록만 쓴다(0개 맞는 필터는 늘 실패). stress는 늘 다시 돈다.
log_root=${DJC_CHECK_LOG_ROOT:-.build/check-logs}
reuse_tree=$(python3 scripts/affected-tests.py --worktree-tree 2>/dev/null) || reuse_tree=""
toolchain_id() {
    local developer=${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || true)} candidate
    print -r -- "$developer|${TOOLCHAINS-}"
    for candidate in "$developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift" "$developer/usr/bin/swift"; do
        if [[ -e "$candidate" ]]; then /usr/bin/stat -L -f '%N %z %m' "$candidate" 2>/dev/null || true; fi
    done
}
reuse_environment=$(env | grep '^DJC_' | grep -vE '^DJC_(HOME|REKORDBOX_DIR|CHECK_LOG_ROOT|TEST_DEFAULTS_PREFIX|CHECK_VERBOSE|CHECK_STALL_SECONDS)=' \
    | LC_ALL=C sort || true)
reuse_cover=$(print -r -- "v1|$reuse_tree|$(toolchain_id)|$reuse_environment" | /usr/bin/shasum -a 256 | cut -d ' ' -f1)
# 릴리스 앱 빌드를 뺀 넓힌 --changed 통과를 인자 없는 전체 검사가 재사용하지 않게 키에 넣는다.
reuse_key=$(print -r -- "v1|$mode|$test_filter|$plan_base|$reuse_cover|release=$release_build" | /usr/bin/shasum -a 256 | cut -d ' ' -f1)
if [[ -n "$reuse_tree" && "$mode" != stress ]] && (( ! no_reuse )) && [[ -f "$log_root/pass-history" ]]; then
    full_covers=0
    if [[ "$requested_mode" == changed ]]; then full_covers=1; fi
    reused=$(awk -F '\t' -v key="$reuse_key" -v cover="$reuse_cover" -v full_covers="$full_covers" '
        { delete f; for (i = 1; i <= NF; i++) { n = index($i, "="); f[substr($i, 1, n - 1)] = substr($i, n + 1) } }
        f["key"] == key || (full_covers && f["mode"] == "full" && f["cover"] == cover) { found = f["log"] }
        END { print found }' "$log_root/pass-history")
    if [[ -n "$reused" && -d "$reused" ]]; then
        echo "재사용: $reused (같은 작업 트리·모드의 통과 기록입니다. 다시 돌리려면 --no-reuse)"
        exit 0
    fi
fi

# 일상 검사(--changed·전체·--coverage)는 시험에 키 유도 장치(Tests/Support/CipherKDF)가 켜져 있어야 한다고 알린다.
# 장치가 모르는 DJC_ 변수가 시험 환경에 들어와 장치가 조용히 꺼지면 CipherTestKDFTests가 실패한다(CIP-15).
# 실험·캡처처럼 일부러 장치를 끄는 실행은 --quick·swift test로 돌아 표지를 받지 않는다.
if [[ "$requested_mode" == (changed|full|coverage) ]]; then export DJC_CHECK_TEST_KDF=1; fi

# 실행마다 다른 폴더를 써서 이전 실패·취소 로그와 섞이지 않게 한다.
mkdir -p "$log_root"
log_dir=$(mktemp -d "$log_root/run.XXXXXX")
printf '단계\t초\t종료코드\n' > "$log_dir/timings.tsv"
# 시험이 사용자 초안·백업 폴더를 건드리지 않게, 따로 주지 않으면 이번 실행 폴더 아래를 DJC_HOME으로 쓴다(CI는 직접 준다).
if [[ -z "${DJC_HOME-}" ]]; then
    export DJC_HOME="${log_dir:A}/djc-home"
    mkdir -p "$DJC_HOME"
fi
# 시험이 실제 rekordbox 라이브러리를 기본값으로 보지 않게, 따로 주지 않으면 빈 임시 폴더를 DJC_REKORDBOX_DIR로 쓴다(#182).
if [[ -z "${DJC_REKORDBOX_DIR-}" ]]; then
    export DJC_REKORDBOX_DIR="${log_dir:A}/rekordbox"
    mkdir -p "$DJC_REKORDBOX_DIR"
fi
# 검사 전후 실제 라이브러리 파일의 크기·수정 시각·inode와 바뀐 분석 파일을 비교한다(#182: 시험이 실제 라이브러리를 덮었다).
live_library="$HOME/Library/Pioneer/rekordbox"
touch "$log_dir/live-reference"
live_fingerprint() {
    local live_files=("$live_library"/master.db*(N) "$live_library"/masterPlaylists6.xml(N))
    # 파일이 없을 때 인자 없는 stat은 표준 입력을 읽어 실행마다 값이 달라진다.
    if (( ${#live_files} )); then /usr/bin/stat -f '%N %z %m %i' "${live_files[@]}" 2>/dev/null || true; fi
    find "$live_library/share/PIONEER/USBANLZ" -newer "$log_dir/live-reference" 2>/dev/null | head -5 || true
}
live_before=$(live_fingerprint)
# DJCrate 사용자 폴더·로그 폴더도 전후 파일 목록·크기·수정 시각을 비교한다(#218: 시험이 사용자 캐시·로그에 썼다).
# 시험·자가 테스트는 DJC_HOME(없으면 시험 임시 폴더) 밖에 쓰지 않아야 한다.
user_folders=("$HOME/Library/Application Support/DJCrate" "$HOME/Library/Logs/DJCrate")
user_fingerprint() {
    local folder
    for folder in "${user_folders[@]}"; do
        if [[ ! -e "$folder" ]]; then print -r -- "없음 $folder"; continue; fi
        find "$folder" -print0 2>/dev/null | xargs -0 /usr/bin/stat -f '%N %z %m' 2>/dev/null || true
    done | LC_ALL=C sort
}
# 시험용 UserDefaults(DJCTestKit의 TestDefaults) 이름 접두사를 실행마다 다르게 준다. 끝나면 사용자 환경설정 폴더에
# 이번 실행의 접두사로 생긴 plist만 센다(adv4 T6: 시험이 ~/Library/Preferences에 plist를 10만 개 넘게 남겼다).
# 같은 기계에서 다른 검사가 함께 돌아도 그쪽 파일은 세지 않는다.
export DJC_TEST_DEFAULTS_PREFIX="djc-test-${${log_dir:t}#run.}-"
preferences_folder="$HOME/Library/Preferences"
preferences_fingerprint() { print -rl -- "$preferences_folder/$DJC_TEST_DEFAULTS_PREFIX"*.plist(N) | LC_ALL=C sort; }
preferences_before=$(preferences_fingerprint)
# 설치한 앱(DJCrate.app)이 켜져 있으면 앱이 쓴 것과 시험이 쓴 것을 가를 수 없어, 바뀐 것을 알리기만 한다.
installed_app_running() { pgrep -f 'DJCrate\.app/Contents/MacOS/DJCrate' >/dev/null 2>&1; }
user_before=$(user_fingerprint)
app_seen=0
if installed_app_running; then app_seen=1; fi
# 앱이 켜져 있어 사용자 폴더 변경을 경고로만 넘긴 실행은 통과로 기록하지 않는다(다음 재사용에서 경고가 사라진다).
record_blocked=""
integer check_started=$SECONDS stage_started=0
stage_name=""
stage_file=""
failed_log=""
stage_pid=""
pulse_pid=""
watch_pid=""

# 이 검사에서 시작한 자식만 정리한다. 부모 셸만 취소되어도 빌드가 남지 않아야 한다.
stop_tree() {
    local pid=$1 child
    for child in ${(f)"$(pgrep -P "$pid" || true)"}; do
        [[ -n "$child" ]] && stop_tree "$child"
    done
    kill -TERM "$pid" 2>/dev/null || true
}

finish() {
    local code=$1
    trap '' INT TERM
    if [[ -n "$stage_pid" ]]; then
        stop_tree "$stage_pid"
        wait "$stage_pid" 2>/dev/null || true
        printf '%s\t%d\t%d\n' "$stage_name" "$((SECONDS - stage_started))" "$code" >> "$log_dir/timings.tsv"
        echo "▸ 종료: $stage_name ($((SECONDS - stage_started))초, 종료코드 $code)"
        failed_log=$log_dir/$stage_file.log
    fi
    local helper
    for helper in $pulse_pid $watch_pid; do
        stop_tree "$helper"
        wait "$helper" 2>/dev/null || true
    done
    if [[ "$(live_fingerprint)" != "$live_before" ]]; then
        echo "✘ 검사 중 실제 rekordbox 라이브러리 파일이 바뀌었습니다. rekordbox를 쓰지 않았다면 시험이 실제 라이브러리를 건드린 것이니 바로 멈추고 알리세요" >&2
        (( code == 0 )) && code=3
    fi
    # 시험 설정 파일은 앱이 만들지 않으므로 앱이 켜져 있어도 실패로 본다.
    local preferences_new
    preferences_new=$(comm -13 <(print -r -- "$preferences_before") <(preferences_fingerprint))
    if [[ -n "$preferences_new" ]]; then
        print -r -- "$preferences_new" > "$log_dir/preferences.diff"
        echo "✘ 검사 중 사용자 환경설정 폴더(~/Library/Preferences)에 이번 시험의 설정 파일(${DJC_TEST_DEFAULTS_PREFIX}*.plist)이 생겼습니다. 시험이 TestDefaults의 임시 폴더 밖에 쓴 것이니 바로 멈추고 알리세요(생긴 목록: $log_dir/preferences.diff)" >&2
        print -r -- "$preferences_new" | head -5 >&2
        (( code == 0 )) && code=4
    fi
    local user_after
    user_after=$(user_fingerprint)
    if [[ "$user_after" != "$user_before" ]]; then
        diff <(print -r -- "$user_before") <(print -r -- "$user_after") > "$log_dir/user-folders.diff" || true
        if installed_app_running; then app_seen=1; fi
        if (( app_seen )); then
            echo "⚠ 검사 중 DJCrate 사용자 폴더·로그 폴더가 바뀌었습니다. 설치한 DJCrate 앱이 켜져 있어 앱이 쓴 것일 수 있습니다(바뀐 목록: $log_dir/user-folders.diff)" >&2
            record_blocked="앱이 켜진 채 사용자 폴더가 바뀌었습니다"
        else
            echo "✘ 검사 중 DJCrate 사용자 폴더·로그 폴더가 바뀌었습니다. 시험이 DJC_HOME 밖에 쓴 것이니 바로 멈추고 알리세요(바뀐 목록: $log_dir/user-folders.diff)" >&2
            grep '^[<>]' "$log_dir/user-folders.diff" | head -5 >&2 || true
            (( code == 0 )) && code=4
        fi
    fi
    echo "▸ 전체 종료: $((SECONDS - check_started))초, 종료코드 $code (로그: $log_dir)"
    print -r -- "$code" > "$log_dir/exit-code.txt"
    if (( code == 0 )) && [[ -n "$reuse_tree" ]]; then
        # 검사 중 파일을 고쳤다 되돌리면 시험하지 않은 트리가 통과로 남는다. 시작과 끝의 작업 트리 해시가 같을 때만 기록한다.
        local end_tree
        end_tree=$(python3 scripts/affected-tests.py --worktree-tree 2>/dev/null) || end_tree=""
        if [[ "$end_tree" != "$reuse_tree" ]]; then record_blocked="검사 중 작업 트리가 바뀌었습니다"; fi
        if [[ -n "$record_blocked" ]]; then
            echo "⚠ 통과 기록을 남기지 않습니다: $record_blocked(다음 실행은 다시 돕니다)"
        else
            record_pass
        fi
    fi
    print_summary "$code"
    exit "$code"
}

# 통과 기록: 한 줄, 탭으로 나눈 이름=값(v·mode·filter·head·tree·key·log·seconds·time·cover·requested·scope·base 순서).
# scope: 실제로 돈 범위(full·tests·build·none). none이면 빌드·시험 없이 가벼운 검사만 돈 --changed다. base: --changed 기준(그 밖 none).
# last-pass는 마지막 통과, pass-history는 통과 이력(재사용 판정이 읽는다). 훅도 last-pass를 읽는다(docs/ci.md).
record_pass() {
    local line scope temporary
    case "$mode" in
        full|coverage) scope=full ;;
        release) scope=build ;;
        quick|stress) scope=tests ;;
        changed) scope=$plan_scope ;;
    esac
    line=$(printf 'v=1\tmode=%s\tfilter=%s\thead=%s\ttree=%s\tkey=%s\tlog=%s\tseconds=%d\ttime=%s\tcover=%s\trequested=%s\tscope=%s\tbase=%s' \
        "$mode" "${test_filter:-none}" "${check_head-unknown}" "$reuse_tree" "$reuse_key" "${log_dir:A}" \
        "$((SECONDS - check_started))" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$reuse_cover" "$requested_mode" "$scope" "${plan_base:-none}")
    print -r -- "$line" >> "$log_root/pass-history"
    # 이력은 최근 200줄만 둔다. 같은 로그 폴더를 쓰는 검사가 함께 끝나도 서로의 임시 파일을 덮지 않게 이름을 따로 만든다.
    temporary=$(mktemp "$log_root/pass-history.XXXXXX")
    tail -200 "$log_root/pass-history" > "$temporary" && mv "$temporary" "$log_root/pass-history"
    temporary=$(mktemp "$log_root/last-pass.XXXXXX")
    print -r -- "$line" > "$temporary" && mv "$temporary" "$log_root/last-pass"
}

plain_text() { LC_ALL=C perl -pe 's/\e\][^\a\e]*(?:\a|\e\\)//g; s/\e\[[0-9;?]*[ -\/]*[@-~]//g; s/\e[@-_]//g'; }

# 끝 요약: 단계별 초·결과, 통과면 몇 줄, 실패면 실패한 시험·첫 오류 줄(최대 10개)과 로그 폴더.
print_summary() {
    local code=$1 title=$mode tests=""
    if [[ "$requested_mode" != "$mode" ]]; then title="$requested_mode → $mode"; fi
    if [[ "$requested_mode" == changed && "$plan_scope" == tests ]]; then title+=" (Suite ${plan_suites}/${plan_total_suites}개)"; fi
    if [[ -f "$log_dir/test.log" ]]; then
        tests=$(awk '/Test run with [0-9]+ tests? / { for (i = 1; i <= NF; i++) if ($i == "with") { n += $(i + 1); break } }
            END { if (n) print n }' "$log_dir/test.log")
    fi
    echo "── 검사 요약 ──"
    awk -F '\t' 'NR > 1 { printf "  %s %s %d초\n", ($3 == 0 ? "✔" : "✘"), $1, $2 }' "$log_dir/timings.tsv"
    if (( code == 0 )); then
        echo "✔ 통과: $title · 총 $((SECONDS - check_started))초${tests:+ · 시험 ${tests}개}"
        if [[ "$requested_mode" == changed && "$mode" == full ]]; then
            echo "▸ 릴리스 빌드는 릴리스 검사에서 합니다(scripts/check.sh·--release)"
        fi
        # 지도가 적은 필수 검사(stress 등)는 --changed가 대신하지 않는다. 통과 뒤에도 남은 일로 다시 알린다.
        if [[ -n "$plan_required" ]]; then print -rl -- ${(f)plan_required} | sed 's/^/⚠ 남은 필수 검사: /'; fi
    else
        echo "✘ 실패: $title · 종료코드 $code · 총 $((SECONDS - check_started))초${tests:+ · 시험 ${tests}개}"
        if [[ -f "$log_dir/stall.txt" ]]; then
            sed 's/^/  /' "$log_dir/stall.txt"
        elif [[ -n "$failed_log" && -f "$failed_log" ]]; then
            local lines
            # 컴파일러의 색(ESC [ … m)·링크(ESC ] 8 ;; … ESC \) 시퀀스는 요약에서만 지운다(로그 원문은 그대로).
            lines=$(plain_text < "$failed_log" | grep -E '^✘ |error:|fatal error|Test Case .* failed|Fatal error' | head -10 | cut -c1-300 || true)
            if [[ -n "$lines" ]]; then
                echo "실패한 시험·첫 오류 줄(최대 10개, $failed_log):"
                print -r -- "$lines" | sed 's/^/  /'
            else
                echo "마지막 출력($failed_log):"
                plain_text < "$failed_log" | tail -5 | cut -c1-300 | sed 's/^/  /'
            fi
        fi
    fi
    echo "로그: ${log_dir:A}"
}
trap 'finish $?' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# 부분 검사 결과를 전체 통과로 오인하지 않도록 설정·후보를 원문 로그에도 남긴다.
check_head=$(git rev-parse --verify HEAD 2>/dev/null || print -r -- unknown)
check_dirty=unknown
if check_worktree=$(git status --porcelain 2>/dev/null); then
    if [[ -n "$check_worktree" ]]; then check_dirty=yes; else check_dirty=no; fi
fi
debug_setting=coverage
release_setting=off
if [[ "$mode" == release ]]; then debug_setting=off; fi
if (( release_build )); then release_setting=on; fi
{
    print -r -- "mode=$mode"
    print -r -- "requested=$requested_mode"
    if [[ "$requested_mode" == changed ]]; then
        print -r -- "base=$plan_base"
        print -r -- "scope=$plan_scope"
    fi
    print -r -- "filter=${test_filter:-none}"
    print -r -- "debug=$debug_setting"
    print -r -- "release=$release_setting"
    print -r -- "cipher_stress=${DJC_CIPHER_STRESS-0}"
    print -r -- "head=$check_head"
    print -r -- "dirty=$check_dirty"
} > "$log_dir/run-info.txt"
cat "$log_dir/run-info.txt"
if [[ "$requested_mode" == changed ]]; then
    print -r -- "$plan_json" > "$log_dir/affected.json"
    print -r -- "$plan_text" > "$log_dir/affected.txt"
fi

# 빌드·시험 단계는 원문을 로그 파일에만 두고 화면에는 실패·오류 줄과 시험 실행 요약 줄만 낸다(시험 통과 줄 수천 개를
# 화면·에이전트 맥락에 쏟지 않는다. CI 요약이 grep하는 `✔ Test run` 줄은 남긴다). DJC_CHECK_VERBOSE=1이면 전부 낸다.
quiet_lines='^(✘|━)|Test run with|error:|fatal error|Fatal error|Test Case .* failed|Build complete'
run_stage() {
    local name=$1 file=$2 code quiet=0
    shift 2
    if [[ "${DJC_CHECK_VERBOSE-0}" != 1 && "$1" == swift && ( "$2" == build || "$2" == test ) ]]; then quiet=1; fi
    stage_name=$name
    stage_file=$file
    stage_started=$SECONDS
    echo "▸ 시작: $name ($(date -u +%Y-%m-%dT%H:%M:%SZ), 로그: $log_dir/$file.log)"
    # 비동기 wait는 셸에 온 취소 신호를 즉시 처리한다. pipefail로 명령·tee 실패를 보존한다.
    # tee의 바이트 청크 사이에 진행 알림이 끼어 UTF-8·한 줄을 나누지 않도록 화면에는 줄로 보낸다.
    (
        "$@" 2>&1 | tee "$log_dir/$file.log" | while IFS= read -r line || [[ -n "$line" ]]; do
            if (( ! quiet )) || [[ "$line" =~ $quiet_lines ]]; then print -r -- "$line"; fi
        done
    ) &
    stage_pid=$!
    # sleep이 출력 파이프를 물려받지 않게 한다. stop_tree의 pgrep이 막 띄운 sleep을 못 보면 고아 sleep이 60초 동안
    # 파이프를 붙들어 `| tee`·캡처하는 쪽이 늦게 끝났다(test-check의 changed-build-fail 간헐 실패). 서브셸이 TERM을 받으면 sleep도 끈다.
    (
        sleeper=""
        trap '[[ -n "$sleeper" ]] && kill "$sleeper" 2>/dev/null; exit 0' TERM
        while true; do
            sleep 60 </dev/null >/dev/null 2>&1 &
            sleeper=$!
            wait "$sleeper" || exit 0
            echo "▸ 진행: $name ($((SECONDS - stage_started))초)"
        done
    ) &
    pulse_pid=$!
    # 시험 단계만 멈춤을 본다. 빌드(특히 릴리스 최적화)는 몇 분 동안 출력이 없을 수 있다.
    if [[ "$1" == swift && "$2" == test ]] && (( stall_seconds > 0 )); then
        watch_stall "$stage_pid" "$log_dir/$file.log" &
        watch_pid=$!
    fi
    if wait "$stage_pid"; then code=0; else code=$?; fi
    stage_pid=""
    local helper
    for helper in $pulse_pid $watch_pid; do
        stop_tree "$helper"
        wait "$helper" 2>/dev/null || true
    done
    pulse_pid=""
    watch_pid=""
    if [[ -f "$log_dir/stall.txt" ]]; then code=124; fi
    printf '%s\t%d\t%d\n' "$name" "$((SECONDS - stage_started))" "$code" >> "$log_dir/timings.tsv"
    echo "▸ 종료: $name ($((SECONDS - stage_started))초, 종료코드 $code, $(date -u +%Y-%m-%dT%H:%M:%SZ))"
    # zsh의 함수 실패에 따른 errexit은 EXIT 트랩을 건너뛸 수 있어 명시적으로 끝낸다.
    if (( code != 0 )); then failed_log=$log_dir/$file.log; exit "$code"; fi
}

# 시험 출력에서 시작만 하고 끝나지 않은 시험·Suite(마지막에 시작한 것부터 12개). swift-testing은 `◇ Test 이름 started.`와
# `✔/✘ Test 이름 (with N test cases )passed/failed after`, XCTest는 `Test Case '…' started.`와 `passed/failed (`를 짝짓는다.
# 바이트로 비교한다(en_US.UTF-8에서 macOS awk는 한글을 strcoll로 비교한다). `◇ `·`✔ `·`✘ `는 4바이트다.
unfinished_tests() {
    plain_text < "$1" | LC_ALL=C awk '
        /^◇ (Test|Suite) .* started\.$/ {
            name = substr($0, 5); sub(/ started\.$/, "", name)
            if (name !~ /^Test (run|case)( |$)/) { open[name]++; order[++n] = name }
            next
        }
        /^(✔|✘) (Test|Suite) .* (passed|failed) after / {
            name = substr($0, 5); sub(/ (with [0-9]+ test cases? )?(passed|failed) after .*$/, "", name)
            if (open[name] > 0) open[name]--
            next
        }
        /^Test Case .* started\.$/ { name = $0; sub(/ started\.$/, "", name); open[name]++; order[++n] = name; next }
        /^Test Case .* (passed|failed) \(/ { name = $0; sub(/ (passed|failed) \(.*$/, "", name); if (open[name] > 0) open[name]--; next }
        END {
            for (i = n; i >= 1; i--) {
                if (open[order[i]] < 1) continue
                open[order[i]]--
                if (shown++ < 12) print order[i]; else more++
            }
            if (more) printf "… 그 밖 %d개\n", more
            if (!shown) print "(시험 출력에서 찾지 못했습니다)"
        }'
}

descendants() {
    local child
    for child in ${(f)"$(pgrep -P "$1" || true)"}; do
        [[ -n "$child" ]] || continue
        print -r -- "$child"
        descendants "$child"
    done
}

# 멈춘 시험 단계를 기록한다: 끝나지 않은 시험, 셸·tee·sleep 밖 자손(swift-test·swiftpm-testing-helper·xctest)의 5초 스택.
# 스택 원문은 로그 폴더의 stall-sample-<pid>.txt, 요약에는 맨 위 함수 몇 줄만 옮긴다.
report_stall() {
    local watched=$1 log=$2 pid command file sampled=()
    {
        echo "✘ 멈춤: $stage_name — ${stall_seconds}초 동안 시험 출력이 없었습니다(종료코드 124)"
        echo "끝나지 않은 시험(마지막에 시작한 것부터):"
        unfinished_tests "$log" | sed 's/^/  /'
    } > "$log_dir/stall.txt"
    for pid in $(descendants "$watched"); do
        command=$(ps -o comm= -p "$pid" 2>/dev/null) || continue
        case "${command:t}" in zsh|-zsh|sh|bash|tee|sleep|sed|awk|perl) continue ;; esac
        (( ${#sampled} < 4 )) || break
        sampled+=("$pid ${command:t}")
        sample "$pid" 5 -file "$log_dir/stall-sample-$pid.txt" </dev/null >/dev/null 2>&1 &
    done
    wait
    for pid in "${sampled[@]}"; do
        file="$log_dir/stall-sample-${pid%% *}.txt"
        if [[ ! -s "$file" ]]; then print -r -- "스택(${pid#* }): sample이 스택을 뜨지 못했습니다"; continue; fi
        print -r -- "스택(${pid#* }): $file"
        awk '/^Sort by top of stack/ { on = 1; next } on && NF == 0 { exit } on && shown++ < 6 { print "  " $0 }' "$file"
    done >> "$log_dir/stall.txt"
}

# 단계 로그가 stall_seconds 동안 자라지 않으면 기록을 남기고 단계의 프로세스를 끝낸다. TERM으로 안 끝나면 5초 뒤 KILL.
watch_stall() {
    local watched=$1 log=$2 size last="" quiet_since=$SECONDS tick=10 sleeper="" victims alive pid
    if (( stall_seconds < 30 )); then tick=1; fi
    trap '[[ -n "$sleeper" ]] && kill "$sleeper" 2>/dev/null; exit 0' TERM
    while true; do
        sleep "$tick" </dev/null >/dev/null 2>&1 &
        sleeper=$!
        wait "$sleeper" || exit 0
        size=$(/usr/bin/stat -f %z "$log" 2>/dev/null || print 0)
        if [[ "$size" != "$last" ]]; then last=$size; quiet_since=$SECONDS; continue; fi
        (( SECONDS - quiet_since >= stall_seconds )) || continue
        # 여기부터는 TERM을 무시한다: 단계가 끝나면 본 셸이 감시를 끄는데, 그 전에 남은 자손을 KILL까지 마쳐야 한다.
        trap '' TERM
        echo "✘ 멈춤: $stage_name — ${stall_seconds}초 동안 시험 출력이 없어 끝나지 않은 시험과 스택을 남기고 끝냅니다"
        report_stall "$watched" "$log"
        victims=($(descendants "$watched") "$watched")
        stop_tree "$watched"
        for _ in 1 2 3 4 5; do
            alive=()
            for pid in $victims; do kill -0 "$pid" 2>/dev/null && alive+=("$pid"); done
            (( ${#alive} )) || exit 0
            sleep 1 </dev/null >/dev/null 2>&1
        done
        echo "▸ TERM으로 끝나지 않은 시험 프로세스를 KILL합니다: ${alive[*]}"
        kill -KILL $alive 2>/dev/null
        exit 0
    done
}

require_filtered_tests() {
    # 집계에는 skip된 시험도 들어갈 수 있으므로 실제 개별 시험의 완료를 확인한다.
    if ! awk '/Test .+ passed after / && !/Test run with / { completed = 1 }
        END { exit !completed }' "$log_dir/test.log"; then
        print -r -- "실제로 완료한 시험이 없습니다. 필터를 확인하세요: $test_filter" >&2
        return 1
    fi
}

PROF=.build/out/Products/Debug/codecov/default.profdata
coverage() {
local only=${1-}
# 이전 실행의 프로파일을 읽지 않게 시험 단계 앞에서 지운다(fresh_profile). 없으면 이번 시험이 만들지 않은 것이다.
if [[ ! -f "$PROF" ]]; then print -r -- "커버리지 프로파일이 없습니다(이번 시험이 만들지 않음): $PROF" >&2; return 1; fi
bundles=(.build/out/Products/Debug/*Tests.xctest)
# --changed: 이번에 빌드·실행한 시험 타깃의 번들만 읽는다(다른 번들은 낡았을 수 있다).
if [[ "$only" == write ]]; then
    bundles=()
    local target
    for target in "${@:2}"; do
        if [[ -d ".build/out/Products/Debug/$target.xctest" ]]; then bundles+=(".build/out/Products/Debug/$target.xctest"); fi
    done
    if (( ! ${#bundles} )); then print -r -- "커버리지를 읽을 시험 번들이 없습니다: ${*:2}" >&2; return 1; fi
fi
first="${bundles[1]}/Contents/MacOS/$(basename ${bundles[1]} .xctest)"
rest=()
for b in "${bundles[@]:1}"; do rest+=(-object "$b/Contents/MacOS/$(basename $b .xctest)"); done
xcrun llvm-cov report "$first" "${rest[@]}" -instr-profile "$PROF" -ignore-filename-regex='(checkouts|Tests|\.build)/' \
    | awk 'NF>=10 && $1 ~ /\.swift$/ {print $1, $8, $9}' > "$log_dir/coverage.txt"
# 파일을 옮기거나 타깃을 새로 만들면 정규식에서 조용히 빠지므로, 그룹별 파일 수를 찍고 쓰기 그룹을 확인한다:
# 정규식의 이름 5종과 Usb/Write/가 각각 한 파일 이상, 쓰기 입구 파일, 파일 수 하한(파일을 합치거나 지우면 write_min_files를 고친다).
# 하한은 커버리지 보고에 줄이 잡힌 파일 수다(실행할 줄이 없는 파일은 보고에 없어 소스 파일 수보다 적다). 지금 값과 같아 여유가 없다.
# 쓰기 관문 포트는 정의(DJCApplication)와 실제 구현(DJCAdapters `RekordboxWriteGate+Live`) 두 파일이다(#167 H2-1에서 실제 구현을 옮겨 64 → 65).
# #167 H2 USB: 값만 있던 `Usb/Write/UsbWriteGuard.swift`를 DJCDomain으로 옮기고(−1), USB 쓰기 절차를 부르는 어댑터
# DJCAdapters `UsbLibraryEngine+Writer`를 더해(+1) 65 그대로다.
write_min_files=65
awk -v write_min="$write_min_files" -v only="$only" '
    function add(group, lines, missed) { total[group] += lines; miss[group] += missed; files[group]++ }
    {
        if ($1 ~ /^RekordboxKit\/(Write\/)?(RekordboxWriter|RekordboxGridWriter|RekordboxCompatibility|RekordboxTrackWriter|RekordboxTrackAdd)/ \
            || $1 ~ /^RekordboxKit\/Usb\/Write\// \
            || $1 ~ /^(DJCApplication\/Reflection\/RekordboxWriteGate|DJCAdapters\/Reflection\/RekordboxWriteGate\+Live)\.swift$/ \
            || $1 ~ /^DJCAdapters\/Usb\/UsbLibraryEngine\+Writer\.swift$/) {
            add("쓰기", $2, $3)
            name = $1; sub(/.*\//, "", name); written[name] = 1
            if ($1 ~ /^RekordboxKit\/Usb\/Write\//) usbWrite++
            k = split("RekordboxWriter RekordboxGridWriter RekordboxCompatibility RekordboxTrackWriter RekordboxTrackAdd", prefixes, " ")
            for (j = 1; j <= k; j++) if (index(name, prefixes[j]) == 1) named[prefixes[j]]++
        }
        if ($1 ~ /^(DJCDomain|DJCEnvironment|DJCApplication|DJCAdapters|RekordboxKit|DJCStorage|DJCAnalysis)\//) add("코어", $2, $3)
        if ($1 ~ /^DJCrate\//) add("앱", $2, $3)
    }
    END {
        target["쓰기"] = 80; target["코어"] = 60; target["앱"] = 0
        failed = 0
        n = split("쓰기 코어 앱", order, " ")
        for (i = 1; i <= n; i++) {
            g = order[i]
            # 쓰기 그룹만 판정할 때(--changed)는 코어·앱 줄을 내지도 판정하지도 않는다.
            # 한글끼리 비교하지 않고 순번으로 거른다: en_US.UTF-8(CI 러너)에서 macOS awk는 한글을 strcoll로 비교해 모두 같다고 본다
            if (only == "write" && i != 1) continue
            pct = total[g] ? 100 * (total[g] - miss[g]) / total[g] : 0
            mark = (pct >= target[g]) ? "✔" : "✘"
            if (pct < target[g]) failed = 1
            printf "  %s %-4s %5.1f%%  (파일 %d개, %d줄 중 %d줄, 목표 %d%%)\n", mark, g, pct, files[g], total[g], total[g] - miss[g], target[g]
        }
        # 쓰기 관문(RekordboxWriter.write·RekordboxTrackWriter·UsbWriter.write)이 든 파일과 앱·CLI가 관문을 부르는 포트의 실제 구현(rekordbox·USB)
        m = split("RekordboxWriter.swift RekordboxTrackWriter.swift UsbWriter.swift RekordboxWriteGate+Live.swift UsbLibraryEngine+Writer.swift", required, " ")
        for (i = 1; i <= m; i++) {
            if (!(required[i] in written)) {
                printf "  ✘ 쓰기 그룹에 %s가 없습니다. 파일을 옮겼다면 scripts/check.sh의 쓰기 정규식을 고치세요\n", required[i]
                failed = 1
            }
        }
        k = split("RekordboxWriter RekordboxGridWriter RekordboxCompatibility RekordboxTrackWriter RekordboxTrackAdd", prefixes, " ")
        for (j = 1; j <= k; j++) {
            if (!(prefixes[j] in named)) {
                printf "  ✘ 쓰기 그룹에 %s 파일이 없습니다. 파일을 옮겼다면 scripts/check.sh의 쓰기 정규식을 고치세요\n", prefixes[j]
                failed = 1
            }
        }
        if (!usbWrite) {
            print "  ✘ 쓰기 그룹에 Usb/Write/ 파일이 없습니다. 폴더를 옮겼다면 scripts/check.sh의 쓰기 정규식을 고치세요"
            failed = 1
        }
        if (files["쓰기"] < write_min) {
            printf "  ✘ 쓰기 그룹 파일이 %d개로 %d개보다 적습니다. 옮긴 파일은 정규식을, 합치거나 지운 파일은 write_min_files를 고치세요\n", files["쓰기"], write_min
            failed = 1
        }
        exit failed
    }' "$log_dir/coverage.txt"
}

fresh_profile() { rm -f "$PROF"; }

if [[ "$mode" == changed ]]; then
    # 소스 타깃 전체(앱·CLI 제품 포함, 시험 제외)를 먼저 빌드한다: 고르지 않은 앱·CLI의 컴파일 오류를 통과로 남기지 않는다.
    # 시험 타깃은 고른 것만 빌드한다(#167 측정: DJCDomain 공개 API 변경 뒤 DJCDomainTests만 8초, 시험 타깃 전체 81초).
    # swift build --target은 한 번에 하나만 받아 타깃마다 부른다. 필터를 타깃 이름으로 앵커해 낡은 번들의 시험은 돌지 않는다.
    checks=" $plan_checks "
    if [[ "$checks" == *" imports "* ]]; then
        run_stage "모듈 경계 규칙(import·핵심부 API·빚 목록)" imports python3 scripts/check-imports.py
    fi
    # 검사 스크립트 회귀 전체가 돌면 그 안에 든다
    if [[ "$checks" == *" selection "* && "$checks" != *" scripts "* ]]; then
        run_stage "안전 시험 선택 검사(실제 지도)" selection python3 scripts/test-check.py affected-real-map safety-
    fi
    case "$plan_scope" in
        tests)
            run_stage "소스 타깃 전체 빌드: 앱·CLI 포함(커버리지 계측)" build-sources swift build --enable-code-coverage
            for target in ${=plan_targets}; do
                run_stage "시험 타깃 빌드: $target(커버리지 계측)" "build-$target" swift build --target "$target" --enable-code-coverage
            done
            if [[ " $plan_checks " == *" write-coverage "* ]]; then fresh_profile; fi
            run_stage "고른 시험 실행(빌드 생략)" test swift test --skip-build --enable-code-coverage --filter "$test_filter"
            run_stage "필터 결과(1개 이상 완료)" filter-result require_filtered_tests ;;
        build)
            run_stage "디버그·테스트 빌드(커버리지 계측)" debug-build swift build --build-tests --enable-code-coverage ;;
    esac
    if [[ "$checks" == *" translations "* ]]; then
        run_stage "번역(en·ja 누락·안 쓰는 문구·자리표시자)" translations swift scripts/i18n.swift check --enable-code-coverage
    fi
    if [[ "$checks" == *" write-coverage "* ]]; then
        run_stage "쓰기 그룹 커버리지(목표 80%)" coverage coverage write ${=plan_targets}
    fi
    if [[ "$checks" == *" docs "* ]]; then
        run_stage "문서 검사(check-docs)" docs python3 scripts/check-docs.py
        run_stage "문장 규칙(check-prose)" prose python3 scripts/check-prose.py ${plan_base:+--base} $plan_base
    fi
    if [[ "$checks" == *" harness "* ]]; then run_stage "훅 검사(test-harness)" harness python3 scripts/test-harness.py --quiet; fi
    if [[ "$checks" == *" scripts "* ]]; then run_stage "검사 스크립트 회귀" script-tests python3 scripts/test-check.py; fi
    if [[ "$plan_scope" == none && "$checks" == "  " ]]; then echo "▸ 빌드·시험 없음: 바꾼 파일에 돌릴 시험·검사가 없습니다"; fi
    echo "▸ 통과: $mode"
    exit 0
fi

# 모듈 경계 규칙(빚 목록 밖 위반·갚은 빚)은 빌드 전에 본다(몇 초).
run_stage "모듈 경계 규칙(import·핵심부 API·빚 목록)" imports python3 scripts/check-imports.py
# 문서·지침(rules paths 글롭·링크)·훅·시험 지도도 빌드 전에 본다(십여 초). 파일·폴더를 옮기면 이것들이 함께 따라가야 하는데,
# --changed가 Package.swift 등으로 전체로 넓히면 문서·훅 검사를 건너뛰어 깨진 rules paths를 놓쳤다(#167 H3c).
# CI는 coverage 묶음이 돈다(release 묶음은 같은 커밋이라 건너뛴다). 넓힌 --changed는 바꾼 검사 스크립트의 회귀도 돈다.
if [[ "$mode" == full || "$mode" == coverage ]]; then
    run_stage "문서 검사(check-docs)" docs python3 scripts/check-docs.py
    # 더한 줄 규칙의 기준: 넓힌 --changed는 그 기준, 전체 검사는 check-prose.py가 dev와의 merge-base를 구한다
    run_stage "문장 규칙(check-prose)" prose python3 scripts/check-prose.py ${plan_base:+--base} $plan_base
    run_stage "훅 검사(test-harness)" harness python3 scripts/test-harness.py --quiet
    run_stage "시험 지도 검사(test-map)" test-map python3 scripts/affected-tests.py --check-map
fi
if [[ "$requested_mode" == changed && " $plan_checks " == *" scripts "* ]]; then
    run_stage "검사 스크립트 회귀" script-tests python3 scripts/test-check.py
elif [[ "$requested_mode" == changed && " $plan_checks " == *" selection "* ]]; then
    run_stage "안전 시험 선택 검사(실제 지도)" selection python3 scripts/test-check.py affected-real-map safety-
fi
# 디버그 앱·CLI·테스트를 같은 계측 설정으로 한 번 빌드해 설정 전환에 따른 재컴파일을 줄인다.
if [[ "$mode" != release ]]; then
    run_stage "디버그·테스트 빌드(커버리지 계측)" debug-build swift build --build-tests --enable-code-coverage
fi
if (( release_build )); then
    run_stage "릴리스 앱 빌드" release-build swift build -c release --product DJCrate
fi
if [[ "$mode" == full || "$mode" == coverage ]]; then
    run_stage "번역(en·ja 누락·안 쓰는 문구·자리표시자)" translations swift scripts/i18n.swift check --enable-code-coverage
    fresh_profile
    run_stage "전체 테스트 실행·프로파일 수집(빌드 생략)" test swift test --skip-build --enable-code-coverage
    run_stage "커버리지 보고·목표 검사" coverage coverage
elif [[ "$mode" == quick || "$mode" == stress ]]; then
    run_stage "관련 테스트 실행(빌드 생략)" test swift test --skip-build --enable-code-coverage --filter "$test_filter"
    run_stage "필터 결과(1개 이상 완료)" filter-result require_filtered_tests
fi
echo "▸ 통과: $mode"
