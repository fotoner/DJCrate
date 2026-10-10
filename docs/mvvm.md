# MVVM 패턴

DJCrate 앱 화면은 뷰와 화면 모델을 나눠, 업무 규칙과 흐름을 뷰 밖에 둔다.

이 문서는 Ledger Live의 MVVM 패턴 문서를 본떠 만들었다. 리뷰와 검사는 규칙을 ID(`MVVM-1` 등)로 가리킨다. ID는 번호를 다시 매기지 않는다.

## 패턴 구조

DJCrate의 MVVM은 세 층이다.

| 층 | 하는 일 | 자리 |
|---|---|---|
| 뷰(View) | 받은 값을 그린다. 사용자 의도를 화면 모델 메서드나 클로저로 넘긴다 | `Sources/DJCrate/<기능>/…View.swift` |
| 화면 모델(ViewModel) | 유스케이스를 부른다. 결과를 화면 상태로 바꾼다 | `Sources/DJCrate/<기능>/…Model.swift` |
| 유스케이스·포트(Model) | 규칙과 순서를 정한다. 바깥 일은 포트로 받는다 | `Sources/DJCApplication/<기능>/`, 규칙은 `Sources/DJCDomain/` |

- 화면 모델은 `@MainActor @Observable final class`다.
- 화면 모델은 `DJCApplication`·`DJCDomain`만 import한다. 실제 구현(`.live`)은 조립 지점이 고른다.
- 층과 모듈의 경계는 [구조 문서의 경계 규칙](architecture.md#경계-규칙)에 있다.

'폴더에서 찾기…'(#62) 화면이 세 층을 모두 갖춘 예다.

```
Sources/DJCDomain/Library/Relocate/
├── RelocateMatcher.swift       규칙: 파일 후보 맞추기
└── RelocateSelection.swift     규칙: 고른 후보와 겹침
Sources/DJCApplication/Library/
└── RelocateTracks.swift        유스케이스 + 포트 RelocateSource
Sources/DJCAdapters/Library/
└── RelocateSource+Live.swift   포트의 실제 구현
Sources/DJCrate/Library/Relocate/
├── RelocateModel.swift         화면 모델
├── RelocateView.swift          뷰(잎 뷰 RelocateRowView 포함)
└── RelocateText.swift          판정 결과를 화면 문구로
Tests/DJCApplicationTests/RelocateTracksTests.swift   유스케이스 시험
Tests/DJCrateTests/RelocateModelTests.swift           화면 모델 시험(가짜 포트)
```

화면을 여는 쪽이 화면 모델을 만들어 뷰에 넘긴다. 큰 화면의 모델은 조립 지점이 만든다(예: `AppComposition.storageSettings()`).

```swift
// Sources/DJCrate/Library/Relocate/RelocateView.swift — RelocateEntryButton
let next = RelocateModel(tracks: …, snapshot: store.snapshotURL, folder: folder,
                         relocate: store.useCases.relocate)
next.start()
model = next
// …
.sheet(item: …) { RelocateView(model: $0) }
```

## 규칙

| ID | 규칙 |
|---|---|
| `MVVM-1` | 화면마다 화면 모델 하나를 둔다. 이름은 `…Model`이다 |
| `MVVM-2` | 화면 모델은 유스케이스를 부른다. 결과를 화면 상태로 바꾼다 |
| `MVVM-3` | 잎 뷰는 값과 클로저만 받는다 |
| `MVVM-4` | 뷰 본문에서 유스케이스나 `Task`를 시작하지 않는다 |
| `MVVM-5` | 화면 모델은 가짜 포트로 시험한다. 잎 뷰는 값으로 시험한다 |
| `MVVM-6` | 예외는 덱 재생 경로와 `LibraryStore`뿐이다 |

### MVVM-1 화면마다 화면 모델 하나

화면은 창, 시트, 주요 패널이다. 화면마다 그 화면 전용 화면 모델을 하나 둔다. 화면 상태와 흐름은 화면 모델이 든다. 뷰는 `@State`에 그리기 상태만 둔다(예: 포커스, 펼침).

올바른 예: 화면 모델이 상태를 든다. 뷰는 화면 모델을 받아 그린다.

```swift
// Sources/DJCrate/Library/Relocate/RelocateModel.swift
@MainActor
@Observable
final class RelocateModel: Identifiable {
    private(set) var phase: Phase = .scanning(…)
    private(set) var selection = RelocateSelection(report: RelocateReport(results: []))
    // …
}

// Sources/DJCrate/Library/Relocate/RelocateView.swift
struct RelocateView: View {
    let model: RelocateModel
    // …
}
```

틀린 예: 시트에 화면 모델이 없다. 뷰가 화면 상태와 흐름을 든다. 아래는 #249에서 고치기 전의 코드다.

```swift
// Sources/DJCrate/Library/UnlinkedDraftsView.swift(#249 전)
struct UnlinkedDraftsView: View {
    let store: LibraryStore
    @State private var drafts: [UnlinkedDraft] = []   // ✗ 화면 상태가 뷰에 있다
    @State private var failure: String?               // ✗
    // …
    Button(.ui("초안 버리기"), role: .destructive) {
        failure = store.discardUnlinkedDrafts(selected)  // ✗ 흐름이 뷰에 있다
        reload()
    }
}
```

고친 코드: 시트를 띄울 때 화면 모델을 한 번 만든다. 뷰는 그 모델만 받는다.

```swift
// Sources/DJCrate/Library/LibraryStore+UnlinkedDrafts.swift
func openUnlinkedDrafts() { unlinkedDraftsSheet = UnlinkedDraftsModel(store: self) }

// Sources/DJCrate/App/ContentView.swift
.sheet(item: $store.unlinkedDraftsSheet) { UnlinkedDraftsView(model: $0) }

// Sources/DJCrate/Library/UnlinkedDraftsView.swift
Button(.ui("초안 버리기"), role: .destructive) { model.discard() }
```

- 시트 모델을 `body`나 시트 내용 클로저에서 만들지 않는다. 본문을 다시 계산할 때마다 새 모델이 생겨 입력과 선택을 잃는다.

### MVVM-2 화면 모델은 유스케이스를 부른다

화면 모델은 유스케이스를 부른다. 그 결과를 화면 상태로 바꾼다. 순서는 DJCApplication의 유스케이스에 둔다. 규칙은 DJCDomain에 둔다. 그래서 앱과 CLI가 같은 규칙을 쓴다. 규칙은 앱 없이 시험한다.

유스케이스에는 화면 상태가 없다. 유스케이스는 `@Observable`이 아니다. 흐름 상태는 값으로, 알림은 출력 포트로 내보낸다. 화면 모델이 그것을 관찰 상태로 바꾼다.

본보기는 `UsbSync`와 앱 `UsbSyncModel`이다. `UsbSync`는 값 `UsbSyncState`와 출력 포트 `UsbSyncOutput`을 쓴다. USB 쓰기 세션 `UsbWriteSession`과 앱 `UsbWriteModel`도 같은 모양이다. 경계 검사의 `api` 규칙이 핵심부의 Observation을 막는다.

올바른 예: 찾기는 유스케이스가 한다. 고르기 규칙은 DJCDomain 값이 한다. 화면 모델은 결과를 상태에 담기만 한다.

```swift
// Sources/DJCrate/Library/Relocate/RelocateModel.swift
let found = try await relocate.find(tracks, snapshot: snapshot, folder: folder) { … }
self.selection = RelocateSelection(report: found.output.report)
self.phase = .reviewing

func choose(_ path: String?, for trackID: String) {
    selection.choose(path, for: trackID)   // 규칙은 DJCDomain의 RelocateSelection
}
```

틀린 예: 뷰가 고르기 규칙을 직접 계산한다. 아래는 #249에서 고치기 전의 코드다. 지금은 DJCDomain 값 `PlaylistChoices`가 이 규칙을 맡는다.

```swift
// Sources/DJCrate/Library/PlaylistPickerView.swift(#249 전)
private var choices: [Choice] {
    let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
    // ✗ 찾기 규칙과 "최근 목록 먼저" 순서가 뷰에 있다
    let recent = store.recentPlaylists.compactMap { item in all.first { $0.id == item.id } }
    // …
    return recent + all.filter { !recentIDs.contains($0.id) }
}
```

### MVVM-3 잎 뷰는 값과 클로저만 받는다

잎 뷰는 다른 뷰를 품지 않는 작은 뷰다(예: 줄, 단추, 칩). 잎 뷰에 화면 모델 전체를 넘기지 않는다. 필요한 값과 동작 클로저만 넘긴다. 그러면 SwiftUI는 넘긴 값이 바뀔 때만 잎 뷰 본문을 다시 계산한다. 잎 뷰를 값만 넣어 시험할 수도 있다.

올바른 예: 묶음 뷰가 모델에서 값을 꺼낸다. 잎 뷰는 값과 클로저만 받는다.

```swift
// Sources/DJCrate/Deck/Views/DeckSuggestionBar.swift
struct DeckSuggestionBar: View {
    let tags: TagEditStore
    let deck: DeckModel

    var body: some View {
        let suggestions = DeckSuggestions(deck: deck, tags: tags)
        DeckSuggestionBarContent(list: suggestions.list, gridStatus: suggestions.gridStatus, isLocked: suggestions.isLocked,
                                 apply: suggestions.apply, dismiss: suggestions.dismiss,
                                 restore: suggestions.restoreDismissed, reanalyze: deck.reanalyze)
    }
}
```

틀린 예: 단추 하나가 덱 모델 전체를 받는다.

```swift
// Sources/DJCrate/Deck/Views/GridShiftButton.swift
struct GridShiftButton: NSViewRepresentable {
    let deck: DeckModel          // ✗ 잎 뷰가 화면 모델 전체를 받는다
    let milliseconds: Double
    // …
}
```

### MVVM-4 뷰 본문에서 유스케이스·Task를 시작하지 않는다

뷰는 화면 모델의 메서드를 부른다. 비동기 일의 시작, 취소, 늦은 결과 버리기는 화면 모델이 맡는다. 뷰가 `Task`를 만들면 창을 닫아도 일이 멈추지 않는다. 진행 상태도 뷰의 `@State`가 맡게 된다.

올바른 예: 단추는 화면 모델 메서드만 부른다. 화면 모델이 `Task`를 든다. 취소와 세대도 화면 모델이 관리한다.

```swift
// Sources/DJCrate/Library/Relocate/RelocateView.swift
if let folder = RelocatePanels.chooseFolder() { model.rescan(in: folder) }
Button(.ui("찾기 취소")) { model.cancel() }

// Sources/DJCrate/Library/Relocate/RelocateModel.swift
func start() {
    task?.cancel()
    generation += 1
    // …
    task = Task { … }
}
```

틀린 예: 뷰가 `Task`를 만들어 저장소를 부른다. 진행 상태도 뷰가 든다. 아래는 #244에서 고치기 전의 코드다.

```swift
// Sources/DJCrate/Library/DuplicateTracksView.swift(#244 전)
Button(.ui("이 곡을 남기고 합치기…")) {
    preparing = true                       // ✗ 진행 상태가 뷰의 @State다
    Task {                                 // ✗ 뷰가 Task를 시작한다
        await store.prepareMerge(keeping: member.id, removing: …)
        preparing = false
    }
}
```

고친 코드: 단추는 화면 모델의 동기 메서드를 부른다. 진행 상태와 `Task` 손잡이는 화면 모델이 든다.

```swift
// Sources/DJCrate/Library/DuplicateTracksView.swift
Button(.ui("이 곡을 남기고 합치기…")) {
    model.startMerge(keeping: member.id, removing: …)
}
.disabled(model.isPreparing || …)

// Sources/DJCrate/Library/DuplicateTracksModel.swift
func startMerge(keeping: String, removing: [String]) {
    isPreparing = true
    task = Task {
        await prepare(keeping, removing)
        isPreparing = false
    }
}
```

- 단추가 시작하는 일의 이름은 `start…`로 짓는다. 화면 모델은 마지막 일의 손잡이를 `task`에 든다. 시험은 그 손잡이를 기다린다.
- 단추의 일은 화면이 사라져도 취소하지 않는다. 화면과 함께 멈출 일은 `.task` 한 줄로 부른다.
- 공유 저장소 `LibraryStore`의 단추 입구는 `LibraryStore+Actions.swift`에 모은다. 입구는 시작한 `Task`를 돌려준다.
- 기능 조각(예: `MusicLibraryStore`)의 단추 입구는 그 조각에 둔다.

`scripts/check-imports.py`의 `view-task` 규칙이 이 규칙을 검사한다.

- 대상은 `DJCrate` 타깃 파일 중 `View`를 채택한 타입이 든 파일이다. struct·class·enum과 extension이 그 타입이다. `NSViewRepresentable`·`ViewModifier`는 대상이 아니다. 화면 모델 파일도 보지 않는다.
- 세는 것은 `Task {`·`Task(…) {`·`Task.detached`와 `await`다. 주석과 문자열 안은 세지 않는다. `@State var job: Task<…>?` 같은 타입 표기도 세지 않는다.
- **허용 꼴은 하나다.** 수명 수식어 `.task {…}`·`.task(id:) {…}`의 본문이 `await 받는쪽.메서드(인자)` 하나뿐이면 세지 않는다. 이때는 SwiftUI가 일의 수명을 맡는다. 뷰에는 로직이 없다.
  - 받는 쪽은 `self`가 아닌 값이다. `model.load()`는 허용한다. `load()`는 센다.
  - 호출은 하나다. 연쇄 호출(`app.runner().loop()`)과 `if await …`는 센다.
  - 인자에 클로저와 `await`가 없다.

올바른 예와 틀린 예:

```swift
.task { await model.load() }                    // 허용: 화면 모델 메서드 하나
.task(id: track.id) { await model.load(track) } // 허용
.task { await load() }                          // ✗ 받는 쪽이 self다
.task { if await model.ready() { show = true } } // ✗ 뷰에 로직이 있다
```

- 옛 위반은 빚 목록 `scripts/import-debt.txt`에 파일마다 곳 수로 고정했다. 2026-10-10에 모두 갚았다. 지금 빚 목록에 `view-task` 줄은 없다.
- 새 위반은 빚 목록에 더하지 않는다. 그 자리에서 화면 모델로 옮긴다.

### MVVM-5 시험 자리

- 화면 모델 시험은 `Tests/DJCrateTests`에 둔다. 포트에는 가짜를 넣는다. rekordbox 라이브러리, 음원, 실제 폴더를 열지 않는다.
- 유스케이스 시험은 `Tests/DJCApplicationTests`에 둔다. 규칙 시험은 `Tests/DJCDomainTests`에 둔다.
- 잎 뷰는 값만 넣어 그려 본다. `#Preview`도 같은 방법이다.
- 시험 재료와 배치 규칙은 `.claude/rules/tests.md`에 있다.

올바른 예: 화면 모델에 가짜 포트를 넣는다. 잎 뷰에는 값만 넣는다.

```swift
// Tests/DJCrateTests/RelocateModelTests.swift
func model(_ source: RelocateSource, snapshot: URL? = …) -> RelocateModel {
    RelocateModel(tracks: Self.tracks, snapshot: snapshot, folder: Self.folder, relocate: RelocateTracks(source: source))
}

// Tests/DJCrateTests/DeckSuggestionBarTests.swift
DeckSuggestionBarContent(list: list, gridStatus: status, isLocked: false, titles: titles)
```

틀린 예: 잎 뷰가 모델 전체를 받는다. 그래서 단추 하나의 시험에 덱 전체가 든다.

```swift
// Tests/DJCrateTests/GridShiftButtonTests.swift
let h = try DeckHarness()      // ✗ 단추 시험에 곡을 불러온 덱이 필요하다
try await h.loaded()
```

### MVVM-6 예외

아래 둘은 이 패턴의 예외다.

- **덱 재생 경로**: `DeckModel`은 오디오 엔진 포트 `DeckAudioEngine`을 직접 부른다. 매 프레임 재생 위치와 샘플 단위 예약을 유스케이스 한 겹 뒤로 미루지 않으려는 것이다. 이유는 [구조 문서의 경계 규칙](architecture.md#경계-규칙)에 있다.
- **공유 저장소 `LibraryStore`**: 사이드바, 곡 목록, 인스펙터, 태그 시트가 함께 쓴다. 나누기 전까지 이 모양을 둔다. 새 화면은 자기 화면 모델을 만든다. 그 화면 모델이 `LibraryStore`의 값을 읽는다.
  - 저장소의 흐름 순서도 유스케이스로 옮긴다. 예: 읽기 순번·요청 합치기·Music 최신화 잇기는 `LibraryReadFlow`에 있다. 저장소는 화면 포트 `LibraryReadScreen`으로 상태를 넘긴다. 저장소는 흐름이 알린 결과를 표시한다.
  - 기능 하나의 상태는 기능 조각(`…Store`)으로 뗀다(#248). 조각은 저장소의 속성이다. 저장소는 조각을 관찰하지 않는다. 화면은 조각의 값을 읽는다.
  - 조각 속성은 `let`으로 둔다. 조각이 저장소를 붙들면 `@ObservationIgnored lazy var`로 둔다.
  - 예: Music 목록과 동기화 창은 `MusicLibraryStore`(`store.music`)가 든다. 태그 인스펙터의 화면 모델 `TagInspectorModel`은 태그 편집 조각 `TagEditStore`(`store.tags`)를 부른다. 규칙은 유스케이스 `EditTags`에 있다.

```swift
// Sources/DJCrate/Deck/DeckModel+Transport.swift — 예외: 화면 모델이 엔진 포트를 직접 부른다
func tick() {
    // …
    playhead = audio.position
    // …
    audio.scheduleClicks(grid)
}
```

## 언제 쓰나

- 창, 시트, 주요 패널
- 유스케이스를 부르는 화면
- 비동기 일(읽기, 쓰기, 훑기)을 시작하는 화면
- 상태가 셋 이상 바뀌는 화면. 예: 읽는 중 → 미리 보기 → 실패

## 언제 안 쓰나

- 값만 받아 그리는 잎 뷰: 줄, 단추, 칩, 표 칸
- 받은 값만 고르는 작은 메뉴와 확인 창
- 화면 규칙이 없는 장식 뷰: 여백, 색, 글자 크기

## 이름 뜻

| 접미사 | 뜻 | 예 |
|---|---|---|
| `…Model` | 화면 하나 전용 화면 모델 | `RelocateModel`, `TrackEditModel`, `StorageSettingsModel` |
| `…Store` | 여러 화면이 함께 쓰는 저장소·기능 조각 | `LibraryStore`, `UsbStore`, `TagEditStore` |
| `…Coordinator` | 화면 여러 개를 잇는 흐름 | `ReflectionCoordinator`, `UsbWriteCoordinator` |
| `…Coordinator`(AppKit) | `NSViewRepresentable`의 대리자 | `TrackListCoordinator`, `SheetCoordinator` |

- 이름을 `…ViewModel`로 바꾸지 않는다. Swift에서는 `…Model`이 흔하다. 바꾸면 타입과 시험 파일 이름이 많이 바뀐다.
- 새 화면 모델은 `…Model`로 짓는다. `…Store`·`…Coordinator`는 위 뜻일 때만 쓴다.

## 남은 빚

지금 코드는 이 규칙과 다른 곳이 있다. `MVVM-3`·`MVVM-1` 수는 2026-10-09에 잰 값이다. 대상은 `Sources/DJCrate`에서 `Diagnostics/`를 뺀 뷰 파일 59개다. 뷰 파일은 `some View`나 `NSViewRepresentable`이 있는 파일이다. `MVVM-4` 수는 2026-10-10 `view-task` 검사의 값이다.

| 규칙 | 지금 | 잰 방법 |
|---|---|---|
| `MVVM-4` | 빚 0줄. 2026-10-10에 #243·#244로 갚았다 | `python3 scripts/check-imports.py --summary` |
| `MVVM-3` | 35개 파일이 `LibraryStore`를 통째로 받는다 | `grep -lE '(let\|var) store: LibraryStore'` |
| `MVVM-3` | 20개 파일이 `DeckModel`을 통째로 받는다 | `grep -lE '(let\|var) deck: DeckModel'` |
| `MVVM-1` | 화면 모델 없는 화면이 있다. 시트 셋(`UnlinkedDraftsView`, `PlaylistPickerView`, `XMLImportSheet`)은 2026-10-10에 #249로 갚았다 | 사람이 본다 |

- `MVVM-3` 수는 잎 뷰와 묶음 뷰를 가리지 않는다. 묶음 뷰가 모델을 받는 것은 규칙 위반이 아니다.
- 이 빚은 손대는 화면부터 조금씩 갚는다. 빚 때문에 큰 화면을 한 번에 나누지 않는다.
- 뷰가 인프라를 import하는 빚은 0이다. 이것은 `scripts/check-imports.py`가 막는다.
- 뷰의 `Task`·`await` 빚은 0이다. 새 위반은 `view-task` 규칙이 막는다.
- `MVVM-3`·`MVVM-1` 빚을 검사로 막는 장치는 아직 없다.

## 더 보기

- [구조와 설계 결정](architecture.md): 모듈, 경계 규칙, 조립 지점
- `.claude/rules/mvvm.md`: 화면 코드를 고칠 때 실리는 규칙 요약
- `.claude/rules/ui.md`: 앱 화면과 설정 규칙
- `.claude/rules/tests.md`: 시험 자리와 시험 재료
- Ledger Live MVVM Pattern: <https://developers.ledger.com/docs/ledger-live/contributing/reference/mvvm-pattern>
