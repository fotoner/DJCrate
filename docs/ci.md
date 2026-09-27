# 빌드·테스트 CI

`.github/workflows/check.yml`은 실행 계기에 따라 검사 범위가 다르다. `dev` 푸시(작업 브랜치를 합칠 때마다)는 `swift test`로 단위 테스트만 돌리고, PR·`main` 푸시·수동 실행(`workflow_dispatch`)은 전체 검사를 두 러너에 나눠 동시에 실행한다. `coverage`는 커버리지 계측 디버그 앱·CLI·테스트 빌드, 번역 검사, 전체 테스트 실행·줄 커버리지 목표(쓰기 80%, 코어 60%)를 맡고, `release`는 릴리스 앱 빌드를 맡는다. 테스트 수와 커버리지는 Actions의 Job summary에 남긴다. 오디오·UI 앱 자가 테스트, 앱 설치·서명·배포는 실행하지 않는다.

마지막 `빌드·테스트·커버리지` job은 기존 필수 체크 이름을 유지한다. 해당 실행의 모든 검사 job이 성공해야 통과하며, 실패·취소·미실행은 통과시키지 않는다. 한 검사 실패로 다른 검사 로그를 잃지 않도록 matrix의 `fail-fast`는 끈다.

로컬·릴리스 배포에서 인자 없이 실행하는 `scripts/check.sh`는 여전히 전체 검사를 순서대로 실행한다. CI 분할용 `--coverage`는 릴리스 빌드만 제외하고, `--release`는 릴리스 빌드만 실행한다. 두 명령을 같은 작업 폴더에서 동시에 실행하지 않는다. CI에서는 서로 다른 러너와 `.build`를 사용하므로 SwiftPM 잠금·산출물이 충돌하지 않는다.

## 진행 로그·실패 진단

`scripts/check.sh`는 각 단계의 UTC 시작·종료 시각, 경과 초, 종료 코드를 출력한다. 명령 출력은 즉시 화면과 단계별 로그에 함께 쓰고, 출력이 없어도 30초마다 현재 단계와 경과 시간을 알린다. 디버그·테스트 컴파일, 릴리스 빌드, 번역, 전체 테스트 실행·프로파일 수집, 커버리지 보고·목표 검사를 구분한다. SwiftPM의 테스트 실행 명령에는 프로파일 병합·내보내기도 포함되므로 이 단계 전체를 순수 테스트 실행 시간으로 부르지 않는다.

- 로컬 로그: `.build/check-logs/run.XXXXXX/`. `DJC_CHECK_LOG_ROOT`로 상위 폴더를 바꿀 수 있다. 실행마다 새 폴더를 만들어 이전 성공 결과와 섞이지 않게 한다.
- `debug-build.log`, `release-build.log`, `translations.log`, `test.log`, `coverage.log`에 원래 출력을 보존한다. `timings.tsv`에는 단계별 초·종료 코드, `exit-code.txt`에는 전체 종료 코드, `coverage.txt`에는 파일별 집계 입력이 남는다. 실패한 단계 뒤의 로그는 생성되지 않는다.
- 명령이나 `tee`가 실패하면 `pipefail`로 검사가 실패한다. INT·TERM은 각각 130·143으로 끝나며 이 검사에서 시작한 자식 빌드와 진행 알림도 종료한다. 강제 KILL·러너 장애는 종료 요약을 기록할 기회가 없으므로 부분 로그만 남을 수 있다.
- CI는 로그를 캐시 밖인 러너 임시 폴더에 저장하고, `always()` 단계에서 Job summary와 `check-logs-<mode>-<run_id>-<attempt>` artifact를 남긴다(14일 보관). 업로드 대상은 검사·툴체인 텍스트 로그뿐이며 DB·스냅샷·프로파일·실행물은 포함하지 않는다. 취소 시에도 보존을 시도하지만 강제 종료나 러너 유실 시 업로드는 보장되지 않는다.

디버그 앱·CLI·테스트는 `swift build --build-tests --enable-code-coverage`로 함께 빌드한다. 번역 검사에도 같은 계측 옵션을 전달해 설정 전환으로 다시 컴파일하지 않게 하되, 앱과 CLI를 실제 빌드하는 기존 검증은 유지한다. 이어서 `swift test --skip-build --enable-code-coverage`로 **전체 테스트를 실행**한다. 별도로 실행하는 `swift scripts/i18n.swift check`·`sync`의 기본 빌드 설정은 바뀌지 않는다. 테스트 병렬성·필터·커버리지 목표는 바꾸지 않았다.

## 본체 컴파일 공유

`DJCrate`·`djc` 본체는 라이브러리 타깃이고, `DJCrateExecutable`·`djcExecutable`은 실행 진입점만 가진다. 실행 파일과 테스트가 같은 본체 모듈을 링크하므로, 실행 타깃을 직접 테스트할 때 생기던 본체의 별도 `-testable` 컴파일을 없앤다. 실행 제품 이름(`DJCrate`·`djc`), 기존 `@testable import`, 리소스 번들 이름·위치는 유지한다. 앱의 언어 목록을 넣는 `__info_plist` 링크 설정은 실행 진입점 타깃에 둔다.

검증할 때는 이전 `.build`에 남은 파일이 아니라 해당 빌드의 `XCBuildData/*.xcbuilddata/manifest.json`에서 `SwiftDriver Compilation` 명령의 소스 입력을 확인한다. 본체의 각 소스는 한 번만 컴파일하고 `-testable` 변형이 없어야 한다. 명령 이름에는 실행 제품과 본체가 모두 `DJCrate`·`djc`로 표시될 수 있으므로 이름 개수만 세지 않는다. 실제 CLI 프로세스의 번역·JSON·종료 코드, 릴리스 앱의 내장 Info.plist와 리소스 번들·패키징도 함께 확인한다.

## 내용 해시 기반 증분 빌드

CI의 디버그 빌드·테스트는 Xcode 27의 `-Xswiftc -enable-incremental-file-hashing`을 사용한다. 같은 내용의 소스를 다시 체크아웃해 수정 시각만 바뀌었을 때도 저장된 내용 해시로 컴파일 결과를 재사용한다. 처음부터 이 옵션으로 만든 캐시가 필요하므로 캐시 버전은 `v3`으로 구분한다. 캐시가 없는 첫 빌드나 실제로 바뀐 파일·그 영향 범위는 여전히 컴파일한다. 테스트 실행 자체를 생략하는 옵션은 아니다.

`scripts/check.sh`는 디버그·테스트 빌드, 번역 스크립트의 앱·CLI 빌드, 테스트 실행에 같은 인자를 전달한다. `scripts/i18n.swift`는 커버리지 옵션과 이 해시 옵션 쌍만 명시적으로 허용하며 임의의 컴파일러 인자를 전달하지 않는다. 인자 없는 번역 검사와 릴리스 빌드의 설정은 유지한다. 이 옵션의 효과는 빈 빌드 폴더, 변경 없는 재빌드, 소스 수정 시각만 바꾼 재빌드, 실제 소스 변경을 나눠 비교하고, `swift build -v`의 파일별 `Compile …swift` 수와 CPU 시간도 확인한다. 릴리스 빌드나 호스티드 CI 전체의 단축률로 확대해 해석하지 않는다.

## 테스트 준비 비용

가짜 오디오·메모리 저장소를 쓰는 `DeckHarness`는 합성 WAV와 임시 폴더만 만든다. DB가 필요한 통합 테스트는 계속 `RekordboxFixture`를 쓴다. 이 픽스처는 암호화 설정을 유지하면서 스키마·초기 행을 한 연결·한 트랜잭션으로 준비하고, 곡·재생 목록의 여러 행도 각각 한 트랜잭션으로 넣는다. 곡·재생 목록 준비가 실패하면 명시적으로 롤백해 같은 연결에서도 다음 준비를 할 수 있다.

여러 행을 준비하는 공통 도우미는 동기 `withConnection` 묶음 안에서 연결을 재사용해 반복 키 유도를 줄인다. 중첩 묶음도 같은 연결을 쓰며, 가장 바깥 묶음이 끝나거나 오류가 나면 연결을 닫는다. 픽스처마다 독립된 파일·연결을 쓰고, `open()`은 항상 새 연결을 연다. 실제 쓰기·백업·복원은 반드시 묶음 밖에서 실행한다. 쓰기·복원 뒤 다시 읽는 연결을 캐시하거나 SQLCipher의 암호화·키 유도 설정을 낮추지 않는다. 회귀 테스트는 연결 재사용·종료·중첩, 실패 후 롤백, DB 파일 교체 뒤 새 값 읽기를 확인한다.

## 시간 비교 방법과 기준

[PR #111 기준 실행](https://github.com/fotoner/DJCrate/actions/runs/36303819883/job/108581536945)은 attempt 2, SHA `7f2395c74307299a222175c1a069dce7a79086f5`, `xcode-27`이었다. API의 해당 attempt/job 시각과 로그로 구분하면 다음과 같다.

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

기준 결과는 테스트 1,049개, 쓰기 93.0%, 코어 88.9%, 번역 누락·stale 0이다. 이전 커밋 캐시를 복원했지만 디버그·릴리스 빌드 시간이 들었으므로 캐시 복원을 컴파일 생략으로 해석하지 않는다. 기존 스크립트는 디버그 빌드를 두 번 직접 호출하고, 번역 이후 커버리지 설정으로 디버그·테스트를 다시 빌드했다. 변경은 이 중복 호출과 계측 설정 전환을 줄인다. 테스트 본문의 실행 시간은 그대로 남는다.

호스티드 비교는 같은 SHA·러너 이미지·툴체인·검사 범위에서 수동 실행의 `use_cache=false`와 `use_cache=true`를 각각 실행해 기록한다. 꺼진 경우 캐시 복원·저장을 모두 건너뛴다. 켜진 실행도 정확 키 일치, 이전 키 복원, 캐시 없음으로 나누고 실제 캐시 키와 `Build complete`·컴파일 로그를 확인한다. 캐시 저장이 완료된 뒤 다음 실행을 시작해야 `cancel-in-progress`로 앞 실행을 취소하지 않는다.

비교 보고에는 run ID·attempt·SHA, job 생성/시작/종료 시각, 캐시 키·복원/저장 시간, 각 단계 시간, 테스트 수·커버리지·종료 코드를 함께 적는다. 로컬 측정에는 동시 빌드·GUI 검사 등 다른 작업의 부하와 빈/기존 `.build` 여부를 기록한다. 로컬 시간 차이는 호스티드 CI 개선 수치가 아니며, 위 기준 실행은 기존 캐시 복원 사례 한 건이므로 변경 후 cold/warm 측정과 일대일 성능 차이를 단정할 수 없다.

## 러너 선택 (2026-09-26 확인)

`Package.swift`는 macOS 27.0 이상과 Swift tools 6.2 이상을 요구한다. 빌드 SDK뿐 아니라 테스트 실행 OS도 macOS 27 이상이어야 한다.

| 공식 이미지 | 실행 OS·Xcode | 판단 |
|---|---|---|
| `macos-26` / `macos-latest` | macOS 26.6.2, 기본 Xcode 26.6 | macOS 27 테스트 실행 조건을 충족하지 않음 |
| `macos-27` | 공식 라벨 목록에 없음 | 사용하지 않음 |
| `xcode-27` | macOS 27.0, 기본 Xcode 27.0, macOS 27 SDK | 이 워크플로에서 사용 |

근거: [GitHub 표준 호스티드 러너](https://docs.github.com/en/actions/reference/runners/github-hosted-runners), [runner-images 라벨 목록](https://github.com/actions/runner-images/blob/ede07f8e48022b2c00dc669c7a9d927c46e32a81/README.md), [macOS 26 이미지](https://github.com/actions/runner-images/blob/ede07f8e48022b2c00dc669c7a9d927c46e32a81/images/macos/macos-26-arm64-Readme.md), [Xcode 27 이미지](https://github.com/actions/runner-images/blob/ede07f8e48022b2c00dc669c7a9d927c46e32a81/images/macos/xcode-27-arm64-Readme.md). [Apple Xcode 요구 사항](https://developer.apple.com/xcode/system-requirements)에 따르면 Xcode 27은 Swift 6.4를 제공하므로 tools 6.2 조건을 충족한다.

`xcode-27`은 **공개 미리보기**다. [공식 공지](https://github.com/actions/runner-images/issues/14404)는 2026-09-16부터 기반 OS를 macOS 27로 변경했다고 명시하며, 안정성·대기열 제약을 안내한다. 워크플로는 `DEVELOPER_DIR`로 Xcode 27.0을 선택하고 실행 시 OS·Xcode·Swift·SDK 버전을 출력한다. 이미지가 바뀌어 OS 또는 SDK가 27 미만이면 빌드 전에 실패한다. 실제 GitHub 실행 여부는 푸시 뒤 확인해야 한다.

## 캐시·데이터·권한

- SwiftPM 의존성과 빌드 결과인 `.build`를 캐시한다. OS·아키텍처·캐시 버전·검사 모드(`test`·`coverage`·`release`)·툴체인 지문·`Package.swift`와 `Package.resolved` 해시·커밋으로 키를 만든다. `restore-keys`도 모드를 포함해 일반 테스트·커버리지·릴리스 산출물이 섞이지 않게 한다. 캐시가 있어도 검증은 매번 실행한다. 새 키를 처음 쓰거나 GitHub의 브랜치 접근 범위 안에 같은 모드 캐시가 없으면 캐시 없이 시작한다.
- 테스트는 합성 픽스처만 쓴다. `DJC_HOME`과 `DJC_REKORDBOX_DIR`은 러너 임시 폴더에 두며, 개인 라이브러리·음원·DB·백업을 CI에 올리지 않는다.
- `GITHUB_TOKEN` 권한은 `contents: read`이고 checkout 뒤 인증 정보를 보관하지 않는다. 별도 비밀값은 필요 없다. Actions 버전은 커밋 SHA로 고정한다.
- 포크 PR도 GitHub가 제공하는 임시 VM에서 `pull_request`로 실행한다. self-hosted 러너와 `pull_request_target`은 사용하지 않는다. 러너를 등록할 필요가 없다.

## 워크플로 검사

워크플로를 수정한 뒤 저장소 루트에서 `actionlint`로 검사한다. `python3 scripts/test-check.py`는 합성 명령만으로 빌드·번역·테스트·커버리지·파이프 실패, 빈/미달 커버리지, INT·TERM 취소와 로그 보존을 검사하며 CI에서도 실행한다. 분할 모드의 검사 범위·실패 전파·커버리지 목표 유지와 잘못된 인자의 거부도 확인한다. 실제 Swift 빌드나 라이브러리 접근은 하지 않는다. `.github/actionlint.yaml`은 actionlint 1.7.12가 아직 인식하지 못하는 공개 미리보기 `xcode-27` 라벨만 허용하며, self-hosted 러너를 사용하는 설정은 아니다.

## 푸시 뒤 관리자 확인

1. Actions 설정에서 이 워크플로와 `actions/checkout`, `actions/cache`, `actions/upload-artifact` 실행을 허용한다. 외부 포크 PR은 **모든 외부 기여자의 실행 승인**을 요구하도록 설정하고, 변경 내용을 확인한 뒤 승인한다.
2. `dev` 푸시에서 `test`, PR·`main`·수동 실행에서 `coverage`와 `release`가 실행되는지 확인한다. 실제 검사 러너는 macOS 27·Xcode 27이며, 결과를 합치는 `빌드·테스트·커버리지` job만 Ubuntu에서 실행된다. 포크 PR도 호스티드 러너에서만 실행되는지 확인한다.
3. 첫 실행의 캐시 저장과 다음 실행의 복원, Job summary의 테스트 수·커버리지, README의 `dev` 상태 배지를 확인한다.
4. `dev`·`main` 보호 규칙에 `빌드·테스트·커버리지`를 필수 상태 체크로 추가한다. 워크플로 파일만으로 병합을 차단하지는 못한다.

이 작업은 러너 등록·저장소 설정 변경·푸시를 수행하지 않는다. 미리보기 이미지의 공급이 중단되면 공식 라벨·SDK·실행 OS를 다시 확인한 뒤 러너를 변경한다.
