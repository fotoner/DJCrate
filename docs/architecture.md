# DJCrate 구조와 설계 결정

이 문서는 DJCrate의 구조와 그 구조를 고른 이유를 설명한다.

파일과 타입 하나하나의 설명은 코드 주석에 둔다. 이 문서의 모듈·폴더 지도는 새 코드를 둘 자리를 고를 만큼만 적는다. 지킬 규칙은 `.claude/rules/`에 있다. 그 규칙의 이유는 이 문서에 있다. 화면 모델과 뷰를 나누는 규칙은 [MVVM 패턴](mvvm.md)에 있다.

## 모듈

```
주도 어댑터   DJCrate(앱: 뷰·화면 모델, 조립 지점 AppComposition) · djc(CLI: 명령, 조립 지점 CLIComposition)
                 │ 유스케이스를 부른다                                   │ 실제 구현을 고른다(조립 지점만)
핵심부        DJCApplication(유스케이스·포트) ──▶ DJCDomain(엔티티·값·순수 규칙)
                 ▲ 포트를 구현한다
피동 어댑터   DJCAdapters(포트의 실제 구현 .live, 오디오 엔진) ──▶ RekordboxKit · DJCStorage · DJCAnalysis · DJCEnvironment(인프라, 포트를 모른다)
실행 파일     DJCrateExecutable · djcExecutable(main.swift 몇 줄)
```

DJCrate는 헥사고날 구조다(#167). 바깥 층은 안쪽 층을 안다. 안쪽 층은 바깥 층을 모른다. 이 구조를 고른 이유는 셋이다.

- 핵심부는 입출력을 하지 않는다. 그래서 규칙을 rekordbox 라이브러리 없이 빠르게 시험한다.
- 핵심부는 파일·DB·시계 같은 바깥 일을 포트로 받는다. 시험은 포트에 가짜를 넣는다.
- 앱과 CLI는 같은 유스케이스를 쓴다. 그래서 쓰기 순서는 한 곳에만 있다.

인프라는 포트를 모르는 보통 라이브러리다. DJCAdapters가 인프라를 불러 포트 모양으로 감싼다.

| 모듈 | 층 | 맡는 일 |
|---|---|---|
| DJCDomain | 핵심부 | 입출력 없는 규칙과 값 |
| DJCApplication | 핵심부 | 유스케이스와 포트 |
| DJCAdapters | 피동 어댑터 | 포트의 실제 구현 한 벌, 오디오 엔진 |
| RekordboxKit | 인프라 | rekordbox 형식, 쓰기 입구와 쓰기 관문 |
| DJCStorage | 인프라 | DJCrate 자신의 파일, iTunes 읽기, USB 볼륨 |
| DJCAnalysis | 인프라 | 소리 분석과 곡 편집 렌더 |
| DJCEnvironment | 인프라 | 이 프로세스의 환경 읽기 |
| DJCrate·djc | 주도 어댑터 | 앱 화면과 CLI 명령, 조립 지점 |

### DJCDomain

DJCDomain은 입출력 없는 규칙과 값을 둔다. 규칙은 시험이 가장 빠른 이 층에서 가장 촘촘히 본다. 여기에 두는 것은 아래와 같다.

- 편집 규칙: 큐 편집, 루프, 그리드 따라가기
- 게인 정책
- 재생 예약(`LoopPlanner`·`JumpPlanner`)과 곡 편집 시간표
- USB 계획과 USB 라이브러리 값 모델
- rekordbox 쓰기 관문이 주고받는 값: 쓰기 보고, 분석 입력, 백업 정보
- 읽은 rekordbox 라이브러리와 iTunes 목록
- CLI JSON 계약 값과 분석 결과 값
- 순수 화면 규칙(입력 → 할 동작). 앱을 빌드하지 않은 채 시험할 수 있게 여기 둔다.

### DJCApplication

DJCApplication은 기능별 폴더에 유스케이스와 포트를 둔다. 유스케이스는 화면 없는 순서를 정한다. 순서는 대개 읽기 → 판정 → 쓰기 → 뒤처리 차례다.

| 폴더 | 유스케이스 예 |
|---|---|
| `Deck/` | `LoadDeckTrack`, `AnalyzeDeckTrack`, `SaveDeckDrafts` |
| `Edit/` | `RenderEdit`, `StageEdit` |
| `Library/` | `LoadLibrary`, `ImportXML`, `RecoverDrafts`, `RelocateTracks`, `StageTracks`, `EditPlaylists`, `ArchiveUsbHistories` |
| `Reflection/` | `ReflectionSession`, `CompatibilityCheck` |
| `Usb/` | `UsbSync`, `UsbExportSession`, `UsbWriteFlow` |

- 반영 세션 `ReflectionSession`은 rekordbox 쓰기 흐름이 함께 쓰는 유스케이스다. 앱의 반영, 곡 넣기·빼기, 복원이 이 세션을 쓴다. 시점 복원과 iTunes 동기화도 같은 세션을 쓴다.
- CLI 쓰기 명령도 같은 세션을 쓴다. CLI는 세션 옵션으로 쓴 뒤의 초안 정리와 되살리기를 끈다.
- 라이브러리 쪽(`Library/`)은 여러 흐름을 유스케이스로 둔다. 읽기, 초안 지켜보기, 추가한 곡이 유스케이스다. XML 가져오기와 내보내기, 막힌 초안 복구도 유스케이스다. 바깥 일은 포트 묶음 `LibraryPorts`로 받는다.
- 공유 저장소 `LibraryStore`는 유스케이스 묶음 `LibraryUseCases`를 받는다. 저장소는 유스케이스 결과를 화면 상태에 적용한다.
- **화면 모델은 포트를 들지 않는다.** `LibraryUseCases.ports`는 모듈 밖에 공개하지 않는다. 화면에 보일 값은 묶음의 읽기 메서드로 받는다.
  - `linkedXML`, `hasWriteBackup`, `writeBackups`
  - `missingFiles`, `log`
- 덱도 초안 저장소를 들지 않는다. 덱의 큐·그리드·게인 저장은 유스케이스 `SaveDeckDrafts`가 한다.
- **쓴 뒤와 복원 뒤의 초안 파일은 반영 세션이 저장한다.** 그 파일은 아래와 같다.
  - 큐·그리드·게인 초안
  - 그림·태그 초안
  - 합치기·재생 목록 초안과 연결 기록
- 저장소는 `ReflectionLibraryChange`를 받아 메모리와 표시만 맞춘다.
- 반영 세션 포트는 `ReflectionPorts(sharing:)`로 라이브러리 묶음을 받는다. 그래서 세션과 저장소가 같은 저장 큐와 스냅샷 뜨기, 연결 기록을 쓴다.
- CLI 읽기와 `djc draft`도 같은 묶음을 쓴다. CLI `xml-diff`·`xml-export`도 마찬가지다.

### 인프라와 어댑터

- **DJCAdapters**는 포트의 실제 구현 한 벌이다. 구현은 `static func live(…)`이고 기능별 폴더에 있다. 오디오 엔진의 실제 구현도 `Audio/`에 있다.
- DJCAdapters의 두 파일은 쓰기 커버리지 그룹이다. `RekordboxWriteGate.live()`는 rekordbox 쓰기 관문을 감싼다. `UsbLibraryEngine+Writer`는 `UsbWriter`를 부른다.
- **RekordboxKit**은 rekordbox 형식을 아는 유일한 곳이다. DB 열기, ANLZ, 스냅샷을 여기서 한다. XML과 USB 형식도 여기서 다룬다.
- RekordboxKit에는 쓰기 입구가 그대로 있다. 쓰기 입구는 `RekordboxWriter.write`·`restore`와 `RekordboxTrackWriter.add`·`delete`다. 관문 `RekordboxWriteGuard`와 USB 쓰기 `UsbWriter.write`도 여기 있다. 위층은 이것들을 부르기만 한다.
- RekordboxKit은 DJCrate 자신의 쓰기 위치(예: 백업 폴더)를 인자로 받는다. 예외로 두 자리는 `DJCIdentity`로 직접 안다. 하나는 스냅샷 폴더(`LibrarySnapshot.defaultDirectory`)다. 다른 하나는 XML 내보내기가 거부하는 자리다. 이 자리는 DJCrate 데이터 폴더와 연동 XML이다.
- **DJCStorage**는 DJCrate 자신의 파일을 맡는다. 초안과 추가한 곡, 반영 묶음과 USB 초안이 그 파일이다. iTunes 읽기와 USB 볼륨·도구 실행도 맡는다.
- **DJCAnalysis**는 소리 분석과 곡 편집 렌더를 맡는다. 파형, 그리드 추정, 조성을 분석한다. 음량과 섹션도 분석한다. DJCAnalysis는 rekordbox를 모르므로 시간축 차이를 인자로 받는다.
- **DJCEnvironment**는 이 프로세스의 환경을 읽는다. 시험 프로세스인지와 그 임시 폴더를 안다(`TestProcess`, #182). 데이터·로그·캐시 위치는 `DJC_HOME`과 `DJC_REKORDBOX_DIR`에 따라 정한다. 환경을 인자로 받는 순수 규칙은 DJCDomain에 남는다. 인프라가 막는 입출력을 협력 풀 밖에서 돌리는 `OffPoolIO`도 여기 있다(#247).
- 앱 **DJCrate**와 CLI **djc**의 본체는 라이브러리 타깃이다. 그래서 실행 파일과 시험이 컴파일 결과를 함께 쓴다. 실행 진입점만 `DJCrateExecutable`·`djcExecutable`로 나눈다. 제품 이름과 리소스 번들 이름은 그대로다.

### 경계 규칙

`scripts/check-imports.py`가 소스에서 경계 규칙을 기계로 검사한다. 이 검사는 모든 검사 모드의 첫 단계로 1~2초 걸린다. 규칙 표의 정본은 그 스크립트 맨 위다. 표 이름은 `ALLOWED`·`FORBIDDEN_API`이고, 예외 목록은 `ASSEMBLY_FILES`·`BROAD_FOLDERS`다.

- 파일의 모듈은 `Package.swift`의 타깃 경로로 정한다.
- 어느 타깃에도 속하지 않는 Swift 파일과 규칙이 없는 타깃은 실패한다. 그래서 폴더를 옮겨도 검사에서 조용히 빠지지 않는다.

| 규칙 | 내용 |
|---|---|
| import | DJCDomain은 프로젝트 모듈을 import하지 않는다. DJCApplication은 DJCDomain만 import한다 |
| import | 인프라는 DJCApplication·DJCAdapters·앱을 import하지 않는다 |
| import | 앱의 화면 모델·뷰와 CLI 명령은 DJCApplication·DJCDomain만 import한다 |
| import 예외 | 조립 지점은 파일 이름 목록 `ASSEMBLY_FILES` 5개다. 아래 층을 모두 import한다 |
| import 예외 | 디버그 자가 테스트(`Sources/DJCrate/Diagnostics/`), 실험 명령(`Sources/djc/Lab/`)은 `BROAD_FOLDERS`에 적은 import만 더 받는다 |
| api | 핵심부(DJCDomain·DJCApplication)는 `FileManager`, `ProcessInfo`, `UserDefaults`를 직접 쓰지 않는다 |
| api | 핵심부는 `Bundle` 타입, `Date()`·`Date.now`, `UUID()`도 직접 쓰지 않는다. `.init()` 꼴도 같다. 시계·ID·환경·파일·번들은 포트나 주입으로 받는다 |
| api | 핵심부는 `Locale`·`TimeZone`·`Calendar`의 `.current`·`.autoupdatingCurrent`를 쓰지 않는다. 타입 없이 쓴 `.main`·`.current`·`.now`도 쓰지 않는다 |
| api | 핵심부에는 화면 상태가 없다. `import Observation`과 `@Observable`을 쓰지 않는다 |
| api | 핵심부는 `Task.detached`를 쓰지 않는다. 막는 입출력은 `BlockingWork.run`으로, 취소를 보는 계산은 `@concurrent`로 부른다 |
| view-task | 앱의 뷰 파일은 `Task`를 시작하지 않는다. `await`도 하지 않는다. 허용 꼴은 [MVVM-4](mvvm.md#mvvm-4-뷰-본문에서-유스케이스task를-시작하지-않는다)에 있다 |
| test-defaults | 시험은 `UserDefaults(suiteName:)`을 직접 만들지 않는다. `TestDefaults`를 쓴다 |
| 시험 타깃 | 시험하는 층과 그 아래 층, 시험 재료만 import한다 |
| 시험 타깃 | 유스케이스 시험(`DJCApplicationTests`)은 가짜 포트와 `DJCTestKit`·`PortTestKit`만 쓴다 |

- **조립 지점 예외는 파일 이름으로 적는다.** 접두 정규식은 쓰지 않는다. 목록의 파일이 없으면 검사가 실패한다.
  - `Sources/DJCrate/App/AppComposition.swift`·`AppComposition+Usb.swift`
  - `Sources/djc/CLIComposition.swift`·`CLIComposition+Usb.swift`
  - `Sources/djc/Commands/CLIWriteTarget.swift`
- `Sources/djc/CLI.swift`는 예외가 아니다. 이 파일에는 명령 표만 있다. `compat` 본문은 유스케이스 `CompatibilityCheck`와 명령 파일 `CompatCommand.swift`로 옮겼다.
- **넓은 예외 폴더는 더 받을 import를 적는다.** 목록 밖 import는 위반이다. 폴더의 어느 파일도 쓰지 않는 허용이 남아도 실패한다.
- 넓은 예외의 크기는 `--summary`의 예외 표로 본다. 2026-10 기준 두 폴더는 앱·CLI 소스 줄의 26%다.
- **남은 위반은 빚 목록에 고정한다.** 빚 목록은 `scripts/import-debt.txt`이고 줄 모양은 `파일<TAB>규칙<TAB>대상`이다. 목록 밖 위반이 생기면 검사가 실패한다. 이미 해소한 항목이 목록에 남아도 실패한다. 그래서 빚이 줄면 목록도 줄어든다.
- `view-task` 빚은 대상 칸에 파일마다 곳 수를 적는다(예: `Task 3곳`). 곳 수가 늘면 새 위반으로 실패한다. 줄어도 빚 목록을 고치라고 실패한다.
- 2026-10 기준 빚은 35줄이다. 모두 새 규칙이 찾아낸 옛 코드다.
  - `api` 1줄: `DJCApplication/Usb/UsbWriteSession.swift`의 `@Observable`
  - `view-task` 34줄: 뷰 18파일의 `Task` 49곳과 `await` 82곳
- 개수는 `python3 scripts/check-imports.py --summary`로 본다. 새 위반은 빚 목록에 더하지 않는다. 위반은 그 자리에서 고친다.
- **모든 Swift 타깃에 `MemberImportVisibility`(SE-0444)를 켠다.** 그러면 전이 의존으로 새어 들어오는 확장 멤버를 컴파일러가 막는다. 그래서 import 줄 검사가 실제 사용과 맞는다.
- SwiftPM은 목록에 없는 아래층 모듈의 `import`를 막지 않는다. 그래서 의존 방향은 `Package.swift`와 이 검사로 지킨다.
- **오디오 엔진도 포트 뒤에 있다.** 포트 `DeckAudioEngine`·`EditAudio`는 DJCApplication에 있다. 실제 구현은 `Sources/DJCAdapters/Audio/`에 있다. 조립 지점이 구현을 고른다. 편집 창은 `EditWindowLinks.makeAudio`로 재생기를 받는다.
- 덱 조작 기록은 포트의 `recordEvent`가 남긴다. 음원 열기 실패 판정은 포트의 `failureState(for:)`가 한다.
- **오디오 엔진은 메인 액터 동기로 둔다.** 덱 재생 경로에서는 예외로 화면 모델이 엔진 포트를 직접 부른다. 매 프레임 재생 위치와 샘플 단위 예약을 유스케이스 한 겹 뒤로 미루지 않으려는 것이다. 덱 오디오의 규칙과 실험은 [덱 오디오](#덱-오디오-deckaudio)에 있다.

### 포트 방향과 모양

- **포트는 핵심부(DJCApplication)가 정의한다.** 실제 구현은 DJCAdapters가 `static func live(…)`로 만든다. 핵심부와 화면 모델에는 실제 구현을 고르는 기본 인자를 두지 않는다. 고르는 일은 조립 지점만 한다.
- **기본 모양은 `Sendable` 클로저 struct다.** 포트는 메인 스레드 밖에서 부른다. 시험은 클로저를 바꿔 넣는다.
- 동기 포트(파일·USB·DB 입출력)는 `BlockingWork.run`으로 GCD 스레드에서 부르고 기다린다. `Task.detached`·`@concurrent`로 협력 스레드 풀에서 막으면 코어가 적은 기계(CI 러너)에서 풀이 바닥나 다른 비동기 일까지 멈춘다. 시험 가짜는 동기 포트 클로저에서 `expectBlockingOffPool`을 부른다. 막을 때는 `waitOffPool`을 쓴다(DJCTestKit).
- 작업 취소를 조각마다 보는 일은 협력 풀에 둔다. 음원 분석과 XML 파싱이 그 예다. GCD에는 지금 작업이 없어 `Task.isCancelled`가 늘 거짓이다. 그래서 옮기면 취소가 닿지 않는다.
- 인프라의 막는 입출력 가운데 취소를 단계마다 보는 일은 `OffPoolIO.run`(DJCEnvironment)으로 GCD에서 돌린다. 이 함수는 작업 취소를 `CancellationCheck` 신호로 넘긴다. 일은 단계 사이에서 `check()`를 부른다. 미리 보기·복구의 사본 뜨기(`WritePreviewSnapshot`)와 옮긴 곡 후보의 폴더 열거(`RelocateScanner`)가 그 예다(#247).
- 메인 액터 상태를 읽는 포트만 `@MainActor` 클로저 struct로 쓴다. 그 상태는 쓰기 잠금, 저장 대기, 화면 알림이다.
- **반영 세션의 화면 상태 포트는 세 가지뿐이다.** 읽기 하나(`state`), 결과 적용 하나(`apply`), 쓰기 전 저장이다. 지울 초안과 되살릴 초안은 세션이 정한다. 라이브러리 저장소는 메모리 초안과 표시만 맞춘다.
- 라이브러리 저장소는 이 포트를 채택하지 않는다. 조립 지점이 저장소 메서드를 클로저로 묶는다.
- **핵심부에는 화면 상태가 없다.** 유스케이스는 Observation을 쓰지 않는다. 흐름 상태는 값으로, 알림은 출력 포트로 내보낸다. 관찰과 표시는 앱 화면 모델이 맡는다. 검사는 경계 규칙의 `api`(Observation)다.
  - 본보기는 USB 동기화다. `UsbSync`는 흐름 상태를 값 `UsbSyncState`로 든다. 바깥에서는 읽기만 한다.
  - `UsbSync`는 출력 포트 `UsbSyncOutput`으로 바뀜과 알림 `UsbSyncNotice`를 내보낸다. 닫기 결과는 값 `UsbSyncCloseResult`다.
  - 앱 `UsbSyncModel`이 이것을 관찰 상태로 바꾼다. 표시 트리, 흐리게, 빈 목록 문구도 화면 모델이 만든다.
  - USB 쓰기 세션도 같은 모양이다. `UsbWriteSession`은 잠금·진행·옮기기 상태를 값 `UsbWriteSessionState`로 든다. 바뀌면 출력 포트 `UsbWriteSessionOutput`으로 내보낸다.
  - 앱 `UsbWriteModel`이 그 값을 칸마다 관찰 상태로 옮긴다. Observation은 같은 값이면 알리지 않는다. 그래서 진행이 바뀌어도 잠금만 보는 화면은 다시 그리지 않는다.
- **예외로 프로토콜인 포트는 아래와 같다.**
  - USB 파일 연산 `UsbFileSystem`: RekordboxKit의 USB 형식 코드가 쓰는 계약이다.
  - USB 쓰기 유스케이스 경계 `UsbWriting`: 실제는 `UsbWriteService`다. 앱 쓰기 흐름 시험은 가짜를 쓴다.
  - 오디오 엔진 `DeckAudioEngine`·`EditAudio`: 메인 액터에서 상태를 든 엔진 객체다.
- **인프라는 포트를 채택하지 않는다.** 인프라는 DJCApplication을 모르므로 채택할 수 없다. DJCAdapters가 인프라 타입을 클로저로 감싸 붙인다.
- **핵심부의 새 ID는 포트가 준다.** 핵심부는 `UUID()`를 직접 부르지 않는다. 새 큐 ID는 초안 포트의 `newCueID`가 준다. 이 칸은 `DraftStore`·`DraftFiles`·`TrackAssetReader`와 USB `CueGrid`에 있다. 저장소가 정체성을 매기는 모양이다.
- 메모리 구현의 `newCueID`는 프로세스 안 차례 번호(`MemoryCueIDs`)다. 실제 구현은 무작위 UUID를 준다. 쓰기 관문 파일이 쓰는 옛 모양(무작위 UUID)은 RekordboxKit `Library/CueDraft+IDs.swift`에 있다.

### 조립 지점

조립 지점은 실제 구현을 골라 잇는 곳이다. 앱은 `AppComposition`, CLI는 `CLIComposition`이다. 조립 지점이 하나라서 위치와 실제 구현은 한 번만 정한다.

앱의 `AppComposition.live()`는 아래 일을 한 번씩 한다.

1. 실행 인자와 환경을 한 번 푼다.
2. 위치 값 `LibraryLocation`을 만든다(`LibraryLocation.resolve`).
3. 설정 하나와 초안 저장 큐 하나를 만든다.
4. 그 큐로 초안 저장소를 만든다. 라이브러리 저장소와 덱이 이 초안 저장소를 함께 쓴다.
5. 같은 위치 값과 초안 저장소로 유스케이스 묶음 `LibraryUseCases`를 붙인다. 실제 구현은 `LibraryPorts.live`다.
6. 이 묶음을 라이브러리 저장소에 넘긴다. 스냅샷 뜨기도 이 묶음 안 포트로 한다.
7. 덱에 덱 읽기 포트와 분석 유스케이스를 붙인다.
8. 반영 세션의 포트를 붙여 `ReflectionCoordinator` 하나를 만든다(`AppComposition.reflection(store:)`). 포트는 저장소의 유스케이스 묶음을 나눠 받는다.

위치 값은 아래 폴더를 정한다.

- 라이브 rekordbox 폴더
- 스냅샷 폴더
- 명시 사본
- 쓰기 대상
- 백업 폴더
- 초안 폴더

조립 지점이 붙이는 포트는 아래와 같다.

- 라이브러리 유스케이스 묶음: 라이브러리 저장소가 받는다. 스냅샷 뜨기도 이 안에 있다.
- 덱 읽기와 분석: 덱이 받는다.
- 편집본 쓰기: `connect()`가 `AppComposition.renderEdit(store:)`를 편집 창 연결 `EditWindowLinks`에 붙인다. 곡 편집 창과 Flip 창이 이 연결을 쓴다.
- 반영 세션: `ReflectionCoordinator`가 받는다.

조립 지점의 다른 결정:

- **라이브러리 저장소는 프로세스 인자와 환경을 다시 읽지 않는다.** 읽기 출처와 변경 확인은 위치 값에서 나온다. 복구 출처와 쓰기 대상도 위치 값에서 나온다. iTunes 동기화도 반영·복원과 같은 쓰기 대상에 쓴다.
- USB 조립은 옆 파일 `AppComposition+Usb.swift`에 있다.
- **보조 창은 전역 `.shared` 대신 `AppWindows` 하나를 나눠 받는다.** `AppWindows`는 조립 지점이 만든다. 보조 창은 곡 편집, Flip, 시점 스냅샷 창과 Apple Music 가져오기 창이다.
- `connect()`는 저장소↔덱 연결, 단축키, 편집 창 연결을 한 번만 한다. `start()`는 USB 절을 붙인 뒤 라이브러리를 처음 읽는다.
- **CLI는 앱과 같은 어댑터를 쓴다.** `CLIComposition`은 위치와 쓰기 관문, 초안 저장소를 붙인다. 쓰기 명령의 반영 세션도 여기서 만든다. 라이브러리 유스케이스 묶음은 앱과 같은 것을 `library(home:)`로 만든다. USB는 `CLIComposition+Usb.swift`에 있다.
- CLI의 쓰기 대상은 `CLIWriteTarget`이 `--live`·`--db`를 풀어 정한다.
- **라이브 라이브러리 쓰기 대상은 조립 지점이 정한다.** 핵심부는 정하지 않는다. 예외로 RekordboxKit이 주는 위치 값 중 셋은 환경을 따른다.
  - 쓰기 미리 보기의 기본 share(`RekordboxShare.directory`)
  - USB 라이브 판정(`UsbLiveDatabase`)이 보는 rekordbox 폴더: 이 Mac의 실제 폴더와 `DJC_REKORDBOX_DIR`
  - 기본 스냅샷 폴더(`DJCIdentity.snapshotsDirectory`): `DJC_REKORDBOX_DIR`이 있으면 그 안 `djc-snapshots/`다. `DJC_HOME`은 스냅샷을 옮기지 않는다.
- **조립 지점 밖에서는 위치와 실제 구현을 정하지 않는다.** 2026-10 기준 화면과 CLI 명령에서 아래 직접 사용은 0이다.
  - 위치 묶음 `DJCPaths`
  - 캐시 위치 `DJCCachePaths.current`
  - 스냅샷 함수 `LibrarySnapshot.latest`·`LibrarySnapshot.take`
- 예외 파일은 `Diagnostics/`, CLI `Lab/`, 조립 지점뿐이다.
- 설정 › 저장 공간의 화면 모델은 `AppComposition.storageSettings()`가 만든다.
- **목록 그림 캐시 싱글턴은 없앴다.** 옛 `PreviewWaveformCache.shared`·`Thumbnails.shared` 대신 라이브러리 저장소가 하나씩 든다(`previewImages`·`thumbnails`).
- 남은 싱글턴은 넷이다.
  - `LoudnessCache.shared`: 인프라 쪽 캐시다. 조립 지점이 붙인다.
  - `PreviewWaveformStore.shared`: 인프라 쪽 캐시다. 실제 구현(`LibraryPorts.live`)이 붙인다.
  - `ITunesRefreshCoordinator.shared`: Music 결과를 채택하는 순서다. 타입 `ITunesRefreshCoordinator`는 DJCApplication에 있다. 프로세스가 함께 쓰는 하나는 실제 구현(`LibraryPorts.live`)이 붙인다.
  - `ArtworkRevisions`: 앱이 그림을 쓴 곡마다 올리는 번호다. 앱 모듈(`Sources/DJCrate/Support/Artwork.swift`)에 있다.

### 새 코드를 어디 둘까

| 무엇 | 어디 |
|---|---|
| 입출력 없는 판정·계산, 값 모델 | DJCDomain의 기능 폴더. 시험은 `DJCDomainTests` |
| 여러 단계를 잇는 흐름(읽기 → 판정 → 쓰기 → 뒤처리) | DJCApplication 기능 폴더의 유스케이스. 바깥 일은 포트로 받는다 |
| 앱과 CLI가 함께 쓸 순서 | DJCApplication의 유스케이스 |
| 포트의 실제 구현(파일·DB·도구·인프라 호출) | DJCAdapters 기능 폴더의 `+Live` |
| 오디오 엔진의 실제 구현 | `Sources/DJCAdapters/Audio/` |
| 포트의 가짜와 계약 함수 | `PortTestKit`(`Tests/Support/Ports`) |
| rekordbox 형식 읽기·쓰기, USB 형식 | RekordboxKit. 쓰기 입구는 최상위, USB 쓰기는 `Usb/Write/` |
| DJCrate 자신의 파일 형식·저장 | DJCStorage |
| 소리 분석·렌더 | DJCAnalysis |
| 화면 상태·의도 전달 | 앱 화면 모델. 유스케이스를 부른다. 모양은 [MVVM 패턴](mvvm.md) |
| 실제 구현 연결 | 앱은 `AppComposition`, CLI는 `CLIComposition` |
| CLI 인자·출력 | `djc` 명령 |
| 규칙을 알아낼 때 쓴 실험 | `djc/Lab/` |

## 시험

- **시험은 시험하는 층의 타깃에 둔다.** 규칙은 가장 아래 층에서 한 번 촘촘히 본다. 위층은 연결만 본다.
- 타깃별 배치, 시험 재료, 사용자 폴더 격리, 판정 규칙은 `.claude/rules/tests.md`에 있다. 검증 단계는 `docs/ci.md`에 있다.
- **새 포트는 계약 함수와 가짜를 `PortTestKit`에 둔다.** `PortTestKit`(`Tests/Support/Ports`)에는 포트별 가짜(메모리 구현)와 공용 계약 함수 `<포트>Contract`가 있다.
- `DJCApplicationTests`의 `PortContractTests`는 계약 함수를 가짜에 돌린다. `DJCAdaptersTests`는 같은 함수를 실제 구현에 돌린다. 그래서 가짜와 실제 구현이 갈라지면 시험이 잡는다.
- **rekordbox 쓰기는 실제 라이브러리 없이 시험한다.** 시험은 구조만 뽑은 7.2.18 스키마로 만든 픽스처 DB를 쓴다. 분석 파일과 음원도 합성한 것을 쓴다. 재료와 골든 시험 규칙은 `.claude/rules/tests.md`에 있다.
- 소리와 실제 화면은 디버그 빌드의 자가 테스트로 본다(`.claude/skills/app-selftest/SKILL.md`). 단위 시험으로 못 잡는 부분만 본다.
- SQLCipher 처음 열기 경쟁은 `.claude/rules/cipher.md`에 있다. `CipherDatabase`로만 여는 이유도 거기 있다.

## 데이터 폴더

DJCrate 데이터는 `~/Library/Application Support/DJCrate/`에 있다. `DJC_HOME`으로 이 자리를 바꾼다. 시험 프로세스는 임시 폴더를 쓴다. 로그는 `~/Library/Logs/DJCrate/`에 있다. 환경 변수는 `docs/cli.md` "환경 변수"에 있다.

- 초안: `cue-drafts/`, `grid-drafts/`, `gain-drafts.json`, `tag-drafts/`
- 앨범아트 초안: `artwork-drafts/`. 앨범아트 초안과 고른 앨범아트 사본이 있다.
- 재생 목록 초안: `playlist-drafts.json`. 재생 목록 편집을 순서대로 적는다.
- `damaged-drafts/`: 읽지 못한 초안 파일을 옮겨 둔 곳이다. 그 파일을 지우지 않는다. 빈 값으로 덮지도 않는다. 합치기 초안 `merge-drafts.json`과 추가 목록 `staged.json`도 여기로 옮긴다. 앱은 읽기·저장 때 파일을 옮긴 뒤 목록 위에 알린다.
- 추가한 곡: `staged.json`
- 읽기용 스냅샷: `snapshots/`
- 쓰기 전 백업: `rekordbox-backups/`
- 시점 스냅샷: `point-snapshots/`(#224)
- 캐시: `analysis/`, `waveforms/`, `loudness.json`
- USB 백업과 초안: `usb-backups/`, `usb-drafts/`
- USB DB의 Mac 사본: `usb-snapshots/`
- USB 저널과 잠금: `usb-sessions/`
- USB 준비 폴더: `usb-staging/`
- USB에서 가져와 보존한 기기 재생 기록: `usb-histories/`. 기록마다 JSON 한 파일이다. 캐시가 아니므로 지우지 않는다(#43).
- 스냅샷·백업·DB 사본에는 rekordbox 클라우드 토큰이 들어 있다. 이 파일을 커밋·이슈·로그에 넣지 않는다.
- 캐시 종류별 비우기는 `docs/cli.md` "캐시 보기·비우기"에 있다.

## 데이터 흐름

아래 그림은 라이브러리를 읽는 길과 rekordbox에 쓰는 길을 보인다.

```
rekordbox master.db ──(스냅샷 사본)──▶ RekordboxLibrary ──▶ LibraryStore(목록·필터) ──▶ DeckModel(덱)
        ▲                                                         │
        │                                            편집은 초안으로 쌓임
        │                  CueDraft · GridDraft · 게인 초안 · TagDraft · ArtworkDraft · PlaylistDraft
        │                                                         │
        └──── RekordboxWriter / RekordboxGridWriter ◀── rekordbox에 쓰기(rekordbox 꺼져 있을 때만)

새 곡 ── StagedTrack ──┬── RekordboxTrackWriter ──▶ 컬렉션에 직접 넣기(rekordbox 꺼져 있을 때만)
                      └── RekordboxXML ──▶ XML 만들기 ──▶ 사용자가 rekordbox에서 Import To Collection
기존 곡의 큐·그리드 초안 ── Reflection ──▶ XML 만들기 ──▶ 사용자가 rekordbox에서 Import To Collection
```

그림의 rekordbox 쓰기는 반영 세션 `ReflectionSession`이 포트 `RekordboxWriteGate`로 부른다.

### 읽기와 초안

- **읽기는 `LibrarySnapshot`이 뜬 사본에서만 한다.** 라이브 DB를 열어 두면 rekordbox와 잠금·WAL이 얽히기 때문이다. rekordbox가 켜져 있으면 `--force`일 때만 WAL까지 합친 읽기용 사본을 뜬다.
- **편집은 초안으로 쌓는다.** 초안은 앱을 꺼도 반영할 때까지 `~/Library/Application Support/DJCrate/`에 JSON 파일로 남는다. 반영한 초안은 지운다. 초안마다 만들 때의 rekordbox 상태 `base`가 있다. 그래서 그 뒤 rekordbox에서 바뀐 곡에는 쓰지 않는다. 덮어쓰기를 막으려는 것이다.
- **명시적 동기화는 초안을 보존한다(#159).** 툴바와 ⌘R의 `rekordbox와 동기화`는 기존 읽기용 사본 경로를 쓴다. `--db`·`DJC_DB` 모드에서는 지정한 사본만 다시 읽는다. 큐·그리드 초안의 기준은 자동으로 덮지 않는다.
  - 태그 초안의 안 고친 칸은 최신값으로 합친다. 같은 칸이나 앨범 관계가 충돌하면 초안을 보존해 사용자가 인스펙터에서 칸별로 고르게 한다.
  - 쓰는 중이나 저장하지 않은 덱 편집 중에는 동기화하지 않는다. 읽는 동안 쓰기를 시작하면 읽은 결과를 버린다.
  - 태그 저장이 실패해도 메모리의 입력과 삭제 의도는 보존한다. 명시적 동기화와 쓰기 준비는 실패한 저장만 다시 시도한다.
- **재생 목록 초안은 편집 순서다.** 곡 초안과 달리 재생 목록 편집은 서로 기댄다. 예를 들어 새 목록에 곡 넣기는 목록 만들기에, 넣은 곡 옮기기는 넣기에 기댄다. 그래서 `PlaylistDraft`는 `PlaylistEdit`을 적힌 순서대로 든다. 편집마다 기대는 rekordbox 목록의 처음 상태(`base`)도 적는다.
  - 사이드바와 곡 목록은 rekordbox 상태에 초안을 얹은 모양을 보여 준다. 이 모양은 쓰기 모듈과 같은 규칙인 `PlaylistLayout`이 만든다.
  - 쓰기 모듈은 트랜잭션 안에서 처음 상태와 지금 상태를 비교해 바뀐 목록의 편집만 막는다. 앱은 쓴 편집만 초안에서 뺀다.
  - 쓰기를 되돌리면 그때 쓴 편집을 되돌린 상태 위에 다시 쌓는다.
- **인텔리전트 재생 목록은 읽기만, 실험실 설정 뒤에 둔다(#68).** 조건 칸인 `SmartList` XML은 `SmartPlaylistSource`가 읽는다(`DJCDomain/Playlist/SmartPlaylist.swift`). 순수 규칙 `SmartPlaylistEvaluator`가 컬렉션 곡에서 목록의 곡을 계산한다. 모르는 항목·연산자·단위가 있는 목록은 곡을 보이지 않는다.
  - 설정 › 실험실의 `lab.smartPlaylists`를 켰을 때만 사이드바 트리에 계산한 곡을 채운다(`LibraryStore+SmartPlaylists`). 이 설정의 기본값은 끔이다.
  - 쓰기·USB 내보내기·XML 경로는 `PlaylistLayout`의 `isSmart` 거름을 그대로 쓴다.
  - 규칙 근거와 확인하지 않은 것은 `docs/rekordbox-internals.md`에 있다.

### XML 경로

- **XML은 별도의 호환 경로다.** 이 경로는 태그·게인·재생 목록 초안까지 다루는 직접 쓰기와 범위가 같지 않다. XML 경로는 전체 라이브러리 입출력도 아니다. 사용자용 [지원 범위와 사용법](features.md#xml-호환-경로)은 기능 문서에 있다.
  - 기존 곡은 `Reflection.plan`으로 큐·그리드 변경과 옮길 수 없는 정보를 확인한 뒤 `Reflection.document`로 내보낸다.
  - 새 곡은 `RekordboxXML.document`로 곡 정보·그리드·점 큐를 내보낸다.
  - 두 경로는 같은 연동 파일을 덮어쓰되 재생 목록 이름은 각각 `DJCrate 반영`·`DJCrate 추가`로 유지한다.
  - 새 스냅샷에서 기존 곡은 `Reflection.verify`로 큐·그리드·곡 정보를 비교한다. 새 곡은 `StagedTrack.ImportCheck`로 그리드를 비교한다.
- **라이브러리 전체 XML 내보내기는 읽기만 하는 세 번째 경로다(#72).** 입구는 앱의 "라이브러리 XML 내보내기…"와 `djc xml-export`다. `RekordboxLibraryXML`이 스냅샷 `RekordboxLibrary`와 분석 파일의 `PQTZ`를 읽어 COLLECTION·PLAYLISTS를 지정한 출력 파일 하나에만 쓴다. 쓰지 않은 초안은 읽지 않는다. DB와 분석 파일의 시각이 이미 rekordbox 시간축이라 인코더 지연은 따로 더하지 않는다. 출력 파일에 넣지 않는 칸은 `docs/cli.md`에 있다.
  - 위 두 경로의 출력은 바꾸지 않은 채 `RekordboxXML`의 직렬화 도우미 `escape`·`location`·`kind`만 나눠 쓴다.
  - `checkOutput`은 `.xml`이 아닌 출력과 아래 자리를 거부한다.
    - rekordbox 폴더
    - USB의 `PIONEER/`
    - DJCrate 데이터 폴더와 그 안의 백업
    - 연동 XML 자리
- **XML 가져오기는 비교 → 초안이다(#72).** 입구는 앱의 "rekordbox XML 가져오기…"와 `djc xml-diff [--draft]`다. 가져오기는 rekordbox에 쓰지 않는다. rekordbox 쓰기는 기존 반영 흐름이 이 초안으로 한다.
  - `RekordboxXMLReader`가 XML을 흘려 읽어 DJCDomain 모델 `XMLLibrary`로 만든다. `RekordboxXMLImport`는 전체 내보내기의 `load`를 그대로 써서 지금 라이브러리를 같은 모델로 읽는다. 그래서 내보낸 XML을 다시 가져오면 차이가 0이다.
  - 곡 맞추기(`XMLTrackMatching`)와 차이(`XMLLibraryDiff`), 고른 차이를 초안으로 바꾸는 `XMLImportDrafts`는 순수 규칙이다.
  - 비교·계획·저장 순서는 앱과 CLI가 함께 쓰는 유스케이스 `ImportXML`이 정한다. 저장은 초안 폴더에만 한다.
  - 기존 초안은 덮지 않는다. 초안이 담지 못하는 차이는 손실로 센다.

### 반영 흐름

**반영 흐름은 DJCApplication의 반영 세션 `ReflectionSession` 한 곳이 정한다.** 화면 쪽 `ReflectionCoordinator`는 입구와 막힌 초안 복구 시트만, `ReflectionPresenter`는 결과 보이기만 맡는다.

반영은 아래 순서로 간다.

1. rekordbox가 꺼져 있는지 확인한다.
2. 미리 보기: 스냅샷 사본에 끝까지 써 본 뒤 되돌린다.
3. `WriteConfirmPolicy`가 정한 아래 이유가 있을 때만 확인 창을 띄운다(#210).
   - 막힌 초안이나 곡이 있다.
   - 제외한 초안이 있다.
   - 되돌려도 다른 변경까지 잃는 손실이 있다(예: 중복 합치기).
   - 백업 폴더에 쓸 수 없다.
4. 쓸 수 있는 것만 실제로 쓴다.
5. 쓰기 전으로 복원할 수 있는 토스트를 띄운다.

- **확인 창은 묻는 이유가 되는 항목만 보인다.** 곡마다의 결과는 쓰기 결과 창에 둔다.
- **토스트에서 누른 복원은 그 뒤 rekordbox 변경이나 초안 충돌이 없으면 묻지 않는다.**
- **아무것도 쓰지 않았으면 창 대신 토스트로 알린다(#230).** 손실과 상태 불명만 창으로 멈춘다.
  - rekordbox가 켜져 있을 때와 쓸 초안·넣을 곡·뺄 곡이 없을 때는 경고 토스트 `AppToast.notice`를 띄운다. 이 토스트는 결과 보기 없이 닫을 때까지 남는다.
  - 모두 막힌 초안과 미리 보기에서 제외한 초안은 결과 토스트와 결과 보기로 알린다.
- **쓰는 동안 덱은 재생을 멈춘 채 조작을 막는다.**
- **되돌리기는 쓰기 전 전체 백업으로 한다.** 백업은 `rekordbox-backups/<시각>-write/`에 최근 20개를 남긴다. 백업에 그때 쓴 초안도 넣어 두어, 되돌릴 때는 DB·분석 파일의 복원과 함께 초안도 다시 살린다.
  - 가장 최근이 아닌 백업이면 그 뒤 백업들의 분석·그림 파일도 최신부터 차례로 되돌린다. 그래서 파일이 DB와 같은 시점에 맞는다(#222). 구현은 `RekordboxWriter+RestoreChain`이다.

### 막힌 초안의 복구

- **막힌 초안의 복구는 한 시트다(#232).** 곡·종류마다, 재생 목록마다 창을 잇지 않는다. `RecoverySheetModel`이 줄(`RecoveryLine`)을 모아 한 시트에 보인다.
- **시트는 줄마다 `LibraryStore`의 기존 규칙을 그대로 부른다.** 그래서 같은 선택은 예전 연속 창 흐름과 같은 초안 상태를 만든다. `RecoverySheetTests`가 옛 흐름의 사본 `LegacyRecoveryFlow`와 결과를 견준다. 부르는 규칙은 아래 넷이다.
  - `prepareDraftRecovery`, `applyDraftRecovery`
  - `preparePlaylistRecovery`, `applyPlaylistRecovery`
- **시트 모델을 `LibraryStore.recoverySheet`에 올리면 `ContentView`가 시트를 띄운다.** 곡 편집 창에서 연 시트는 그 창이 띄운다(`anchor`). 편집 창이 닫히면 그 창의 시트도 닫는다.
- **시트가 열려 있는 동안 쓰기 입구를 막는다.** 막는 입구는 `ReflectionCoordinator`의 `start…`·`LibraryMenuAction`·사이드바 단추다. `writesBlockedBySheet`로 막은 입구를 누르면 이유를 알린다.
- **쓰기 결과에서 연 시트는 미리 보기에서 막힌 곡·종류(`BlockedDrafts`)만 줄로 넣는다.** 줄마다 현재값과 비교해 기준이 바뀌지 않은 줄은 뺀다. `isStale`이 거짓인 이런 줄은 다른 이유로 막힌 초안이다.
- **`ReflectionPrompter.review`는 기본 구현이 없다.** 시트를 띄우지 않는 프롬프터는 `HeadlessReflectionPrompter`를 따른다. 이 프롬프터는 기다리지 않는 대신 시트를 바로 닫는다. 시험에서는 같은 역할을 `NoRecoverySheetPrompter`가 한다.
- **현재값은 줄 종류마다 사본 하나로 읽는다.** 곡 줄 전체는 `readRecoveryPrefetches`가, 재생 목록 줄 전체는 `readPlaylistRecoveryPrefetch`가 읽는다. 읽은 값은 줄끼리 나눠 쓴다. 저장 직전에도 각각 한 번 다시 읽는다.
- **읽기·비교·저장은 유스케이스 `RecoverDrafts`가 한다.** 저장이 실패하면 입력을 되돌린다. 저장소 메서드는 결과를 화면 상태에 얹는다. 차이 요약·경고·자세히 보기 같은 줄의 글은 `RecoverySummary`가 만든다.
- **저장은 줄마다 지금 상태를 다시 확인한다.** 실패한 줄만 초안을 그대로 둔 채 그 줄에 이유를 남긴다.
- **재생 목록의 뒤 줄은 다시 비교한 뒤 적용한다.** 앞 줄을 저장하면 재생 목록 초안 전체가 바뀐다. 그래서 뒤 줄은 고를 때 본 것과 같을 때만 적용한다.

### 덱에 곡 올리기

- **목록 선택과 덱은 따로다(#93).** 목록 한 번 클릭·↑↓·태그 시트 커서는 덱을 그대로 둔 채 고른 곡(`LibraryStore.selection`)만 바꾼다. 덱을 바꾸는 길은 아래 입구에서 부르는 불러오기 명령 `LibraryStore.loadToDeck`뿐이다.
  - 더블클릭: 키를 고칠 수 있는 곡의 키 칸만은 키 고르기를 연다(#204).
  - ⌘→
  - 오른쪽 클릭 "덱에 불러오기"
  - 덱으로 끌어다 놓기
- **재생 기록의 반복 행도 덱에는 컬렉션 곡으로 올린다.** 덱의 곡 ID `deckTrackID`는 ContentID다. 스냅샷을 새로 읽으면 덱의 곡만 새 값으로 맞추되, 새 스냅샷에 없는 곡이면 덱에서 내린다.
- **곡을 추가해도 덱은 그대로다.** 아래 두 경우만 덱의 곡을 바꿔 올린다.
  - 덱의 곡을 편집해 렌더한 편집본을 rekordbox에 넣었을 때
  - 덱에 올린 추가한 곡을 rekordbox에 넣었을 때
- **덱 곡 불러오기는 파일을 메인 밖에서 읽어 한 번에 적용한다.** 그래서 초안 읽기가 늦어도 재생은 먼저 된다. `DeckModel.load`(`DeckModel+Loading`)는 아래 순서로 곡을 올린다.
  1. 덱 상태를 비운다.
  2. `LoadDeckTrack.prepareAudio`로 음원 준비 값을 메인 밖에서 읽는다.
  3. 오디오 엔진이 메인 액터에서 동기로 음원을 연다.
  4. `content`로 곡 내용을 다시 메인 밖에서 읽는다.
  5. 곡 내용을 한 값으로 덱에 적용한다.

  | 단계 | 읽는 값 |
  |---|---|
  | `prepareAudio` | 음원 있음, 인코더 지연, 크로마, 음량 캐시, 게인 초안 |
  | `content` | 큐 초안, 그리드 판정 `DeckGridGate`, 그림, 분석 파일 상태 |

- **파일과 초안 읽기는 포트 `TrackAssetReader`가 한다.** 실제 구현은 DJCAdapters의 `.live(drafts:)`로, 초안 저장소와 분석 파일·그림을 읽는다. 분석 캐시 읽기는 포트 `AnalysisStore`가 한다.
- **늦게 끝난 읽기는 곡을 바꿀 때마다 오르는 `loadGeneration` 하나로 버린다.**
- **쓴 뒤 다시 읽기인 `softReload`·`refreshAfterWrite`도 같은 loader의 `reloadContent`를 쓴다.**
- **덱 분석은 포트 `TrackAnalyzer`·`AnalysisStore`를 쓰는 유스케이스 `AnalyzeDeckTrack`이 한다.** 덱이 정하는 것은 언제 돌릴지뿐이다: 곡에 1초 머문 뒤 시작·취소·우선순위. 분석은 아래 네 가지다.
  - 파형
  - 음악 분석
  - 그리드 추정
  - 조성 흐름
- **덱 머리의 분석 전 경고도 불러올 때 읽은 값 `RekordboxAnalysisState`로 보인다.**

### 다시 읽기와 Music 조회

- **반영 뒤에는 조용히 다시 읽는다.** 화면을 로딩으로 바꾸지 않은 채 스냅샷을 새로 떠서 목록을 바꾼다. 덱은 소리·파형·분석을 그대로 둔다. `DeckModel.softReload`가 초안·그리드·게인만 새 값으로 맞춘다.
- **쓰기 완료는 Music 조회를 기다리지 않는다(#130).** 쓰기·복원 뒤와 곡 추가·삭제 뒤에는 새 DB에 출처가 같은 기존 iTunes 사본을 결합한다. 결합한 사본은 새 스냅샷 옆에도 보존한다.
  - 지금 동기화 선택과 일치하는 정상 사본을 이전 자료보다 우선한다. 캐시가 없을 때는 읽기 실패 안내를 유지한다.
  - 스냅샷 대기열은 DB 복사·읽기만 직렬화한다. Music 캡처는 대기열 밖에서 돌려 이미 읽은 곡 목록에 결합한다. 늦은 결과는 요청 세대와 사본별 순서를 검사해 버린다.
  - 쓰기 뒤 다시 읽기가 버린 Music 조회는 다시 조회하지 않는 대신 새 사본에서 그 결과를 이어받는다. 지난 세션 목록이 세션 내내 남지 않게 하기 위해서다.
  - 수동 새로고침은 그 Music 작업까지 기다리되 뒤따르는 쓰기는 막지 않는다.
  - Framework 캡처는 동기화 선택 창에 필요한 전체 목록을 유지한다. 곡 위치는 없는 위치까지 영구 ID별로 한 번만 조회한다. 다음 캡처에는 캐시를 넘기지 않는다.
  - 아래 네 단계는 단계마다 걸린 시간을 남긴다.
    - DB 읽기
    - Music 캡처
    - iTunes 사본 적용
    - 곡 목록 준비
- **iTunes 선택 창은 이미 읽은 전체 목록을 재사용한다.** 지금 동기화 선택과 일치하는 정상 카탈로그가 있으면 Music 응답을 기다리지 않은 채 창을 연다. 앱을 켤 때도 이 캐시가 있으면 DB와 화면을 먼저 준비한다. Music 최신화는 뒤에서 진행한다.
  - 최신화가 도는 동안 창은 캐시를 보여 주되 동기화 쓰기는 막는다. 최신화가 끝나면 그 결과로 창을 다시 연다. 낡은 폴더 계층으로 `playlists3.sync`를 쓰지 않기 위해서다.
  - 창의 새로고침은 카탈로그를 다시 읽되 겹친 요청은 캡처 하나를 함께 쓴다.
  - 갱신이 실패하면 이전 자료와 편집한 선택을 보존한다. 더 최신 라이브러리나 다른 DB의 상태는 오래된 결과로 덮지 않는다.
  - 명시한 사본 모드에서는 새로고침도 Music에 접근하지 않는다.
- **iTunes 동기화는 반영·복원과 같은 쓰기 대상과 백업 폴더에 쓴다(2026-10-10 결정).** 명시한 사본(`--db`·`DJC_DB`)은 읽기 출처만 바꾼다. 그래서 최근 쓰기 복원이 동기화를 쓴 곳과 같은 대상을 되돌린다.
  - 쓰기 전에 연 사본의 동기화 원문과 쓰기 대상의 `playlists3.sync`를 견준다. 다르면 쓰지 않는다.
  - 명시한 사본이 쓰기 대상과 다른 폴더에 있으면 그 사본은 쓴 동기화 파일을 읽지 않는다. 이때 화면 목록과 사본 옆 목록 사본을 바꾸지 않는다. 대신 토스트로 알린다.
  - 그 사본은 새로고침해도 원문이 쓰기 대상과 맞춰지지 않는다. 그래서 원문이 다르면 쓰기 전에 막는다. 막힘 안내는 `--db` 없이 다시 열라고 한다(`LoadLibrary.syncDiffersFromTarget`).

## 시간축

rekordbox는 압축 음원 앞의 인코더 지연을 잘라 내지 않는다. 그래서 rekordbox의 0초는 AVFoundation의 0초보다 앞선다.

- **덱·초안·그리드의 모든 시각은 rekordbox 시간축이다.** 이 시간축의 시각은 음원 시각에 `RekordboxTimeline.predictedOffset`을 더한 값이다.
- **음원을 읽을 때와 파형을 그릴 때만 `timelineOffset`만큼 뺀다.** 음원을 읽을 때는 재생할 프레임을 고를 때다.
- **인코더 지연 예측은 150곡 실측으로 맞췄다.** 내보낸 그리드는 rekordbox 그리드와 1ms 안에서 일치한다.

## 분석

| 기능 | 방법 | 수준 |
|---|---|---|
| 섹션·메모리 큐 제안 | Apple Music Understanding 섹션 경계 → 박에 맞춤 | 직접 찍은 큐 ±1박 재현율 62% |
| 그리드 추정 | MU 박·마디 + 1ms 어택 곡선, 105~215 BPM, 구간별 맞춤(변속) | BPM ±0.05 84%, 박 일치 67% |
| 조성 흐름 | 16384점 FFT 크로마 + 라이브러리 400곡으로 학습한 프로필 + 12조표 비터비 | 주 조표 rekordbox 일치 67% |
| 음량 | BS.1770 통합 음량(vDSP K-가중) | ffmpeg ebur128과 ±0.05 LU |

- **분석 결과는 `analysis/`에 캐시해 음원 파일이 바뀔 때만 다시 계산한다.**
- **오토게인은 약 −10 LUFS 기준인 rekordbox 값을 기본으로 쓴다.** DJCrate가 잰 음량과 1.5dB 넘게 다르면 새 값을 제안한다.
- **게인·그리드·키 제안은 덱 제안 줄 `DeckSuggestionBar` 한 곳에 모은다.** 문구는 `DeckSuggestion` 한 규칙으로 만든 "이름 · 값 · [적용] [무시]" 모양이다. 적용하면 게인·그리드 제안은 덱 초안이, 키 제안은 태그 초안(`LibraryStore`)이 된다.
- **무시 표시는 종류마다 따로 저장한다.** 저장 키는 `SettingKeys` 하단에 있다. 되살리기는 "무시한 제안 다시 보기" 하나다.

## 덱 오디오 (`DeckAudio`)

덱이 부르는 포트 `DeckAudioEngine`(DJCApplication)의 실제 구현 `DeckAudio`는 `Sources/DJCAdapters/Audio/`에 있다. 코드 규칙은 `.claude/rules/audio.md`에, 그 이유와 실험 근거는 이 절에 둔다. 노드 그래프는 아래와 같다.

```
trackNode → gainUnit(오토게인) → trackMixer(볼륨) ┐
clickNode(메트로놈) ─────────────────────────────┴→ subMixer → varispeed → timePitch → 출력
```

- **템포는 키 락이면 timePitch로, 아니면 varispeed로 바꾼다.** 메트로놈 클릭도 같은 경로를 지나므로, 템포를 바꿔도 클릭이 박에 붙어 있다.
- **곡은 불러올 때 메모리에 통째로 디코딩해 둔다(20분 이하).** 그래서 외장 드라이브에서도 재생·점프·CUE가 바로 반응한다. 디코딩이 끝나기 전에는 파일에서 읽는다.
- **`pause()` 금지, `stop()`만 쓴다.** pause 뒤 다시 켜면 엔진이 `play(at:)`의 호스트 시각을 쉬기 전 기준으로 환산했다. 그래서 쉰 시간만큼 소리가 늦어 무음이 쌓였다.
- **엔진은 메인 스레드 밖에서 만든다(#142).** 출력 장치의 IO 유닛을 여는 `mainMixerNode`·`outputNode`는 coreaudiod가 응답하지 않으면 끝없이 기다린다. 그래서 메인 스레드에서 부르면 앱이 첫 화면 전에 멈췄다.
  - 엔진과 노드 묶음은 직렬 큐 `AudioEngineQueue`에서 다 만든 뒤에만 메인 액터로 넘긴다. 덱은 `DeckAudioGraph`, 편집 창은 `EditAudioGraph` 묶음을 쓴다. 넘긴 뒤에는 메인 액터만 묶음을 만진다.
  - 넘겨받기 전에도 곡은 불러 둔다. 재생만 "오디오 장치를 쓸 수 없습니다" 안내로 막은 채 엔진 준비를 다시 시도한다.

### 루프

- **루프는 샘플 단위로 되풀이한다.** 재생 노드에 "조각"을 예약하면 오디오가 직접 되풀이한다. 조각은 노드 샘플을 곡 프레임에 맞춘 값과 루프 길이를 든다. 화면 틱이 위치를 되돌리던 예전 방식은 바퀴마다 짧게 끊겼다.
- **`LoopPlanner`가 무엇을 언제 예약할지 순수 함수로 정하면 `DeckAudio`는 그 계획을 실행만 한다.** 계획은 루프 걸기·길이 바꾸기·나가기를 다룬다. 루프를 늘일 때 잇는 다리 버퍼도 계획에 든다.
- **곡 위치와 메트로놈 클릭도 이 조각을 따라 계산한다(`PlaybackSchedule`).** 클릭 예약 창은 반열린 구간 `[from, to)`라서 창 경계의 박이 빠지지도, 두 번 나지도 않는다.
- 오프라인 렌더 실험으로 확인한 예약 제약은 아래와 같다. 새로 알아낸 제약은 날짜와 함께 이 목록에 더한다.
  - 시각을 정한 `.interrupts` 예약은 이미 그린 곳보다 렌더 블록 하나 이상 앞서야 정확하다.
  - 앞서 예약하면 되풀이 버퍼(`.loops`)도 바퀴 중간에서 샘플 단위로 끊긴다. 렌더 블록 441·512·1024에서 모두 확인했다. 처음에는 "바퀴 경계에서만"이라고 잘못 결론 내려 ½을 한 바퀴 늦게 적용했다.
  - 엔진은 `.interrupts` 버퍼 뒤에 시각 없이 줄 세운 버퍼를 지운다.
  - 나중에 예약한 `.interrupts` 버퍼는 그 시각에 앞서 예약한 미래 버퍼를 루프 몸통까지 모두 지운다. 시각이 같으면 나중 것이 이긴다(2026-09-27).
  - 재생 시작 버퍼도 노드 샘플 0에 시각을 정해 예약한다. 시각을 nil로 두면 버퍼가 다음 렌더 덩어리에서 시작해 노드 시각과 곡 프레임이 최대 한 덩어리 어긋났다. 그만큼 첫 루프·점프가 일찍 넘어갔다(2026-09-27 실측, `--jump-audio-selftest`).

### 재생 퀀타이즈 (Q, #90·#107)

- **재생 중 핫큐는 현재 박을 계속 재생하다 다음 정수 비트그리드 선에서 넘어간다.** 착지는 저장 큐의 첫 샘플이다. 큐 앞부분에 source의 소수 박을 더하지 않는다.
- **이전 1/4·1/2·1박 저장값은 모두 같은 동작이라 호환용으로만 읽는다.**
- **경계·착지는 `PlayQuantize`가, 예약은 `JumpPlanner`가 정한다.** 예약은 루프처럼 시각을 정한 `.interrupts` 버퍼로 한다.
- **예약할 수 있는 첫 경계에서 넘어간다.** 예약 여유는 이미 렌더한 노드 위치에서 실제 출력 버퍼 두 개만큼이다. 이미 렌더한 경계나 이 여유 안의 경계는 소급해 바꿀 수 없어 그다음 큰 박을 쓴다.
- **착지는 곡 시각을 비교하는 대신 노드가 경계에 닿았는지로 확인한다.**
- **넘어가기 전에 다른 핫큐를 누르면 새 점프가 그 자리를 대신한다.** 새 예약을 못 하면 옛 예약도 취소해 화면 틱으로 넘긴다.
- **일시정지·스크럽으로 예약을 취소하면 도착 전 루프 상태를 복원한다.** 새 루프 조작도 대기 중 점프를 취소한 뒤 현재 재생 구간에 적용한다.
- **메트로놈은 옛 선예약을 지운 뒤 새 시간표로 다시 예약해 점프 뒤의 박·강박을 따른다.**
- **곡을 메모리에 풀기 전에는 화면 틱이 경계를 지날 때 넘긴다.** 이 대체 경로는 틱이 늦은 만큼 큐 뒤에서 시작해 박자 지연을 보상한다. 그래도 샘플 예약 경로와 달리 큐의 첫 샘플과 정확한 경계는 보장하지 않는다.

### 끄는 중 핫큐 (#133)

- **확대 파형을 끄는 동안에는 `DragHotCueKeys`가 핫큐 키를 직접 읽는다.** 그동안 키 이벤트가 앱에 오지 않기 때문이다.
  - 마우스를 쥔 SwiftUI 제스처(`DragGesture`·`MagnifyGesture`)가 도는 동안 AppKit은 이벤트 추적 모드로 이벤트를 받는다.
  - 그 사이 AppKit은 키 이벤트를 `sendEvent`에 보내지 않은 채 버린다. 그래서 로컬 모니터인 `KeyRouter`까지도 오지 않는다.
  - 2026-09-28에 최소 SwiftUI 앱으로 실험해 확인했다.
- **`DragHotCueKeys`는 핫큐 키의 눌림 상태를 8ms마다 읽어 새로 누른 키만 보낸다(`HotCueKeyWatch`).** 끌기 전부터 누르던 키는 무시한다.
- **빈 칸은 끄는 중 자리에 큐를 찍는다.** 큐가 든 칸은 자리만 옮긴다. 이때 끌기 기준점 `ScrubAnchor`도 옮겨 다음 끌기가 거기서 이어진다.
- **재생과 루프는 손을 놓은 뒤 평소대로 한다.** 끄는 중에 재생을 시작하면 끌기와 부딪친다.

## 곡 편집 (`TrackEdit`, #80 PoC)

곡 편집은 원본 마디 구간을 차례로 이어 새 WAV·AIFF로 렌더한다. 그리드와 큐도 옮겨 새 곡으로 넣는다. 무엇을 어디에 쓸지는 순수 규칙 `TrackEdit`이 정한다. `EditRenderer`는 그 계획대로 원본 음원을 읽어 새 파일에 쓰되, 원본은 고치지 않는다. 실험 명령은 `djc lab edit-render`다.

### 렌더 규칙

- **조각은 온전한 마디로만 만든다.** 그래야 출력 그리드가 원본 BPM의 한 구간으로 이어진다. 템포 구간이 여러 개인 곡은 막는다.
  - 첫 다운비트 앞의 0마디인 곡 머리는 맨 앞 조각에만 둔다.
  - 곡 끝에서 잘린 마지막 마디는 맨 뒤 조각에만 둔다.
  - 원본에서 이어지는 구간(`1-16,17-64`)은 이음새가 아니므로 한 조각으로 합친다.
- **출력 시각의 어긋남이 쌓이지 않게 한다.** 출력 시각은 앞 조각들의 마디 수 × 마디 길이로 바로 구한다. 프레임은 경계마다 반올림한다. 그래서 1마디 조각을 200번 이어도 k번째 조각은 k × 마디 길이 자리에서 시작한다.
- **이음새는 이음새 앞에서 4ms 동안 섞는다.** 앞 조각 끝을 줄이는 동안 다음 조각 바로 앞의 원본을 키워 이음새에서 섞기를 끝낸다. 그래서 다음 조각의 다운비트 어택은 그대로다.
- **시간표가 rekordbox 시간축이라 MP3·AAC 원본의 음원 프레임은 `(시각 − predictedOffset) × 샘플레이트`다.** 곡 머리를 살리면 인코더 지연만큼 생기는 음수 프레임은 무음으로 채운다. 그래서 출력 WAV의 0초가 rekordbox가 보던 원본의 0초와 같다. 출력은 PCM이라 출력 시간축이 곧 음원 시간축이다.
- **큐는 처음 나오는 자리 하나에만 옮긴다.** 그래서 같은 소리가 여러 번 나와도 핫큐 슬롯이 겹치지 않는다. 인트로를 늘려도 메모리 큐가 또 생기지 않는다. 루프는 끝까지 한 조각 안에 드는 자리로 옮긴다. 빠진 구간의 큐와 이음새에 걸친 루프는 이유와 함께 버린다. 큐 시각은 ms 정수라 조각 시작 1ms 앞 큐도 그 조각에 든다.

### 곡 넣기

- **편집본은 기존 곡 넣기 흐름을 그대로 탄다.** 넣기와 XML 내보내기는 아래 초안을 쓴다.
  - 추가한 곡(`StagedTrack`)에는 추정 대신 변환한 그리드 초안과 옮긴 큐 초안을 둔다.
  - 렌더한 WAV에는 태그가 없으므로 원곡 정보는 태그 초안으로 둔다.
  - 이 초안을 만드는 규칙은 `StagedEditDrafts`, 유스케이스는 `StageEdit`이다.
- **추가 목록은 포트 `StagingStore` 한 길로 고친다.** 앱에서는 조립 지점이 저장소가 든 목록과 디스크를 함께 맞추는 구현을 넣는다. 그래서 넣기와 목록 저장이 겹쳐도 줄을 잃지 않는다(adv2 N8).

### 편집 창 (#128 컷 편집기)

- **편집 창(`TrackEditWindow`)은 덱과 따로 된 창으로, 원곡 줄과 결과 타임라인이 있다.** 창 코드는 `Sources/DJCrate/Edit/`에 있다. 원곡 그리드·큐·길이는 창을 열 때 덱에서 읽는다.
- **원곡 파형을 끌면 양 끝을 가까운 마디 줄에 붙여 구간을 고른다(`BarLayout.selection`).** 고른 구간은 결과에서 고른 클립 뒤에, 고른 클립이 없으면 끝에 넣는다.
- **클립은 목록 구간 하나로, 이어진 구간도 합치지 않는다(`TrackEdit.clips`).** 클립에 하는 조작은 아래와 같다.
  - 재생선에서 가장 가까운 마디 줄로 자르기(`TrackEdit.split`)
  - 복제와 지우기
  - 끌어 옮기기(`dropOffset`)
- **목록을 바꿀 때마다 바꾸기 전 목록을 창의 `undoManager`에 남겨, 편집 메뉴의 ⌘Z·⇧⌘Z로 되돌린다.**
- **규칙에 맞지 않는 목록도 `TrackEdit.place`로 그려 고칠 수 있게 한다.** 이런 목록(예: 가운데 곡 머리)은 렌더와 결과 재생만 막는다.

### 확대·다듬기·끌어 넣기 (#134)

- **두 줄은 보이는 자리(`EditViewport`)를 따로 든다.** 보이는 자리는 보이는 길이와 왼쪽 끝으로 정한다. 그리기와 누르기는 모두 이 자리를 기준으로 시각을 바꾼다.
- **보이는 길이를 들고 있어서 결과 길이가 바뀌어도 마디 폭이 그대로다.** 가장 가깝게 확대하면 2마디가 보인다.
- **확대에는 두 가지 길이 있다.**
  - 세로 휠·핀치는 덱 확대 파형과 같은 `WaveformScrollPolicy`로, 포인터 자리를 기준으로 확대한다.
  - `=`/`−`/`0` 키와 줄 아래 단추는 재생선을 기준으로 확대한다. 이 키는 보기 › 글자 크기의 ⌘+/−와 겹치지 않는다.
- **재생선이 보이는 자리의 오른쪽 끝을 넘으면 다음 쪽으로 넘긴다.** 다른 곳을 보고 있으면 끌어오지 않는다.
- **클립 가장자리를 끌면 끈 자리를 원곡 시각으로 바꿔 가까운 마디 줄에 붙인다(`BarLayout.trimmed`).** 손을 뗄 때 한 번에 바꿔 실행 취소 하나로 남긴다.
  - 가장자리 폭은 5포인트, 좁은 클립은 길이의 ¼이다.
  - 다듬기로 곡 머리를 넣을 수 있는 클립은 맨 앞 클립뿐이다. 잘린 끝 마디는 맨 뒤 클립만 넣을 수 있다.
- **원곡에서 고른 구간 안을 아래로 끌면 결과 줄 위에 놓을 자리(`insertion`)를 보여 준다.** 놓으면 그 자리에 넣는다. 옆으로 끌면 예전처럼 구간을 새로 고른다.
  - 놓을 자리는 가운데를 지난 클립 수로 정한다. 곡 머리로 시작하는 결과의 맨 앞은 피한다.

### 창 재생기 (`EditAudioPlayer`)

- **편집 창은 덱과 따로 원곡을 메모리에 풀어(`DecodedAudio`) 재생한다.** 포트는 DJCApplication의 `EditAudio`, 실제 구현은 `Sources/DJCAdapters/Audio/`의 `EditAudioPlayer`다. 조립 지점이 `EditWindowLinks.makeAudio`로 구현을 넘긴다. 원곡 줄은 푼 버퍼를 그대로 재생한다.
- **결과는 렌더 없이 아래 순서로 재생한다.**
  1. `TrackEdit.playbackItems`가 렌더러와 같은 프레임 예약표를 만든다.
  2. 예약표에는 조각 본문과 이음새 앞 4ms 섞기 칸이 있다.
  3. 본문은 원곡 버퍼를 복사 없이 잘라 쓴다.
  4. 섞기 칸만 `EditRenderer.playbackBuffer`로 새로 만든다.
  5. 이 버퍼들을 노드 샘플 시각에 잇는다.
- 그래서 결과 어디서 시작해도, 이음새 가운데서 시작해도 렌더 파일과 소리가 같다(`EditRendererTests`).
- **멈출 때는 엔진 `stop()`을 쓴다.** 이음새 듣기는 앞뒤 2마디만 재생한 뒤 멈춘다.
- **사용자는 `DJC_HOME/edits`에 둔 결과 파일을 추가한 곡에서 고른다.**
- **렌더는 백그라운드에서 한다.** 작업을 취소하면 조각 사이에서 멈춘 뒤 쓰던 파일을 지운다.
- **창의 단축키(`TrackEditCommand`)는 이 창이 앞일 때만 받는다.** `KeyRouter`는 이 창을 덱 창으로 보지 않는다. 단축키는 아래와 같다.

| 키 | 하는 일 |
|---|---|
| 스페이스 | 마지막으로 누른 줄 재생·일시정지 |
| ←→ | 재생선을 앞뒤 마디 줄로 옮기기 |
| ⏎ | 원곡에서 고른 구간을 결과에 넣기 |
| ⌫ | 고른 클립 지우기 |
| ⌘D | 고른 클립 복제 |
| ⌘B | 결과 재생선에서 자르기 |
| Esc | 고른 클립·구간 놓기 |

### 확인한 값 (2026-09-26)

2026-09-26에 스냅샷 사본과 임시 `DJC_HOME`에서 `djc lab edit-render --check-grid`로 확인했다.

- MP3 인트로 연장(LAME, 192 BPM)에서는 조각 영역 샘플이 원본을 처음부터 이어 읽은 값과 차이가 0이다. 출력에서 추정한 박과 변환 그리드의 차이는 중앙값 7.0ms로, 원본 기준선 7.0ms와 같다. 원본 기준선은 원본에서 추정한 박과 rekordbox 그리드의 차이다.
- FLAC 곡 머리와 이음새 3곳(168 BPM)에서는 샘플 차이가 0이다. 박 차이는 0.0ms로 기준선 0.0ms와 같다.
- 사본 DB에 넣기(`--into`)에서는 분석 파일에서 다시 읽은 그리드가 보낸 그리드와 1.0ms 안에서 같다. 큐 16개는 계획한 위치와 ms 단위로 같다.

## Flip (`FlipRecording` → `FlipEdit`)

Flip은 Serato Flip처럼 재생 중에 쓴 점프와 루프를 기록한다. rekordbox에는 Flip 재생이 없으므로 DJCrate는 같은 소리가 나는 편집본(WAV)을 만든다. 렌더·창 재생·큐 옮기기는 곡 편집과 같은 조각 규칙(`EditPieceTiming`)을 쓴다. 프레임은 `frames`, 큐는 `carry`가 맡는다.

- **들린 구간은 오디오가 샘플 단위로 알린다.** 화면 틱으로 위치를 재면 루프 이음새와 퀀타이즈 점프 경계를 놓치므로 화면 틱은 쓰지 않는다.
  - 재생 한 번은 노드 시작부터 멈춤이나 다시 재생까지다.
  - 재생 한 번이 끝나면 `DeckAudio`가 지금 재생 조각(`PlaybackSchedule.pieces`)을 들리는 노드 샘플까지 펼친다(`playedSpans`). 루프는 바퀴마다 펼친다. 펼친 구간은 `onPlayedRun`으로 넘긴다.
  - 재생 중에 다시 재생하면 그 재생은 `continuing`이라 다음 재생 시작이 점프 착지다. 핫큐, 탐색 이동, 샘플 단위로 잇지 못한 루프가 이런 다시 재생을 만든다.
  - 끌기는 멈췄다 잇는 재생이라 덱이 `linkNextRun`으로 잇는다.
- **`FlipRecording`은 경로를 0초에서 시작해 점프마다 출발점에서 끊은 뒤 착지점에서 잇는다.**
  - 멈춘 뒤 다른 자리에서 다시 재생한 것은 점프가 아니다. 재생을 어디서 시작했든 결과는 곡 처음부터다.
  - 멈춘 뒤 앞으로 돌아가 다시 하면 점프 출발점이 마지막 착지보다 앞일 수 있다. 이때는 출발점이 들 수 있는 가장 최근 경로 칸에서 끊는다. 그보다 뒤의 점프는 버린다.
- **출력은 `FlipEdit`이 만든다.** 1ms보다 짧은 조각은 버리되, 마지막 칸은 곡 끝까지 늘린다.
  - 그리드는 조각마다 원곡 템포 구간의 첫 박을 옮긴다. 그 첫 박이 앞 구간의 박 줄에 놓이면 구간을 새로 열지 않는다. 박 줄 위인지는 같은 BPM, 1ms 안, 이어지는 박 번호로 본다.
  - 원곡 그리드를 정확히 옮길 수 없는 곡과 그리드 없는 곡은 그리드 없이 넣는다. 그리드 편집이 막힌 곡이 앞의 경우다.
- **덱의 편집 단추 아래 Flip 단추(`TrackEditButton`)가 기록 켜기·끄기를 맡는다(`FlipWindow.toggleRecording`).** 기록을 마치면 결과 창(`FlipWindow`·`FlipModel`)이 결과를 창 재생기로 들려준다. 결과 창은 결과를 렌더해 추가한 곡에 넣는다. 곡을 바꾸면 기록을 버린다.

## 화면 성능

화면 코드 규칙은 `.claude/rules/ui.md`에, 그 이유와 잰 값은 이 절에 둔다.

### 재생 중 갱신 빈도

- **재생 중 매 프레임(디스플레이 링크 60Hz) 바뀌는 값은 `playhead` 하나다.** SwiftUI는 이 값을 읽는 뷰만 매 프레임 다시 그린다.
- **큰 뷰는 매 프레임 바뀌는 값을 읽지 않는다.** SwiftUI 갱신 한 번에는 창 전체 비용인 프레임당 약 2ms가 든다(릴리스 측정).
  - 글자와 전체 파형 재생선은 `displayTime`(15Hz)을 읽는다.
  - 레벨 미터는 자체 30fps 타이머 대신 재생 틱이 올리는 `meterFrame`으로 갱신한다.
  - 결과로 재생 중 메인 스레드 시간이 366 → 약 215ms/초로 줄었다. 빠른 목록 스크롤 때 25ms 넘는 프레임은 3초당 약 30 → 10번으로 줄었다.
- **확대 파형 그리기 자체는 약 1ms로 작다.** 막대 그리기를 끄는 A/B에서도 차이가 없었다.
- **일부 뷰를 별도 NSHostingView로 떼는 방법은 오히려 느렸다(504ms/초).**

### 조작별 비용 (#129)

- **조작별 비용은 곡 3천 개와 재생 목록 300개가 든 합성 라이브러리에서 `--ui-perf=`로 잰다.**
- 2026-09-28에 찾아 고친 것은 아래와 같다.
  - SwiftUI는 닫힌 인스펙터의 내용도 계속 계산해, 곡을 고를 때마다 태그 입력 칸을 새로 만들었다. 덱 ScrollView까지 창 레이아웃도 다시 잡았다. 지금은 인스펙터가 열려 있을 때만 그린다.
  - `ContentView` 본문은 선택 줄과 표시 줄을 읽지 않는다. 창 제목, 부제, 빈 목록 안내는 작은 수정자나 뷰가 읽는다.
  - `pendingUUIDs`는 부를 때마다 합집합을 만들므로 곡마다 거를 때는 한 번 받아 둔다. 초안이 많으면 곡 선택마다 수백 ms가 들었다.
- 릴리스 최적화 빌드에서 곡 선택은 약 55 → 12ms로 줄었다. 태그 초안이 600곡일 때는 약 290 → 20ms로 줄었다.

### 사이드바 (#141)

- **사이드바 본문(`Sidebar.body`)은 어떤 줄·구역이 있는지 같은 목록 구조만 읽는다.** 본문을 다시 계산하면 List가 재생 목록 전체를 다시 비교하기 때문이다.
- **배지와 진행 값은 `SidebarStagedRow`·`SidebarPendingRow`·`SidebarGridJobRow` 등 줄 뷰가 각자 읽는다.**
- **설정값은 구역 뷰 `PlaylistSection`·`SidebarHistorySection`·`SidebarStatusSections`에서 읽는다.**
  - 부모 ContentView를 다시 계산하면 SwiftUI는 `@AppStorage`를 든 뷰의 값이 바뀐 것으로 보아 그 본문도 새로 계산한다.
  - 덱에 곡을 올리면 덱 높이가 바뀌어 SwiftUI가 ContentView를 다시 계산한다.
- **`--ui-perf=load`에서 `OutlineListCoordinator.diffRows`의 대부분은 사이드바가 아니라 덱 큐 목록(`CueRow`)이다.** 곡 하나에 약 55~70ms가 든다.

### 덱 큐 목록 (#152)

- **덱 큐 목록(`CueListView`)은 행 높이를 28pt로 고정한다.** 곡이 바뀌면 큐 id가 모두 달라 SwiftUI가 행을 통째로 바꾼다. 그때마다 표가 행 높이를 자동으로 다시 쟀다(`_doAutomaticRowHeightsForInsertedAndVisibleRows`). `CueListFixedRowHeight`가 표의 자동 행 높이를 꺼 이 측정을 없앴다.
- **List에도 같은 행 높이를 준다.** 행을 바꿀 때 SwiftUI가 표의 `rowHeight`를 `defaultMinListRowHeight`(기본 24pt)로 되돌리기 때문이다.
- **고정이 걸렸는지, 곧 표를 찾았는지는 `CueListRowHeightTests`가 실제 창에서 확인한다.**
- 결과는 릴리스 최적화 빌드에서 `--ui-perf=load`로 6곡을 올려, Time Profiler로 전후를 번갈아 3번 쟀다.

| 값 | 전 | 후 |
|---|--:|--:|
| `diffRows` 중앙값 | 370ms | 72ms |
| 곡 하나의 `diffRows` | 약 62ms | 약 12ms |
| 자동 행 높이 표본 | 약 360ms | 0ms |

남은 몫은 대부분 새 행 뷰를 만드는 `viewFor`다.

### 곡 목록 (#137)

- **곡 목록이 바뀔 때 `reloadData`를 쓰지 않는다.** 목록은 사이드바 항목·정렬·검색으로 바뀐다. `reloadData`는 보이는 셀과 행 뷰를 모두 버린 뒤 새로 만든다.
- **대신 표 높이 애니메이션 없이 줄 수만 알린다.** 만들어 둔 줄의 칸은 제자리에서 다시 채운다.
- **목록 글자 칸(`TrackTextCell`)은 제약 대신 `layout()`에서 프레임으로 둔다.**

| 조작 | 전 | 후 |
|---|--:|--:|
| 재생 목록 전환·정렬 | 약 175ms | 약 45ms |
| 검색 지우기 | 약 200ms | 약 65ms |
| 전체 목록(3천 곡)으로 전환 | 약 155ms | 약 95ms |

### 태그 시트 스크롤 (#140)

- **칸당 뷰 수를 줄인다.** 스크롤마다 AppKit이 하위 뷰를 모두 훑어, 칸당 뷰 수가 비용을 정하기 때문이다. 레이어를 선택 칸과 기준 칸에만 두는 시도는 이득이 없었다.
- **툴팁은 표(`SheetTableView`)가 영역 하나로 알려 준다.** 칸마다 `toolTip`을 달면 칸을 다시 쓸 때마다 추적 영역이 생겼다.
- **시트 글자 칸(`SheetCell`)도 제약 대신 `layout()`에서 프레임으로 둔다.**
- **초안 표식 뷰는 초안 칸에만 만든다.** 색·읽기 값도 상태가 그대로면 다시 쓰지 않는다.
- 결과는 릴리스 빌드와 합성 곡 3천으로 쟀다.

| 조작 | 전 | 후 |
|---|--:|--:|
| 빠른 스크롤 한 번(곡 목록은 약 2.4ms) | 약 2.5ms | 약 1.7ms |
| 메인 스레드가 일한 시간 | 약 710ms/초 | 약 580ms/초 |
| 시트 열기 | 약 175ms | 약 145ms |

### 재생 중 덱 화면 (#139)

합성 곡 3천과 실제 오디오 엔진을 쓰는 릴리스 최적화 빌드에서 전후를 번갈아 5번 잰 중앙값이다.

| 조작 | 전 | 후 |
|---|--:|--:|
| 재생 중 가만히 | 235ms/초 | 138ms/초 |
| 스크럽 | 315ms/초 | 184ms/초 |
| 재생 중 확대·축소(6번 합) | 91ms | 66ms |

Time Profiler(`--attach`)로 본 원인은 아래 둘이다.

- **`WaveformTextCache`가 해석한 글자(`ResolvedText`)와 잰 크기를 글자·모양별로 두어 다음 프레임에도 쓴다.**
  - 고치기 전에는 확대 파형 Canvas가 매 프레임 글자를 다시 해석해 쟀다. 이 일이 `draw` 80ms/초의 대부분이었다.
  - 그 글자는 마디.박과 큐 글자다. 큐 글자는 큐 이름·핫큐 칩·다음 큐 알약이다.
  - 화면 배율·명암·굵은 글자 설정이 바뀌면 캐시를 비운다.
  - 결과로 글자 해석은 30 → 2ms/초, `draw`는 80 → 29ms/초로 줄었다.
- **덱 머리 시각(`DeckHeaderTime`)은 바뀌지 않는 기준 글자로 자리 크기를 정한다.** 바뀌는 글자는 그 위에 얹어 크기 계산에 끼지 않게 한다.
  - 고치기 전에는 덱 전체를 `fixedSize`로 감싸서, 시각이 초당 15번 바뀔 때마다 덱 `ScrollView`가 크기를 다시 쟀다.
  - 재측정은 약 18ms/초, 호스팅 뷰 크기 요청은 약 10ms/초였다.
  - 폭만 고정한 자리 안에서도 글자가 바뀌면 바깥 스택과 `ViewThatFits`를 다시 계산한다.
  - 결과로 재측정은 18 → 0ms/초로 줄었다.
  - `NSHostingView.layout`에 보이던 시간의 대부분은 레이아웃이 아니라 그 안에서 도는 Canvas 그리기였다.
- **남은 재생 중 비용은 확대 파형 Canvas 그리기·화면 갱신과 나머지 화면이다.** 확대 파형을 숨기면 154 → 74ms/초다.

### 창 크기 바꾸기 (#138)

- **사이드바·인스펙터를 여닫는 동안이나 창 크기를 바꾸는 동안에는 큰 뷰의 본문을 프레임마다 다시 계산하지 않는다.**
- **`--ui-perf=`는 조작마다 본문 계산 횟수와 메인 스레드 CPU 시간도 찍는다.** 부하가 흔들려도 견줄 수 있는 것은 이 횟수와 CPU 시간이다. 횟수는 뷰 `body` 첫머리의 `let _ = PerfProbe.body(Self.self)`가 센다. `--perf-trace-body`는 다시 계산한 이유도 찍는다.

찾아 고친 것은 아래와 같다.

- **`sidebar.visible`·`view.textScale`·`deck.cueListFilter`처럼 이름에 점이 든 설정은 `ObservedSetting`으로 둔다.**
  - `@AppStorage`는 이런 키를 KVO로 지켜보지 못해, UserDefaults의 어느 키가 바뀌어도 그 뷰를 다시 계산한다. 창 크기를 바꾸는 동안의 창 프레임 자동 저장도 키를 바꾼다.
  - `ObservedSetting`은 같은 키가 실제로 바뀔 때만 알린다. 키 이름과 기본값은 `SettingKeys` 그대로다.
- **덱이 잰 크기 상태는 주 창(`ContentView`)이 아니라 본문 `LibraryDetail`이 든다.** `LibraryDetail`은 덱과 목록이 든 본문이다.
  - 덱이 잰 높이는 `deckChromeHeight` 등이다. 주 창이 이 값을 `@State`로 들면, 창 폭이 바뀔 때마다 컨트롤 줄바꿈으로 덱 높이가 바뀐다. 그러면 툴바·사이드바·메뉴까지 본문을 다시 계산한다.
  - 파형 높이 메뉴는 그 값에서 나오므로 포커스 값 `\.waveformHeight`로 따로 싣는다.
- **덱의 큐 목록 폭 단계(`DeckWidthClass`)는 본문이 진짜 크기만 걸러(`DeckLayout.isDetailMeasurement`) 재서 덱에 넘긴다.** 덱이 자기 폭을 재면, SwiftUI가 창 최소·최대 크기를 알아볼 때 제안한 임시 폭에도 상태가 바뀐다. PR #151의 고정 헤더 배치는 유지한다.
- **`FlowLayout`은 칸의 자연 크기를 캐시에 재 둔 뒤 제안 폭마다 줄을 나눈다.** 칸 내용이나 개수가 바뀌면 SwiftUI가 캐시를 갱신한다. PR #151의 양끝 맞춤·세로 가운데 정렬도 같은 크기를 쓴다.
- **파형 높이에 쓰는 `fittedChromeHeight`는 곡이 있을 때 본문 높이가 1pt 넘게 바뀌어야만 갱신한다(PR #151).** 곡 로드나 덱 내용 증가 때는 파형 높이를 줄이는 대신 덱 뷰포트만 제한한다.

#### 2026-09-30 재검증

PR #151·#139·#152가 든 `a365937`과 수정본을 교대 A/B로 쟀다. 두 쪽 모두 같은 `UIPerfFixtureCapture` 합성 라이브러리·가짜 오디오·디버그 빌드를 썼다. 값은 예열 1쌍을 뺀 5쌍의 중앙값이다. 폭 1700→1415→1700의 40단계 결과는 아래와 같다.

| 값 | `a365937` | 수정본 |
|---|--:|--:|
| 메인 스레드 CPU | 5234ms | 1868ms |
| 단계 실행 시간 | 67.5ms | 24.1ms |
| `ContentView` 본문 계산 | 152 | 0 |
| `DeckView` 본문 계산 | 304 | 2 |
| `CueListView` 본문 계산 | 304 | 0 |

- 사이드바·인스펙터를 각 8회 여닫은 CPU 개선은 2.0%·3.8%로 작았다.
- 수정 뒤에도 최대 프레임 간격은 사이드바 93.3ms, 인스펙터 85.0ms, 폭 단계 221.9ms로 지연이 남는다.
- 실제 마우스 끌기·오디오 재생·릴리스 성능은 이 측정으로 확인하지 않았다.
- 같은 합성 곡을 라이트/다크와 글자 배율 1.0/1.3/1.5로 캡처했다([대표 전후 화면](images/issues/138)). 넓은 창의 배치는 전후가 같다.
- 좁은 창에서는 임시 본문 높이 0pt가 끼어 파형이 80pt로 줄었다. 지금은 실제 크기만 받아 요청한 150pt를 유지한다.
- 요청 높이 480pt와 실제 창 높이 변경도 별도 회귀 시험으로 확인했다.

## 글자 크기

- **macOS는 Dynamic Type을 지원하지 않아 앱이 글자 배율을 직접 곱한다.** `dynamicTypeSize`를 바꿔도 글자 크기가 그대로다.
- **배율 설정은 `SettingKeys.textScale`, 배율 규칙은 `TextScale`이다.** 배율은 1배, 1.15배, 1.3배, 1.5배 네 단계다. 사용자는 보기 › 글자 크게·작게(⌘+ · ⌘−)나 설정 › 일반에서 바꾼다.
- **창마다 `AppTextScale`이 배율을 환경값 `textScale`로 넣는다.** 화면 종류마다 배율을 곱하는 자리는 아래와 같다. 1.3배부터는 작은 컨트롤을 한 단계 키운다.

| 화면 | 배율을 곱하는 자리 |
|---|---|
| SwiftUI 글자 | `Font.scaled(.caption, scale)`(1배면 텍스트 스타일 그대로) |
| 고정 pt 글자(CDJ 패드) | `Font.scaled(size:…)` |
| 파형 Canvas | `WaveformMetrics` |
| AppKit 표(곡 목록·태그 시트) | `NSFont` 크기와 `rowHeight` |

- **가장 작은 글자는 macOS 최소인 10pt다.** 파형 눈금처럼 자리가 모자라면 글자를 줄이는 대신 라벨 수를 줄인다(`BeatRulerLabel`).

## rekordbox 쓰기

rekordbox 쓰기의 규칙·절차·막아 둔 것은 `docs/rekordbox-internals.md`에 있다. 쓰기 전에 확인하는 버전, DB 구조, 카운터도 그 문서에 있다.

## USB

USB 형식과 쓰기 절차는 `docs/usb-internals.md`에 있다. USB 코드를 고칠 때 지킬 규칙은 `.claude/rules/usb-write.md`에 있다. 이 절은 그 규칙과 흐름을 왜 그렇게 정했는지 적는다.

### 설계 원칙

- **USB 라이브러리는 모델 하나에서 두 형식을 만든다.** DJCrate는 USB 라이브러리를 곡·재생 목록·큐 모델 하나로 읽는다. 쓸 때는 이 모델에서 두 형식(`UsbFormat`)을 따로 만든다: OneLibrary `exportLibrary.db`와 Device Library `export.pdb`·`exportExt.pdb`. 두 형식이 같은 내용을 담도록 계획은 한 곳에서 세운다.
- **음원·분석 파일·아트워크를 다 쓴 뒤 라이브러리 DB를 마지막에 바꾼다.** 쓰기가 중간에 멈춰도 기기는 옛 DB를 읽는다. 그래서 기기는 USB에 없는 파일을 가리키지 않는다. 새 파일은 임시 이름 `.djc-part-…`로 쓴 뒤 이름을 바꾼다.
- **쓰기 전 백업과 진행 기록인 저널은 USB가 아니라 Mac에 둔다.** 두 가지는 DJCrate 데이터 폴더의 `usb-sessions/`에 있어서 USB가 뽑혀도 회복할 근거가 남는다.
- **USB에 쓰는 길은 `UsbWriter.write` 하나다.** 이 함수는 아래 순서로 쓰다가 중간에 실패하면 백업으로 되돌린다.
  1. 막힘을 확인한다.
  2. Mac에 백업한다.
  3. 파일을 쓴다.
  4. DB를 바꾼다.
  5. 지울 파일을 지운다.
  6. 검증한다.

  `UsbWriter.write`는 형식을 모르는 변경 묶음 `UsbChangeSet`을 받아, 형식별 막힘과 검증은 주입한 `UsbWriteInspector`·`UsbWriteVerifier`에 맡긴다. 되돌리기(`restore`)와 회복(`recover`)도 같은 확인을 먼저 거친다. 파일 연산은 `UsbFileSystem` 프로토콜 뒤에 있어서 시험이 실패·끊김·분리를 흉내 낸다.
- **회복은 대상 USB를 먼저 본다.** 끊긴 쓰기는 USB의 DB 해시로 마저 쓰기와 되돌리기 중 하나를 고른다. 기기가 그 사이 DB를 바꿨으면 다시 계획한다. 회복은 단계마다 볼륨이 아직 붙어 있는지 본다. 떼어 낸 볼륨의 마운트 지점 폴더에 쓰면 Mac에 쓰게 되므로, 볼륨이 사라졌으면 되돌리기 없이 멈춘다.
- **USB 위에서 SQLite를 열지 않는다.** USB의 DB는 Mac 사본에서 열어 고친 뒤, 다 고친 파일을 USB로 복사한다. 그래서 FAT 위에 WAL 파일과 잠금 파일을 만들지 않는다. 쓰다가 USB가 뽑혀도 DB가 반쯤 바뀐 채 남지 않는다.
- **비교와 지문에서 `._*` 파일은 세기만 한다.** macOS는 FAT에 확장 속성을 `._이름` 파일로 남긴다. 임시 이름은 이 모양과 겹치지 않게 짓는다(`UsbLayout.tempName`).
- **실물 USB에는 코드 관문과 쓰기마다의 동의가 둘 다 열릴 때만 쓴다.** 볼륨을 미리 등록하는 목록은 두지 않는다. 자세한 것은 `docs/usb-internals.md` §12에 있다.
  - 코드 관문은 비상 스위치 `UsbPhysicalWriteGate.buildEnabled`다.
  - 동의는 앱 내보내기 시트, 쓰기 확인 창, CLI `--allow-physical`과 `--confirm <볼륨 이름>`이다.
  - 관문이 닫혀 있으면 루트가 임시 폴더 아래 마운트 지점일 때만 쓴다. 이 조건은 가드의 볼륨 정보와 상관없이 본다. 그래서 가드 값 하나가 틀려도 실물에 닿지 않는다.
  - 시험 프로세스는 관문이 열려 있어도 임시 폴더 아래 마운트 지점에만 쓴다.
  - 관문이 열린 뒤에도 볼륨 정책과 볼륨 이름 확인을 거친다. 볼륨 정책은 FAT32·exFAT 파일 시스템과 MBR·GPT 파티션만 받는다. 시동 볼륨, 내장 볼륨, 읽기 전용 볼륨은 받지 않는다.
  - 임시 폴더 밖 볼륨은 디스크 이미지라고 나와도 실물로 판정한다.
- **확인하지 않은 규칙(`UsbProvisionalRule`)은 `carriedDeviceRows`만 막는다.** 곡 내용 규칙은 확인 창에 알리기만 한다. 자세한 것은 `docs/usb-internals.md` §9에 있다.
- **디스크 이미지 판정과 파일 시스템 판정은 DiskArbitration 정보를 바탕으로 한다.** 순수 함수 `UsbVolumes.make`가 세 근거를 합쳐 정한다: DA 설명 사전, statfs, `hdiutil info` 짝. 판정할 수 없으면 실물로, 파일 시스템을 모르면 FAT32가 아닌 것으로 본다.

### 흐름

#### 빈 USB 내보내기

**빈 USB 내보내기는 여섯 단계를 차례로 지난다.** DJCApplication 유스케이스 `UsbExportSession`이 이 순서를 한 번에 부른다. CLI `djc usb-export`와 앱이 이 세션을 쓴다.

1. 후보: `UsbExportCandidates`가 스냅샷 사본과 share를 읽기만 한다.
2. 계획: DJCDomain의 순수 계획기 `UsbExportPlanner`가 경로·ID·막힘을 정한다. 확인 안 된 규칙도 계획에 싣는다.
3. 빌더: `UsbLibraryBuilder`가 계획으로 두 형식 모델을 만든다. Device Library 행 크기로 막힌 곡이 있으면 그 곡을 뺀 뒤 다시 계획한다.
4. 준비: `UsbExportAssembly`가 Mac 준비 폴더에 DB 셋·분석 파일·아트워크를 만든 뒤 변경 묶음을 낸다.
5. 쓰기: `UsbWriter.write`가 USB에 쓴다.
6. 검증: USB에서 사본을 다시 떠서 `OneLibraryVerifier`·`PdbVerifier`·`UsbInvariantVerifier`로 검증한다.

- **세션은 입출력을 포트 `UsbLibraryEngine`·`UsbDevice`로만 한다.** 조립 지점은 세션에 세 가지를 기본값 없이 넘긴다: 볼륨 가드, Mac 쪽 폴더, 포트의 실제 구현. 앱과 CLI는 같은 쓰기 유스케이스 `UsbWriteService`로 넘긴다.
- **라이브 master.db 판정은 RekordboxKit `UsbLiveDatabase`가 한다.** 이 Mac의 실제 master.db는 거부 목록과 상관없이 늘 거부한다.
- **세션은 넘겨받은 스냅샷 사본을 세션 전용 폴더에 한 번 더 떠서 읽는다.** 끝나면 그 사본만 지우므로 사용자 스냅샷 폴더는 건드리지 않는다.

#### 옮기기: Device Library에 OneLibrary 더하기

**Device Library만 있는 USB에 OneLibrary를 더할 때 원래 파일은 바꾸지 않는다.** 목표 지문에 원래 pdb 해시를 넣어, 쓰기 절차의 G 단계가 원래 파일이 그대로인지 확인한다. 규칙은 `docs/usb-internals.md` §8.4에 있다.

DJCApplication 유스케이스 `UsbMigrateSession`이 아래 순서를 부른다. CLI `djc usb-migrate`와 앱 USB의 “OneLibrary 더하기…”가 이 세션을 쓴다.

1. USB DB 사본을 떠서 pdb 모델로 읽는다.
2. 변환: `UsbMigration.model`이 Device Library 투영은 그대로 둔 채 OneLibrary 몫만 채운다.
3. 준비: 새 `exportLibrary.db`와, a 아트워크를 복사한 b 아트워크를 만든다.
4. 쓰기: `UsbWriter.write`가 검사기 `UsbMigrationInspector`와 함께 쓴다.

앱은 쓰기 흐름 `UsbWriteFlow`를 따라 잠금, 미리 보기, 확인을 거쳐 쓴다. 쓴 뒤에는 USB를 다시 읽는다. 끊긴 쓰기의 회복도 같은 흐름이 한다. 회복은 사용자가 누를 때만 한다. 옮기기 백업으로 되돌릴 수도 있다. 그 뒤 다른 쓰기가 성공하면 이전 백업 메뉴는 숨긴다.

#### 앱의 USB 읽기

- **앱은 USB를 사본으로 읽기만 한다.** 사이드바 USB 절은 `UsbStore`가 `UsbHost` 프로토콜 뒤의 호스트로 읽는다. `UsbStore`는 볼륨 모양, 라이브러리, 갱신 상태를 든다.
- **실제 호스트 `SystemUsbHost`는 `UsbVolumeMonitor`로 볼륨을 지켜본다.** 모니터가 받는 DA의 나타남, 경로 바뀜, 사라짐은 순수 함수가 해석한다.
- **읽기와 꺼내기는 메인 액터 밖에서 한다.** `UsbRead.info`·`UsbRead.library`는 DJC_HOME의 `usb-snapshots/<볼륨키>/`에 뜬 사본을 읽는다.
- **실물 볼륨도 등록 없이 읽는다.** 볼륨 정책에 걸리는 볼륨(예: APFS)은 사본을 뜨지 않은 채 이유만 보인다.
- **읽기 직전에는 그 자리의 볼륨을 다시 본다(`UsbRead.currentVolume`).** 훑은 뒤 같은 자리에 다른 볼륨이 붙을 수 있기 때문이다. 읽기는 새 정보로 하므로 옛 디스크 이미지 판정과 UUID로 지나가지 않는다.
- **시험 실행은 디스크 이미지 볼륨만 본다(`UsbReadPolicy.diskImagesOnly`).** 시험 실행은 디버그 빌드에 `DJC_HOME`이나 `--usb-selftest`를 준 실행이다.

#### 앱 내보내기

- **앱 내보내기의 동의는 시트의 [USB에 쓰기] 버튼이다.** 빈 FAT32 볼륨에서 "USB로 내보내기…"를 고르면 시트 `UsbExportSheet`가 열린다. 시트에는 아래 칸이 있다.
  - 볼륨 줄
  - 형식
  - 원본 목록 트리
  - 고른 곡
  - 미리 보기
- **무엇을 물을지와 순서는 DJCApplication 유스케이스 `UsbWriteFlow`가 정한다.** 확인 창은 `UserConfirmation` 포트가 답만 한다. 화면 쪽 `UsbWriteCoordinator`는 포트를 붙여 부르기만 한다. 흐름은 아래 순서로 간다.
  1. rekordbox와 rekordboxAgent가 꺼져 있는지 본다.
  2. `UsbStore.beginWrite`로 볼륨을 잠근다.
  3. 시트에서 미리 본 결과로 쓴다. 미리 본 결과가 없으면 미리 보기를 한 뒤 확인 창을 띄운다(#212).
  4. 쓰는 동안 취소는 DB 교체 전까지 받는다.
  5. 끝나면 [꺼내기] 단추가 달린 토스트를 띄운다.
- **잠금과 진행은 핵심부 `UsbWriteSession`이 든다.** 한 볼륨은 한 번만 잠근다. 한 볼륨에 쓰는 동안 다른 볼륨도 잠그지 않는다. 앱 `UsbWriteModel`이 그 상태를 덮개와 사이드바에 보인다.
- **시트와 쓰기 대기의 단추는 화면 모델을 부른다.** 시트는 `UsbExportSheetModel`, 쓰기 대기는 `UsbPendingModel`이다. 사이드바 메뉴는 `UsbEditActions.start`와 `UsbWriteCoordinator`의 시작 메서드를 부른다. 뷰는 일을 기다리지 않는다.
- **아래 경우는 창 대신 경고 토스트로 알린다.** 시트가 떠 있으면 시트 안에도 보인다.
  - rekordbox가 켜져 있다.
  - 이미 쓰는 중이다.
  - 볼륨이 붙어 있지 않다.
  - 쓸 것이 없다.
  - 꺼내기에 실패했다.
- **미리 본 결과 쓸 것이 없으면 쓰기 대기의 [USB에 쓰기…]를 막는다(#230).**
- **세션과 `UsbWriter` 호출은 DJCApplication의 쓰기 유스케이스 경계 `UsbWriting` 뒤에 둔다.** 이 경계 덕분에 앱 시험은 쓰기를 가짜로 바꾼다. 실제 구현은 `UsbWriteService`다. 호출은 모두 메인 액터 밖에서 한다. 회복과 되돌리기도 CLI `usb-recover`·`usb-restore`와 같은 `UsbWriteService`를 지난다.
- **끝나지 않은 저널, 곧 닫힌 상태가 아닌 저널이 있는 볼륨이 나타나면 알림만 띄운다.** 회복과 되돌리기는 사용자가 누를 때만 한다. 되돌리기는 저널을 회복으로 닫은 뒤 그 쓰기의 백업으로 `restore`한다. 기기 변경이 있으면 한 번 더 묻는다.
- **디버그 자가 테스트 `--usb-selftest`가 디스크 이미지로 이 흐름을 지난다.**

#### 앱 USB 편집

- **앱의 USB 편집은 모두 초안에 편집을 더할 뿐이다.** 화면의 `UsbEditActions`가 유스케이스 `UsbDraftEditing`을 불러 편집을 더한다. 포트 `UsbDraftFiles`는 DJC_HOME의 `usb-drafts/`에 있는 볼륨키별 초안 파일을 메인 액터 밖에서 다룬다. 초안에 편집을 더하는 동작은 아래와 같다.
  - 곡 목록의 "USB에 넣기 ▸ <볼륨> ▸ 컬렉션·목록"
  - 사이드바 USB 컬렉션이나 목록에 끌어다 놓기
  - USB 곡의 "USB에서 빼기"·"‘목록’에서 빼기"
  - 목록 만들기와 지우기
  - 목록 이름과 순서 바꾸기
  - "로컬 변경을 USB에 반영": 갱신할 수 있는 곡마다 로컬에서 바뀐 부분만 넣는다. 바뀐 부분이 같은 곡끼리 편집 하나로 묶는다.
- **초안 고치기와 초안 쓰기는 볼륨마다 한 줄로 선다(`UsbStore.draftQueue`).** 초안 고치기는 더하기, 빼기, 버리기다. 그래서 둘이 겹쳐도 편집의 내용과 순서가 그대로 남는다.
- **처음 편집할 때 base 지문은 같은 볼륨에서만 뜬다.** 사이드바 읽기처럼 그 자리의 볼륨을 `UsbRead.currentVolume`으로 다시 본다. base를 뜨지 못하면 빈 base로 둔 뒤 쓸 때 다시 계획한다.
- **목록 위로·아래로 옮기기는 초안의 목록 편집을 적용한 자리에서 센다.** 이어 누르면 같은 편집 하나를 고친다. 제자리로 돌아오면 그 편집을 뺀다.
- **막힐 편집은 메뉴에서 미리 막는다.** 더하기 전에 읽은 라이브러리와 볼륨만으로 막힘을 가볍게 판정한다. 판정 문구와 실물 관문 판정은 쓰기 계획과 같다. 그래서 임시 폴더 밖 디스크 이미지도 실물로 본다. 막는 메뉴에는 순서 바꾸기와 로컬 변경 반영도 든다. 막은 메뉴에는 이유를 도움말로 단다.
- **초안이 남은 채 빠진 볼륨은 이번 실행 동안 사이드바에 "연결 안 됨"으로 남는다.** 이 볼륨의 초안도 더하기·빼기·버리기를 할 수 있다. 쓰기만 막는다.
- **초안 쓰기는 내보내기와 같은 쓰기 흐름 `UsbWriteFlow`·`UsbWriting`을 탄다.** 잠금과 회복도 내보내기와 같다. 쓰기는 사이드바 "USB 쓰기 대기"(`UsbPendingView`)의 "USB에 쓰기…"나 동기화 화면의 SYNC에서 시작한다. 세션 쪽 입구는 `UsbEditSession.preview`·`writeDraft`다.
- **확인 창에서 본 편집만 쓴다.** 미리 보기는 초안 줄 밖에서 하므로, 미리 보는 동안에도 사용자가 초안을 고칠 수 있다. 그래서 쓰기 줄에 선 뒤 초안을 확인 창의 편집과 견준다. 둘이 다르면 쓰지 않은 채, 지금 초안으로 다시 미리 본 뒤 묻는다.
- **로컬 사본은 앱이 연 스냅샷 사본을 넘긴다.** 세션은 곡 더하기, 갱신, 목록 동기화 때만 `local-<세션>/`에 사본을 따로 뜬다. 앱 USB 코드는 스냅샷을 뜨지도 정리하지도 않는다.
- **쓴 뒤 초안에는 막힌 편집만 남는다.**

#### USB 목록은 읽기 전용

- **USB 곡은 곡 목록에 읽기 전용 줄로 보인다.** 줄은 곡 목록 `TrackTable`에 `usb:<볼륨키>:<content_id>` ID로 들어간다. 이 줄은 아래 대상에서 빠진다(`LibraryStore.uniqueTracks`).
  - 편집
  - 쓰기
  - 재생 목록
  - 끌기
  - 덱 불러오기
- **갱신 상태는 `UsbTrackMatch`·`UsbSyncStatus`가 정한다.** 근거는 앱이 연 로컬 스냅샷 사본에서 읽은 짝짓기 키 `LocalLibraryKeys`다.
- **USB 목록은 여섯 칸만 보인다.** 읽지 않은 큐·그리드 칸은 비운다.
  - # 번호
  - 제목
  - 아티스트
  - BPM
  - 키
  - 갱신 상태
- **USB 목록의 칸 배치는 사용자 칸 배치로 저장하지 않는다.** 나올 때 들어가기 전의 칸 순서·너비·숨김으로 되돌린다(#241).
- **USB 코드는 로컬 스냅샷을 뜨지도 정리하지도 않는다.**
- **`--db`나 `DJC_DB`로 명시한 사본을 연 창은 사본 폴더 `DJC_REKORDBOX_DIR`가 없으면 라이브에서 스냅샷을 뜨는 길을 모두 막는다.** 판정은 `LibraryLocation.allowsSnapshot`이 한다. 막는 길은 아래 다섯이다.
  - 스냅샷 뜨기
  - 창 복귀
  - 곡 추가 미리 보기
  - 곡 빼기 미리 보기
  - 복원 전 확인

### 동기화

#### 순서와 원본

- **동기화 순서는 DJCApplication 유스케이스 `UsbSync`가 정한다.** 바깥 일은 포트 `UsbSyncPorts`로 한다. 화면 모델 `UsbSyncModel`은 포트를 붙여 부른다. 순서는 아래와 같다.
  1. 준비
  2. 선택 판정
  3. 확인
  4. 쓰기 넘기기
- **동기화 화면 `UsbSyncView`는 iTunes 화면과 `PlaylistSyncPane`·`PlaylistSyncCheckbox`를 공유한다.**
- **`UsbSyncSource`는 일반 rekordbox 목록과 사이드바의 `SyncedITunesLibrary` 목록을 합친다.** 합칠 때 iTunes ID(`itunes:`)를 그대로 둔다. 실제 폴더, 목록 순서, 항목 중복도 그대로 둔다. 선택용 원본 그룹은 USB의 폴더로 만들지 않는다.
- **rekordbox 컬렉션에 잇지 못한 곡이 있는 iTunes 목록도 동기화한다.** 잇지 못한 곡만 뺀 뒤 넣지 못한 곡으로 알린다. 목록 옆에는 경고 표시와 이유를 보인다. 2026-10-08 실제 동기화에서 rekordbox도 이렇게 했다.
- **iTunes 목록을 로컬 DB에 임시로 만드는 일은 없다.**

#### 계획과 목록 연결

- **`UsbSyncPlan`은 선택 트리와 USB 트리를 짝지어 기존 USB 초안 편집을 만든다.** 편집 `syncPlaylist`는 로컬 곡 ID를 쓰므로, 같은 묶음에서 더한 곡도 여러 목록에 넣는다. 목록 항목 적용은 기존 `UsbEntriesChange`와 형식별 쓰기·검증을 다시 쓴다.
- **USB 목록은 선택 파일의 `Dev_ID`로 원본에 잇는다.** `Dev_ID`가 없으면 저장한 연결과 경로로 잇는다. 이름이 바뀐 원본은 새 USB 목록을 만든다. 옮긴 원본은 이은 USB 목록도 옮긴다.
- **선택 파일 행으로 이었던 USB 목록은 원본 선택 해제나 로컬 삭제 때 지운다.** 이 판정과 미리 보기는 같은 계획 `UsbSyncPlan.playlistPlan`을 쓴다. 이은 적 없는 USB 목록은 흐리게 남긴다.
- **어느 목록에도 없게 된 곡은 확인 창 `UsbSync.orphanPrompt`를 거쳐 뺀다.** 사용자가 받아들이면 `removeTracks` 편집을 더한다. 취소하면 동기화 전체를 하지 않는다. rekordbox도 이때 같은 확인을 묻는다(#233). 근거는 `docs/usb-internals.md`에 있다.

#### SYNC와 선택 파일

- **SYNC는 초안을 저장한 뒤 쓰기 흐름 `UsbWriteFlow.writeDraft`의 미리 보기와 확인을 거친다.**
- **"장치와 플레이리스트 동기화"만 바꾼 채 닫으면 `.syncSelection(enabledOnly)` 초안을 쓴다.** 켜짐만 바꾸는 이 초안도 SYNC와 같은 길로 쓴다.
- **선택 파일이 없는 USB는 동기화 꺼짐으로 연다.** SYNC하면 USB에 있는 형식마다 새 선택 파일을 같은 쓰기 묶음에서 만든다. 라이브러리가 없는 빈 USB는 `UsbExportSession` 내보내기에 선택 초안을 실어 DB와 함께 만든다.
- **동기화를 켜기만 한 채 닫으면 행 없는 선택 파일을 만든다.** 한 형식의 선택 파일만 있으면 `UsbSyncSelectionStage.gateBlock`이 쓰기를 막는다.
- **볼륨키별 선택·로컬 DBID·목록 연결은 `usb-sync-selections/`에 내구 쓰기로 저장한다.** 손상 설정은 덮어쓰지 않는다.

#### 선택 파일 읽기

- **USB 선택 파일은 `UsbSyncSelectionBundle`이 정해 둔 두 XML만 읽는다.** 이 파일은 로컬 `SYNC_ITUNES_PLAYLIST`와 따로 다룬다. 읽을 때 원본마다 범주·ID·부모와 명시 선택을 되살린다.
- **앱 설정의 `nativeSelectionFingerprint`는 선택의 뜻만 담은 지문이다.** 원문 시각과 USB 번호는 지문에서 뺀다. 편집 중인 선택은 같은 USB 원본에서 나온 것만 이어 쓴다. rekordbox가 선택을 갱신한 경우와 옛 설정에 지문이 없는 경우에는 USB 원본을 다시 채택한다.
- **형식마다 다른 선택, 잇지 못한 원본, 불명확한 번호는 빈 선택으로 쓰지 않는다.** 이런 경우는 화면에 문제로 보인다.
- **선택 XML은 `UsbFileSystem.readFile`이 루트에서 연 핸들을 기준으로 읽는다.** 루트까지의 경로 구성 요소와 파일은 링크 없이 연다. 그 뒤 경로와 핸들이 같은 파일을 가리키는지 확인한다.

#### 선택 파일 쓰기

- **선택 XML은 원문을 고치지 않는다.** 확인한 칸 규칙대로 파일 전체를 새로 만든다. 2026-10-08 실험에서 rekordbox도 매번 파일 전체를 같은 모양으로 다시 썼다. 모르는 칸·요소·주석이 있는 원문은 뜻을 추측하지 않은 채 쓰기를 거부한다. 원본 번호나 최종 USB 번호가 겹쳐 이어져도 거부한다.
- **`.syncSelection`은 선택 파일 쓰기를 담는 초안으로, 아래 넷을 든다.**
  - 원본 노드
  - 선택
  - 최종 목록 참조
  - 두 원문
- **`Dev_ID`는 구조 편집을 실제로 적용한 모델과 새로 만든 ID로 푼다.** 그 뒤 XML을 준비해 같은 `UsbChangeSet`에 넣는다.
- **두 선택 파일은 DB 뒤에 확정한다(`UsbFileWrite.afterDatabases`).** 확정할 때 해시, XML 속성, Mac 사본의 실제 USB 목록 참조를 다시 읽는다.
- **끊긴 native 동기화는 전체를 쓰기 전으로 되돌린다.** 다른 앱이 바꾼 파일이나 지운 파일은 조용히 되돌리지 않은 채 `restorePending`으로 남긴다. 옛 저널에는 새 optional 칸이 없어도 된다.
- **선택 파일 쓰기에는 비상 스위치 `UsbSyncXMLWriteContract.production`이 있다.** 이 값이 nil이면 백업과 USB 쓰기 전에 선택 파일 쓰기를 막는다. 지금 값은 2026-10-08 rekordbox 7.2.x 전후 실험으로 확인한 판 `confirmed`다. 합성 시험의 가정으로 이 관문을 열지 않는다. 일반 파일 복사·쓰기·삭제로도 이 관문을 우회하지 못한다.

#### 사본과 취소한 초안

- **동기화는 목록을 읽은 스냅샷 파일로 작업 전용 사본을 만든다.** 앱은 그 스냅샷의 읽기 세대·경로·파일 지문을 기록한다. `UsbSyncSnapshotLease`는 사본을 만들 때 복사 전과 뒤의 지문을 견준다. 동기화 작업과 재시도 시트가 이 사본을 소유한다. 원본 경로와 시각은 사본과 따로 넘긴다.
- **같은 경로에서 파일만 바뀌어도 다시 준비하게 막는다.** 그래서 오래된 목록과 새 DB가 섞이지 않는다.
- **확인을 취소한 동기화 초안도 같은 앱 실행 안에서는 이어 쓴다.** `UsbStore.SyncDraftSource`가 작업 사본을 소유해 쓰기 대기 화면의 미리 보기와 쓰기로 이어 간다. 아래 경우에는 사본 소유권을 놓는다.
  - 쓰기 완료
  - 초안 변경이나 버리기
  - 원본 변경
  - USB 분리나 교체
  - 선택 원문 변경
- **앱을 다시 띄워 문맥을 잃은 초안은 현재 DB로 다시 만들지 않는다.** 그 초안은 버린 뒤 사용자에게 다시 준비하라고 안내한다.
- **native 쓰기는 각 대기 뒤와 최종 제출 전에 실제 마운트를 다시 읽는다(`UsbWriting.currentVolume`).** 읽을 때마다 원본·초안·선택 원문도 견준다. 여유 용량이 바뀐 것은 볼륨 교체로 보지 않는다. 마지막 확인 뒤의 분리는 하위 Writer의 UUID 검사가 그대로 잡는다.

### 반대 방향: USB 큐·그리드 가져오기

- **USB에서는 큐·그리드·평점 초안만 가져온다.** `LibraryStore.importUsbCueGrid`가 USB DB 사본과 로컬 스냅샷에서 1:1 짝을 새로 계산한다. ANLZ는 `UsbCueGridReader`로 읽어 초안으로 저장한다. 기존 초안, 더 새로운 로컬 카운터, 표현할 수 없는 값은 그대로 둔다. 가져온 뒤 목록과 덱의 초안 표시를 갱신한다.
- **USB에도 로컬 rekordbox DB에도 쓰지 않는다.**

### 기기 재생 기록 보존 (#43)

- **기기 재생 기록은 Mac에 보존한다. USB에는 쓰지 않는다.** 사이드바가 USB를 읽으면 `UsbStore.onLibraryEvaluated`가 저장소에 알린다. 저장소는 보존을 한 줄(`historyImports`)에 세운다.
- **보존 흐름은 유스케이스 `ArchiveUsbHistories`가 정한다.** 순서는 아래와 같다.
  1. 후보: `UsbHistoryCandidates`
  2. 계획: `UsbHistoryImport.plan`
  3. 짝 다시 검증: `UsbHistoryRules.rematch`
  4. 기록마다 저장: 포트 `UsbHistoryFiles`
- **보존 파일의 실제 구현은 DJCStorage `UsbHistoryStore`다.** 어댑터 `UsbHistoryFiles.live`가 이것을 감싼다. 조립 지점 `UsbAppSetup`이 `usb-histories/`를 정해 붙인다. 시험 저장소는 붙이지 않으므로 보존하지 않는다.
- **트리·숨김·쓰기 대기는 `UsbHistoryRules.view` 하나가 정한다.** 저장소는 기록이나 보존본이 바뀔 때만 이 값을 다시 계산한다(#141).
- **rekordbox에는 다른 초안처럼 반영 세션으로 쓴다.** 저장소는 쓰기 대기 기록을 `HistoryImport`로 바꿔 `ReflectionLibraryState.pendingHistories`에 싣는다. 세션은 이것을 `DraftWriteBatch.histories`로 묶어 관문 `RekordboxWriteGate`에 넘긴다. 관문의 실제 구현은 `RekordboxWriter.write(histories:)`를 부른다.
- **쓴 기록은 다시 읽기 전에 보존본에 표시한다.** 세션은 포트 `ReflectionLibrary.recordHistories`로 결과를 넘긴다. 미리 보기에서 최신 대상에 이미 있던 기록도 같은 길로 표시한다. 쓰기 전으로 복원해 그 기록이 사라지면 다시 쓰기 대기에 오른다.
- **쓰기 경로를 연 근거는 `docs/rekordbox-internals.md` "재생 기록"에 있다.** 보존 규칙은 `docs/usb-internals.md` §8.5에 있다.

## 더 보기

- [MVVM 패턴](mvvm.md): 화면 모델과 뷰를 나누는 규칙
- [rekordbox 형식과 쓰기 규칙](rekordbox-internals.md): 실험으로 확인한 사실
- [USB 형식과 쓰기](usb-internals.md)
- [검증과 CI](ci.md): 검증 단계와 측정 기준
- [CLI](cli.md): `djc` 명령과 환경 변수
- `.claude/rules/`: 경로별 규칙. 규칙의 이유는 이 문서를 가리킨다.
