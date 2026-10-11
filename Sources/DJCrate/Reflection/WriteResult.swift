import DJCApplication
import DJCDomain
import Foundation
import Observation
import SwiftUI

/// 토스트가 닫힌 뒤에도 읽을 마지막 결과. 전체 문구와 백업 위치만 DJCrate 데이터 폴더에 보관한다.
struct WriteResult: Codable, Equatable {
    var kind: AppToast.Kind
    var title: String
    var text: String
    /// 경고 알림의 둘째 줄: 무엇을 쓰지 않았는지와 할 일(#147)
    var shortfall: String?
    var backups: [URL] = []
    var createdAt = Date.now

    var toast: AppToast {
        AppToast(kind: kind, title: title, detail: shortfall ?? String(ui: "전체 내용과 백업 위치는 ‘마지막 쓰기 결과…’에서 다시 볼 수 있습니다."))
    }

    /// "그리드 1곡은 쓰지 않았습니다 — 이유". 막힘 이유는 할 일까지 적은 문장이라 하나뿐이면 그대로 보이고, 여럿이면 결과 보기로 안내한다.
    static func shortfallLine(_ what: [String], reasons: [String]) -> String? {
        guard !what.isEmpty else { return nil }
        let what = what.joined(separator: " · ")
        let reasons = Set(reasons)
        // 줄 모양은 언어와 관계없고 내용만 번역한다.
        if reasons.count == 1, let reason = reasons.first { return "\(what) — \(reason)" }
        return String(ui: "\(what) — 이유와 할 일은 ‘결과 보기’에서 확인하세요")
    }

    static func written(_ report: RekordboxWriteReport, preview: RekordboxWriteReport) -> Self {
        let groups: [(WritePart, [RekordboxWriteOutcome], [RekordboxWriteOutcome])] = [
            (.cue, report.outcomes, preview.outcomes),
            (.grid, report.gridOutcomes ?? [], preview.gridOutcomes ?? []),
            (.analysis, report.analysisOutcomes ?? [], preview.analysisOutcomes ?? []),
            (.gain, report.gainOutcomes ?? [], preview.gainOutcomes ?? []),
            (.tag, report.tagOutcomes ?? [], preview.tagOutcomes ?? []),
            (.artwork, report.artworkOutcomes ?? [], preview.artworkOutcomes ?? []),
            (.merge, report.mergeOutcomes ?? [], preview.mergeOutcomes ?? []),
        ]
        var lines: [String] = [], summaries: [String] = [], skipped: [String] = [], reasons: [String] = [], count = 0
        for (part, actual, predicted) in groups {
            let written = actual.filter { $0.status == .written }.count
            if written > 0 { summaries.append(part.summary(written)) }
            let seen = Set(actual.map(\.trackUUID))
            let outcomes = actual + predicted.filter { $0.status != .written && !seen.contains($0.trackUUID) }
            let blocked = outcomes.filter { $0.status == .blocked }
            if !blocked.isEmpty { skipped.append(part.summary(blocked.count)) }
            for outcome in outcomes {
                switch outcome.status {
                case .written:
                    count += 1
                    // 그림은 무엇을 했는지(넣기·바꾸기·지우기)까지 적는다.
                    lines.append("• \(outcome.title) — " + (outcome.artwork.map { "\(part.written) · \($0.label)" } ?? part.written))
                    // 쓴 항목의 이유는 참고(경로가 예상과 달라 분석 파일을 남김)라 경고로 올리지 않는다.
                    if let reason = outcome.reason { lines.append(reason) }
                case .blocked:
                    let reason = outcome.reason ?? String(ui: "이유 없음")
                    reasons.append(reason)
                    lines.append("• \(outcome.title) — " + part.blocked(reason))
                case .unchanged: lines.append("• \(outcome.title) — " + part.unchanged)
                }
            }
        }
        // 재생 목록은 초안 전체를 넘겨 쓰므로 결과가 편집마다 하나씩 있다(쓰지 않았으면 미리 보기 결과).
        let playlists = report.playlistOutcomes ?? preview.playlistOutcomes ?? []
        let playlistWritten = playlists.filter { $0.status == .written }.count
        if playlistWritten > 0 { summaries.append(PlaylistWriteText.summary(playlistWritten)) }
        count += playlistWritten
        let playlistBlocked = playlists.filter { $0.status == .blocked }
        if !playlistBlocked.isEmpty { skipped.append(PlaylistWriteText.summary(playlistBlocked.count)) }
        reasons += playlistBlocked.map { $0.reason ?? String(ui: "이유 없음") }
        lines += playlists.map(PlaylistWriteText.result)
        // 재생 기록(#43)은 미리 보기에서 쓸 수 있던 기록만 넘겨 쓰므로 막힌 기록은 미리 보기 결과에서 가져온다(곡 초안과 같다).
        let histories = HistoryWriteText.merged(report, preview: preview)
        let historyWritten = histories.filter { $0.status == .written }.count
        if historyWritten > 0 { summaries.append(HistoryWriteText.summary(historyWritten)) }
        count += historyWritten
        let historyBlocked = histories.filter { $0.status == .blocked }
        if !historyBlocked.isEmpty { skipped.append(HistoryWriteText.summary(historyBlocked.count)) }
        reasons += historyBlocked.map { $0.reason ?? String(ui: "이유 없음") }
        lines += histories.map(HistoryWriteText.result)
        return Self(kind: !skipped.isEmpty || count == 0 ? .warning : .success,
                    title: count == 0 ? String(ui: "rekordbox에 쓴 것이 없습니다")
                        : String(ui: "rekordbox에 썼습니다 · \(summaries.joined(separator: " · "))"),
                    text: lines.joined(separator: "\n"),
                    shortfall: skipped.isEmpty ? nil : shortfallLine([String(ui: "\(skipped.joined(separator: " · "))은 쓰지 않았습니다")], reasons: reasons),
                    backups: report.backup.map { [URL(filePath: $0)] } ?? [])
    }

    /// 쓰기·복원은 끝났지만 뒤따른 일(초안 정리·다시 읽기·복원 충돌)에 남은 경고를 결과와 나눠 덧붙인다(#175).
    func followedUp(_ notes: [String]) -> Self {
        guard !notes.isEmpty else { return self }
        var result = self
        result.kind = .warning
        result.shortfall = ([shortfall].compactMap { $0 } + notes).joined(separator: "\n")
        result.text = ([text] + notes.map { "• \($0)" }).joined(separator: "\n")
        return result
    }

    static func tracks(_ report: RekordboxTrackWriteReport, preview: RekordboxTrackWriteReport,
                       adding: Bool, withoutAnalysis: [String: String] = [:], unreadable: [String] = []) -> Self {
        let actual = adding ? report.added : report.deleted
        let predicted = adding ? preview.added : preview.deleted
        let seen = Set(actual.map(\.path))
        let outcomes = actual + predicted.filter { !$0.written && !seen.contains($0.path) }
        // 할 일이 남은 것만 경고다: 넣지(빼지) 않은 곡, 분석 없이 넣은 곡, 쓰지 않은 큐·키
        var notDone = unreadable, unanalyzed = 0, cueReasons: [String] = [], keyReasons: [String] = []
        var lines = outcomes.map { outcome in
            var parts: [String] = []
            if outcome.written {
                parts.append(adding ? String(ui: "넣기 완료") : String(ui: "빼기 완료"))
                // 쓴 곡의 이유는 참고(경로가 예상과 달라 분석 파일을 남김)다.
                if let reason = outcome.reason { parts.append(reason) }
                if adding, let reason = withoutAnalysis[outcome.path] {
                    unanalyzed += 1
                    parts.append(String(ui: "분석 없이 넣음(\(reason)): rekordbox에서 분석하세요"))
                }
                if let count = outcome.cuesWritten { parts.append(String(ui: "큐 \(count)개")) }
                if let reason = outcome.cueReason {
                    cueReasons.append(reason)
                    parts.append(String(ui: "큐는 쓰기 대기: \(reason)"))
                }
                if let key = outcome.keyWritten { parts.append(String(ui: "키 \(key)")) }
                if let reason = outcome.keyReason {
                    keyReasons.append(reason)
                    parts.append(String(ui: "키는 쓰기 대기: \(reason)"))
                }
            } else {
                let reason = outcome.reason ?? String(ui: "이유 없음")
                notDone.append(reason)
                parts.append(adding ? String(ui: "넣지 않음: \(reason)") : String(ui: "빼지 않음: \(reason)"))
            }
            return "• \(outcome.title) — " + parts.joined(separator: " · ")
        }
        lines += unreadable.map { "• " + String(ui: "넣지 않음: \($0)") }
        var what: [String] = [], reasons = notDone + cueReasons + keyReasons
        if !notDone.isEmpty {
            what.append(adding ? String(ui: "\(notDone.count)곡은 넣지 않았습니다") : String(ui: "\(notDone.count)곡은 빼지 않았습니다"))
        }
        if unanalyzed > 0 {
            what.append(String(ui: "\(unanalyzed)곡은 분석 없이 넣었습니다"))
            reasons.append(String(ui: "rekordbox에서 분석하세요"))
        }
        if !cueReasons.isEmpty { what.append(String(ui: "\(cueReasons.count)곡의 큐는 쓰지 않았습니다")) }
        if !keyReasons.isEmpty { what.append(String(ui: "\(keyReasons.count)곡의 키는 쓰지 않았습니다")) }
        let count = actual.filter(\.written).count
        return Self(kind: !what.isEmpty || count == 0 ? .warning : .success,
                    title: count == 0 ? (adding ? String(ui: "rekordbox에 넣은 곡이 없습니다") : String(ui: "rekordbox에서 뺀 곡이 없습니다"))
                        : adding ? String(ui: "rekordbox에 \(count)곡을 넣었습니다") : String(ui: "rekordbox에서 \(count)곡을 뺐습니다"),
                    text: lines.joined(separator: "\n"), shortfall: shortfallLine(what, reasons: reasons),
                    backups: report.backup.map { [URL(filePath: $0)] } ?? [])
    }

    /// - Parameter fileWarning: 복원 직전 백업에 남은 참고 경고(반영 세션이 백업 폴더에서 읽는다)
    static func restored(_ backup: RekordboxWriteBackup, saved: URL, fileWarning: String? = nil) -> Self {
        let report = backup.report
        let outcomes: [RekordboxWriteOutcome] = (report?.written ?? []) + (report?.gridWritten ?? []) + (report?.gainWritten ?? [])
            + (report?.analysisWritten ?? []) + (report?.tagWritten ?? []) + (report?.artworkWritten ?? []) + (report?.mergeWritten ?? [])
        // 그때 쓴 재생 기록은 rekordbox에서 사라져 다시 쓰기 대기에 오른다(#43)
        let names: [String] = (report?.playlistWritten ?? []).map(\.name) + (report?.historyWritten ?? []).map(\.name)
            + (backup.trackReport?.titles ?? [])
        let titles = Set(outcomes.map(\.title) + names)
        var lines = [String(ui: "rekordbox 라이브러리 전체를 선택한 백업의 쓰기 전 상태로 복원했습니다."),
                     String(ui: "그때 쓴 초안과 추가 목록도 복원했습니다. 복원 직전 상태는 아래 두 번째 백업에 남아 있습니다.")]
        lines += titles.sorted().map { "• \($0)" }
        // 경로가 예상과 달라 남긴 분석 파일은 참고로 적는다(복원은 끝났다).
        if let fileWarning { lines.append(fileWarning) }
        return Self(kind: .success, title: String(ui: "rekordbox를 쓰기 전으로 복원했습니다"), text: lines.joined(separator: "\n"), backups: [backup.url, saved])
    }
}

@MainActor
@Observable
final class WriteResultHistory {
    private(set) var latest: WriteResult?
    private(set) var storageError: String?
    private let url: URL?

    /// nil은 시험용 메모리 저장소다.
    init(url: URL? = nil) {
        self.url = url
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        do { latest = try JSONDecoder().decode(WriteResult.self, from: Data(contentsOf: url)) }
        catch { storageError = String(ui: "지난 결과를 읽지 못했습니다. DJCrate 데이터 폴더의 읽기 권한을 확인하세요: \(error.localizedDescription)") }
    }

    func record(_ result: WriteResult) {
        latest = result
        guard let url else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(result).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            storageError = nil
        } catch {
            storageError = String(ui: "결과를 파일에 보관하지 못했습니다. 앱을 닫기 전에 내용을 복사하고 DJCrate 데이터 폴더의 쓰기 권한을 확인하세요: \(error.localizedDescription)")
        }
    }
}

struct WriteResultView: View {
    let history: WriteResultHistory
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(.ui("마지막 쓰기 결과")).font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let error = history.storageError { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                    if let result = history.latest {
                        Label(result.title, systemImage: result.kind.icon).font(.headline).foregroundStyle(result.kind.tint)
                        Text(result.createdAt.formatted(date: .abbreviated, time: .standard)).foregroundStyle(.secondary)
                        Text(result.text).frame(maxWidth: .infinity, alignment: .leading)
                        Text(.ui("백업 위치")).font(.headline)
                        if result.backups.isEmpty { Text(.ui("이 결과에 연결된 백업이 없습니다.")).foregroundStyle(.secondary) }
                        ForEach(result.backups, id: \.self) { url in
                            Text(url.path).font(.callout.monospaced())
                            Button(.ui("Finder에서 백업 보기")) { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path) }
                                .disabled(!FileManager.default.fileExists(atPath: url.path))
                        }
                        if !result.backups.isEmpty { Text(.ui("정리되거나 이동한 백업은 열 수 없습니다.")).font(.caption).foregroundStyle(.secondary) }
                    } else { Text(.ui("아직 보관한 쓰기 결과가 없습니다.")) }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Spacer(); Button(.ui("닫기")) { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(24)
        .frame(width: 660, height: 500)
    }
}
