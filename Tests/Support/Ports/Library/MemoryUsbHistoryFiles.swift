import DJCApplication
import DJCDomain
import Foundation
import Synchronization
import Testing

/// 보존한 기기 재생 기록 파일의 메모리 구현(`UsbHistoryFiles`, #43). 실제(`UsbHistoryFiles.live`)와 같은 약속인지는 `usbHistoryFilesContract`가 본다.
/// 실패를 만들 수 있다: `failing`에 든 ID는 저장 전에 던지고(파일 없음), `failingAfterWrite`에 든 ID는 저장한 뒤 던진다
/// (실제의 rename 뒤 폴더 fsync 실패와 같다: 파일 내용은 이 기록이다)
public final class MemoryUsbHistoryFiles: Sendable {
    public struct Failure: Error, Equatable {}

    private struct State {
        var stored: [String: ArchivedHistory] = [:]
        var failing: Set<String> = []
        var failingAfterWrite: Set<String> = []
        var damaged: [String] = []
        var unreadable: [String] = []
        var saves: [String] = []
    }

    private let state: Mutex<State>

    public init(_ histories: [ArchivedHistory] = []) {
        state = Mutex(State(stored: Dictionary(histories.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })))
    }

    /// 저장된 기록(가져온 차례)
    public var histories: [ArchivedHistory] { state.withLock { Self.ordered($0.stored) } }
    /// 저장을 부른 기록 ID(차례대로, 실패 포함)
    public var saves: [String] { state.withLock { $0.saves } }

    public func fail(_ ids: Set<String>, afterWrite: Bool = false) {
        state.withLock { afterWrite ? ($0.failingAfterWrite = ids) : ($0.failing = ids) }
    }

    /// 다음 읽기에 알릴 옮긴 파일·읽지 못한 파일
    public func report(damaged: [String] = [], unreadable: [String] = []) {
        state.withLock {
            $0.damaged = damaged
            $0.unreadable = unreadable
        }
    }

    public var files: UsbHistoryFiles {
        UsbHistoryFiles(
            load: {
                self.state.withLock { ArchivedHistoryLoad(histories: Self.ordered($0.stored), damaged: $0.damaged, unreadable: $0.unreadable) }
            },
            save: { history in
                try self.state.withLock { state in
                    state.saves.append(history.id)
                    guard Self.isSafe(history.id) else { throw Failure() }
                    if state.failing.contains(history.id) { throw Failure() }
                    // 실제 저장 모양처럼 초 아래를 버린다
                    var stored = history
                    stored.importedAt = Date(timeIntervalSince1970: history.importedAt.timeIntervalSince1970.rounded(.down))
                    state.stored[history.id] = stored
                    if state.failingAfterWrite.contains(history.id) { throw Failure() }
                }
            },
            containsExact: { history in
                self.state.withLock { state in
                    var expected = history
                    expected.importedAt = Date(timeIntervalSince1970: history.importedAt.timeIntervalSince1970.rounded(.down))
                    return state.stored[history.id] == expected
                }
            })
    }

    private static func ordered(_ stored: [String: ArchivedHistory]) -> [ArchivedHistory] {
        stored.values.sorted { ($0.importedAt, $0.sequence, $0.id) < ($1.importedAt, $1.sequence, $1.id) }
    }

    /// 실제 저장과 같은 ID 규칙: 접두사 + 영숫자·'-'
    private static func isSafe(_ id: String) -> Bool {
        id.hasPrefix(ArchivedHistory.idPrefix) && id.count > ArchivedHistory.idPrefix.count
            && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
}

/// 보존 기록 파일(`UsbHistoryFiles`, #43): 처음엔 비어 있고, 저장한 기록을 같게 읽으며(초 아래는 버린다), 같은 ID는 덮어쓰고,
/// 가져온 차례(가져온 시각·차례·ID)로 읽는다. 저장할 수 없는 ID는 아무것도 쓰지 않고 던진다. 저장한 내용 확인(`containsExact`)은 같은 내용일 때만 참이다
public func usbHistoryFilesContract(_ files: UsbHistoryFiles) throws {
    #expect(files.load() == ArchivedHistoryLoad())
    func history(_ key: String, sequence: Int, at seconds: TimeInterval, name: String = "HISTORY 2026-09-21") -> ArchivedHistory {
        ArchivedHistory(id: ArchivedHistory.idPrefix + key, name: name, importedAt: Date(timeIntervalSince1970: seconds), sequence: sequence,
                        source: .init(volumeKey: "SYNTH", volumeName: "합성 USB", format: "oneLibrary", historyID: sequence,
                                      historyName: "HISTORY \(sequence)"),
                        entries: [.init(trackNumber: 1, usbContentID: 1, contentID: "101", title: "합성 곡", artist: nil, path: "/Contents/a.mp3",
                                        masterDbId: 1, masterContentId: 11, fileName: "a.mp3")])
    }
    let later = history("b", sequence: 1, at: 1_790_000_100)
    let earlier = history("a", sequence: 2, at: 1_790_000_000)
    try files.save(later)
    try files.save(earlier)
    #expect(files.load().histories == [earlier, later])
    #expect(files.containsExact(earlier))

    // 같은 ID는 덮어쓴다
    var renamed = earlier
    renamed.name = "HISTORY 2026-09-21 (2)"
    renamed.excludedFromRekordbox = true
    #expect(!files.containsExact(renamed))
    try files.save(renamed)
    #expect(files.load().histories == [renamed, later])
    #expect(files.containsExact(renamed) && !files.containsExact(earlier))

    // 초 아래는 저장 모양에서 버린다(같은 기록으로 본다)
    var fraction = history("c", sequence: 3, at: 1_790_000_200)
    fraction.importedAt = Date(timeIntervalSince1970: 1_790_000_200.4)
    try files.save(fraction)
    #expect(files.containsExact(fraction))
    #expect(files.load().histories.last?.importedAt == Date(timeIntervalSince1970: 1_790_000_200))

    // 저장할 수 없는 ID
    var unsafe = history("x", sequence: 4, at: 1_790_000_300)
    unsafe.id = "../escape"
    #expect(throws: (any Error).self) { try files.save(unsafe) }
    #expect(!files.containsExact(unsafe))
    #expect(files.load().histories.map(\.id) == [renamed.id, later.id, fraction.id])
}
