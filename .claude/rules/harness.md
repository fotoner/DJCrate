---
paths:
  - "scripts/**"
  - ".github/**"
  - ".claude/**"
  - "AGENTS.md"
  - "CLAUDE.md"
---

# 검사 스크립트·지침·하네스를 고칠 때

검사 스크립트, 훅, 에이전트 지침을 고칠 때 지키는 규칙이다. 리뷰는 규칙을 ID로 가리킨다.

## 고친 뒤 돌릴 검사

- **HAR-1** 아래 파일을 바꾸면 `python3 scripts/test-check.py [경우 이름 일부]`를 돌린다. `--changed`도 이때 이 검사를 돈다.
  - `scripts/check.sh`
  - `scripts/affected-tests.py`
  - `scripts/test-map.txt`
  - `scripts/check-imports.py`
  - `scripts/ci-base.sh`
  - `scripts/ci-mtimes.py`
- **HAR-2** 아래 파일을 바꾸면 `python3 scripts/test-harness.py`를 돌린다.
  - 훅(`scripts/hooks/`)
  - `scripts/worker-lock.sh`
  - `.claude/settings.json`
  - `scripts/check-docs.py`, `scripts/test-harness.py`
  - `scripts/check-prose.py`, `scripts/prose-terms.txt`
- **HAR-3** 워크플로를 바꾸면 `actionlint`를 돌린다.
- **HAR-4** 문서 문장을 고치면 `python3 scripts/check-prose.py`를 돌린다. 사용법은 `docs/ci.md`의 "문장 규칙"에 있다.
- **HAR-5** 지침을 바꾸면 `python3 scripts/check-docs.py`를 돌린다.
- **HAR-36** `python3 scripts/test-check.py` 전체는 2분을 넘는다. 에이전트의 Bash 도구 기본 timeout(120초)에 걸린다. 그래서 배경으로 돌린다. 앞에서 돌릴 때는 timeout을 600초로 준다.

## CI 범위

- **HAR-38** PR과 `dev` 푸시 CI는 `scripts/check.sh --changed`만 돈다. 전체 검사는 릴리스에만 돈다. 릴리스는 `main`·`release/*` 푸시, `main` 대상·`release/*` PR, 수동 실행이다. 정책을 바꾸면 AGENTS.md "검증", `docs/ci.md` "CI 구성", 스킬 `verify-change`를 함께 고친다.
- **HAR-39** CI의 `--changed` 비교 기준은 `scripts/ci-base.sh`가 정한다. 기준을 구할 수 없으면 전체 검사로 넓힌다. 새 브랜치, 강제 푸시, 앞 끝이 조상이 아닌 경우가 그렇다. 조용히 좁히지 않는다. 그래서 푸시 실행은 앞 실행을 취소하지 않는다. 취소하면 그 푸시의 차이를 아무도 검사하지 않는다.
- **HAR-40** Swift를 바꾼 `--changed`는 안전 시험 선택 검사(`test-check.py affected-real-map safety-`)를 돈다. 이 검사를 빼지 않는다. PR CI가 고른 시험만 돌기 때문에, 안전 Suite를 고르는 일이 곧 안전 시험을 돌리는 일이다. `--changed`가 놓칠 수 있는 회귀는 릴리스 전체 검사가 잡는다. 그런 회귀를 알게 되면 `scripts/test-map.txt`에 줄을 더한다. 프로토콜로만 닿는 구현, 전역 함수, 다른 타입을 거친 동작 변화가 그런 예다.
- **HAR-41** 시험 단계 멈춤 감시는 끄지 않는다. 기준 초는 `DJC_CHECK_STALL_SECONDS`다. 기본값은 300초다. 멈춘 실행은 종료 코드 124로 끝난다. 느린 시험이 걸리면 먼저 시험을 고친다. 고칠 수 없을 때만 값을 늘린다.
- **HAR-42** 넓힌 `--changed`는 릴리스 앱 빌드를 뺀 전체 검사를 돈다. 릴리스 빌드는 릴리스 검사(인자 없는 `check.sh`·`--release`)의 몫이다. 이 통과 기록은 인자 없는 전체 검사를 대신하지 않는다. CI의 기준 없는 changed job도 `--coverage`를 돈다.

## 워크트리 작업 표시

- **HAR-37** 워크트리에서 일을 시작하는 작업자는 `scripts/worker-lock.sh take <작업 이름>`을 먼저 부른다. 이미 표시가 있으면 아무것도 고치지 않는다. 그 자리에서 멈춰 보고한다. 일이 끝나면 `scripts/worker-lock.sh drop <작업 이름>`으로 지운다. 두 세션이 같은 워크트리를 함께 고친 일이 있었다(#167).

## 시험 지도

- **HAR-6** Suite 이름 변경, Suite 삭제, 시험 파일 이동 뒤에는 `scripts/test-map.txt`도 고친다.
- **HAR-7** 지도가 맞지 않으면 `--changed`가 종료 코드 2로 끝난다. 지도에 없는 Suite나 어느 파일에도 맞지 않는 `when`이 그런 경우다.
- **HAR-8** 지도는 `python3 scripts/affected-tests.py --check-map`으로 미리 확인한다. 문법은 그 지도 파일 머리에 있다. 앞으로 생길 자리는 `maybe`로 적는다.
- **HAR-9** 안전 시험을 고르는 묶음은 경로로 넓게 둔다. 기호 grep은 프로세스로 띄우는 CLI 시험을 못 찾는다.
- **HAR-10** `.build/check-logs/last-pass` 형식을 바꾸면 Stop 훅(`scripts/hooks/stop-verify-reminder.py`)도 함께 고친다. `scripts/test-harness.py`의 실제 기록 줄 표본도 고친다. 형식은 `docs/ci.md` "끝 요약과 통과 기록"에 있다.

## 안전 장치

- **HAR-11** 시험 환경을 바꿀 때 AGENTS.md "안전 불변식"의 SAFE-9~SAFE-11을 지킨다(#182).
- **HAR-12** 안전 장치는 어떤 모드에서도 빼지 않는다. 안전 장치는 아래와 같다.
  - 종료 코드 3·4
  - 임시 `DJC_HOME`·`DJC_REKORDBOX_DIR`
  - 환경설정 누수 검사
- **HAR-13** 쓰기 커버리지 정규식(`scripts/check.sh`)에 걸리는 파일을 옮길 때와 지울 때는 아래를 함께 고친다. 고친 이유도 적는다.
  - 그 정규식
  - `write_min_files`
  - 필수 파일 확인

## 모듈 경계

- **HAR-14** 모듈 경계 규칙은 `scripts/check-imports.py` 맨 위 표에 있다. 남은 위반은 빚 목록 `scripts/import-debt.txt`에 둔다. 2026-10-10 기준 빚은 0줄이다.
- **HAR-15** 새 위반을 빚 목록에 더하지 않는다. 빚을 갚으면 그 줄을 지운다. `view-task` 줄은 곳 수가 줄면 곳 수를 고친다.
- **HAR-16** 파일의 모듈은 `Package.swift` 타깃 경로로 정한다. 타깃 이름이나 폴더를 바꾸면 `ALLOWED` 키만 맞춘다.
- **HAR-17** 파일·폴더를 옮기면 `.claude/rules/*.md`의 `paths`도 따라 고친다. `scripts/test-map.txt`의 `when`도 고친다.
- **HAR-18** 맞는 파일이 없는 글롭은 전체 검사에서 실패한다. 넓힌 `--changed`에서도 실패한다. `check-docs.py`와 `affected-tests.py --check-map`이 이것을 본다.
- **HAR-34** 경계 예외는 두 가지다. 조립 지점은 파일 이름 목록 `ASSEMBLY_FILES`다. `Diagnostics/`·`Lab/`은 `BROAD_FOLDERS`에 허용 import를 적는다. 그 파일·폴더를 옮기면 두 목록도 고친다.
- **HAR-35** 목록에 있는 파일이 없으면 검사가 실패한다. 아무도 쓰지 않는 허용 import가 남아도 실패한다. 넓은 예외의 크기는 `check-imports.py --summary`로 본다.

## 지침의 자리

- **HAR-19** AGENTS.md는 늘 실리는 지도다. 12KiB 아래를 목표로 한다. 16KiB를 넘으면 `scripts/check-docs.py`가 실패한다.
- **HAR-20** 경로별 세부는 `.claude/rules/`에 둔다. `paths` 글롭은 파일 하나 이상에 맞아야 한다.
- **HAR-21** 되풀이하는 절차는 `.claude/skills/`에 둔다. 스킬 본문은 500줄 미만이다.
- **HAR-22** 사실과 이유는 `docs/`에 둔다. 같은 문장을 두 곳에 두지 않는다.
- **HAR-23** Claude 밖 도구(예: Codex)는 AGENTS.md만 읽는다. 그래서 안전 불변식은 AGENTS.md 안에서 완결한다.
- **HAR-24** 규칙 ID(예: `SAFE-1`)는 번호를 다시 매기지 않는다. 지운 ID는 비워 둔다.

## 훅

- **HAR-25** 훅은 이 기계의 다른 Claude 세션에도 걸린다.
- **HAR-26** 훅은 에이전트의 실수를 줄이는 안내와 센서다. 안전 경계는 아래 코드 관문이다.
  - `RekordboxWriteGuard`
  - `TestProcess`
  - `UsbPhysicalWriteGate`
  - `CLIGuards`
- **HAR-27** 훅이 놓친 쓰기는 관문이 막아야 한다. 관문에 빠진 곳을 알게 되면 관문부터 고친다. 이때도 시험을 먼저 쓴다.
- **HAR-28** 막는 훅(`guard-bash.py`)은 셸 문법을 다 풀지 않는다. 단순한 규칙만 쓴다. 모르면 막는다.
- **HAR-29** 막는 훅은 아래 표의 명령을 막는다.

| 막는 것 | 자세히 |
|---|---|
| 보호 경로에 쓰기 | 보호 경로는 라이브 rekordbox 폴더, `/Volumes`, `/dev/disk*`다. 대소문자·`//`·지금 폴더 기준 상대 경로도 본다 |
| 보호 경로를 품은 폴더 지우기 | — |
| 쓰기 명령의 `--live` | — |
| `--allow-physical` | 어떤 명령이든 막는다 |
| 디스크 지우기·포맷·원시 쓰기 | 경로와 상관없이 막는다 |
| 읽기 명령 밖 `djc`에 라이브 경로 | — |
| 보호 경로가 글자로 든 코드 넘기기 | `python -c`·`perl -e`·`osascript`·`eval`·`bash -c`·here-document. 읽기도 막는다 |
| 보호 경로인 `DJC_REKORDBOX_DIR` | — |
| 보호 경로를 가리키는 링크 | — |

- **HAR-30** 막는 훅은 읽기 명령과 빌드 명령을 막지 않는다. 시험과 git도 막지 않는다.
- **HAR-31** Stop 훅은 경고만 한다.
- **HAR-32** 아래는 훅이 못 막는 알려진 한계다. 이것은 코드 관문이 막는다.
  - `git` 하위 명령 전부
  - 명령 치환, `read`, 이전 Bash 호출에서 정한 변수. 같은 명령 안의 `이름=값`과 `for` 변수는 따라간다.
  - 스크립트 파일 안의 쓰기(예: `python3 tool.py /Volumes/…`, `bash ./x.sh`)
  - 함수와 별칭
  - `cd "$변수"` 뒤 상대 경로
  - 보호 경로를 글자로 쓰지 않은 코드(예: `Path.home() / …`)
  - `rsync --delete`로 조상 폴더 비우기
- **HAR-33** 오탐·놓침을 고칠 때는 `scripts/test-harness.py`에 그 명령을 표본으로 더한다. 한계는 `LIMITS`에 더한다. 그 뒤 HAR-29·HAR-32를 맞춘다.

## 더 보기

- 검사 단계와 하네스 검사: [`docs/ci.md` "워크플로 검사"](../../docs/ci.md#워크플로-검사)
- 문장 규칙과 기준선: [`docs/ci.md` "문장 규칙(check-prose)"](../../docs/ci.md#문장-규칙check-prose)
- 통과 기록의 형식: [`docs/ci.md` "끝 요약과 통과 기록"](../../docs/ci.md#끝-요약과-통과-기록)
