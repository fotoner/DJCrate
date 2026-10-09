# 빌드·테스트 CI

이 문서는 로컬 검증 단계와 `scripts/check.sh` 모드, GitHub Actions CI를 설명한다.

## 로컬 검증 운영

TDD로 일하되, 단계마다 돌리는 범위를 달리해 매번 전체 검사를 돌리지 않는다. AGENTS.md의 "검증"은 이 절의 요약이다.

| 단계 | 언제 | 명령 | 목표 시간 |
|---|---|---|---|
| 편집 중 | Swift 파일을 고칠 때마다 | 모듈 경계 검사(Claude Code는 PostToolUse 훅이 `scripts/check-imports.py`를 알아서 돌린다) | 수 초 |
| 빨강·초록 | 시험을 쓰고 고칠 때 | `scripts/check.sh --quick --filter '^DJCDomainTests\.LoopPlannerTests/'`(시험·Suite 하나) | 10~60초(빌드 포함) |
| 작업 끝·합치기 | "됐다"고 말하기 전, `dev`에 합치기 직전, PR·`dev` 푸시 CI | `scripts/check.sh --changed` | 문서만 몇 초, Suite 몇 개 30초 안팎, 쓰기 그룹 변경 약 5분 |
| 릴리스 | `main`·`release/*` CI, 수동 실행, 사용자 요청 | `scripts/check.sh`(전체) | 8~9분 |
| 특수 | 해당 영역을 고칠 때만 | `--stress`(SQLCipher), 아래 "선택 실행 장치", 앱 자가 테스트 | — |

전체 검사는 릴리스 때만 돈다(2026-10-10 결정). 로컬에서는 릴리스 준비, 사용자 요청, `--changed`가 전체로 넓힐 때만 돌린다. `dev`에 합칠 때는 `--changed`로 확인한다. PR·`dev` 푸시 CI도 `--changed`만 돈다([CI 구성](#ci-구성)). `--changed`가 놓치는 회귀와 코어 커버리지(60%)는 릴리스 전체 검사가 잡는다.

| 명령 | 범위 | 쓰임 |
|---|---|---|
| `scripts/check.sh` | 가벼운 검사(빌드 전, 십여 초), 디버그·릴리스 앱, 번역, 전체 시험, 커버리지 목표(쓰기 80%, 코어 60%) | 릴리스·요청·넓히기 때 전체 검사 |
| `scripts/check.sh --changed [--base <rev>]` | 바꾼 파일에 닿는 시험·검사만(아래) | 작업 끝·`dev` 합치기·PR CI |
| `scripts/check.sh --quick --filter '<정규식>'` | 필터에 맞는 시험만, 같은 계측 빌드 재사용 | 편집 중 빨강·초록 |
| `scripts/check.sh --stress` | `CipherColdOpenTests` 필터(경쟁 1개·설정 계약 3개), `DJC_CIPHER_STRESS=1` | SQLCipher 처음 열기 경쟁(`.claude/rules/cipher.md`) |
| `scripts/check.sh --coverage` | 전체에서 릴리스 빌드만 제외. 앞의 가벼운 검사도 돈다 | 릴리스 CI에서 별도 러너의 `--release`와 함께 전체 검사 |
| `scripts/check.sh --release` | 릴리스 앱 빌드만 | 릴리스 CI에서 별도 러너의 `--coverage`와 함께 전체 검사 |

전체 검사와 `--coverage`는 빌드 전에 십여 초 걸리는 가벼운 검사를 먼저 돈다.

- 모듈 경계 검사(`scripts/check-imports.py`)
- 문서 검사(`scripts/check-docs.py`)와 문장 규칙(`scripts/check-prose.py`)
- 훅 검사(`scripts/test-harness.py`)
- 시험 지도 검사(`python3 scripts/affected-tests.py --check-map`)

quick·stress·changed는 릴리스 빌드와 전체 커버리지 보고를 하지 않는다. 계측 디버그 빌드는 모드마다 다르게 만든다.

- quick·stress: `swift build --build-tests --enable-code-coverage`로 시험 타깃 전체의 계측 디버그 빌드를 만들되, 이미 있으면 재사용한다.
- changed: 시험 타깃을 뺀 소스 타깃 전체(앱·CLI 제품 포함)를 `swift build --enable-code-coverage`로 먼저 빌드한 뒤 고른 시험 타깃만 빌드한다. 그래서 앱이나 CLI에 컴파일 오류가 있으면 changed도 실패한다. 이 빌드로 더 드는 시간은 공개 인터페이스가 그대로면 약 3초, DJCDomain 공개 API를 바꾸면 17~19초다.

quick의 필터는 Swift 시험 필터 정규식이다. 타깃 이름으로 앵커하면 그 타깃의 시험만 돈다(예: `'^DJCDomainTests\.LoopPlannerTests/'`). 다음 경우는 성공시키지 않는다.

- 빈 필터
- 고른 시험이 0개
- 틀린 인자
- 모든 시험을 건너뜀

`Tests`처럼 거의 모든 시험에 맞는 필터로 전체 검사를 대신하지 않는다. `--stress`는 단독으로 쓴다.

### `--changed`

`--changed`는 바뀐 파일에 닿는 시험과 검사만 고른다. 고르기만 미리 보려면 `python3 scripts/affected-tests.py [--base <rev>] [--files <경로…>] [--json]`을 쓴다.

바뀐 파일은 기준과의 `git diff --no-renames`에 추적 안 된 파일을 더한 것이다. 추적 안 된 파일 가운데 `.gitignore`에 맞는 파일은 뺀다. 이름을 바꾼 파일은 옛 경로와 새 경로가 둘 다 바뀐 파일이다.

- `--base <rev>`를 주면 그 값을 기준으로 그대로 쓴다. merge-base를 다시 구하지 않는다. 트리 해시를 기준으로 주면 내용이 같은 파일은 뺀다.
- `--base`가 없으면 `git merge-base HEAD dev`를 기준으로 쓴다. 그것이 없으면 `origin/dev`, 그것도 없으면 `main`을 쓴다.
- 조정자가 파트 워크트리를 따로 확인할 때는 작업 전에 `git write-tree`로 뜬 시작 트리를 `--base`로 준다.

`--changed`는 다음 순서로 돈다.

1. 고른 범위와 이유, 필터를 출력한다. 이유는 파일 → 규칙 → Suite 순서로 보인다.
2. Swift 변경이 있으면 모듈 경계 검사를 돈다.
3. 소스 타깃 전체를 빌드한 뒤 고른 시험 타깃을 빌드한다.
4. 고른 시험을 돌린 뒤 1개 이상 끝났는지 필터 결과로 본다.
5. 바뀐 파일에 따른 조건부 검사를 돈다.

Swift 소스를 바꾸면 그 파일이 선언한 타입을 쓰는 Suite를 고른다. 시험 파일을 바꾸면 그 파일의 Suite를 고른다. 그 밖의 경우는 다음 표를 따른다.

| 바뀐 파일 | 돌리는 것 |
|---|---|
| `Package.swift`, `Package.resolved`, `scripts/check.sh`, `.github/**` | 전체 검사로 넓힌다 |
| 어느 규칙에도 맞지 않는 파일 | 전체 검사로 넓힌다 |
| 시험 재료(`Tests/Support/**`) | 그 재료를 쓰는 시험 타깃 전체 |
| Suite가 없는 시험 파일(가짜·하네스·도우미) | 그 시험 타깃 전체 |
| 시험이 닿지 않는 소스 | 그 모듈에 의존하는 시험 타깃 전체 |
| `Sources/djc/**`, `Sources/djcExecutable/**`, `Sources/DJCAdapters/**` | djcTests 전체를 더한다(시험 실행 약 6초) |
| 화면 문구, `Localizable.xcstrings`, `scripts/i18n.swift` | 번역 검사 |
| 쓰기 커버리지 그룹 파일 | 쓰기 그룹 커버리지(80%). 코어 60%는 전체 검사·CI만 본다 |
| 문서, `skills/**` | `scripts/check-docs.py`와 문장 규칙 |
| 하네스: `scripts/hooks/**`, `.claude/**`, `scripts/test-harness.py`, `scripts/check-docs.py`, `scripts/check-prose.py`, `scripts/prose-*.txt`, `scripts/worker-lock.sh` | `scripts/test-harness.py`와 `scripts/check-docs.py`. 이것만 바뀌면 넓히지 않는다 |
| 검사 스크립트: `scripts/test-check.py`, `affected-tests.py`, `test-map.txt`, `check-imports.py`, `ci-base.sh`, `ci-mtimes.py`, `check.sh` | `python3 scripts/test-check.py`. `check.sh`는 전체 검사로도 넓힌다 |
| `Sources/**`, `Tests/**`(위 시험에 더해) | 안전 시험 선택 검사: `python3 scripts/test-check.py affected-real-map safety-`(몇 초) |

고른 Suite가 전체의 절반을 넘어도 전체 검사로 넓힌다. 넓힐 때는 이유를 담아 `▸ 전체 검사로 넓힙니다: <이유>`를 출력한다. 넓힌 실행은 문서·훅 검사를 포함해 전체 검사와 같은 단계를 돈다. 검사 스크립트가 바뀌었으면 `scripts/test-check.py`도 돈다. 전체 검사만으로는 이 검사가 돌지 않는다.

djcTests는 `.build/debug/djc`를 명령 문자열로 띄워서 기호 grep이 닿지 않으므로 경로로 고른다.

쓰기 그룹 커버리지는 RekordboxKitTests·DJCApplicationTests·DJCAdaptersTests를 통째로 돌려 잰다. 그래서 쓰기 그룹 파일을 바꾼 `--changed`는 약 5분 걸린다. 그 밖의 변경은 고른 Suite만 돈다.

Swift·Package 변경이 없으면(문서만) 빌드와 시험 없이 가벼운 검사만 돈다. 지운 시험 파일처럼 시험이 없는 변경은 빌드만 한다.

허용하지 않는 조합은 종료 코드 2로 거부한다.

- `--changed --filter`
- `--changed` 없는 `--base`
- `--base`의 값이 없음, 빈 값, `--`로 시작하는 값
- `--changed` 두 번
- `--changed --stress`
- `--no-reuse` 두 번

안전 시험 묶음, 필수 검사, 시험 없는 파일 같은 수기 묶음은 `scripts/test-map.txt`에 둔다. 경로와 Suite 목록은 그 파일이 정본이다. 안전 묶음은 기호가 아니라 경로로 넓게 고른다.

| 묶음 | 바뀐 경로 | 고르는 시험 |
|---|---|---|
| `rekordbox-safety` | rekordbox 쓰기 입구·백업·복원, 쓰기 대상을 정하는 위치 값, 조립 지점, CLI 명령 | 관문·백업·복원·복원 대상 시험 |
| `usb-safety` | 모든 모듈의 `Usb/`, USB 조립 지점·명령·lab | USB 쓰기 안전·실물 관문·임시 폴더·CLI·앱 실물 거부 시험 |
| `test-isolation` | 환경 읽기, 데이터 폴더 위치 | 시험 격리 시험 |

지도 문법은 `scripts/test-map.txt` 머리에 있다. 그중 `require <글>` 줄은 `--changed`가 대신하지 않는 필수 검사다. 그래서 통과해도 요약 끝에 `⚠ 남은 필수 검사: …`가 남는다. 지금 필수 검사는 다음 둘이다.

- cipher → `--stress`
- 관찰 범위 → `DJC_LAYOUT_RECOMPUTE_TESTS=1 … LayoutRecomputeTests`

이 줄은 결과 보고에 함께 적는다. 필수 검사에 해당하는 변경이면 그 검사를 돌린다.

지도는 저장소와 맞아야 하므로, 다음이 있으면 `--changed`와 `python3 scripts/affected-tests.py --check-map`이 종료 코드 2로 멈춘다.

- 없는 Suite
- 어느 파일에도 맞지 않는 `when`

멈출 때는 줄 번호와 묶음 이름을 낸다. Suite 이름 바꾸기, Suite 지우기, 파일 옮기기 뒤에는 지도도 함께 고친다. 일부러 비워 둔 자리는 `maybe`로 적는다.

선택은 기호 이름 grep이라 놓치는 경우가 있다. 프로토콜로만 닿는 구현, 전역 함수, 다른 타입을 거친 동작 변화 등이다. 이 몫은 릴리스 전체 검사(`main`·`release/*` CI)가 잡는다. 놓친 회귀를 알게 되면 `scripts/test-map.txt`에 줄을 더한다.

### 끝 요약과 통과 기록

모든 모드는 취소한 실행까지 끝에 요약 블록을 낸다. 요약 블록에는 다음이 들어간다.

- 단계별 `✔`/`✘`와 초
- `✔ 통과: <모드> … · 총 N초 · 시험 N개` 또는 `✘ 실패: <모드> · 종료코드 N`
- 실패면 실패한 시험과 첫 오류 줄(최대 10개). 오류 줄이 없으면 단계 로그 끝 5줄
- 시험 단계가 멈췄으면 끝나지 않은 시험과 스택 요약([시험 멈춤 감시](#시험-멈춤-감시))
- 마지막 줄 `로그: <로그 폴더>`

결과 보고는 이 블록의 수치로 한다. 자세한 것은 로그 폴더의 단계 로그에서 grep한다.

빌드·시험 원문은 단계 로그 파일에만 남는다. 화면에는 실패 줄, 시험 실행 요약 줄, 끝 블록만 나온다. 진행 줄은 60초마다 나온다. 원문을 화면에 보려면 `DJC_CHECK_VERBOSE=1`을 준다.

통과하면 `.build/check-logs/last-pass`에 한 줄을 쓴다. `DJC_CHECK_LOG_ROOT`를 주면 그 폴더 아래에 쓴다. 같은 줄을 `pass-history`에도 더한다(최근 200줄). 줄은 탭으로 나눈 `이름=값`을 이 순서로 담는다: `v=1 mode= filter= head= tree= key= log= seconds= time= cover= requested= scope= base=`.

| 칸 | 뜻 |
|---|---|
| `mode` | 실제로 돈 모드. `--changed`가 넓혀지면 `full`, `requested=changed`다 |
| `tree` | 작업 트리 해시. `python3 scripts/affected-tests.py --worktree-tree`와 같은 값 |
| `scope` | 실제로 돈 범위(`full`·`tests`·`build`). 빌드·시험 없이 가벼운 검사만 돈 `--changed`는 `none` |
| `base` | `--changed`의 기준. 그 밖은 `none` |

다음 실행은 기록하지 않는다.

- 실패한 실행
- 시작과 끝의 작업 트리 해시가 다른 실행
- 설치한 앱이 켜진 채 사용자 폴더가 바뀐 실행(⚠로 끝난 실행)

해시는 임시 index에 `git add -A`로 떠서 구하므로, 추적 안 된 큰 사본·음원을 작업 트리에 두면 느려진다. 그 파일은 `.git/objects`에도 쌓인다. 사본은 작업 트리 밖 임시 폴더에 둔다.

커버리지를 읽는 실행은 전체 검사, `--coverage`, 쓰기 그룹이 바뀐 `--changed`다. 이전 실행의 프로파일로 재지 않도록, 이 실행은 시험 단계 전에 `default.profdata`를 지운다. 시험이 이 파일을 새로 만들지 않으면 실패한다.

같은 조건의 통과 기록이 이력에 있으면 다시 돌리지 않는다. 이때 `재사용: <로그 폴더>`만 출력한 뒤 종료 코드 0으로 끝난다. 같은 조건(`key`)은 다음 값이 모두 같다는 뜻이다.

- 작업 트리
- 모드와 필터
- 기준
- 툴체인
- `DJC_` 환경 변수

같은 작업 트리의 전체 검사(`mode=full`) 통과는 `--changed`만 대신한다. `--quick`은 필터가 1개 이상 맞는지 봐야 하므로 같은 `key`일 때만 재사용한다. 0개 맞는 필터는 늘 실패한다. stress는 확률 시험이라 늘 다시 돈다.

기록의 로그 폴더를 지웠으면 다시 돈다. 일부러 다시 돌리려면 `--no-reuse`를 붙인다.

Claude Code의 Stop 훅(`scripts/hooks/stop-verify-reminder.py`)은 작업 끝 검증 기록을 본다. Swift·Package 변경이 있으면 `last-pass`와 `pass-history`를 읽는다. 지금 작업 트리(`tree`)의 `changed`·`full` 통과 기록이 없으면 `--changed`를 권하는 경고를 낸다. 훅은 경고만 낼 뿐 막지 않는다. 다음 기록은 작업 끝 검증으로 보지 않는다.

- `quick`, `coverage`, `release`, `stress` 통과
- `scope=none` 기록

이 경고는 `systemMessage`라 사용자에게만 보이므로 모델 맥락에는 들어가지 않는다. 에이전트가 작업 끝에 `--changed`를 돌게 하는 것은 AGENTS.md "검증"과 스킬 `verify-change`의 지침이다.

통과 결과는 코드·툴체인과 빌드 설정·시험 환경이 모두 같을 때만 재사용한다. 코드·의존성이나 설정·환경이 바뀌면 그 영향이 닿는 검사만 다시 한다.

단순 병합으로 커밋만 바뀐 경우, 검증한 코드와 조건이 같으면 다시 돌리지 않는다. 캐시 복원은 시험 통과의 근거가 아니므로, 실제로 실행한 범위만 검증 결과로 보고한다.

### 안전 장치

안전 장치는 모든 모드에서 같다. 따로 주지 않으면 실행 로그 폴더 아래의 임시 `DJC_REKORDBOX_DIR`·`DJC_HOME`을 쓴다. 검사가 끝나면 다음을 검사 전과 비교한다.

| 바뀐 것 | 결과 |
|---|---|
| 실제 rekordbox 라이브러리 파일(`master.db`·`masterPlaylists6.xml`·분석 파일) | 종료 코드 3으로 실패 |
| DJCrate 사용자 폴더(`~/Library/Application Support/DJCrate`)·로그 폴더(`~/Library/Logs/DJCrate`)의 파일 목록·크기·수정 시각 | 종료 코드 4로 실패. 설치한 DJCrate 앱이 켜져 있었으면 알리기만 한다 |
| `~/Library/Preferences`에 남은 이번 실행 접두사(`DJC_TEST_DEFAULTS_PREFIX`)의 시험 환경설정 plist | 종료 코드 4로 실패 |

`swift test`를 직접 돌릴 때도 두 변수를 임시 폴더로 준다.

### 잠금과 동시 실행

같은 checkout에서는 다음을 동시에 실행하지 않는다.

- `swift build`와 `swift test`
- Swift를 호출하는 검사·번역 스크립트
- 성능 측정

공유 작업 트리에서는 담당자와 실행 슬롯을 합의한 뒤 단계별 진행 로그를 남긴다. 다른 담당자는 같은 후보의 로그를 검토한다. 전체 검증 명령을 고정 240초에 끊어 다시 시작하지 않는다. 빌드·시험·보고는 단계별 진행 로그와 종료 코드로 관찰한다.

| 잠금 | 무엇을 감싸나 |
|---|---|
| `lockf /tmp/djc-heavy.lock <명령>` | 여러 워크트리가 한 기계를 나눠 쓸 때의 전체 검사·앱 자가 테스트·성능 측정(`--resize-perf` 등) |
| `/tmp/djc-audio.lock` | 소리를 내는 실행. 빌드와 별도 구간으로 나누고 본인이 잡은 잠금 안에서 5분 이하로 끝낸다 |
| `/tmp/djc-gui.lock` | 창을 앞에 두거나 앱 안에 키를 넣는 실행(키 전달 시험·캡처) |

앱 자가 테스트의 인자·조건과 키 전달 시험·화면 캡처는 `.claude/skills/app-selftest/SKILL.md`에 있다.

### 선택 실행 장치

여기 적은 시험은 전체 검사(`scripts/check.sh`)에서도 평소에 건너뛰는 시험과 줄여서 도는 시험이다. 해당 영역을 고칠 때 직접 켜서 돌린다.

| 장치 | 평소 | 켜면 | 언제 돌리나 |
|---|---|---|---|
| `DJC_CIPHER_STRESS=1` | 미설정·`0`: cold-open 새 프로세스 4개 | 새 프로세스 100개(`scripts/check.sh --stress`가 켠다, 그 밖의 값은 실패) | `CipherDatabase` 초기화·`CipherLab`·cold-open 경쟁 변경(필수) |
| `DJC_FULL_RELEASE_COMBINATIONS=1` | `RekordboxTagReleaseTests`의 여러 칸 한 번에 쓰기를 짝 조합 42가지로 | 칸 묶음 26 × 값 종류 3 × 상태 2 = 156가지 전부 | 아티스트·앨범 아티스트·앨범·작곡가·장르 쓰기 순서·행 버리기 규칙을 고칠 때 |
| `DJC_LAYOUT_RECOMPUTE_TESTS=1` | `LayoutRecomputeTests`(창 크기·여닫기 때 본문 다시 계산 횟수) 스위트 전체를 건너뛴다. 전체 검사도 켜지 않는다 | 실제 창을 띄워(`orderBack`, 활성화·입력 없음) 횟수 상한을 본다 | 관찰 범위·덱 높이·레이아웃을 고칠 때. 다른 UI 시험과 겹치지 않게 단독으로 |
| `DJC_LAYOUT_BENCHMARK_DB=<사본>` | 꺼짐 | 위 스위트를 그 사본으로 돌리고 `저부하_배치_성능_기록`도 돈다 | 성능 A/B 기록 |
| `.perfContract` 태그 | 다른 시험과 함께 돈다(`LayoutRecomputeTests`만 위 변수 필요) | — | 관찰 범위를 좁혀 둔 곳이나 이 태그의 시험을 고칠 때. 묶음 전체를 다시 돌린다 |

`.perfContract` 묶음은 뷰 본문 다시 계산 횟수와 관찰 범위를 지킨다. 경로 캐시와 창 크기 측정 기록도 지킨다(#129·#137·#138). 관찰 범위를 좁혀 둔 곳은 다음과 같다.

- `ContentView` 하위 뷰
- `TrackTable.updateNSView`
- 사이드바 줄 뷰

이 태그가 붙은 시험은 다음과 같다.

- `LayoutRecomputeTests`
- `ResizePerfTests`
- `SidebarObservationTests`의 일부
- `WaveformBandPathCacheTests`의 일부

묶음 전체는 다음 명령으로 돌린다. 이 명령은 시험 이름으로 거르므로 같은 파일의 태그 없는 시험도 함께 돈다.

```bash
DJC_LAYOUT_RECOMPUTE_TESTS=1 scripts/check.sh --quick --filter 'LayoutRecomputeTests|ResizePerfTests|SidebarObservationTests|WaveformBandPathCacheTests'
```

창 크기 변경의 본문 다시 계산 회귀는 `DJC_LAYOUT_RECOMPUTE_TESTS=1 scripts/check.sh --quick --filter 'LayoutRecomputeTests|LibraryLayoutMetricsTests|DeckLayoutTests|ResizePerfTests'`로 단독 실행한다. 이 변수가 없으면 전체 검사에서도 건너뛴다. 시험은 덱·파형이 들어맞는 세로 40단계에서 본문 횟수 상한을 본다.

- `LibraryDetail`: 2회 이하
- `DeckView`: 5회 이하
- 파형 높이 메뉴 문맥(`LibraryWaveformHeightContext`): 2회 이하

낮은 창, 내용 변경, 수동 파형 높이 복원도 검사한다. 시험 창은 `orderBack`으로 열어 활성화하지 않는다. 실제 입력도 보내지 않는다.

## 진행 로그·실패 진단

`scripts/check.sh`는 단계마다 UTC 시작·종료 시각, 경과 초, 종료 코드를 출력한다. 명령 출력은 단계별 로그 파일에 쓴다. 단계가 오래 걸리면 60초마다 `▸ 진행` 줄로 경과 시간을 알린다. 시간은 다음 단계로 나눠 잰다.

- 디버그·테스트 컴파일
- 릴리스 빌드
- 번역
- 전체 시험 실행·프로파일 수집
- 커버리지 보고·목표 검사

SwiftPM의 시험 실행 명령은 프로파일 병합·내보내기도 하므로 이 단계 전체를 순수 시험 실행 시간으로 부르지 않는다.

화면에서는 [끝 요약 블록](#끝-요약과-통과-기록)을 읽는다. 원래 출력은 아래 로그에서 본다. 로컬 로그는 `.build/check-logs/run.XXXXXX/`에 쌓인다. `DJC_CHECK_LOG_ROOT`로 상위 폴더를 바꿀 수 있다. 실행마다 새 폴더를 만들어 이전 성공 결과와 섞지 않는다.

| 파일 | 내용 |
|---|---|
| `debug-build.log`, `release-build.log`, `translations.log`, `test.log`, `coverage.log` | 단계별 원래 출력 |
| `timings.tsv` | 단계별 초·종료 코드 |
| `exit-code.txt` | 전체 종료 코드 |
| `coverage.txt` | 파일별 커버리지 집계 입력 |
| `stall.txt` | 시험 단계가 멈췄을 때 끝나지 않은 시험과 스택 요약 |
| `stall-sample-<pid>.txt` | 시험 단계가 멈췄을 때 시험 프로세스의 `sample` 원문 |

실패한 단계 뒤의 로그는 생기지 않는다.

명령이나 `tee`가 실패하면 `pipefail`로 검사가 실패한다. INT는 130, TERM은 143으로 끝난다. 이때 이 검사가 시작한 자식 빌드와 진행 알림도 끝낸다. 강제 KILL과 러너 장애는 종료 요약을 남길 기회가 없어 부분 로그만 남을 수 있다.

CI는 로그를 캐시 밖인 러너 임시 폴더에 저장한다. `always()` 단계에서는 Job summary와 14일 보관하는 `check-logs-<mode>-<run_id>-<attempt>` artifact를 남긴다. 업로드 대상은 검사·툴체인 텍스트 로그뿐이라 DB·스냅샷은 올리지 않는다. 프로파일·실행물도 올리지 않는다.

취소 때에도 로그 보존을 시도한다. 강제 종료나 러너 유실 때는 업로드를 보장하지 않는다.

### 시험 멈춤 감시

시험 단계(`swift test`)의 로그가 300초 동안 자라지 않으면 `check.sh`는 그 단계가 멈췄다고 본다. 그때 다음을 한 뒤 종료 코드 124로 끝난다.

1. `✘ 멈춤: <단계>` 줄을 낸다.
2. 끝나지 않은 시험을 로그 폴더의 `stall.txt`에 적는다. 대상은 시작 줄만 남긴 시험과 Suite다. 마지막에 시작한 것부터 12개를 적는다.
3. 시험 프로세스의 스택을 `sample <pid> 5`로 떠서 `stall-sample-<pid>.txt`에 둔다. 대상은 셸·`tee` 밖의 자손 프로세스다. 최대 4개를 뜬다.
4. 시험 프로세스를 TERM으로 끝낸다. 5초 안에 끝나지 않은 자손은 KILL한다.

시작 줄은 swift-testing의 `◇ Test … started.`와 XCTest의 `Test Case '…' started.`다. 끝 줄은 `passed`·`failed` 줄이다. 끝 요약에는 `stall.txt`의 내용이 나온다. 그 내용은 끝나지 않은 시험과 스택 맨 위 함수 몇 줄이다. CI에서는 Job summary와 로그 artifact에도 남는다.

`DJC_CHECK_STALL_SECONDS=<초>`로 기준을 바꾼다. 0이면 감시를 끈다. 정수가 아니면 종료 코드 2로 거부한다. 빌드 단계는 보지 않는다. 릴리스 최적화 빌드는 몇 분 동안 출력이 없을 수 있다.

기준을 300초로 둔 근거는 run 37983504195다. 이 실행에서 정상 시험 출력이 가장 오래 끊긴 시간은 115초였다. DJCrateTests는 650초 동안 출력을 내지 않았다. 그 뒤 job 제한 30분이 실행을 끝냈다. 그래서 끝나지 않은 시험도, 스택도 남지 않았다.

비동기 시험이 `await`에서 멈추면 그 작업은 스레드 스택에 없다. 그때는 스택보다 끝나지 않은 시험 목록이 먼저 볼 단서다.

디버그 앱·CLI·시험은 `swift build --build-tests --enable-code-coverage`로 함께 빌드한다. 번역 검사에도 같은 계측 옵션을 넘겨 설정 전환에 따른 재컴파일을 피한다. 앱과 CLI를 실제로 빌드하는 기존 검증은 그대로 둔다. full·coverage에서는 이어서 `swift test --skip-build --enable-code-coverage`로 **전체 시험을 실행**한다. 따로 실행하는 `swift scripts/i18n.swift check`·`sync`의 기본 빌드 설정은 바뀌지 않는다. full의 시험 병렬성과 커버리지 목표는 그대로다.

## 테스트 준비 비용

DB 연결은 SQLCipher 키 유도 때문에 비싸므로, 시험은 필요한 재료만 준비한다.

`DeckHarness`는 가짜 오디오, 메모리 저장소, 가짜 곡 읽기를 쓴다. 가짜 곡 읽기는 `TrackAssetReader.memory`와 `MemoryTrackAssets`다. 합성 WAV는 음원이 필요한 시험만 만든다. 이 하네스는 임시 폴더만 만들 뿐 DB 재료(`RekordboxFixtures`)는 가져오지 않는다.

임시 폴더만 필요한 시험은 `TemporaryFolder`(DJCTestKit)를 쓰므로 `RekordboxFixture`를 만들지 않는다. DB가 필요한 통합 시험은 계속 `RekordboxFixture`를 쓴다.

`RekordboxFixture`는 암호화 설정을 유지한 채 스키마와 초기 행을 한 연결, 한 트랜잭션으로 준비한다. 곡·재생 목록의 여러 행도 각각 한 트랜잭션으로 넣는다. 준비 중 실패하면 연결을 닫을 때 미완료 트랜잭션을 되돌린다. 파일은 픽스처마다 따로 쓴다. 실제 쓰기·복원 뒤 다시 읽는 연결은 공유하지도, 캐시하지도 않는다.

시험 시간의 대부분은 SQLCipher 키 유도였다. 키 유도 한 번은 PBKDF2 256,000번 반복이라 연결마다 약 55ms가 든다. CI 러너는 3코어라 시험 시간이 거의 CPU 합 ÷ 3이다. 픽스처가 연결마다 키를 유도하던 때의 CI 시험 시간은 2026-10-06 886초, 10-07 1,131초였다. 이 값은 RekordboxKitTests의 CPU 합 ÷ 3(약 957초)과 맞았다.

그래서 픽스처는 키 유도를 두 가지로 줄인다.

- 프로세스마다 한 번, 제품과 같은 `CipherDatabase`·문자열 키로 템플릿 DB를 만든다. 픽스처는 이 템플릿을 복사한다.
- 시험 쪽 연결(`FixtureConnection`)은 파일 머리의 솔트로 키를 솔트마다 한 번만 유도한다. 그 뒤 원시 키(`x'…'`)로 연다.

원시 키로 열지 못하면 문자열 키로 다시 연다. 시험은 픽스처마다 센 이 횟수(`passphraseFallbacks`)가 0이기를 기대한다. 파일 형식과 키는 그대로다. 제품 코드와 `fixture.open()`은 늘 문자열 키로 연다.

로컬(14코어) 측정에서 RekordboxKitTests 벽시계 시간은 240 → 106초였다. CPU 시간은 2,867 → 1,208초(−58%)였다. 이 측정은 다른 빌드와 겹친 부하에서 했다. CI 추정은 7~8분이라, 실제 CI 시간은 dev에 합친 뒤 첫 실행으로 확인한다.

남은 비용은 두 가지다.

- 제품 쓰기·검증·복원 경로의 키 유도. 바쁜 CPU의 약 47%다.
- `OneLibraryFixture`의 문자열 키 열기

## 시간 비교 방법과 기준

시간마다 담는 범위가 다르므로 시험 본문 시간, 전체 CI 시간, 로컬 명령의 wall 시간은 나눠 보고한다.

| 시간 | 담는 범위 |
|---|---|
| 시험 로그의 `Test run ... passed after ...` | 그 시험 실행 구간. 병렬 suite·test 시간은 겹치므로 합산하지 않는다 |
| `timings.tsv`의 테스트 단계 | SwiftPM 실행·프로파일 수집 포함 |
| 전체 CI 시간 | 러너 준비·캐시 복원·검사·캐시 저장 포함 |
| 로컬 wall 시간 | 실행한 명령의 시작부터 종료까지 |

서로 다른 범위의 수치를 개선 전후로 비교하지 않는다.

30초는 같은 계측 빌드가 이미 있는 warm 상태에서 관련 시험에 집중할 때의 개발 피드백 목표다. cold 빌드, 전체 검사, 전체 호스티드 CI의 제한 시간이 아니다. 같은 필터와 코드로 실제로 재기 전에는 달성을 보장하지 않는다. 툴체인과 환경도 같아야 한다.

[PR #111 기준 실행](https://github.com/fotoner/DJCrate/actions/runs/36303819883/job/108581536945)은 attempt 2, SHA `7f2395c74307299a222175c1a069dce7a79086f5`, `xcode-27`이었다. 아래 구간은 API의 그 attempt/job 시각과 로그로 나눴다.

| 구간 | 기준 시간 | 해석 |
|---|---:|---|
| job 생성 → 러너 시작 | 9초 | 08:15:08 → 08:15:17 UTC; 재실행 전 대기와 섞지 않음 |
| job 실행 전체 | 18분 10초 | 준비·캐시 복원·검사·캐시 저장 포함 |
| 검사 명령 전체 | 약 17분 20초 | 08:15:42 → 08:33:02 UTC |
| 디버그 빌드 구간 | 약 91초 | 두 번 호출 합계; 첫 호출 시간은 로그에서 분리 불가 |
| 릴리스 빌드 | 약 196초 | Swift가 보고한 빌드 자체는 193.99초 |
| 번역 | 약 32초 | 내부 앱·CLI 빌드 포함 |
| 테스트 단계 | 약 11분 58초 | 컴파일·실행·프로파일 수집 포함, 기존 로그로 각각 분리 불가 |
| 커버리지 보고·목표 검사 | 약 2.4초 | 테스트 명령 종료 뒤 집계 |

기준 결과는 시험 1,049개, 쓰기 93.0%, 코어 88.9%다. 번역 누락·stale은 0이다.

이 실행은 이전 커밋 캐시를 복원했는데도 디버그·릴리스 빌드 시간이 들었다. 그래서 캐시 복원을 컴파일 생략으로 해석하지 않는다.

기존 스크립트는 디버그 빌드를 두 번 직접 호출했을 뿐 아니라, 번역 뒤에 커버리지 설정으로 디버그·테스트를 다시 빌드했다. 바꾼 스크립트는 이 중복 호출과 계측 설정 전환을 줄인다. 시험 본문의 실행 시간은 그대로 남는다.

호스티드 비교는 수동 실행으로 `use_cache=false`와 `use_cache=true`를 각각 돌려 기록한다. 두 실행은 SHA·러너 이미지와 툴체인·검사 범위를 같게 둔다. 꺼진 실행은 캐시 복원·저장을 모두 건너뛴다. 켜진 실행은 정확 키 일치, 이전 키 복원, 캐시 없음으로 나눈다. 실제 캐시 키와 `Build complete`·컴파일 로그도 확인한다.

`cancel-in-progress`가 앞 실행을 취소하지 않도록 캐시 저장이 끝난 뒤 다음 실행을 시작한다.

비교 보고에는 다음을 함께 적는다.

- run ID·attempt·SHA
- job 생성/시작/종료 시각
- 캐시 키, 복원·저장 시간
- 각 단계 시간
- 시험 수·커버리지·종료 코드

로컬 측정에는 다른 작업의 부하를 기록한다(예: 동시 빌드·GUI 검사). 빈 `.build`인지 기존 `.build`인지도 적는다. 로컬 시간 차이는 호스티드 CI 개선 수치가 아니다. 위 기준 실행은 기존 캐시를 복원한 사례 한 건이다. 그래서 변경 후 cold/warm 측정과 일대일로 성능 차이를 단정할 수 없다.

### 창 크기 변경 측정

시간 회귀를 비교할 때는 같은 합성 `UIPerfFixtureCapture` 사본과 디버그 계측 빌드에 `--resize-perf=all --resize-perf-repeats=3 --perf-preview=off --text-scale=1`을 준다. `DJC_DB`·`DJC_REKORDBOX_DIR`·임시 `DJC_HOME`과 `/tmp/djc-heavy.lock`을 쓴 채 전→후→후→전 순서로 실행한다. 첫 왕복을 뺀 `RESIZE_SUMMARY`에서 다음을 함께 비교한다.

- 단계 중앙값/최댓값
- 프레임 간격
- CPU
- 본문 횟수
- 1·5·15분 load average

`RESIZE_STEP`은 단계별 원본이다. 크기 요청 자체에서도 배치가 일어날 수 있으므로 `layout_flush_ms`만 전체 레이아웃 비용으로 해석하지 않는다. `display_flush_ms`는 표시 처리 호출 비용, `zoom_draw_ms`는 확대 파형 Canvas 실행 비용이다. 디스플레이 링크 콜백 간격은 실제 화면 표시 FPS나 물리 입력 지연이 아니다.

`interval_ms`는 다음 호출을 나눠 잰다.

| 구간 | 호출 |
|---|---|
| `table.resize`·`table.columns`·`table.layout` | 표의 `resize(withOldSuperviewSize:)`·`sizeToFit()`·`layout()` |
| `swiftui.deck.size`·`swiftui.deck.place` | 덱의 SwiftUI 제안 크기 측정·배치 |
| `overview.static.draw`·`overview.playhead.draw` | 전체 파형의 정적 내용·재생선 Canvas |

각 항목에는 호출 횟수(`count`)와 ms 값이 있다(`median`, `max`, `total`). 한 구간이 다른 구간을 품을 수 있으므로 합산하지 않는다. SwiftUI 경계는 같은 제안을 하위 뷰로 넘기는 디버그 측정용 Layout이다. 경계 밖에서 나중에 일어나는 CoreGraph 갱신이나 GPU 표시 시간 전체는 재지 않는다.

표본이 없는 구간은 그 호출을 관찰하지 못한 것이지, 비용이 없다는 뜻이 아니다. 기본 화면과 `--perf-hide=zoom`, `--perf-hide=overview`를 각각 같은 전→후→후→전 순서로 비교한다. 결과에는 `hidden`·부하·설정 복원 결과를 함께 남긴다.

전체 파형은 같은 원본·시간축·크기의 3밴드 경로를 최대 네 개 보관한다. 반복 생성이 줄었는지는 `WaveformBandPath.build` 본문 횟수로 확인한다.

## CI 구성

`.github/workflows/check.yml`은 실행 계기에 따라 검사 범위가 다르다. 릴리스가 아니면 바뀐 부분에 닿는 시험만 돈다(2026-10-10 결정). 매일 도는 예약 전체 검사는 두지 않는다.

| 실행 계기 | job | 하는 일 |
|---|---|---|
| `dev` 푸시, 그 밖의 PR(대상이 `main`이 아니고 `release/*`에서 오지 않은 PR) | `changed` | `scripts/check.sh --changed --base <비교 기준>` |
| 릴리스: `main`·`release/*` 푸시, `main` 대상 PR, `release/*`에서 온 PR, 수동 실행(`workflow_dispatch`) | `coverage` | 계측 디버그 앱·CLI·시험 빌드, 번역 검사, 전체 시험, 줄 커버리지 목표(쓰기 80%, 코어 60%) |
| 릴리스 | `release` | 릴리스 앱 빌드, 검사 스크립트 회귀(`scripts/test-check.py`) |
| 수동 실행에서 `run_stress=true` | `stress` | 별도 러너에서 stress 검사 |

릴리스는 전체 검사를 두 러너에 나눠 동시에 돌린다. 시험 수와 커버리지는 Actions의 Job summary에 남긴다. changed job의 Job summary에는 비교 기준, 고른 범위, 끝 요약 블록이 남는다. CI는 오디오·UI 앱 자가 테스트를 돌리지 않는다. 앱 설치·서명·배포도 하지 않는다.

### changed의 비교 기준

`scripts/ci-base.sh`가 비교 기준을 정한다. changed job은 비교 기준과 견줄 수 있게 기록을 모두 받는다(`fetch-depth: 0`).

| 실행 계기 | 비교 기준 |
|---|---|
| PR | 체크아웃한 병합 커밋과 `origin/<PR 기준 브랜치>`의 merge-base. 이 값은 병합 커밋의 첫 부모, 곧 기준 브랜치 끝이다 |
| 푸시 | 앞 끝(`github.event.before`) |

다음 경우에는 기준을 비운다. 그러면 전체 검사(`scripts/check.sh`)로 넓힌다. 조용히 좁히지 않는다. 넓힌 이유는 경고 주석과 Job summary에 남는다.

- 새 브랜치: `before`가 `000…`이거나 비어 있다.
- 강제 푸시(`github.event.forced`)
- 앞 끝이 지금 커밋의 조상이 아니다. 받은 기록에 없는 경우도 같다.
- PR 기준 브랜치와의 merge-base를 구하지 못했다.

기준을 구해도 `--changed`가 스스로 넓힐 수 있다. `Package.swift`·`scripts/check.sh`·`.github/**`가 바뀐 경우가 그렇다. 고른 Suite가 절반을 넘는 경우도 같다([`--changed`](#--changed)). 넓힌 changed job은 한 러너에서 전체를 차례로 돌기 때문에 릴리스의 두 러너보다 길다.

푸시 실행은 앞 실행을 취소하지 않는다. 푸시는 앞 끝과의 차이만 보므로, 앞 실행을 취소하면 그 차이를 아무도 검사하지 않는다. PR 실행은 새 푸시가 앞 실행을 취소한다. PR은 늘 기준 브랜치와 비교하므로 놓치는 변경이 없다.

`--changed`가 놓칠 수 있는 회귀는 릴리스 전체 검사가 잡는다. 프로토콜로만 닿는 구현, 전역 함수, 다른 타입을 거친 동작 변화 등이다. 코어 커버리지(60%)도 릴리스에서만 본다. 쓰기 그룹 커버리지(80%)는 쓰기 그룹 파일이 바뀐 changed job도 본다.

검사 스크립트 회귀(`scripts/test-check.py`)는 changed job에 따로 단계를 두지 않는다. 검사 스크립트가 바뀌면 `--changed`가 이 검사를 돈다. 릴리스에서는 짧은 `release` 러너가 릴리스 빌드 뒤에 돈다.

Swift가 바뀌면 `--changed`가 그 가운데 안전 시험 선택 경우만 돈다. 이 경우는 실제 지도로 안전 Suite를 고르는지 본다. 파일을 옮기면 지도의 `when`이 다른 파일에 맞아 `--check-map`은 통과해도 안전 Suite를 놓칠 수 있다.

비교 기준이 없어 전체 검사로 넓힌 changed job은 이 검사 전체를 따로 돈다. 인자 없는 `scripts/check.sh`는 이 검사를 돌지 않기 때문이다.

### 제한 시간

검사 단계 제한은 40분, job 제한은 50분이다. 검사 단계가 제한에 걸려도 요약, 로그 보존, 캐시 저장 단계가 돈다. 멈춘 시험은 그보다 먼저 [시험 멈춤 감시](#시험-멈춤-감시)가 끝낸다.

`run_stress`는 기본값이 `false`라 푸시·PR이나 자동 스케줄로는 stress를 돌리지 않는다. 관련 변경을 수동 stress CI로 확인할 때는 이 입력을 켠다.

마지막 `빌드·테스트·커버리지` job은 기존 필수 체크 이름을 유지한다. 이 job은 그 실행의 모든 검사 job이 성공해야 통과한다. 모든 검사 job은 changed 하나, 또는 릴리스의 coverage·release·선택한 stress다. 실패·취소·미실행은 통과시키지 않는다. 한 검사가 실패해도 다른 검사 로그를 잃지 않도록 matrix의 `fail-fast`는 끈다.

릴리스와 요청 때 쓰는 인자 없는 `scripts/check.sh`는 전체 검사를 순서대로 돈다. CI 분할용 `--coverage`는 릴리스 빌드만 빼서 돈다. `--release`는 릴리스 빌드만 돈다.

두 명령을 같은 작업 폴더에서 동시에 돌리지 않는다. CI에서는 두 명령이 서로 다른 러너와 `.build`를 쓰므로 SwiftPM 잠금과 산출물이 부딪치지 않는다. 작업 중 로컬 검증은 위 [로컬 검증 운영](#로컬-검증-운영)의 단계대로 범위를 좁힌다.

## 러너 선택 (2026-09-26 확인)

`Package.swift`는 macOS 27.0 이상과 Swift tools 6.2 이상을 요구한다. 빌드 SDK뿐 아니라 시험 실행 OS도 macOS 27 이상이어야 한다.

| 공식 이미지 | 실행 OS·Xcode | 판단 |
|---|---|---|
| `macos-26` / `macos-latest` | macOS 26.6.2, 기본 Xcode 26.6 | macOS 27 테스트 실행 조건을 충족하지 않음 |
| `macos-27` | 공식 라벨 목록에 없음 | 사용하지 않음 |
| `xcode-27` | macOS 27.0, 기본 Xcode 27.0, macOS 27 SDK | 이 워크플로에서 사용 |

근거는 다음 문서다.

- [GitHub 표준 호스티드 러너](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
- [runner-images 라벨 목록](https://github.com/actions/runner-images/blob/ede07f8e48022b2c00dc669c7a9d927c46e32a81/README.md)
- [macOS 26 이미지](https://github.com/actions/runner-images/blob/ede07f8e48022b2c00dc669c7a9d927c46e32a81/images/macos/macos-26-arm64-Readme.md)
- [Xcode 27 이미지](https://github.com/actions/runner-images/blob/ede07f8e48022b2c00dc669c7a9d927c46e32a81/images/macos/xcode-27-arm64-Readme.md)

[Apple Xcode 요구 사항](https://developer.apple.com/xcode/system-requirements)에 따르면 Xcode 27은 Swift 6.4를 제공하므로 tools 6.2 조건을 충족한다.

`xcode-27`은 **공개 미리보기**다. [공식 공지](https://github.com/actions/runner-images/issues/14404)에 따르면 2026-09-16부터 기반 OS가 macOS 27이다. 공지는 안정성·대기열 제약도 안내한다.

워크플로는 `DEVELOPER_DIR`로 Xcode 27.0을 고른다. 실행할 때 OS·Xcode 버전과 Swift·SDK 버전을 출력한다. 이미지가 바뀌어 OS나 SDK가 27 미만이면 빌드 전에 실패한다. 실제 GitHub 실행 여부는 푸시 뒤 확인한다.

## 캐시·데이터·권한

SwiftPM 의존성과 빌드 결과인 `.build`를 캐시한다. 캐시 키는 다음 값으로 만든다.

- OS·아키텍처·캐시 버전(`v3`)
- 빌드 묶음: `debug-coverage` 또는 `release`. changed·coverage·stress는 모두 `--enable-code-coverage` 디버그 빌드라 `debug-coverage`를 함께 쓴다.
- 툴체인 지문
- `Package.swift`와 `Package.resolved` 해시
- 커밋

받을 때는 같은 묶음·툴체인 캐시 가운데 가장 가까운 것을 쓴다(`restore-keys`). `Package.swift`가 바뀌었으면 해시가 다른 캐시도 받는다. 묶음이 다른 산출물은 섞지 않는다. 같은 묶음 캐시가 GitHub의 브랜치 접근 범위 안에 없으면 캐시 없이 시작한다.

저장은 `actions/cache/save` 단계가 따로 한다. `actions/cache`의 자동 저장은 job이 성공할 때만 돈다. 그래서 실패가 이어진 2026-10 초에는 캐시가 하나도 생기지 않았다. run 37983504195도 `Cache not found`였고, `swift test`의 빌드가 399초 걸렸다. 지금은 시험이 실패해도 빌드 결과를 저장한다. 다음 경우에는 저장하지 않는다.

- 취소 상태로 끝난 실행
- 같은 키를 이미 받은 실행(재실행)
- 빌드·시험이 없는 changed job(문서·하네스만 바뀜). 이때는 캐시를 받지도 않는다.
- 캐시를 이미 받은 PR 실행. PR의 캐시는 그 PR에서만 쓸 수 있다. `dev`·`main` 푸시의 캐시는 그 브랜치를 기준으로 한 PR도 쓴다.

저장하기 전에 커버리지 프로파일 폴더(`codecov`)를 지운다. 이 폴더는 시험마다 새로 생기므로 저장할 까닭이 없다.

### 소스 수정 시각 되돌리기

체크아웃은 모든 파일의 수정 시각을 새로 매긴다. Swift 빌드는 수정 시각이 바뀐 소스를 다시 컴파일한다. 그래서 `.build`를 받아도 컴파일이 거의 줄지 않는다. 이 저장소로 로컬에서 잰 결과(2026-10-10, `swift build --build-tests --enable-code-coverage`)는 다음과 같다.

| 상태 | 빌드 시간 |
|---|--:|
| 빈 `.build`(cold) | 65초 |
| 바뀐 것 없음 | 2초 |
| 모든 추적 파일을 같은 내용의 새 파일로 바꿈(체크아웃 흉내) | 72~74초 |
| 위와 같되 수정 시각을 앞 값으로 둠(inode만 바뀜) | 1초 |
| Swift 소스의 수정 시각만 바꿈 | 29초 |
| 체크아웃 흉내 뒤 `scripts/ci-mtimes.py restore`, 앱 파일 하나는 내용을 바꿈 | 8초 |

inode는 다시 컴파일과 관계가 없다. 수정 시각이 다시 컴파일을 일으킨다. 그래서 캐시와 함께 수정 시각도 저장한다. 캐시를 받은 뒤에는 그 시각으로 되돌린다.

- 저장 전: `scripts/ci-mtimes.py save`가 추적 파일의 내용 해시와 수정 시각을 `.build/djc-source-mtimes.tsv`에 적는다. 이 파일은 캐시에 함께 들어간다.
- 받은 뒤: `scripts/ci-mtimes.py restore`가 내용 해시가 기록과 같은 파일만 기록한 시각으로 되돌린다.

바뀐 파일과 새 파일은 체크아웃 시각을 그대로 둔다. 이 시각은 캐시를 만든 빌드보다 늦다. 그래서 빌드가 그 파일을 다시 컴파일한다. 내용이 같은 파일은 캐시를 만든 빌드가 본 상태와 같다. 그래서 되돌린 빌드는 그 기계에서 이어 빌드한 것과 같다.

작은 패키지 실험에서는 수정 시각만 바뀐 파일을 다시 컴파일하지 않았다. 이 저장소에서는 달랐다. 실제 CI 시간은 캐시를 받는 첫 실행의 `Build complete` 시간으로 확인한다.

캐시가 있어도 검증은 매번 실행한다. 캐시 복원은 시험 통과의 근거가 아니다.

시험은 합성 픽스처만 쓴다. `DJC_HOME`과 `DJC_REKORDBOX_DIR`은 러너 임시 폴더에 둔다. 개인 라이브러리와 음원은 CI에 올리지 않는다. DB와 백업도 올리지 않는다.

`GITHUB_TOKEN` 권한은 `contents: read`다. checkout 뒤에는 인증 정보를 보관하지 않는다. 별도 비밀값은 필요 없다. Actions 버전은 커밋 SHA로 고정한다.

포크 PR도 GitHub가 제공하는 임시 VM에서 `pull_request`로 실행한다. self-hosted 러너와 `pull_request_target`은 쓰지 않으므로 러너를 등록할 필요가 없다.

## 워크플로 검사

워크플로를 고친 뒤 저장소 루트에서 `actionlint`로 검사한다. actionlint 1.7.12가 아직 공개 미리보기 `xcode-27` 라벨을 모르므로 `.github/actionlint.yaml`은 이 라벨만 허용한다. 이 설정은 self-hosted 러너를 쓰는 설정이 아니다.

`python3 scripts/test-check.py [경우 이름 일부…]`는 합성 명령만으로 `scripts/check.sh`를 검사한다. 인자를 주면 그 경우만 돈다. CI에서는 세 job이 이 검사를 돈다. 검사 스크립트가 바뀐 changed job, 비교 기준이 없어 넓힌 changed job, 릴리스의 `release` job이다. Swift만 바뀐 changed job은 안전 시험 선택 경우(`affected-real-map`·`safety-`)만 돈다. 실제 Swift 빌드나 라이브러리 접근 없이 다음을 확인한다.

- 빌드·번역·시험 실패
- 커버리지·파이프 실패
- 빈 커버리지와 목표에 못 미친 커버리지
- INT·TERM 취소와 로그 보존
- 분할 모드·quick·stress의 검사 범위와 실패 전파
- 커버리지 목표 유지와 틀린 인자 거부
- 합성 `HOME` 아래에서 시험이 DJCrate 사용자 폴더·로그 폴더에 쓰면 종료 코드 4로 실패하는지. 설치 앱이 켜져 있으면 알림만 한다.
- 가짜 시험이 멈추면 멈춤 감시가 종료 코드 124로 끝내는지. 이때 끝나지 않은 시험과 스택을 남기는지. 빌드 단계와 정한 초보다 짧은 침묵은 기다리는지.
- `scripts/ci-base.sh`가 PR에서 merge-base를, 푸시에서 앞 끝을 내는지. 기준을 구할 수 없으면 비우는지.
- `scripts/ci-mtimes.py`가 내용이 같은 파일만 기록한 수정 시각으로 되돌리는지. 바뀐 파일과 새 파일은 그대로 두는지.

## 푸시 뒤 관리자 확인

1. Actions 설정에서 이 워크플로의 실행을 허용한다. `actions/checkout`, `actions/cache`, `actions/upload-artifact` 실행도 허용한다.
2. 외부 포크 PR은 **모든 외부 기여자의 실행 승인**을 요구하도록 설정한다. 변경 내용을 확인한 뒤 승인한다.
3. `dev` 푸시와 `dev` 대상 PR에서 `changed`가 도는지, Job summary의 비교 기준이 맞는지 확인한다. `main`·`release/*`·수동 실행에서는 `coverage`와 `release`를 확인한다. `run_stress=true`인 수동 실행에서는 추가 `stress`를 확인한다.
4. 선택한 stress의 실패·취소·미실행도 필수 집계 체크를 통과시키지 않는지 본다.
5. 실제 검사 러너가 macOS 27·Xcode 27인지 확인한다. 결과를 합치는 `빌드·테스트·커버리지` job만 Ubuntu에서 돈다. 포크 PR도 호스티드 러너에서만 도는지 확인한다.
6. 첫 실행의 캐시 저장과 다음 실행의 복원을 확인한다. 시험이 실패한 실행도 캐시를 저장하는지 본다. Job summary의 시험 수·커버리지와 README의 `dev` 상태 배지도 확인한다.
7. `dev`·`main` 보호 규칙에 `빌드·테스트·커버리지`를 필수 상태 체크로 더한다. 워크플로 파일만으로는 병합을 막지 못한다.

이 작업은 러너를 등록하지 않는다. 저장소 설정 변경과 푸시도 하지 않는다. 미리보기 이미지 공급이 끊기면 공식 라벨·SDK·실행 OS를 다시 확인한 뒤 러너를 바꾼다.

## 하네스·문서 검사

하네스는 따로 본다. Claude Code 훅은 에이전트의 실수를 줄이는 안내이자 센서일 뿐, 안전 경계가 아니다. 안전 경계는 다음 코드 관문이다.

- `RekordboxWriteGuard`
- `TestProcess`
- `UsbPhysicalWriteGate`
- `CLIGuards`

막는 훅의 범위와 알려진 한계는 `.claude/rules/harness.md`에 있다.

몇 초 걸리는 `python3 scripts/check-docs.py`는 지침에 적힌 다음 항목을 확인한다. 지침은 AGENTS.md와 CLAUDE.md다. `.claude/rules`·`.claude/skills`·`.claude/agents` 아래 문서도 지침이다.

- 저장소 경로
- `djc` 명령 이름
- 규칙의 `paths` 글롭
- 스킬 머리
- 문서 링크
- AGENTS.md 크기. 12KiB를 넘으면 경고, 16KiB를 넘으면 실패다.

`python3 scripts/test-harness.py [--quiet]`는 Claude Code 훅(`scripts/hooks/`)에 표본 JSON을 넣어 다음을 시험한다.

- 막을 명령과 통과할 명령
- 알려진 한계
- Stop·SessionStart 출력 모양
- `.claude/settings.json`. 훅 명령을 `sh`로 그대로 돌려 본다.
- `check-docs.py`의 경우

`--changed`는 관련 파일이 바뀌었을 때 두 스크립트를 부른다.

### 문장 규칙(check-prose)

`scripts/check-prose.py`는 문서 문장이 간결 기술 한국어 규칙을 따르는지 잰다.
규칙 목록과 문장을 뽑는 법은 스크립트 머리에 있다.
쓰지 않는 말과 굳은 용어는 `scripts/prose-terms.txt`에 있다.
`--changed`는 문서가 바뀌면 같은 기준으로 이 검사를 부른다.
전체 검사와 CI도 이 검사를 부른다.

다음 가운데 하나면 실패한다.

- 새로 쓴 줄이나 고친 줄에 걸친 문장에 오류(E1~E6)가 있다.
- 문서의 A(문장 준수율)가 기준선보다 낮다.
- 문서의 B(100어절당 위반 수)가 기준선보다 높다.

경고(W1~W4)만 있으면 실패하지 않는다.
기준선은 `scripts/prose-baseline.txt`에 있다.
기준선보다 나은 값은 `--write-baseline`으로 적는다.
이 명령은 나쁜 값을 적지 않는다.
A가 80% 이상인 문서는 기준선을 80으로 둔다.
꼭 필요한 예외는 줄 끝에 `<!-- prose: E3 -->`처럼 규칙을 적는다.

문장을 고쳐 쓸 때 쓰는 명령:

```bash
python3 scripts/check-prose.py --all --no-diff --files docs/ci.md   # 문서 하나의 모든 위반 줄
python3 scripts/check-prose.py --report                             # 문서별 표(A·A'·B·B'·규칙별 수)
python3 scripts/check-prose.py --preserve HEAD:docs/ci.md --to docs/ci.md  # 고쳐 쓴 뒤 빠진 숫자·식별자·이슈 번호·부정어
```

`--morph`는 `kiwipiepy`가 있으면 명사 묶음(W3)도 본다.
기준선에는 W3을 넣지 않는다.

## 더 보기

- [AGENTS.md](../AGENTS.md): 검증 단계 요약과 안전 불변식
- [스킬 `verify-change`](../.claude/skills/verify-change/SKILL.md): 작업 끝 확인과 보고 형식
- [스킬 `app-selftest`](../.claude/skills/app-selftest/SKILL.md): 앱 자가 테스트 인자와 잠금
- [시험 규칙](../.claude/rules/tests.md): 시험 배치와 사용자 폴더 격리
- [하네스 규칙](../.claude/rules/harness.md): 훅과 검사 스크립트를 고칠 때
- [CLI 문서](cli.md): `djc` 명령과 환경 변수
- [CONTRIBUTING.md](../CONTRIBUTING.md): 기여 절차
