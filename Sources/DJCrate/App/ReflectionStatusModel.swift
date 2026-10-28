import DJCApplication
import DJCDomain
import Foundation
import Observation
import SwiftUI

/// 상태 줄 쓰기 상태 칩이 보이는 상태 하나(#324). 칩의 글자·모양은 이 값만 보고 정한다.
/// rekordbox 켜짐·꺼짐 이유(#326)와 쓸 수 없음(#327)은 경우를 더해 같은 모델에 잇는다.
enum ReflectionChip: Equatable {
    /// 쓸 것이 없다
    case clean
    /// 쓰기 대기. 수는 사이드바 「rekordbox 쓰기 대기」 배지와 같은 정의(`LibraryStore.pendingWriteCount`, 곡과 쓰기 대기 재생 기록)라 단위는 「건」이다
    case pending(items: Int, playlistEdits: Int)
    /// rekordbox에 쓰는 중. 쓰기가 짧게 끝나면 깜빡이지 않게 1초가 지난 뒤에만 보인다
    case writing

    /// 곡과 재생 목록 편집 수로 상태를 정한다. 쓰는 중이면 대기 수와 관계없이 쓰는 중이다
    static func make(items: Int, playlistEdits: Int, writing: Bool) -> Self {
        if writing { return .writing }
        return items > 0 || playlistEdits > 0 ? .pending(items: items, playlistEdits: playlistEdits) : .clean
    }

    var title: String {
        switch self {
        case .clean: String(ui: "쓰기 대기 없음")
        case let .pending(items, playlistEdits): items > 0 ? String(ui: "쓰기 대기 \(items)건") : String(ui: "재생 목록 편집 \(playlistEdits)건")
        case .writing: String(ui: "rekordbox에 쓰는 중…")
        }
    }

    var isPending: Bool {
        if case .pending = self { return true }
        return false
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

/// 창 아래 상태 줄의 rekordbox 쓰기 상태 화면 모델(#324): 칩(쓰기 대기 없음·쓰기 대기 N곡·재생 목록 편집 N건·쓰는 중), 보조 글(마지막 쓰기),
/// 상태 팝오버의 단추, Dock 배지. 저장소의 쓰기 대기 수·재생 목록 초안·쓰기 중·활동 기록을 관찰해 스스로 고친다. 뷰는 읽기만 한다.
/// 새 쓰기 경로는 없다. 팝오버 단추와 [쓰기]는 메뉴 막대와 같은 `LibraryMenuAction`을 같은 조건으로 부른다.
/// 조립 지점(`AppComposition.writeStatus`)이 한 번 만든다.
@MainActor
@Observable
final class ReflectionStatusModel {
    /// 쓰기가 이만큼 이어질 때만 「쓰는 중」을 보인다
    static let writingDelay: Duration = .seconds(1)
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
    /// 「쓰는 중」을 늦추는 기다림. 시험이 바꿔 끼운다
    @ObservationIgnored var sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var showsWriting = false
    @ObservationIgnored private var writingDelayTask: Task<Void, Never>?
    @ObservationIgnored private var shownDockLabel: String?
    @ObservationIgnored private var isObserving = false

    /// - Parameters:
    ///   - window: 메뉴 막대와 같은 명령을 보고 부르는 주 창 모델
    ///   - windows: 창을 여는 명령(시점 스냅샷)이 쓸 앱 창. 팝오버에는 그런 명령이 없어 nil이어도 된다
    ///   - reflection: 쓰기·복원 명령이 부를 화면 쪽. nil이면 그 명령은 아무것도 하지 않는다(`LibraryMenuAction.perform`과 같다)
    init(store: LibraryStore, window: LibraryWindowModel, windows: AppWindows?, reflection: ReflectionCoordinator?,
         dock: DockBadge = .none, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.store = store
        self.window = window
        self.windows = windows
        self.reflection = reflection
        self.dock = dock
        self.sleep = sleep
    }

    // MARK: - 읽는 값

    /// 칩 옆 보조 글. 마지막 쓰기가 없으면 nil(숨긴다)
    var lastWriteText: String? { lastWrite?.text() }

    /// 곡 대기와 재생 목록 편집이 함께 있으면 팝오버가 편집 건수를 덧붙인다
    var extraLine: String? {
        guard case let .pending(items, playlistEdits) = chip, items > 0, playlistEdits > 0 else { return nil }
        return String(ui: "재생 목록 편집 \(playlistEdits)건")
    }

    /// 실제로 쓰는 중인가: 백업·DB·분석 파일을 쓰는 단계와 쓴 뒤 다시 읽는 단계. 잠금만 걸린 미리 보기·확인 창(아직 쓰지 않았다)은 뺀다(#301)
    private var isWriting: Bool {
        let phase = store.rekordboxWritePhase
        return phase == .writing || phase == .readingBack
    }

    /// 칩 옆 [쓰기] 단추를 보일 때: 쓰기 대기가 있을 때
    var showsWriteButton: Bool { chip.isPending }

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
        let next = ReflectionChip.make(items: count, playlistEdits: store.playlists.playlistDraft.steps.count, writing: showsWriting)
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
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refresh()
                self.track()
            }
        }
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
