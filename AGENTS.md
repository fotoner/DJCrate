# AGENTS.md — DJCrate

<!-- 12KiB 안. "## 안전 불변식" 제목은 scripts/hooks/session-safety.py가 찾는다. ID는 다시 매기지 않는다. -->

DJCrate는 rekordbox 7 DJ 라이브러리를 관리하는 1인용 macOS 앱이다. 약칭은 DJC, CLI는 `djc`, 옛 이름은 anicue다.
이 파일은 사람과 모든 에이전트(Claude Code·Codex 등)가 따르는 정본이자 문서 지도다.

## 안전 불변식

rekordbox 라이브러리와 사용자 데이터를 절대 깨뜨리지 않는다. 어떤 도구로 일하든 늘 지킨다.
이 절에서 라이브러리는 `master.db`와 `share/PIONEER/USBANLZ`를 말한다.

- **SAFE-1** IMPORTANT: rekordbox나 rekordboxAgent가 켜져 있으면 라이브러리와 USB에 **절대 쓰지 않는다**.
- **SAFE-2** 라이브러리는 RekordboxKit 쓰기 입구로만 바꾼다. 입구는 `RekordboxWriter.write`·`restore`와 `RekordboxTrackWriter.add`·`delete`다.
- **SAFE-3** 모든 쓰기 입구는 관문 `RekordboxWriteGuard`를 먼저 지난다.
- **SAFE-4** 앱과 CLI는 반영 세션 `ReflectionSession`으로만 쓴다. 이 세션이 포트 `RekordboxWriteGate`로 입구를 부른다.
- **SAFE-5** 그 밖의 코드는 `master.db`와 분석 파일을 직접 고치지 않는다.
- **SAFE-6** 라이브 DB와 음원은 읽기 전용이다. 읽기는 스냅샷 사본(`LibrarySnapshot`)에서 한다.
- **SAFE-7** 시험과 실험의 쓰기는 **사본에만** 한다. `DJC_REKORDBOX_DIR=<사본 폴더>`와 `DJC_HOME=<임시 폴더>`를 준다.
- **SAFE-8** 사본 안 `share/PIONEER/USBANLZ`는 링크로 두지 않는다. 실제 파일로 복사한다.
- **SAFE-9** 시험은 실제 라이브러리와 사용자 데이터에 쓰지 않는다(#182). 사용자 데이터는 `~/Library/Application Support/DJCrate`, `~/Library/Logs/DJCrate`, 환경설정이다.
- **SAFE-10** 시험 프로세스의 기본 폴더는 임시 폴더(`TestProcess.sandbox`)다. 쓰기·복원 API에 라이브 기본 인자를 두지 않는다.
- **SAFE-11** 시험 환경을 바꾸면 새로 도는 시험이 무엇을 쓰는지 먼저 확인한다. 시험 환경은 검사 스크립트의 환경 변수와 시험 활성 조건이다.
- **SAFE-12** 규칙을 확인하지 않은 쓰기는 열지 않는다. 막아 둔 형식·조건과 확인한 버전 밖의 rekordbox가 여기에 든다.
- **SAFE-13** 새 쓰기 경로는 rekordbox 실험 → 사본 재현 → 칸 단위 일치를 확인한 뒤에만 연다.
- **SAFE-14** rekordbox 규칙은 rekordbox 화면에서 편집한 결과 파일을 비교해서만 알아낸다. rekordbox 실행 파일(본체·rb_http_server 등)은 분석하지 않는다. strings와 디스어셈블도 하지 않는다.
- **SAFE-15** DB 사본(`*.db`·`-wal`·`-shm`)과 `snapshots/`, 백업에는 rekordbox 클라우드 토큰이 들어 있다. 이 파일은 커밋과 이슈에 넣지 않는다. 출력과 로그에도 넣지 않는다.
- **SAFE-16** `agentRegistry`의 인증값은 읽지도 옮기지도 않는다.
- **SAFE-17** 내보내는 파일(예: USB)은 칸 단위로 만든다. rekordbox가 만든 파일의 페이지·표 바이트를 통째로 넣지 않는다.
- **SAFE-18** 라이선스가 없는 외부 코드·문서는 쓰지 않는다. 외부 코드를 옮기면 라이선스를 확인한 뒤 `THIRD_PARTY_NOTICES.md`에 더한다.
- **SAFE-19** USB 쓰기는 `UsbWriter.write` 한 곳으로만 한다.
- **SAFE-20** USB의 DB(`exportLibrary.db`·`export.pdb`·`exportExt.pdb`)는 Mac 사본에서만 연다. USB 위에서 SQLite를 열지 않는다.
- **SAFE-21** 실물 USB는 등록 없이 읽는다. 쓰기는 사용자가 동의한 쓰기에만 한다. 동의는 앱의 쓰기 확인 창·내보내기 시트와 CLI `--allow-physical --confirm <볼륨 이름>`이다.
- **SAFE-22** 시험과 에이전트는 이 Mac에 꽂힌 실제 볼륨(`/Volumes/*`)에 쓰지 않는다. 나열과 읽기 전용 확인만 한다.
- **SAFE-23** 시험과 에이전트는 USB 쓰기를 임시 폴더 안에서만 한다. 대상은 `djc lab usb-image`로 만든 디스크 이미지나 주입한 가짜 볼륨뿐이다.
- **SAFE-24** `PIONEER/extracted`·`PIONEER/CDP`·`djprofile.nxs`는 열거도, 읽기도, 복사도 하지 않는다.
- **SAFE-25** 사전 확인, 막아 둔 형식, 볼륨 정책은 `.claude/rules/rekordbox-write.md`와 `.claude/rules/usb-write.md`에 있다. 그 경로의 코드를 고치기 전에 읽는다.

## 명령

```bash
python3 scripts/check-imports.py  # 모듈 경계 검사(1~2초)
swift scripts/i18n.swift sync     # 화면 문구로 String Catalog 맞추기, 뒤에 en·ja 번역을 채운다
swift build                       # 디버그 빌드
.build/debug/djc                  # CLI 명령 목록(자세히는 docs/cli.md)
.build/debug/djc compat           # rekordbox 버전·DB 구조가 쓰기를 확인한 모양인지(읽기 전용)
scripts/build-app.sh [--install]  # dist/DJCrate.app, --install이면 /Applications에
```

## 검증

TDD로 일한다. 버그는 실패하는 시험으로 먼저 재현한 뒤 고친다. 새 규칙은 시험을 먼저 써서 빨간색을 본 뒤 구현한다.
시험 삭제나 기대값 완화로 통과시키지 않는다. 시험을 둘 곳은 `.claude/rules/tests.md`에 있다.

| 단계 | 언제 | 명령 |
|---|---|---|
| 편집 중 | 시험을 쓰고 고칠 때 | `scripts/check.sh --quick --filter '<Suite>'`(시험·Suite 하나) |
| 작업 끝 | "됐다"고 말하기 전, `dev` 합치기 직전, PR·`dev` CI | `scripts/check.sh --changed`(바꾼 파일에 닿는 시험·검사만) |
| 릴리스 | `main`·`release/*` CI, 수동 실행, 사용자 요청 | `scripts/check.sh`(릴리스 빌드·번역·전체 시험·커버리지 쓰기 80%·코어 60%) |
| 특수 | SQLCipher 초기화(`CipherDatabase`)·`CipherLab`·cold-open 경쟁 | `scripts/check.sh --stress`도 반드시 통과 |

- `swift test`를 직접 돌리면 `DJC_HOME`과 `DJC_REKORDBOX_DIR`을 임시 폴더로 준다.
- `scripts/check.sh`가 종료 코드 3이나 4를 내면 작업을 멈춘 뒤 사용자에게 알린다. 3은 실제 rekordbox 파일이, 4는 DJCrate 사용자 폴더·로그 폴더·환경설정이 바뀌었다는 뜻이다.
- 같은 checkout에서 Swift 빌드·시험·성능 측정을 동시에 돌리지 않는다(잠금: `docs/ci.md`).
- 같은 작업 트리에서 통과한 검사는 다시 돌리지 않는다(`--no-reuse`).
- 결과는 추측하지 않는다. 끝 요약·종료 코드·로그 폴더로 보고한다.
- `--changed`가 놓친 회귀는 릴리스 전체 검사가 잡는다(넓히기·보고: 스킬 `verify-change`).
- 소리·실제 UI·rekordbox 쓰기 전 과정은 스킬 `app-selftest`로, USB 쓰기 전 과정은 스킬 `usb-image-check`로 확인한다.

## 지도

| 알고 싶은 것 | 볼 곳 |
|---|---|
| 기능(사용자용) | `README.md`, `docs/features.md` |
| 구조·경계 규칙·설계 이유, 새 코드를 둘 곳, 데이터 폴더 | `docs/architecture.md` |
| 화면 모델·뷰(MVVM 패턴) | `docs/mvvm.md` |
| rekordbox 형식·쓰기 규칙(실험으로 확인한 사실) | `docs/rekordbox-internals.md` |
| USB 형식·쓰기 | `docs/usb-internals.md` |
| 검증 단계·`check.sh` 모드·선택 실행 장치·CI·측정 기준 | `docs/ci.md` |
| `djc` 명령·환경 변수·JSON | `docs/cli.md` |
| 화면 문구·번역 | `docs/i18n.md` |
| 이슈·배포·기여 | `docs/issues.md`, `docs/releasing.md`, `CONTRIBUTING.md` |

경로별 규칙은 `.claude/rules/`에 있다. 그 경로를 고치기 전에 읽는다. Claude Code는 알아서 싣는다.

| 파일 | ID | 다루는 것 |
|---|---|---|
| `rekordbox-write.md` | RBW | rekordbox 쓰기·반영 |
| `usb-write.md` | USB | USB |
| `tests.md` | TEST | 시험 |
| `audio.md` | AUD | 덱·편집 재생, 오디오 엔진 |
| `ui.md` | UI | 앱 화면·설정, 재생 중 화면 갱신 |
| `mvvm.md` | MVVM | 화면 모델·뷰 |
| `ui-strings.md` | STR | 화면 문구·용어 |
| `cipher.md` | CIP | SQLCipher 열기 |
| `harness.md` | HAR | 검사 스크립트·지침 |

- 절차 스킬(`.claude/skills/<이름>/SKILL.md`): `verify-change`, `app-selftest`, `usb-image-check`, `rekordbox-experiment`, `worker-brief`, `release`.
- 리뷰어 서브에이전트: `.claude/agents/reviewer.md`.

## 구조

- 의존은 한쪽으로만 간다(헥사고날): 앱 `DJCrate`·CLI `djc` → `DJCApplication` → `DJCDomain`.
- `DJCApplication`은 유스케이스와 포트를 둔다. `DJCDomain`은 순수 규칙이다. 이 핵심부는 바깥 자원을 포트로 받는다.
- 포트의 실제 구현은 `DJCAdapters`가 인프라를 불러 만든다. 인프라는 `RekordboxKit`, `DJCStorage`, `DJCAnalysis`, `DJCEnvironment`다.
- 인프라는 포트를 모른다. 실제 구현은 조립 지점(`AppComposition`·`CLIComposition`)만 고른다.
- 모듈 경계는 `scripts/check-imports.py`가 검사한다. 빚 목록 `scripts/import-debt.txt`에는 새 규칙이 찾은 옛 코드만 있다. 새 위반은 빚 목록에 더하지 않는다. 그 자리에서 고친다.
- 쓰기 입구 파일(`Sources/RekordboxKit/RekordboxWriter*` 등)과 `Sources/RekordboxKit/Usb/Write/`는 옮기지 않는다. `scripts/check.sh`의 쓰기 커버리지 정규식이 그 자리를 본다.

## 핵심 설계 결정

- 편집은 모두 **초안**으로 쌓는다. rekordbox에는 반영 때만 쓴다. 초안은 큐, 그리드, 게인, 태그, 앨범아트, 재생 목록이다.
- 초안은 만들 때의 rekordbox 상태(`base`)를 든다. 그 뒤 rekordbox에서 바뀐 곡은 쓰지 않는다.
- 덱과 초안의 시각은 모두 **rekordbox 시간축**이다. 이 시간축은 음원 시각 + 인코더 지연(`RekordboxTimeline.predictedOffset`)이다. 파형만 음원 시간축이라 `timelineOffset`만큼 당겨 그린다.
- 새 곡은 미리 보기를 거쳐 컬렉션에 직접 넣는다. 호환 경로인 rekordbox XML(Import To Collection)로 넘길 수도 있다.
- 기존 큐를 덮어쓰지 않게, 추가 목록에는 이미 컬렉션에 있는 경로를 넣지 않는다.
- 기존 곡의 XML 경로는 큐·그리드 초안만 다룬다([안내](docs/features.md#xml-호환-경로)).

## 말·코드 스타일

- UI 문구 원문, 주석, 커밋 메시지는 한국어로 쓴다. 식별자는 영어로 쓴다.
- 화면 문구는 `String(ui:)`·`.ui(…)`로 쓴다. en·ja 번역, 용어표, `…` 규칙은 `.claude/rules/ui-strings.md`를 따른다.
- 사용자에게 보이는 막힘·오류 이유는 한국어 한 문장으로 쓴다. 무엇을 하면 되는지까지 쓴다. 예: "rekordbox에서 트랙 분석을 먼저 한 뒤 쓰세요".
- 주석은 "왜"를 짧게 한국어로 쓴다. 둘레 코드의 주석 밀도와 말투에 맞춘다.
- Swift 6 엄격 동시성을 쓴다. 오디오 탭·렌더 콜백은 메인 액터 밖(`nonisolated static`)에서 만든다. 메인 액터 격리를 물려받으면 오디오 스레드에서 죽는다.

## 저장소 규칙

- 브랜치: `main`은 릴리스, `dev`는 통합이다. 작업 브랜치는 `feat/…`, `fix/…`, `chore/…`, `hotfix/…`, `release/vX.Y.Z`다. 이슈 번호를 앞에 둔다(예: `feat/38-playlist-write`).
- 작업 브랜치는 `dev`에서 딴다. `git merge --no-ff`로 합친다. 합친 커밋 제목은 "Merge branch 'feat/…' into dev"다.
- 커밋 제목은 `타입: 한국어 설명`이다. 마침표를 찍지 않는다. 자세한 내용은 본문에 불릿으로 쓴다.
- 커밋 타입: feat, fix, docs, style, design, test, refactor, build, ci, perf, chore, rename, remove.
- 커밋·푸시는 요청받았을 때만 한다.
- 할 일·조사·계획은 GitHub 이슈로 관리한다(`docs/issues.md`). 저장소에 계획 문서를 따로 만들지 않는다.
- 공개 저장소다. 이슈에 라이브러리 사본, 토큰, 곡 수, 개인 경로를 넣지 않는다.
- 빌드해서 앱을 바꿀 때 DJCrate가 꺼져 있으면 `scripts/build-app.sh --install`로 설치한다. **켜져 있으면 끄기 전에 사용자에게 묻는다.**
- rekordbox 실험이 필요하면 사용자에게 rekordbox에서 편집을 부탁한다(곡 이름을 받는다). 끝나면 rekordbox를 꺼 달라고 한 뒤 전후 스냅샷을 비교한다. 절차는 스킬 `rekordbox-experiment`에 있다.
