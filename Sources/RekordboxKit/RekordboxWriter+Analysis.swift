import DJCDomain
import Foundation

/// 분석 전 곡(분석 파일 없음)에 DJCrate가 분석 파일을 만들어 붙인다(#6).
///
/// 곡 넣기(분석 포함) 레시피를 그대로 쓴다(`RekordboxTrackWriter.prepare`·`fileRow`·`mixerRow`):
/// - 분석 파일 `.DAT`·`.EXT`·`.2EX`를 곡 UUID 폴더(`/PIONEER/USBANLZ/<앞 3자>/<나머지>`)에 만든다.
/// - `djmdContent`: 분석 칸(BPM·Length 버림·BitRate·BitDepth·SampleRate·AnalysisDataPath·Analysed 105·ContentLink)과
///   상태 256→257·변경 번호·`updated_at`.
/// - `contentFile` 행(파일마다)과 `djmdMixerParam` 행(오토게인)을 새로 넣는다.
/// - 음원에 그림이 있으면 아트워크 파일 셋(`TrackArtwork`)·`ImagePath`·`artwork.jpg` 파일 행도 넣는다(#87). rekordbox는 분석 전 곡을
///   분석할 때 아트워크를 뽑는다(2026-09-26 실험 "DJC 실험 아트": 자동 분석을 끄고 넣은 곡을 다음 세션의 자동 분석이 분석).
///   이미 아트워크가 있는 곡은 rekordbox가 다시 뽑는지 확인하지 않아 그대로 둔다.
/// 카운터는 곡 넣기와 같은 첫 BPM/Grid 분석의 '1'·'1'(글자, 2026-09-27 #95 합성 곡 실험). 기존 카운터가 있는 곡은 계속 막는다.
/// 기존 곡의 변경 번호 순서는 rekordbox 7.2.18이 XML로 들어온 분석 전 곡을 분석했을 때를 따른다(2026-09-26 #6 실험):
/// - 변경 번호: (아트워크 파일 행) → 오토게인 행 → 곡 행 → 파일 행 .2EX·.DAT·.EXT(rekordbox는 사이에 .3EX 행도 넣는다. DJCrate는 만들지 못한다).
///   아트워크 파일 행이 오토게인 행 앞인 것은 "DJC 실험 아트"에서, 나머지는 The Asterisk War (edit)에서 확인했다.
/// 같은 쓰기의 큐·게인 초안은 분석을 붙인 뒤에 쓴다(rekordbox에서 분석한 곡을 고치는 순서).
///
/// 대상은 분석 경로가 빈 곡이다(자동 분석을 끄고 넣은 곡 Analysed 0, XML로 들어온 곡 Analysed 41).
/// `.DAT`만 있고 `.EXT`가 없는 반쪽 곡(rekordbox 분석이 실패한 곡)은 기존 파일·행을 바꾸는 규칙을 아직 쓰지 않아 그리드 쓰기에서 막는다.
extension RekordboxWriter {
    /// 분석 붙이기를 연다. 2026-09-26 실험(기존 분석 전 곡을 rekordbox가 분석한 전후 비교)과 사본 재현으로 칸을 확인해 열었다.
    /// 규칙이 맞지 않는 것이 드러나면 여기서 닫는다.
    public static let attachesAnalysis = true

    /// 첫 BPM/Grid 분석 카운터(글자, 2026-09-27 합성 곡 auto/manual-grid 사본 재현)
    static let attachedCounters: [String: CipherDatabase.Value] = ["AnalysisUpdated": .text("1"), "TrackInfoUpdated": .text("1")]

    /// 분석을 붙일 곡의 음원 길이·음량(값은 DJCDomain, #167)
    public typealias AnalysisInput = RekordboxAnalysisInput

    /// 분석 파일이 없는 곡인지(분석 경로가 비었다). 분석을 붙이는 대상이다.
    public static func needsAnalysis(_ analysisDataPath: String?) -> Bool { (analysisDataPath ?? "").isEmpty }

    /// 분석을 붙일 곡 하나(파일 바이트까지 미리 만든다)
    struct AttachPlan {
        var trackUUID: String
        var contentID: String
        var title: String
        var ready: RekordboxTrackWriter.PreparedAnalysis
        /// 함께 넣을 아트워크 파일 셋(음원에 그림이 없거나 이미 아트워크가 있으면 nil)
        var artwork: RekordboxTrackWriter.PreparedArtwork?
        /// 넣은 행(커밋 뒤 다시 읽어 비교)
        var inserted: [RekordboxTrackWriter.InsertedRow] = []
    }

    /// 계획(읽기만 한다). 막히면 `Blocked`.
    /// - Parameter writesArtwork: 음원 내장 그림으로 아트워크도 넣는지(`RekordboxTrackWriter.writesArtwork`).
    static func attachPlan(draft: GridDraft, content: (id: String, title: String, path: String, fileName: String), input: AnalysisInput?,
                           share: URL, reader: CipherDatabase, enabled: Bool, writesArtwork: Bool) throws -> AttachPlan {
        func block(_ reason: String) -> Blocked { Blocked(title: content.title, reason: reason) }
        guard enabled else { throw block(String(ui: "rekordbox 분석 전 곡입니다. rekordbox에서 트랙 분석을 먼저 한 뒤 쓰세요")) }
        guard draft.base.isEmpty else { throw block(String(ui: "초안을 만든 뒤 rekordbox에서 그리드가 바뀌었습니다. DJCrate에서 다시 불러와 확인하세요")) }
        guard FileManager.default.fileExists(atPath: content.path) else { throw block(String(ui: "음원 파일이 없습니다. rekordbox에서 파일 위치를 확인하세요")) }
        guard let input else { throw block(String(ui: "음원 길이를 재지 못해 분석을 붙이지 않습니다. 음원 파일을 확인한 뒤 다시 쓰세요")) }
        // 분석 파일·오토게인 기록이 이미 있으면 rekordbox가 무엇을 기대하는지 모른다(곡 넣기와 달리 새 행을 넣는다).
        guard try scalar(reader, "SELECT count(*) FROM djmdMixerParam WHERE ContentID = ? AND rb_local_deleted = 0", [.text(content.id)]) == 0 else {
            throw block(String(ui: "오토게인 행이 이미 있는 곡이라 분석을 붙이지 않습니다. rekordbox에서 트랙 분석을 하세요"))
        }
        guard try scalar(reader, "SELECT count(*) FROM contentFile WHERE ContentID = ? AND Path LIKE '/PIONEER/USBANLZ/%'", [.text(content.id)]) == 0 else {
            throw block(String(ui: "분석 파일 기록이 이미 있는 곡이라 분석을 붙이지 않습니다. rekordbox에서 트랙 분석을 하세요"))
        }
        // 카운터가 NULL인 곡만 확인했다(곡 정보를 저장한 곡은 TrackInfoUpdated가 있다). 그 카운터는 rekordbox에서 곡 정보를 고쳤을 때뿐 아니라
        // DJCrate가 곡을 키와 함께 넣을 때도 생긴다(#5). DB로는 누가 만들었는지 알 수 없어 이유는 누구 탓도 하지 않는다(#197).
        guard try scalar(reader, "SELECT count(*) FROM djmdContent WHERE ID = ? AND AnalysisUpdated IS NULL AND TrackInfoUpdated IS NULL",
                         [.text(content.id)]) == 1 else {
            throw block(String(ui: "곡 정보가 이미 저장된 분석 전 곡이라 분석을 붙이지 않습니다. rekordbox에서 트랙 분석을 하세요"))
        }
        let folder = share.appending(path: String(RekordboxTrackWriter.analysisFolder(uuid: draft.trackUUID).dropFirst()))
        guard ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).isEmpty else {
            throw block(String(ui: "분석 폴더에 파일이 이미 있어 분석을 붙이지 않습니다. rekordbox에서 트랙 분석을 하세요"))
        }
        let analysis = RekordboxTrackWriter.Analysis(segments: draft.segments, loudness: input.loudness, peak: input.peak)
        let ready: RekordboxTrackWriter.PreparedAnalysis
        do {
            ready = try RekordboxTrackWriter.prepare(path: content.path, fileName: content.fileName, duration: input.duration,
                                                     uuid: draft.trackUUID, analysis: analysis, share: share)
        } catch {
            throw block(String(ui: "분석 파일을 만들지 못했습니다: \(DJCError.reason(of: error))"))
        }
        if let reason = ready.blocked { throw block(reason) }
        var plan = AttachPlan(trackUUID: draft.trackUUID, contentID: content.id, title: content.title, ready: ready)
        if writesArtwork, let image = input.artwork, try hasNoArtwork(content.id, uuid: draft.trackUUID, share: share, reader: reader),
           let files = TrackArtwork.make(image) {
            let artwork = RekordboxTrackWriter.PreparedArtwork(uuid: draft.trackUUID, files: files, share: share)
            // 그림 폴더 위가 링크면 share 밖에 쓰게 된다(#66 리뷰). 쓰지 않는 쪽으로 막는다.
            guard !artwork.files.contains(where: { hasSymlinkComponent($0.0, under: share) }) else { throw block(artworkLinkReason) }
            plan.artwork = artwork
        }
        return plan
    }

    /// 아트워크가 아직 없는 곡인지(`ImagePath` 빈 값, 아트워크 파일 행 없음, 곡 UUID 아트워크 폴더에 파일 없음).
    /// 있으면 분석만 붙이고 아트워크는 그대로 둔다(라이브러리에 분석 전인데 `ImagePath`가 있는 곡이 있다).
    static func hasNoArtwork(_ contentID: String, uuid: String, share: URL, reader: CipherDatabase) throws -> Bool {
        let folder = share.appending(path: String(TrackArtwork.folder(uuid: uuid).dropFirst()))
        return try scalar(reader, "SELECT count(*) FROM djmdContent WHERE ID = ? AND ifnull(ImagePath, '') = ''", [.text(contentID)]) == 1
            && scalar(reader, "SELECT count(*) FROM contentFile WHERE ContentID = ? AND Path LIKE '/PIONEER/Artwork/%'", [.text(contentID)]) == 0
            && ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).isEmpty
    }

    /// 분석을 붙인 곡 행 칸(곡 넣기 분석 칸 + 기존 곡 카운터 + 아트워크면 `ImagePath`)
    static func attachedColumns(_ plan: AttachPlan) -> [String: CipherDatabase.Value] {
        var columns = plan.ready.columns.merging(attachedCounters) { _, counter in counter }
        if let artwork = plan.artwork { columns["ImagePath"] = .text(artwork.imagePath) }
        return columns
    }

    /// 트랜잭션 안에서 rekordbox 순서대로 쓰고(아트워크 파일 행 → 오토게인 행 → 곡 행 분석 칸 → 파일 행 .2EX·.DAT·.EXT) 다시 읽어 비교한다.
    static func applyAttach(_ plan: inout AttachPlan, db: CipherDatabase, usn: inout Int, stamp: (db: String, json: String)) throws {
        var status: Int?
        try db.query("""
            SELECT rb_data_status FROM djmdContent WHERE ID = ? AND rb_local_deleted = 0 AND ifnull(AnalysisDataPath, '') = ''
                AND AnalysisUpdated IS NULL AND TrackInfoUpdated IS NULL AND (? = 0 OR ifnull(ImagePath, '') = '')
            """, [.text(plan.contentID), .int(plan.artwork == nil ? 0 : 1)]) { status = $0.int(0) ?? 0 }
        guard let status else { throw Blocked(title: plan.title, reason: String(ui: "초안을 만든 뒤 rekordbox에서 곡이 바뀌었습니다. DJCrate에서 다시 불러와 확인하세요")) }
        func insert(_ row: RekordboxTrackWriter.InsertedRow) throws {
            try RekordboxTrackWriter.insert(db, table: row.table, row.values)
            try RekordboxTrackWriter.verify(db, table: row.table, id: row.id, row.values)
            plan.inserted.append(row)
        }
        if let artwork = plan.artwork {
            // artwork.jpg 파일 행이 먼저 번호를 받는다(_m·_s는 행이 없다, 2026-09-26 실험 "DJC 실험 아트")
            usn += 1
            try insert(RekordboxTrackWriter.fileRow(uuid: plan.trackUUID, share: artwork.share, artwork.files[0], contentID: plan.contentID,
                                                    usn: usn, stamp: stamp))
        }
        usn += 1
        try insert(RekordboxTrackWriter.mixerRow(plan.ready, contentID: plan.contentID, usn: usn, stamp: stamp))
        usn += 1
        var columns = attachedColumns(plan)
        columns["rb_data_status"] = .int(savedState(status))
        columns["rb_local_usn"] = .int(usn)
        columns["updated_at"] = .text(stamp.db)
        let keys = columns.keys.sorted()
        let changed = try db.run("UPDATE djmdContent SET \(keys.map { "\"\($0)\" = ?" }.joined(separator: ", ")) WHERE ID = ?",
                                 keys.map { columns[$0]! } + [.text(plan.contentID)])
        guard changed == 1 else { throw DJCError.writeVerificationFailed(String(ui: "곡 행에 분석 칸을 쓰지 못했습니다 (\(plan.title))")) }
        try RekordboxTrackWriter.verify(db, table: "djmdContent", id: plan.contentID, columns)
        for ext in ["2EX", "DAT", "EXT"] {
            guard let file = plan.ready.files.first(where: { $0.0.pathExtension == ext }) else {
                throw DJCError.writeVerificationFailed(String(ui: "분석 파일(.\(ext))을 만들지 못했습니다 (\(plan.title))"))
            }
            usn += 1
            try insert(RekordboxTrackWriter.fileRow(plan.ready, file, contentID: plan.contentID, usn: usn, stamp: stamp))
        }
    }

    /// 커밋 뒤 다시 읽기. 같은 쓰기의 큐·게인 초안이 곡 행 변경 번호·오토게인 칸을 다시 바꾸므로 그 칸은 빼고 본다.
    /// - Parameter skipsTrackInfo: 같은 쓰기에서 태그도 써서 `TrackInfoUpdated`가 더 늘어난 곡(그 칸은 태그 검증이 본다)
    static func verifyAttach(_ plan: AttachPlan, db: CipherDatabase, skipsTrackInfo: Bool = false) throws {
        var columns = attachedColumns(plan)
        if skipsTrackInfo { columns["TrackInfoUpdated"] = nil }
        try RekordboxTrackWriter.verify(db, table: "djmdContent", id: plan.contentID, columns)
        for row in plan.inserted {
            let values = row.table == "djmdMixerParam"
                ? row.values.filter { !["GainHigh", "GainLow", "rb_data_status", "rb_local_usn", "updated_at"].contains($0.key) }
                : row.values
            try RekordboxTrackWriter.verify(db, table: row.table, id: row.id, values)
        }
    }

    /// 커밋 뒤 분석 파일(과 아트워크 파일 셋)을 만든다(없던 파일만). 만든 파일은 `created`에 더한다(실패하면 되돌릴 때 지운다).
    static func writeAnalysisFiles(_ plan: AttachPlan, created: inout [URL]) throws {
        let fm = FileManager.default
        if let artwork = plan.artwork, artwork.files.contains(where: { hasSymlinkComponent($0.0, under: artwork.share) }) {
            throw DJCError.writeVerificationFailed("\(artworkLinkReason) (\(plan.title))")
        }
        for (url, data) in plan.ready.files + (plan.artwork?.files ?? []) {
            guard !fm.fileExists(atPath: url.path) else { throw DJCError.writeVerificationFailed(String(ui: "파일이 이미 있습니다: \(url.lastPathComponent)")) }
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            created.append(url)
            guard try Data(contentsOf: url) == data else {
                throw DJCError.writeVerificationFailed(String(ui: "파일 확인 실패: \(url.lastPathComponent) (\(plan.title))"))
            }
        }
    }

    /// 만든 분석·아트워크 파일을 지우고, 비게 된 `USBANLZ`·`Artwork` 아래 `<3자>/<나머지>` 폴더도 지운다.
    /// 쓰기 실패 때 이번 작업이 만든 파일만 지워 넣기 전 모양으로 돌린다.
    static func removeAnalysisFiles(_ created: [URL]) throws {
        let fm = FileManager.default
        let roots = ["USBANLZ", "Artwork"]
        try each(created.filter { fm.fileExists(atPath: $0.path) }) { try fm.removeItem(at: $0) }
        for directory in Set(created.map { $0.deletingLastPathComponent() }) where roots.contains(where: { directory.path.contains("/\($0)/") }) {
            var current = directory
            while !roots.contains(current.lastPathComponent), (try? fm.contentsOfDirectory(atPath: current.path))?.isEmpty == true {
                try? fm.removeItem(at: current)
                current = current.deletingLastPathComponent()
            }
        }
    }
}
