import DJCDomain
import Foundation

/// 확인 창 제목에 보이는 종류별 수("큐 3곡", "재생 목록 2건")
public enum WriteCount: Equatable, Sendable {
    case part(WritePart, Int)
    case playlists(Int)

    public var summary: String {
        switch self {
        case let .part(part, count): part.summary(count)
        case let .playlists(count): PlaylistWriteText.summary(count)
        }
    }
}

/// 넣는 곡 가운데 빠지는 것이 있는 곡 한 줄(분석 없이 넣음, 큐·키가 안 들어감)
public struct TrackAddShortfall: Equatable, Sendable {
    public var title: String
    /// 분석 없이 넣는 이유(nil이면 그리드·파형·오토게인까지)
    public var withoutAnalysis: String?
    /// 앨범아트도 함께 넣는다
    public var artwork: Bool
    /// 함께 넣는 큐 수(0이면 nil)
    public var cues: Int?
    public var cueReason: String?
    public var key: String?
    public var keyReason: String?

    var line: String {
        var parts = [withoutAnalysis.map { String(ui: "분석 없이(\($0))") } ?? String(ui: "그리드·파형·오토게인까지")]
        if artwork { parts.append(String(ui: "앨범아트")) }
        if let cues { parts.append(String(ui: "큐 \(cues)개")) }
        if let cueReason { parts.append(String(ui: "⚠︎ 큐는 안 들어감(\(cueReason))")) }
        if let key { parts.append(String(ui: "키 \(key)")) }
        if let keyReason { parts.append(String(ui: "⚠︎ 키는 안 들어감(\(keyReason))")) }
        return "• \(title) — " + parts.joined(separator: " · ")
    }
}

/// 넣기 확인 창 끝에 붙는 안내
public enum TrackAddNote: Equatable, Sendable {
    /// 분석 없이 넣는 곡은 rekordbox에서 분석해야 한다(`artwork`: 그 가운데 아트워크가 든 곡이 있다)
    case analyseLater(artwork: Bool)
    /// 아트워크 쓰기가 닫혀 있는데 분석까지 붙이는 곡에 아트워크가 있다
    case artworkClosed
    /// 분석 없이 넣으며 키도 쓰는 곡이 있다
    case bareKey

    var text: String {
        switch self {
        case .analyseLater(artwork: true): String(ui: "분석 없이 넣는 곡은 rekordbox에서 분석해야 파형·그리드·앨범아트가 생깁니다.")
        case .analyseLater(artwork: false): String(ui: "분석 없이 넣는 곡은 rekordbox에서 분석해야 파형·그리드가 생깁니다.")
        case .artworkClosed: ReflectionPrompts.artworkClosedNote
        case .bareKey: ReflectionPrompts.bareKeyNote
        }
    }
}

/// 넣기 확인 창의 빠지는 것: 곡 줄과 안내
public struct TrackAddShortfalls: Equatable, Sendable {
    public var tracks: [TrackAddShortfall]
    public var notes: [TrackAddNote]
}

/// 복원 확인 창의 안내(백업 날짜와 끝 안내 사이)
public enum RestoreNotice: Equatable, Sendable {
    /// 곡 넣기·빼기 백업: 넣었던 곡은 추가 목록으로, 뺐던 곡은 컬렉션으로 돌아온다
    case tracks(added: Int, deleted: Int)
    /// 초안 쓰기 백업: 그때 쓴 초안도 DJCrate에 복원한다
    case drafts
    /// 이 백업 뒤에 뜬 백업 수(그 쓰기·복원이 바꾼 분석 파일도 함께 되돌린다, #222)
    case laterBackups(Int)
    /// 백업 뒤 rekordbox에서도 라이브러리가 바뀌었다
    case changed
    /// 백업 뒤 바뀌었는지 확인하지 못했다
    case unknownChanges
    /// 쓴 뒤 새로 만든 초안이 백업의 초안과 다른 곡 수
    case conflicts(Int)

    var text: String {
        switch self {
        case let .tracks(added, deleted):
            // 문장마다 번역하고, 문장 뒤 빈칸은 원래 모양 그대로 둔다.
            var sentences = [String(ui: "라이브러리 전체를 이 백업으로 복원합니다.")]
            if added > 0 { sentences.append(String(ui: "넣었던 \(added)곡은 컬렉션에서 빠지고 DJCrate 추가 목록으로 돌아옵니다(분석·앨범아트 파일도 삭제).")) }
            if deleted > 0 { sentences.append(String(ui: "뺐던 \(deleted)곡은 큐·재생 목록·분석 파일·앨범아트와 함께 복원됩니다.")) }
            return sentences.map { $0 + " " }.joined()
        case .drafts:
            return String(ui: "라이브러리 전체를 이 백업으로 복원합니다. 그때 쓴 초안(큐·그리드·게인·태그·앨범아트)도 DJCrate에 복원됩니다.")
        case let .laterBackups(later):
            return String(ui: "이 백업 뒤에 DJCrate가 쓰거나 복원한 \(later)번도 분석 파일까지 함께 되돌립니다. 그 쓰기의 초안은 되살리지 않습니다.")
        case .changed:
            return String(ui: "⚠︎ 이 백업 뒤에 rekordbox에서도 라이브러리가 바뀌었습니다(큐·재생 목록·곡 추가 등). 복원하면 그 변경도 함께 사라집니다.")
        case .unknownChanges:
            return String(ui: "백업 뒤 rekordbox에서 바뀐 것이 있는지 확인하지 못했습니다. 그 뒤 rekordbox에서 한 변경은 함께 사라집니다.")
        case let .conflicts(count):
            return String(ui: "\(count)곡은 쓴 뒤 새로 만든 초안이 백업의 초안과 다릅니다. 지금 초안을 남기면 그 곡의 백업 초안은 되살리지 않고, 백업 초안으로 바꾸면 지금 초안이 사라집니다.")
        }
    }
}

/// 반영(쓰기·넣기·빼기·복원) 확인 창과 알림의 문구. 무엇을 보일지는 코드(`WriteCount`·`TrackAddNote`·`RestoreNotice`)로 먼저 정하고 문장으로 옮긴다.
public enum ReflectionPrompts {
    public static var quitRekordboxText: String {
        String(ui: "rekordbox를 완전히 종료한 뒤 다시 누르세요. DJCrate는 rekordbox가 켜져 있는 동안에는 rekordbox 라이브러리에 절대 쓰지 않습니다.")
    }

    /// 확인 창이 쓰는 백업 안내(쓰기·넣기·빼기 공통)
    static var backupThenWriteText: String {
        String(ui: "백업한 뒤 쓰고 다시 확인합니다. 끝날 때까지 rekordbox를 켜지 마세요.")
    }

    /// 쓰기 전 백업 폴더에 쓸 수 없을 때의 줄
    public static var noBackupText: String {
        String(ui: "쓰기 전 백업을 만들 폴더에 쓸 수 없어 쓰기가 막힐 수 있으니 DJCrate 데이터 폴더의 쓰기 권한을 확인하세요.")
    }

    /// 분석 없이 넣으며 키도 쓰는 곡의 안내
    public static var bareKeyNote: String {
        String(ui: "분석 없이 넣으며 키를 함께 쓴 곡은 DJCrate가 나중에 분석을 붙이지 않으니 rekordbox에서 분석하세요.")
    }

    /// 아트워크 쓰기가 닫혀 있을 때(`RekordboxTrackWriter.writesArtwork`) 음원에 아트워크가 든 곡을 넣으면 보이는 안내
    public static var artworkClosedNote: String {
        String(ui: "음원의 앨범아트는 아직 넣지 않으니, 필요하면 rekordbox 곡 정보 창에서 이미지를 끌어다 붙이세요.")
    }

    public static func skippedHeader(_ count: Int) -> String { String(ui: "쓰지 않는 것 \(count):") }
    public static func notAddedHeader(_ count: Int) -> String { String(ui: "넣지 않는 곡 \(count):") }
    public static func notDeletedHeader(_ count: Int) -> String { String(ui: "빼지 않는 곡 \(count):") }

    /// 이유 줄 목록을 토스트 한 줄로: 앞 둘과 "외 N건"
    public static func summaryLine(_ lines: [String], prefix: String? = nil, limit: Int = 2) -> String? {
        guard !lines.isEmpty else { return nil }
        var text = lines.prefix(limit).map { $0.hasPrefix("• ") ? String($0.dropFirst(2)) : $0 }.joined(separator: ", ")
        if lines.count > limit { text += " " + String(ui: "외 \(lines.count - limit)건") }
        return prefix.map { "\($0) \(lines.count): \(text)" } ?? text
    }

    /// 쓰기 확인도 자동 복원도 실패했을 때의 경고(상태를 알 수 없음 + 할 일). 그 밖의 오류면 nil.
    /// 반영·넣기·빼기 모두 '반영 대기' 목록의 '되돌리기…'(가장 최근 쓰기 백업으로 되돌림)를 안내한다.
    /// 툴바의 '마지막 반영 되돌리기…'는 쓰기가 성공했을 때만 활성화된다.
    public static func restoreFailureAlert(_ error: any Error) -> ReflectionPrompt? {
        guard case let DJCError.restoreFailed(_, _, backup, database) = error else { return nil }
        let command = DJCError.restoreCommand(backup: backup, database: database)
        let text = [
            String(ui: "rekordbox 라이브러리(master.db)와 분석 파일이 어떤 상태인지 알 수 없습니다. rekordbox를 켜지 말고, 사이드바에서 'rekordbox 쓰기 대기'를 고른 뒤 목록 위 '쓰기 전으로 복원…'으로 백업을 복원하세요."),
            String(ui: "터미널에서는: \(command)"),
        ]
        return ReflectionPrompt(title: String(ui: "쓰기 확인에 실패했고 자동 복원도 하지 못했습니다"), text: text.joined(separator: "\n\n"), critical: true)
    }

    // MARK: - 쓰기

    public static func reasons(_ report: RekordboxWriteReport) -> [String] {
        (report.blocked + report.gridBlocked + report.analysisBlocked + report.gainBlocked + report.tagBlocked + report.artworkBlocked
            + report.mergeBlocked).map { "• \($0.title): \($0.reason ?? "")" }
            + report.playlistBlocked.map(PlaylistWriteText.reason)
    }

    /// 쓰는 종류별 곡 수(확인 창 제목의 순서)
    public static func writeCounts(_ report: RekordboxWriteReport) -> [WriteCount] {
        let parts: [(WritePart, [RekordboxWriteOutcome])] = [
            (.cue, report.written), (.grid, report.gridWritten), (.analysis, report.analysisWritten), (.gain, report.gainWritten),
            (.tag, report.tagWritten), (.artwork, report.artworkWritten), (.merge, report.mergeWritten),
        ]
        return parts.filter { !$0.1.isEmpty }.map { .part($0.0, $0.1.count) }
            + (report.playlistWritten.isEmpty ? [] : [.playlists(report.playlistWritten.count)])
    }

    /// 쓰기 전 확인 창(#210): 막힘·제외·손실이 있거나 백업을 만들 수 없을 때만 뜬다(`WriteConfirmPolicy`).
    /// 제목에 종류별 곡 수를 두고, 목록에는 묻는 이유가 되는 항목(합치기·쓰지 않는 것·백업)만 보인다. 곡마다의 결과는 쓰기 결과 창에 남는다.
    public static func confirmation(_ report: RekordboxWriteReport, exclusions: [String] = [], canBackUp: Bool = true) -> ReflectionPrompt {
        var sections: [[String]] = []
        if !report.mergeWritten.isEmpty {
            sections.append(report.mergeWritten.map { String(ui: "• \($0.title) 유지 · 중복 \($0.removed)곡을 컬렉션에서 뺍니다") }
                + report.mergeWritten.compactMap(\.reason) + ["", DuplicateMerge.lossNotice])
        }
        let reasons = reasons(report) + exclusions
        if !reasons.isEmpty { sections.append([skippedHeader(reasons.count)] + reasons) }
        if !canBackUp { sections.append([noBackupText]) }
        return ReflectionPrompt(title: String(ui: "\(writeCounts(report).map(\.summary).joined(separator: " · "))을 rekordbox에 쓸까요?"),
                                text: backupThenWriteText,
                                confirm: String(ui: "rekordbox에 쓰기"), destructive: !report.mergeWritten.isEmpty,
                                details: Array(sections.joined(separator: [""])))
    }

    // MARK: - 넣기·빼기

    public static func addReasons(_ preview: TrackAddPreview) -> [String] {
        preview.report.added.filter { !$0.written }.map { "• \($0.title): \($0.reason ?? "")" } + preview.unreadable.map { "• \($0)" }
    }

    /// 넣는 곡 가운데 빠지는 것이 있는 곡(분석 없이 넣음, 큐·키가 안 들어감)과 그 안내(#210).
    /// 비어 있으면 넣기는 묻지 않는다. 아트워크는 분석까지 붙이는 곡에만 넣는다(rekordbox도 분석할 때 뽑는다, 2026-09-26 실험).
    public static func addShortfallItems(_ preview: TrackAddPreview, writesArtwork: Bool) -> TrackAddShortfalls {
        let written = preview.report.added.filter(\.written)
        let artwork = Set(preview.plans.filter { $0.artwork != nil }.map(\.path))
        let bare = written.filter { preview.withoutAnalysis[$0.path] != nil }
        let analysedArtwork = written.filter { preview.withoutAnalysis[$0.path] == nil && artwork.contains($0.path) }
        let tracks = written.filter { preview.withoutAnalysis[$0.path] != nil || $0.cueReason != nil || $0.keyReason != nil }.map { outcome in
            TrackAddShortfall(title: outcome.title, withoutAnalysis: preview.withoutAnalysis[outcome.path],
                              artwork: writesArtwork && analysedArtwork.contains(outcome),
                              cues: outcome.cuesWritten.flatMap { $0 > 0 ? $0 : nil }, cueReason: outcome.cueReason,
                              key: outcome.keyWritten, keyReason: outcome.keyReason)
        }
        var notes: [TrackAddNote] = []
        if !bare.isEmpty { notes.append(.analyseLater(artwork: bare.contains { artwork.contains($0.path) })) }
        if !writesArtwork, !analysedArtwork.isEmpty { notes.append(.artworkClosed) }
        // 키를 쓰면 곡 정보 변경 횟수가 생겨, 분석 없이 넣은 곡에는 DJCrate가 나중에 분석을 붙이지 않는다(카운터 있는 분석 전 곡은 미확인).
        if bare.contains(where: { $0.keyWritten != nil }) { notes.append(.bareKey) }
        return TrackAddShortfalls(tracks: tracks, notes: notes)
    }

    /// `addShortfallItems`를 확인 창 줄로(곡 줄, 빈 줄과 안내)
    public static func addShortfalls(_ preview: TrackAddPreview, writesArtwork: Bool) -> [String] {
        let items = addShortfallItems(preview, writesArtwork: writesArtwork)
        let body = items.tracks.map(\.line) + items.notes.flatMap { ["", $0.text] }
        return body.first == "" ? Array(body.dropFirst()) : body
    }

    /// 넣기 전 확인 창(#210): 빠지는 것(`addShortfalls`)·넣지 않는 곡이 있거나 백업을 만들 수 없을 때만 뜨고, 그 줄만 보인다.
    /// - Parameter writesArtwork: 분석까지 붙여 넣는 곡에 아트워크 파일도 만드는지(반영 세션 옵션, `RekordboxTrackWriter.writesArtwork`)
    public static func addConfirmation(_ preview: TrackAddPreview, writesArtwork: Bool, canBackUp: Bool = true) -> ReflectionPrompt {
        let written = preview.report.added.filter(\.written)
        var sections: [[String]] = []
        let shortfalls = addShortfalls(preview, writesArtwork: writesArtwork)
        if !shortfalls.isEmpty { sections.append(shortfalls) }
        let reasons = addReasons(preview)
        if !reasons.isEmpty { sections.append([notAddedHeader(reasons.count)] + reasons) }
        if !canBackUp { sections.append([noBackupText]) }
        return ReflectionPrompt(title: String(ui: "\(written.count)곡을 rekordbox에 넣을까요?"),
                                text: backupThenWriteText,
                                confirm: String(ui: "rekordbox에 넣기"), details: Array(sections.joined(separator: [""])))
    }

    /// 빼기 전 확인 창(경고): 뺄 곡, 빼지 않는 곡과 이유, 함께 사라지는 것
    public static func deleteConfirmation(_ preview: TrackDeletePreview) -> ReflectionPrompt {
        let written = preview.report.deleted.filter(\.written), blocked = preview.report.deleted.filter { !$0.written }
        var body = written.map { "• \($0.title)" }
        if !blocked.isEmpty { body += ["", notDeletedHeader(blocked.count)] + blocked.map { "• \($0.title): \($0.reason ?? "")" } }
        return ReflectionPrompt(title: String(ui: "\(written.count)곡을 rekordbox에서 뺄까요?"),
                                text: String(ui: "음원 파일은 지우지 않습니다. rekordbox의 큐·재생 목록 항목·재생 기록·분석 파일·앨범아트가 함께 사라집니다.")
                                    + "\n" + backupThenWriteText,
                                confirm: String(ui: "rekordbox에서 빼기"), critical: true, details: body)
    }

    // MARK: - 복원

    /// 복원 확인 창에 보일 안내(순서대로)
    public static func restoreNotices(_ backup: RekordboxWriteBackup, changedSince changed: Bool?, conflicts: Int = 0,
                                      later: Int = 0) -> [RestoreNotice] {
        var notices: [RestoreNotice]
        if let tracks = backup.trackReport {
            notices = [.tracks(added: tracks.added.filter(\.written).count, deleted: tracks.deleted.filter(\.written).count)]
        } else {
            notices = [.drafts]
        }
        if later > 0 { notices.append(.laterBackups(later)) }
        switch changed {
        case true?: notices.append(.changed)
        case nil: notices.append(.unknownChanges)
        case false?: break
        }
        if conflicts > 0 { notices.append(.conflicts(conflicts)) }
        return notices
    }

    /// 되돌리기 확인 창. 백업 뒤 변경이 있거나 확인하지 못했으면 파괴적 경고로 띄운다.
    /// - Parameter conflicts: 쓴 뒤 새로 만든 초안이 있는 곡. 있으면 지금 초안을 남길지(확인), 백업 초안으로 바꿀지(둘째 단추) 고른다.
    /// - Parameter later: 이 백업 뒤에 뜬 백업 수. 그 쓰기·복원이 바꾼 분석 파일도 함께 되돌리므로 알린다(#222).
    public static func restoreConfirmation(_ backup: RekordboxWriteBackup, changedSince changed: Bool?, conflicts: [String] = [],
                                           later: Int = 0) -> ReflectionPrompt {
        var details = backup.titles.isEmpty ? [] : [String(ui: "그때 쓴 곡:")] + backup.titles.map { "• \($0)" }
        if !conflicts.isEmpty { details += [String(ui: "쓴 뒤 새로 만든 초안:")] + conflicts }
        let lines = [String(ui: "백업: \(backup.createdAt.formatted(date: .abbreviated, time: .shortened))")]
            + restoreNotices(backup, changedSince: changed, conflicts: conflicts.count, later: later).map(\.text)
            + [String(ui: "백업한 뒤 복원하고 다시 확인합니다. 끝날 때까지 rekordbox를 켜지 마세요.")]
        return ReflectionPrompt(title: String(ui: "rekordbox를 쓰기 전으로 복원할까요?"),
                                text: lines.joined(separator: "\n\n"),
                                confirm: conflicts.isEmpty ? String(ui: "쓰기 전으로 복원") : String(ui: "복원하고 지금 초안 남기기"),
                                critical: changed != false, destructive: changed != false, details: details,
                                alternate: conflicts.isEmpty ? nil : String(ui: "복원하고 백업 초안으로 바꾸기"))
    }
}
