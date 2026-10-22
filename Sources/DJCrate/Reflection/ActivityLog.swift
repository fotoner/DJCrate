import DJCDomain
import Foundation
import Observation

/// 활동 기록 한 줄: 창 알림 하나와 그 자세한 내용. 쓰기 결과면 결과(전체 문구·백업 위치)를 함께 둔다.
struct ActivityEntry: Codable, Equatable, Identifiable {
    var id = UUID()
    var kind: AppToast.Kind
    var title: String
    /// 자세한 내용(쓰기 결과는 곡마다의 전체 결과)
    var detail: String?
    /// 쓰기 결과. 쓰기 결과가 아닌 알림은 nil
    var result: WriteResult?
    /// 마지막으로 뜬 시각
    var date: Date
    /// 잇달아 뜬 횟수(바로 앞과 같은 알림은 합친다)
    var count = 1

    init(kind: AppToast.Kind, title: String, detail: String?, result: WriteResult? = nil, date: Date) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.result = result
        self.date = date
    }

    init(_ result: WriteResult, date: Date) {
        self.init(kind: result.kind, title: result.title, detail: result.text, result: result, date: date)
    }

    /// 바로 앞 항목과 같은 알림인지. 쓰기 결과는 백업까지 같아야 한다(다른 쓰기의 백업 위치를 잃지 않게).
    func repeats(_ other: Self) -> Bool {
        kind == other.kind && title == other.title && detail == other.detail && result?.backups == other.result?.backups
    }
}

/// 창 알림의 기록(#296). 알림이 닫힌 뒤에도 최근 알림과 쓰기 결과를 다시 본다. 전체 문구와 백업 위치만 DJCrate 데이터 폴더에 보관한다.
/// 창 알림은 `LibraryStore.showToast`가 모두 여기에 남긴다. 창 없이 경고 창(NSAlert)으로 알린 쓰기 실패도 남긴다.
@MainActor
@Observable
final class ActivityLog {
    /// 남기는 최근 항목 수. 넘치면 오래된 것부터 지운다
    static let limit = 200
    /// 곡마다의 전체 문구를 그대로 두는 최근 쓰기 결과 수. 쓰기 전 백업도 최근 20개만 남아, 그보다 오래된 결과는
    /// 자세한 내용의 앞부분(`trimmedLength`자)만 둔다. 알림마다 파일 전체를 다시 쓰므로 파일이 한없이 커지지 않게 한다
    static let fullResults = 20
    static let trimmedLength = 1_000
    /// 최근 것이 앞
    private(set) var entries: [ActivityEntry] = []
    /// 지난 기록을 읽지 못함(이번 실행 동안 창에 남긴다)
    private(set) var readFailure: String?
    /// 마지막 보관이 실패함(다음 보관이 되면 지운다)
    private(set) var saveFailure: String?
    /// 창에 보일 기록 오류
    var storageError: String? { Self.joined([readFailure, saveFailure]) }
    var latest: ActivityEntry? { entries.first }
    @ObservationIgnored private let url: URL?
    @ObservationIgnored private let now: () -> Date
    /// 아직 새 파일에 옮기지 못한 옛 결과 파일(보관이 되면 지운다)
    @ObservationIgnored private var pendingLegacy: URL?
    /// 읽지 못한 기록 파일을 옆으로 옮기지 못했다. 그 파일을 덮지 않게 이번 실행 동안 보관하지 않는다
    @ObservationIgnored private var keepsUnreadable = false
    @ObservationIgnored private var readFailureAnnounced = false

    /// - Parameters:
    ///   - url: 기록 파일. nil은 시험용 메모리 저장소다.
    ///   - legacyResult: 옛 '마지막 쓰기 결과' 파일(결과 한 건). 기록 파일이 아직 없으면 그 결과를 첫 항목으로 옮기고,
    ///     새 파일에 보관한 뒤 옛 파일을 지운다. 읽지 못한 옛 파일은 지우지 않는다.
    init(url: URL? = nil, legacyResult: URL? = nil, now: @escaping () -> Date = { .now }) {
        self.url = url
        self.now = now
        guard let url else { return }
        let files = FileManager.default
        if files.fileExists(atPath: url.path) {
            do { entries = try JSONDecoder().decode([ActivityEntry].self, from: Data(contentsOf: url)) }
            catch { setAsideUnreadable(url, error: error) }
        } else if let legacyResult, files.fileExists(atPath: legacyResult.path) {
            do {
                let result = try JSONDecoder().decode(WriteResult.self, from: Data(contentsOf: legacyResult))
                entries = [ActivityEntry(result, date: result.createdAt)]
                pendingLegacy = legacyResult
                save()
            } catch {
                readFailure = String(ui: "지난 활동 기록을 읽지 못했습니다. DJCrate 데이터 폴더의 읽기 권한을 확인하세요: \(error.localizedDescription)")
            }
        }
    }

    /// 알림에 덧붙일 기록 오류. 보관하지 못한 것은 늘, 지난 기록을 읽지 못한 것은 처음 한 번만 알린다
    /// (읽지 못한 파일을 덮지 않으려고 보관을 멈췄으면 늘 알린다).
    func toastNote() -> String? {
        let read = readFailure.flatMap { !readFailureAnnounced || keepsUnreadable ? $0 : nil }
        readFailureAnnounced = true
        return Self.joined([read, saveFailure])
    }

    /// 창 알림을 남기고 그 항목(합쳤으면 합친 항목)을 돌려준다.
    @discardableResult
    func record(_ toast: AppToast) -> ActivityEntry.ID {
        append(ActivityEntry(kind: toast.kind, title: toast.title, detail: toast.detail, date: now()))
    }

    /// 쓰기 결과를 남긴다. 자세한 내용은 결과의 전체 문구다.
    @discardableResult
    func record(_ result: WriteResult) -> ActivityEntry.ID {
        append(ActivityEntry(result, date: now()))
    }

    private func append(_ entry: ActivityEntry) -> ActivityEntry.ID {
        // 창으로 돌아올 때마다 같은 안내가 쌓이지 않게 바로 앞 항목과 같으면 시각과 횟수만 고친다.
        if var last = entries.first, last.repeats(entry) {
            last.date = entry.date
            last.result = entry.result
            last.count += 1
            entries[0] = last
        } else {
            entries.insert(entry, at: 0)
            if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
            trimOldResults()
        }
        save()
        return entries[0].id
    }

    /// 최근 `fullResults`개보다 오래된 쓰기 결과는 자세한 내용과 결과 문구의 앞부분만 남긴다. 백업 위치는 그대로 둔다
    private func trimOldResults() {
        let note = String(ui: "… 오래된 결과라 앞부분만 남겼습니다.")
        func trimmed(_ text: String) -> String {
            text.count > Self.trimmedLength + note.count + 1 ? String(text.prefix(Self.trimmedLength)) + "\n" + note : text
        }
        var results = 0
        for index in entries.indices {
            guard var result = entries[index].result else { continue }
            results += 1
            guard results > Self.fullResults else { continue }
            result.text = trimmed(result.text)
            entries[index].result = result
            entries[index].detail = entries[index].detail.map(trimmed)
        }
    }

    private func save() {
        guard let url, !keepsUnreadable else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            saveFailure = nil
        } catch {
            saveFailure = String(ui: "활동 기록을 파일에 보관하지 못했습니다. 앱을 닫기 전에 내용을 복사하고 DJCrate 데이터 폴더의 쓰기 권한을 확인하세요: \(error.localizedDescription)")
            return
        }
        // 이어 받은 옛 결과는 새 파일에 들어간 뒤에만 지운다
        if let legacy = pendingLegacy {
            try? FileManager.default.removeItem(at: legacy)
            pendingLegacy = nil
        }
    }

    /// 읽지 못한 기록 파일은 지우거나 덮지 않고 옆 이름으로 옮긴 뒤 새 기록을 시작한다(`damaged-drafts`와 같은 원칙).
    /// 옮기지 못하거나 파일이 아니면(폴더 등) 그 자리를 덮지 않게 이번 실행 동안 보관하지 않는다.
    private func setAsideUnreadable(_ url: URL, error: any Error) {
        let name = "\(url.deletingPathExtension().lastPathComponent)-unreadable-\(Int(now().timeIntervalSince1970)).json"
        do {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw error }
            try FileManager.default.moveItem(at: url, to: url.deletingLastPathComponent().appending(path: name))
            readFailure = String(ui: "지난 활동 기록을 읽지 못해 ‘\(name)’ 파일로 옮겨 두고 새 기록을 시작했습니다. 지난 기록이 필요하면 DJCrate 데이터 폴더에서 그 파일을 여세요: \(error.localizedDescription)")
        } catch {
            keepsUnreadable = true
            readFailure = String(ui: "지난 활동 기록을 읽지 못해 이번 실행의 활동 기록은 파일에 보관하지 않습니다. DJCrate 데이터 폴더의 읽기·쓰기 권한을 확인한 뒤 앱을 다시 켜세요: \(error.localizedDescription)")
        }
    }

    private static func joined(_ notes: [String?]) -> String? {
        let notes = notes.compactMap { $0 }
        return notes.isEmpty ? nil : notes.joined(separator: "\n")
    }
}
