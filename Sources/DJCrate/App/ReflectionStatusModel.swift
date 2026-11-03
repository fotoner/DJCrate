import DJCApplication
import DJCDomain
import Foundation
import Observation
import SwiftUI

/// 상태 줄 쓰기 상태 칩이 보이는 상태 하나(#324). 칩의 글자·모양은 이 값만 보고 정한다.
/// rekordbox 켜짐·꺼짐 이유(#326)는 쓰기 대기에 붙고, 쓸 수 없음(#327)은 경우를 더해 같은 모델에 잇는다.
/// 앞서는 차례: 쓰는 중 > 쓸 수 없음 > 쓰기 대기(켜짐·끝나는 중·꺼짐 이유) > 쓰기 대기 없음
enum ReflectionChip: Equatable {
    /// 쓸 것이 없다
    case clean
    /// 쓰기 대기. 수는 사이드바 「rekordbox 쓰기 대기」 배지와 같은 정의(`LibraryStore.pendingWriteCount`, 곡과 쓰기 대기 재생 기록)라 단위는 「건」이다.
    /// 이유(`reason`)는 rekordbox 켜짐·꺼짐 감지가 붙인다. 없으면 감지 값을 모르거나 이유를 말할 때가 아니다
    case pending(items: Int, playlistEdits: Int, reason: Reason? = nil)
    /// rekordbox에 쓸 수 없다(#327): 지원 밖 버전·DB 구조·백업 폴더. 편집하기 전에 알리려고 쓰기 대기가 없어도 보인다.
    /// 편집은 초안으로 남으므로 쓰기 대기 수는 그대로 센다(수가 있으면 함께 보인다)
    case blocked(LibraryWriteBlock, items: Int, playlistEdits: Int)
    /// rekordbox에 쓰는 중. 쓰기가 짧게 끝나면 깜빡이지 않게 1초가 지난 뒤에만 보인다
    case writing

    /// 쓰기 대기에 붙는 이유(#326). 쓰기 대기가 있을 때만 붙는다
    enum Reason: Equatable {
        /// rekordbox가 켜져 있다
        case rekordboxRunning
        /// rekordbox는 꺼졌고 rekordboxAgent만 켜져 있다
        case agentRunning
        /// 켜짐(또는 Agent만)에서 꺼짐으로 바뀐 직후의 확인 시간. [지금 쓰기] 강조를 미룬다
        case rekordboxStopping
        /// 확인 시간 뒤에도 꺼져 있다. [지금 쓰기]를 강조한다
        case rekordboxStopped

        var text: String {
            switch self {
            case .rekordboxRunning: String(ui: "rekordbox가 켜져 있습니다")
            case .agentRunning: String(ui: "rekordboxAgent가 켜져 있습니다")
            case .rekordboxStopping: String(ui: "rekordbox가 끝나는 중…")
            case .rekordboxStopped: String(ui: "rekordbox가 꺼졌습니다")
            }
        }
    }

    /// 곡과 재생 목록 편집 수로 상태를 정한다. 쓰는 중이면 대기 수와 관계없이 쓰는 중이다. 그다음은 쓸 수 없음이다(대기가 없어도 보인다).
    /// 이유는 쓰기 대기가 있을 때만 붙는다(대기가 없으면 「쓰기 대기 없음」 그대로)
    static func make(items: Int, playlistEdits: Int, writing: Bool, block: LibraryWriteBlock? = nil, reason: Reason? = nil) -> Self {
        if writing { return .writing }
        if let block { return .blocked(block, items: items, playlistEdits: playlistEdits) }
        return items > 0 || playlistEdits > 0 ? .pending(items: items, playlistEdits: playlistEdits, reason: reason) : .clean
    }

    /// 칩 글자. 이유가 있으면 이유를 앞에 두고 「 · 」로 쓰기 대기 수를 잇는다
    var title: String {
        switch self {
        case .clean: return String(ui: "쓰기 대기 없음")
        case let .pending(items, playlistEdits, reason):
            let count = PendingWriteCount(items: items, playlistEdits: playlistEdits).text
            guard let reason else { return count }
            return String(ui: "\(reason.text) · \(count)")
        case let .blocked(_, items, playlistEdits):
            let blocked = String(ui: "rekordbox에 쓸 수 없음")
            let count = PendingWriteCount(items: items, playlistEdits: playlistEdits)
            return count.isEmpty ? blocked : String(ui: "\(blocked) · \(count.text)")
        case .writing: return String(ui: "rekordbox에 쓰는 중…")
        }
    }

    /// 쓸 수 없는 이유 한 문장(원인과 할 일). 칩 툴팁과 팝오버 맨 위에 보인다. 쓸 수 없을 때만 있다
    var blockReason: String? {
        if case let .blocked(block, _, _) = self { return block.reason }
        return nil
    }

    var isPending: Bool {
        if case .pending = self { return true }
        return false
    }

    /// 칩에 붙은 이유
    var reason: Reason? {
        if case let .pending(_, _, reason) = self { return reason }
        return nil
    }
}

/// 마지막으로 rekordbox에 쓴 때(활동 기록의 쓰기 결과)와 쓰기 전 백업이 남아 있는지
struct ReflectionLastWrite: Equatable {
    var date: Date
    var hasBackup: Bool

    /// 시각 형식. 시를 두 자리로 쓴다(활동 기록 목록과 같다, #298). 오늘이 아닌 쓰기는 월·일을 앞에 붙인다
    static func timeFormat(includesDate: Bool, locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .autoupdatingCurrent) -> Date.FormatStyle {
        let time = Date.FormatStyle(locale: locale, timeZone: timeZone).hour(.twoDigits(amPM: .abbreviated)).minute(.twoDigits)
        return includesDate ? time.month(.abbreviated).day() : time
    }

    /// 「마지막 쓰기 14:02 · 백업 있음」. 오늘이 아니면 월·일을 함께 적는다
    func text(now: Date = .now, calendar: Calendar = .current) -> String {
        let when = date.formatted(Self.timeFormat(includesDate: !calendar.isDate(date, inSameDayAs: now)))
        return hasBackup ? String(ui: "마지막 쓰기 \(when) · 백업 있음") : String(ui: "마지막 쓰기 \(when)")
    }
}

/// Dock 아이콘 배지를 바꾸는 입구. 모델이 값이 바뀔 때만 부른다. 실제 구현은 조립 지점이 고른다(`AppComposition`), 시험은 가짜를 넣는다
struct DockBadge {
    var show: @MainActor (String?) -> Void

    static var none: DockBadge { DockBadge { _ in } }
}

/// 창 아래 상태 줄의 rekordbox 쓰기 상태 화면 모델(#324): 칩(쓰기 대기 없음·쓰기 대기 N건·재생 목록 편집 N건·쓰는 중), 보조 글(마지막 쓰기),
/// 상태 팝오버의 단추, Dock 배지. 저장소의 쓰기 대기 수·재생 목록 초안·쓰기 중·활동 기록을 관찰해 스스로 고친다. 뷰는 읽기만 한다.
/// 새 쓰기 경로는 없다. 팝오버 단추와 [쓰기]는 메뉴 막대와 같은 `LibraryMenuAction`을 같은 조건으로 부른다.
///
/// rekordbox 켜짐·꺼짐(#326): 감지 서비스의 판정(`runState`)을 쓰기 대기의 이유로 붙인다(켜져 있습니다·Agent·끝나는 중·꺼졌습니다).
/// 강조는 켜짐(또는 Agent만)→꺼짐 **전이**에서만 시작한다. 전이 직후 `settleDelay` 동안은 「끝나는 중…」이고 [지금 쓰기] 강조를 미룬다.
/// 그 뒤 다시 읽어도 꺼져 있으면 꺼짐 강조, 다시 켜졌으면 켜짐이다. 강조는 쓰기를 시작하거나(어느 쓰기 단계든) 쓰기 대기가 0이 되거나
/// 다시 켜지거나 모름이 되면 끝나고, 새 전이가 있기 전에는 다시 시작하지 않는다(앱을 켤 때 이미 꺼져 있으면 강조하지 않는다).
/// 모름·읽기 전은 이유도 강조도 없다. 이 값은 표시만 바꾼다: 쓸지 말지는 이 값을 보지 않고 기존 판단(`LibraryMenuAction.isEnabled`)과 쓰기 관문이 정한다.
///
/// 쓸 수 없는 라이브러리(#327): 읽기 흐름이 읽은 사본으로 미리 본 막힘(`LibraryStore.writeBlock`, 지원 밖 버전·DB 구조·백업 폴더)이 있으면
/// 칩은 쓰기 대기가 없어도 「rekordbox에 쓸 수 없음」이고 이유를 툴팁·팝오버 맨 위에 보인다. 쓰는 중만 이보다 앞선다.
/// 칩 옆 [쓰기]·[지금 쓰기]만 숨기고 쓰기 대기 수와 Dock 배지는 그대로 센다. 이것도 표시만이다(쓰기 판단·관문은 그대로).
/// 조립 지점(`AppComposition.writeStatus`)이 한 번 만든다.
@MainActor
@Observable
final class ReflectionStatusModel {
    /// 쓰기가 이만큼 이어질 때만 「쓰는 중」을 보인다
    static let writingDelay: Duration = .seconds(1)
    /// 켜짐(또는 Agent만)에서 꺼짐으로 바뀐 뒤 이만큼 지켜보고 [지금 쓰기]를 강조한다(#326). 그 안에 다시 켜지면 강조하지 않는다
    static let settleDelay: Duration = .seconds(3)
    /// 팝오버에 늘어놓는 명령(메뉴 막대 rekordbox 메뉴의 앞 네 항목과 같은 것)
    static let popoverActions: [LibraryMenuAction] = [.reflect, .pending, .activityLog, .restore]

    /// 팝오버 단추 하나(뷰에는 값만 넘긴다)
    struct Item: Identifiable, Equatable {
        let action: LibraryMenuAction
        var id: LibraryMenuAction { action }
        var title: String
        /// 단축키 안내(⇧⌘E). 단축키는 메뉴 막대가 맡으므로 단추에 달지 않고 글자로만 보인다
        var shortcutHint: String?
        var isEnabled: Bool
        /// 막힌 이유(메뉴 막대 항목의 툴팁과 같은 문장)
        var disabledReason: String?
    }

    private(set) var chip: ReflectionChip = .clean
    private(set) var lastWrite: ReflectionLastWrite?
    /// 상태 팝오버가 열려 있다
    var isPresented = false

    @ObservationIgnored private let store: LibraryStore
    @ObservationIgnored private let window: LibraryWindowModel
    @ObservationIgnored private let windows: AppWindows?
    @ObservationIgnored private let reflection: ReflectionCoordinator?
    @ObservationIgnored private let dock: DockBadge
    /// rekordbox 실행 판정. 조립 지점이 감지 서비스(`RekordboxRunModel`)에 잇는다. 읽기 전·잇지 않았으면 nil(모름)이다
    @ObservationIgnored private let runState: @MainActor () -> RekordboxRunState?
    /// 「쓰는 중」을 늦추는 기다림. 시험이 바꿔 끼운다
    @ObservationIgnored var sleep: @Sendable (Duration) async throws -> Void
    /// 켜짐→꺼짐 전이 뒤 확인 시간. 시험이 바꿔 끼운다
    @ObservationIgnored var settleSleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var showsWriting = false
    @ObservationIgnored private var writingDelayTask: Task<Void, Never>?
    /// 마지막으로 안 켜짐·꺼짐 판정(모름은 넣지 않는다). 켜짐→꺼짐 전이를 알아보는 데 쓴다
    @ObservationIgnored private var lastKnownRun: RekordboxRunState?
    /// 꺼짐 전이 뒤 단계: 확인 중(끝나는 중) → 강조
    private enum Stopped { case none, settling, highlighted }
    @ObservationIgnored private var stopped: Stopped = .none
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    @ObservationIgnored private var shownDockLabel: String?
    @ObservationIgnored private var isObserving = false

    /// - Parameters:
    ///   - window: 메뉴 막대와 같은 명령을 보고 부르는 주 창 모델
    ///   - windows: 창을 여는 명령(시점 스냅샷)이 쓸 앱 창. 팝오버에는 그런 명령이 없어 nil이어도 된다
    ///   - reflection: 쓰기·복원 명령이 부를 화면 쪽. nil이면 그 명령은 아무것도 하지 않는다(`LibraryMenuAction.perform`과 같다)
    ///   - runState: rekordbox 실행 판정(조립 지점이 감지 서비스에 잇는다). 표시만 바꾼다: 쓸지 말지는 이 값을 보지 않는다
    init(store: LibraryStore, window: LibraryWindowModel, windows: AppWindows?, reflection: ReflectionCoordinator?,
         dock: DockBadge = .none, runState: @escaping @MainActor () -> RekordboxRunState? = { nil },
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         settleSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.store = store
        self.window = window
        self.windows = windows
        self.reflection = reflection
        self.dock = dock
        self.runState = runState
        self.sleep = sleep
        self.settleSleep = settleSleep
    }

    // MARK: - 읽는 값

    /// 칩 옆 보조 글. 마지막 쓰기가 없으면 nil(숨긴다)
    var lastWriteText: String? { lastWrite?.text() }

    /// 곡 대기와 재생 목록 편집이 함께 있으면 팝오버가 편집 건수를 덧붙인다(쓸 수 없을 때도 같다)
    var extraLine: String? {
        let items: Int, playlistEdits: Int
        switch chip {
        case let .pending(count, edits, _), let .blocked(_, count, edits): (items, playlistEdits) = (count, edits)
        case .clean, .writing: return nil
        }
        guard items > 0, playlistEdits > 0 else { return nil }
        return String(ui: "재생 목록 편집 \(playlistEdits)건")
    }

    /// 실제로 쓰는 중인가: 백업·DB·분석 파일을 쓰는 단계와 쓴 뒤 다시 읽는 단계. 잠금만 걸린 미리 보기·확인 창(아직 쓰지 않았다)은 뺀다(#301)
    private var isWriting: Bool {
        let phase = store.rekordboxWritePhase
        return phase == .writing || phase == .readingBack
    }

    /// 칩 옆 [쓰기] 단추를 보일 때: 쓰기 대기가 있을 때. 쓸 수 없을 때는 보이지 않는다(화면 표시만, 메뉴·팝오버 항목은 지금 판단 그대로)
    var showsWriteButton: Bool { chip.isPending }

    /// rekordbox가 꺼진 것을 확인해 [지금 쓰기]를 강조할 때(#326). 단추는 같고 글자와 모양만 다르다
    var emphasizesWrite: Bool { chip.reason == .rekordboxStopped }

    /// 칩 옆 단추 글자. 강조할 때만 「지금 쓰기」다. 둘 다 같은 명령(`LibraryMenuAction.reflect`)을 같은 조건으로 부른다
    var writeButtonTitle: String { emphasizesWrite ? String(ui: "지금 쓰기") : String(ui: "쓰기") }

    /// 팝오버에 붙이는 할 일 한 줄. 켜진 것을 끈 뒤 쓰라고 알린다(#326). rekordboxAgent는 끄는 방법을 확인하지 않았으므로 끄라고만 쓴다
    var todoLine: String? {
        switch chip.reason {
        case .rekordboxRunning: String(ui: "rekordbox를 끈 뒤 쓰세요")
        case .agentRunning: String(ui: "rekordboxAgent를 종료한 뒤 쓰세요")
        case .rekordboxStopping, .rekordboxStopped, nil: nil
        }
    }

    /// 팝오버 상태 아래 글(차례대로): 쓸 수 없는 이유(맨 위), 할 일, 함께 있는 재생 목록 편집 건수, 마지막 쓰기
    var popoverLines: [String] { [chip.blockReason, todoLine, extraLine, lastWriteText].compactMap { $0 } }

    /// 메뉴 막대 「rekordbox에 쓰기」와 같은 활성 조건
    var canWrite: Bool { LibraryMenuAction.reflect.isEnabled(in: window) }
    var writeDisabledReason: String? { LibraryMenuAction.reflect.disabledReason(in: window) }

    var items: [Item] {
        Self.popoverActions.map { action in
            Item(action: action, title: action.title, shortcutHint: action.shortcut.map(Self.hint),
                 isEnabled: action.isEnabled(in: window), disabledReason: action.disabledReason(in: window))
        }
    }

    /// 단축키를 STR-15 순서(⌃⌥⇧⌘)의 글자로
    static func hint(_ shortcut: KeyboardShortcut) -> String {
        let modifiers = shortcut.modifiers
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + shortcut.key.character.uppercased()
    }

    // MARK: - 단추

    /// 팝오버·[쓰기] 단추: 팝오버를 닫고 메뉴 막대와 같은 명령을 부른다. 막힌 명령은 메뉴처럼 이유를 알린다
    func perform(_ action: LibraryMenuAction) {
        isPresented = false
        action.perform(in: window, windows: windows, reflection: reflection)
    }

    // MARK: - 관찰

    /// 지금 값으로 맞추고 저장소를 지켜보기 시작한다
    func start() {
        guard !isObserving else { return }
        isObserving = true
        refresh()
        track()
    }

    /// 저장소 값에서 상태를 다시 읽는다. 바뀐 값만 쓴다(같은 값을 다시 쓰면 상태 줄이 쓸데없이 다시 그려진다)
    func refresh() {
        updateWritingDelay(isWriting)
        let count = store.pendingWriteCount
        let playlistEdits = store.playlists.playlistDraft.steps.count
        let run = runState()
        updateStopped(run: run)
        let next = ReflectionChip.make(items: count, playlistEdits: playlistEdits, writing: showsWriting, block: store.writeBlock,
                                       reason: reason(for: run))
        if next != chip { chip = next }
        let last = latestWrite()
        if last != lastWrite { lastWrite = last }
        let label = count > 0 ? String(count) : nil
        if label != shownDockLabel {
            shownDockLabel = label
            dock.show(label)
        }
    }

    private func track() {
        withObservationTracking {
            _ = store.pendingWriteCount
            _ = store.playlists.playlistDraft.steps.count
            _ = store.rekordboxWritePhase
            _ = store.hasWriteBackup
            _ = store.activityLog.entries
            _ = store.writeBlock
            _ = runState()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refresh()
                self.track()
            }
        }
    }

    /// 쓰기 대기에 붙일 이유. 꺼짐 전이 뒤 단계가 먼저고, 아니면 지금 판정이다. 모름·읽기 전은 이유가 없다
    private func reason(for run: RekordboxRunState?) -> ReflectionChip.Reason? {
        switch stopped {
        case .settling: return .rekordboxStopping
        case .highlighted: return .rekordboxStopped
        case .none:
            switch run {
            case .running: return .rekordboxRunning
            case .agentOnly: return .agentRunning
            case .stopped, .unknown, nil: return nil
            }
        }
    }

    /// 강조를 시작하거나 끝낼 수 있는 때: 쓰기 대기가 있고 아직 쓰기를 시작하지 않았다(미리 보기·확인 창도 쓰기를 시작한 것으로 본다)
    private var canHighlight: Bool {
        (store.pendingWriteCount > 0 || !store.playlists.playlistDraft.steps.isEmpty) && store.rekordboxWritePhase == .idle
    }

    /// 판정에 맞춰 꺼짐 전이 뒤 단계를 고친다. 켜짐(또는 Agent만)에서 꺼짐으로 바뀔 때만 확인 시간을 건다
    private func updateStopped(run: RekordboxRunState?) {
        switch run {
        case .running, .agentOnly:
            lastKnownRun = run
            endStopped()
        case .stopped:
            let isTransition = lastKnownRun == .running || lastKnownRun == .agentOnly
            lastKnownRun = .stopped
            if isTransition, stopped == .none, canHighlight { beginSettling() }
        case .unknown, nil:
            // 모르는 동안은 이유도 강조도 없다. 다시 알게 되면 마지막으로 안 상태와 견준다
            endStopped()
        }
        if stopped != .none, !canHighlight { endStopped() }
    }

    private func beginSettling() {
        stopped = .settling
        let settleSleep = settleSleep
        settleTask = Task { [weak self] in
            do { try await settleSleep(Self.settleDelay) } catch { return }
            guard let self, !Task.isCancelled else { return }
            finishSettling()
        }
    }

    /// 확인 시간이 끝났다. 다시 읽어도 꺼져 있으면 강조하고, 아니면 그 판정대로 보인다
    private func finishSettling() {
        settleTask = nil
        guard stopped == .settling else { return }
        stopped = runState() == .stopped && canHighlight ? .highlighted : .none
        refresh()
    }

    private func endStopped() {
        settleTask?.cancel()
        settleTask = nil
        stopped = .none
    }

    /// 쓰기가 시작되면 `writingDelay` 뒤에 「쓰는 중」을 보이고, 그 전에 끝나면 보이지 않는다
    private func updateWritingDelay(_ writing: Bool) {
        guard writing else {
            writingDelayTask?.cancel()
            writingDelayTask = nil
            showsWriting = false
            return
        }
        guard writingDelayTask == nil, !showsWriting else { return }
        let sleep = sleep
        writingDelayTask = Task { [weak self] in
            do { try await sleep(Self.writingDelay) } catch { return }
            guard let self, !Task.isCancelled, isWriting else { return }
            showsWriting = true
            writingDelayTask = nil
            refresh()
        }
    }

    /// 활동 기록의 가장 최근 쓰기 결과: 실패가 아니고 쓰기 전 백업이 딸린 결과다(취소·알림은 쓰기가 아니다)
    private func latestWrite() -> ReflectionLastWrite? {
        let entry = store.activityLog.entries.first { entry in
            guard let result = entry.result else { return false }
            return result.kind != .failure && !result.backups.isEmpty
        }
        return entry.map { ReflectionLastWrite(date: $0.date, hasBackup: store.hasWriteBackup) }
    }
}
