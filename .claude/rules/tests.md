---
paths:
  - "Tests/**"
---

# 시험을 쓰고 고칠 때

새 시험을 쓸 때와 시험을 고칠 때 지키는 규칙이다. 리뷰는 규칙을 ID로 가리킨다.

## TDD

- **TEST-1** 버그는 실패하는 시험으로 먼저 재현한다. 그 뒤에 고친다.
- **TEST-2** 새 규칙은 시험을 먼저 써서 빨간색을 본다.
- **TEST-3** 빨강·초록은 `scripts/check.sh --quick --filter '<Suite>'`로 그 시험만 돌린다. 작업 끝에는 `--changed`를 돌린다(AGENTS.md "검증").
- **TEST-4** 시험을 지워서 통과시키지 않는다. 기대값을 느슨하게 해서 통과시키지도 않는다.
- **TEST-5** 안전 시험은 지우지 않는다. 조합만 줄일 수 있다. 안전 시험은 아래와 같다.
  - rekordbox: 실제 라이브러리 보호, 복원 대상, 쓰기 관문, 쓰기 대상 관문, 백업, 복원, 골든 쓰기
  - USB: 쓰기 가드, 쓰기 실패, 되돌리기, 회복, 저널, 실물 관문
  - 그 밖: scratch 밖 거부, CLI 거부, cold-open, lab 인증값, `LiveDraftHome` 격리

## 어디에 두나

- **TEST-6** 시험은 시험하는 층의 타깃에 둔다. 그 층과 아래 층, 재료만 의존한다.
- **TEST-7** 시험 타깃의 의존은 `Package.swift`에 있다. 시험 타깃의 import도 `scripts/check-imports.py`가 본다.
- **TEST-8** 규칙은 가장 아래 층에서 한 번 촘촘히 본다. 위층에는 연결을 보는 시험 하나만 둔다.
- **TEST-9** 같은 판정표를 층마다 되풀이하지 않는다.

| 타깃 | 무엇을 | 재료 |
|---|---|---|
| `DJCDomainTests` | 순수 규칙(아래), 환경 읽기 `DJCEnvironment`의 경로 | 값만, `DJCTestKit` |
| `RekordboxKitTests` | rekordbox 형식 읽기·쓰기·복원·관문, USB 형식·쓰기. 새 쓰기 규칙은 실험 곡·날짜를 적은 골든 시험 | `RekordboxFixtures`(구조만 있는 7.2.18 DB `RekordboxFixture`·합성 ANLZ `AnlzBuilder`·pdb) |
| `DJCAnalysisTests` | 소리 분석·편집 렌더 | 합성 음원 |
| `DJCApplicationTests` | 유스케이스의 순서·판정, 순수 USB 규칙(아래) | 가짜 포트만(아래), `DJCTestKit`. DB 재료 없음 |
| `DJCStorageTests` | DJCrate 자신의 파일(초안 저장소·라이브러리·재생 기록·중복 읽기·볼륨·도구 실행·iTunes 읽기) | 합성 DB 재료, `FakeToolRunner` |
| `DJCAdaptersTests` | 포트의 실제 구현(`.live`), 실제 엔진을 묶은 USB 세션·읽기 통합, 같은 포트의 가짜·실제 계약 시험 | 합성 DB 재료·USB 트리, `Tests/DJCAdaptersTests/Support/` |
| `djcTests` | CLI 인자·출력·`.build/debug/djc` 프로세스 | 합성 사본 |
| `DJCrateTests` | 화면 모델(덱·목록·반영·USB 흐름)과 앱 어댑터, 관찰 범위·본문 다시 계산 횟수(`.perfContract`), 오디오 엔진 계약 | 아래 |

`DJCDomainTests`가 보는 순수 규칙은 아래와 같다.

- 큐 편집, 루프, 게인, 재생 예약
- 덱 그리드 판정, 곡 편집 시간표
- USB 계획, 태그 값

`DJCApplicationTests`가 보는 유스케이스와 규칙은 아래와 같다.

- 덱: 곡 불러오기, 분석
- 반영: 반영 세션, 시점 스냅샷, 곡 넣기·빼기·복원, 편집본 쓰기
- 라이브러리: 읽기, 읽기 순서, 초안 지켜보기, 추가한 곡, XML 가져오기, 막힌 초안 복구, 옮긴 곡 찾기, `djc draft`
- 태그: 초안 편집(`EditTags`)
- USB: 세션, 읽기, 큐 그리드 가져오기, 동기화, 쓰기 흐름, 초안 고치기
- 순수 USB 규칙: 동기화 계획, 초안 편집 규칙

`DJCApplicationTests`의 가짜 포트는 아래와 같다.

- 반영: `ReflectionHarness`
- 포트별 가짜와 공용 계약 함수: `PortTestKit`
- USB: `FakeUsbPorts`
- 덱·라이브러리: 포트의 클로저, DJCApplication의 메모리 구현 `Memory…`(예: `MemoryDrafts`, `MemoryAnalysisStore`), `LibrarySource.memory`
- 라이브러리 읽기 화면: `FakeLibraryReadScreen`(PortTestKit). 읽기 순서 `LibraryReadFlow`가 보는 화면의 가짜다

`DJCrateTests`의 재료는 아래와 같다.

- 덱: `FakeDeckAudio`, `DeckStorage.memory`, `TrackAssetReader.memory`, `DeckModel.test`. `FakeDeckAudio`는 덱 조작 기록을 `events`에 남긴다.
- 덱 저장을 바꿔 넣을 때는 `DraftStore`를 먼저 고친다. 그 저장소를 `DeckStorage.memory(store)`로 준다. 덱은 초안 저장소 대신 `SaveDeckDrafts`를 든다.
- 라이브러리: `LibraryStore.test`. `settings`를 주지 않으면 저장소마다 새 `TestDefaults` 영역을 쓴다. `draftHome`·`backupDirectory`를 주지 않으면 저장소마다 새 임시 폴더를 쓴다. 앱 기본 폴더(`DJCPaths`)를 나눠 쓸 시험은 그 값을 명시한다. 저장소의 포트는 `store.testPorts`·`testDrafts`로만 본다.
- 확인 창: `ScriptedPrompter`
- 화면 시험: `PreviewWaveformCell(cache:)`, `StorageSettingsModel(paths:files:)`, `SettingsStore(sharedFile: .live(file:))`

## 재료

- **TEST-10** 재료 타깃은 셋이다. 실데이터는 없다.
  - `Tests/Support/Kit`(`DJCTestKit`): DJCDomain만 안다. SQLCipher를 빌드하지 않는다.
  - `Tests/Support/Fixtures`(`RekordboxFixtures`): rekordbox DB, ANLZ, pdb, USB 트리
  - `Tests/Support/Ports`(`PortTestKit`): DJCApplication, DJCDomain, DJCTestKit만 안다.
- **TEST-11** `DJCTestKit`에는 가짜 볼륨, DiskArbitration 사전, 합성 음원, 그림이 있다. `TemporaryFolder`·`TestDefaults`·`FixtureError`도 있다. 협력 풀 검사 `expectBlockingOffPool`·`waitOffPool`도 여기 있다.
- **TEST-12** `PortTestKit`에는 포트별 가짜와 공용 계약 함수 `<포트>Contract`가 있다.
- **TEST-13** 같은 계약 함수를 두 타깃에서 돌린다. DJCApplicationTests의 `PortContractTests`는 가짜에 돌린다. DJCAdaptersTests는 실제 구현에 돌린다.
- **TEST-14** 새 포트를 만들면 `PortTestKit`에 계약 함수와 가짜를 둔다. 그 계약을 두 시험 타깃에서 돌린다.
- **TEST-15** 오디오 엔진 계약 시험은 `DJCrateTests/AudioEngineContractTests`에 둔다. 가짜(`FakeDeckAudio`·`FakeEditAudio`)가 앱 시험 타깃에 있기 때문이다.
- **TEST-16** DB가 필요 없는 시험에 `RekordboxFixture`를 만들지 않는다. 연결마다 키 유도 비용이 든다.
- **TEST-17** 덱 시험 하네스(`DeckHarness`)는 Kit만 쓴다.
- **TEST-18** 앱 시험이 DB 옆 파일만 읽을 때는 DB를 열지 않는다. `LibrarySource.withoutDatabase`나 `LibrarySource.memory`를 쓴다. 앞의 것은 `Tests/DJCrateTests/LoadedLibrary+Test.swift`에 있다.
- **TEST-19** `Tests/Support/Fixtures/Resources/rekordbox-7.2.18-schema.sql`은 실제 DB에서 **구조만** 뽑은 것이다(`djc schema-dump`, 데이터 0행). 같은 키로 암호화해 픽스처 DB를 만든다. 키 유도 반복 수는 그 시험 프로세스의 SQLCipher 기본값을 따른다. 장치(`CipherTestKDF`)가 있는 묶음은 1번, djcTests는 256,000번이다(CIP-10·11). 일상 검사에서 장치가 꺼지면 시험이 실패한다(CIP-15).
- **TEST-20** 큐 ID 값이 상관없는 시험은 `CueIDs+Test.swift`의 옛 모양으로 만든다. 이 파일은 시험 타깃마다 있다. 옛 모양(예: `EditableCue(kind:time:)`)은 무작위 ID를 쓴다.
- **TEST-21** ID를 주입하는 규칙 자체는 `DJCDomainTests/CueIDInjectionTests`가 본다.

## 사용자 폴더를 쓰지 않는다

- **TEST-22** 시험은 사용자 초안·백업 폴더를 쓰지 않는다. 시험이 실제 라이브러리로 복원해 덮은 일이 있었다(#182).
- **TEST-23** 폴더는 주입한다(`directory:`·`backupDirectory:`).
- **TEST-24** 앱 기본 폴더(`DJCPaths`)를 써야 하는 시험만 `.enabled(if: LiveDraftHome.isIsolated)`를 단다. 이 시험은 `DJC_HOME`이 있을 때만 돈다.
- **TEST-25** `scripts/check.sh`는 `DJC_HOME`이 없으면 실행 로그 폴더 아래를 준다.
- **TEST-26** 설정은 `UserDefaults(suiteName:)`으로 직접 만들지 않는다. `TestDefaults`(DJCTestKit)로 만든다.
- **TEST-27** `TestDefaults`의 영역은 임시 폴더 안 경로다. 그래서 `~/Library/Preferences`에 plist를 남기지 않는다.
- **TEST-28** `scripts/check-imports.py`의 `test-defaults` 규칙이 TEST-26을 본다. plist를 남기면 `scripts/check.sh`가 종료 코드 4로 실패한다.
- **TEST-29** 시험 프로세스의 실제 rekordbox 폴더 쓰기·복원은 쓰기 관문이 거부한다(`TestProcess`). 그래도 늘 사본과 임시 폴더를 준다.

## 판정

- **TEST-30** 시험은 걸린 시간으로 판정하지 않는다(#149, #153, #154). 순서·상태·신호로 판정한다.
- **TEST-31** 기다릴 때는 `waitForState`(`Tests/DJCrateTests/StateWaiting.swift`)로 상태를 기다린다.
- **TEST-32** `waitForState`의 안전망(300초)은 시험이 멈추지 않게 할 뿐이다. 구현이 틀려 판정이 오지 않을 때를 위한 장치다.
- **TEST-33** 실제 마우스·키 상태처럼 시험 밖 상태를 읽는 곳은 주입한다. 그 값은 시험이 정한다(`TrackListCoordinator.isMouseDown`).
- **TEST-34** 부하 재현은 `yes`를 여러 개 띄운 채 `DJCrateTests` 전체를 한 프로세스로 돌린다.
- **TEST-35** 부하 재현을 필터로 좁히지 않는다. 좁히면 다른 `@MainActor` 시험과 메인 액터를 나눠 쓰는 정체가 없어 재현할 수 없다.
- **TEST-36** 골든 시험은 rekordbox 실험에서 확인한 칸 값을 그대로 기대값으로 둔다. 실험 곡과 날짜를 주석으로 단다.
- **TEST-37** 평소 건너뛰는 묶음과 줄여 도는 묶음은 `docs/ci.md` "선택 실행 장치"로 켠다. 레이아웃 다시 계산, 태그 쓰기 전체 조합, cold-open stress가 그 묶음이다.

## 더 보기

- 시험 층과 재료의 이유: [`docs/architecture.md` "시험"](../../docs/architecture.md#시험)
- 켜서 도는 묶음: [`docs/ci.md` "선택 실행 장치"](../../docs/ci.md#선택-실행-장치)
- 키 유도 비용: [`docs/ci.md` "테스트 준비 비용"](../../docs/ci.md#테스트-준비-비용)
