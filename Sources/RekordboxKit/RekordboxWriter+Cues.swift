import DJCDomain
import Foundation

/// 큐 쓰기: djmdCue 행 지우기·넣기, contentCue JSON, CueUpdated
extension RekordboxWriter {
    struct Blocked: Error {
        var title: String
        var reason: String
    }

    /// 쓴 뒤 곡이 가져야 할 상태
    struct Expectation {
        var contentUUID: String
        /// 편집 가능한 큐(자동 큐 포함, Kind 4 제외): 종류·ms·이름
        var editable: [String]
        /// 건드리지 않은 큐 ID
        var untouchedIDs: Set<String>
        /// 새로 넣은 큐 ID
        var insertedIDs: Set<String>
        /// 새로 넣은 큐의 탐색 칸: InMpegFrame·InMpegAbs·OutMpegFrame·OutMpegAbs·InPointSeekInfo·OutPointSeekInfo(NULL은 "NULL")
        var insertedSeek: [String: [String]] = [:]
        /// 건드리지 않은 JSON 객체 원문
        var untouchedJSON: [String: String]
        var cueUSN: Int
        var contentUSN: Int
    }

    struct CueRow {
        var id: String
        var kind: Int
        var inMsec: Int
        var outMsec: Int
        var comment: String
        var color: Int?
        var colorTableIndex: Int?
        var activeLoop: Int
        var beatLoopSize: Int = 0
        var inMpegFrame: Int
        var hasSeekInfo: Bool
        var deleted: Bool

        var cue: Cue {
            Cue(id: id, contentID: "", kind: kind, inMsec: inMsec, name: comment, colorTableIndex: colorTableIndex,
                outMsec: outMsec, color: color, activeLoop: activeLoop, beatLoopSize: beatLoopSize)
        }
    }

    static func apply(_ draft: CueDraft, db: CipherDatabase, usn: inout Int,
                      stamp: (db: String, json: String)) throws -> (outcome: Outcome, contentID: String, expectation: Expectation?) {
        var draft = draft
        // 곡
        var contents: [(id: String, title: String, fileType: Int, bitRate: Int, cueUpdated: String?, length: Int, deleted: Bool, path: String,
                        analysed: Int)] = []
        try db.query("""
            SELECT ID, Title, FileType, BitRate, CueUpdated, Length, rb_local_deleted, FolderPath, Analysed FROM djmdContent WHERE UUID = ?
            """, [.text(draft.trackUUID)]) { r in
            contents.append((r.string(0) ?? "", r.string(1) ?? "", r.int(2) ?? -1, r.int(3) ?? 0, r.string(4),
                             r.int(5) ?? 0, (r.int(6) ?? 0) != 0, r.string(7) ?? "", r.int(8) ?? 0))
        }
        guard contents.count == 1, let content = contents.first else {
            throw Blocked(title: draft.trackUUID, reason: contents.isEmpty ? String(ui: "rekordbox 컬렉션에서 곡을 찾지 못했으니 컬렉션에서 곡을 확인한 뒤 DJCrate에서 다시 동기화하세요") : String(ui: "같은 UUID의 곡이 여럿인 구조는 지원하지 않으니 rekordbox에서 곡을 확인하고 직접 편집하세요"))
        }
        func block(_ reason: String) -> Blocked { Blocked(title: content.title, reason: reason) }
        guard !content.deleted else { throw block(String(ui: "rekordbox 컬렉션에서 지운 곡이니 컬렉션에서 곡을 확인한 뒤 DJCrate에서 다시 동기화하세요")) }

        // 큐 행
        var rows: [CueRow] = []
        try db.query("""
            SELECT ID, Kind, InMsec, OutMsec, Comment, Color, ColorTableIndex, ActiveLoop, InMpegFrame, InPointSeekInfo, rb_local_deleted,
                BeatLoopSize
            FROM djmdCue WHERE ContentID = ?
            """, [.text(content.id)]) { r in
            rows.append(CueRow(id: r.string(0) ?? "", kind: r.int(1) ?? -1, inMsec: r.int(2) ?? 0, outMsec: r.int(3) ?? 0,
                               comment: r.string(4) ?? "", color: r.int(5), colorTableIndex: r.int(6), activeLoop: r.int(7) ?? 0,
                               beatLoopSize: r.int(11) ?? 0,
                               inMpegFrame: r.int(8) ?? 0, hasSeekInfo: r.string(9) != nil, deleted: (r.int(10) ?? 0) != 0))
        }
        guard !rows.contains(where: \.deleted) else { throw block(String(ui: "삭제 표시된 큐 행이 있는 구조는 지원하지 않으니 rekordbox에서 큐를 확인하고 직접 편집하세요")) }

        // 형식: FLAC은 rekordbox처럼 큐가 든 프레임의 탐색 위치(SeekInfo)를 계산해 적는다(기존 큐 1,818개와 전수 일치 확인).
        // VBR MP3는 큐마다 MPEG 칸(InMpegFrame·InMpegAbs)을 적는다(기존 VBR 큐 1,118개·루프 끝 6개와 전수 일치 확인).
        var flac: (sampleRate: Int, frames: [SeekInfo.FlacFrame])?
        var vbr: (counted: [Int], sampleRate: Int, samplesPerFrame: Int)?
        switch content.fileType {
        case 1:
            // VBR은 DB에 BitRate 0으로도, 첫 프레임 비트레이트(예: 32)로도 적혀서 파일 머리로 가린다(2026-09-26).
            let url = URL(filePath: content.path)
            guard let frames = SeekInfo.mp3Frames(url: url) else {
                throw block(String(ui: "음원 파일을 읽지 못해 VBR MP3인지 확인할 수 없습니다. rekordbox에서 파일 위치를 확인하세요"))
            }
            if frames.isVariableBitRate {
                vbr = (SeekInfo.countedMp3Offsets(frames, url: url), frames.sampleRate, frames.samplesPerFrame)
            } else {
                // 분석 전 곡(Analysed 0)은 rekordbox도 BitRate 0으로 넣는다(VBR 표시가 아님)
                guard content.bitRate > 0 || content.analysed == 0, !rows.contains(where: { $0.inMpegFrame != 0 }) else {
                    throw block(String(ui: "파일은 CBR MP3인데 rekordbox에는 VBR처럼(비트레이트 0·MPEG 위치) 적혀 있어 직접 쓰지 않습니다"))
                }
            }
        case 4, 11:
            break
        case 5:
            guard let table = SeekInfo.flacFrames(url: URL(filePath: content.path)) else {
                throw block(String(ui: "FLAC 파일을 읽지 못했습니다(탐색 위치를 계산할 수 없음)"))
            }
            flac = table
        default:
            throw block(String(ui: "이 파일 형식(FileType \(content.fileType))은 아직 직접 쓰지 않습니다"))
        }
        guard flac != nil || !rows.contains(where: \.hasSeekInfo) else { throw block(String(ui: "탐색 위치가 적힌 큐가 있어 아직 직접 쓰지 않습니다")) }

        // contentCue(JSON)
        var cueRecords: [(id: String, cues: String?, deleted: Bool)] = []
        try db.query("SELECT ID, Cues, rb_local_deleted FROM contentCue WHERE ContentID = ?", [.text(content.id)]) { r in
            cueRecords.append((r.string(0) ?? "", r.string(1), (r.int(2) ?? 0) != 0))
        }
        guard cueRecords.count <= 1 else { throw block(String(ui: "큐 기록(contentCue)이 여럿인 구조는 지원하지 않으니 rekordbox에서 큐를 확인하고 직접 편집하세요")) }
        if let record = cueRecords.first, record.deleted { throw block(String(ui: "큐 기록(contentCue)이 삭제 표시된 구조는 지원하지 않으니 rekordbox에서 큐를 확인하고 직접 편집하세요")) }
        if cueRecords.isEmpty, !rows.isEmpty { throw block(String(ui: "큐 행은 있지만 큐 기록(contentCue)이 없는 구조는 지원하지 않으니 rekordbox에서 큐를 확인하고 직접 편집하세요")) }
        let objects: [CueJSON.Object]
        if let record = cueRecords.first {
            guard let text = record.cues, let parsed = try? CueJSON.parse(text) else { throw block(String(ui: "큐 기록(JSON)을 읽지 못했습니다")) }
            objects = parsed
        } else {
            objects = []
        }
        let objectIDs = objects.map { object -> String in if case let .string(id)? = object["ID"] { id } else { "" } }
        let rowsByID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let consistent = objectIDs.count == rows.count && Set(objectIDs).count == objectIDs.count
            && zip(objectIDs, objects).allSatisfy { id, object in
                guard let row = rowsByID[id] else { return false }
                return object["InMsec"] == .int(row.inMsec) && object["Kind"] == .int(row.kind)
            }
        guard consistent else { throw block(String(ui: "rekordbox 큐 기록(JSON)과 큐 행이 서로 다릅니다")) }

        // 자동 큐도 메모리 큐로 다룬다(#145). 자동 큐를 빼고 만든 옛 초안·중복 합치기 초안은 곡의 자동 큐를 채워
        // 예전처럼 그 행을 그대로 둔다. 고친 자동 큐는 전용 규칙 없이 아래 일반 규칙으로 쓴다.
        draft = draft.includingAutoCues(from: rows.map(\.cue))
        // 초안을 시작할 때와 rekordbox 큐가 같아야 한다.
        let current = rows.map(\.cue).compactMap(EditableCue.init)
        guard key(current, withSource: true) == key(draft.base, withSource: true) else {
            throw block(String(ui: "초안을 만든 뒤 rekordbox에서 이 곡의 큐가 바뀌었습니다. DJCrate에서 다시 불러와 확인하세요"))
        }

        // 바꿀 것
        var removals: [CueRow] = []
        var inserts: [(cue: EditableCue, replacing: CueRow?)] = []
        for change in draft.changes {
            switch change {
            case let .removed(old):
                guard let id = old.sourceID, let row = rowsByID[id] else { throw block(String(ui: "지울 큐를 찾지 못했습니다")) }
                removals.append(row)
            case let .modified(old, new):
                guard let id = old.sourceID, let row = rowsByID[id] else { throw block(String(ui: "옮길 큐를 찾지 못했습니다")) }
                removals.append(row)
                inserts.append((new, row))
            case let .added(new):
                inserts.append((new, nil))
            }
        }
        guard !removals.isEmpty || !inserts.isEmpty else {
            return (Outcome(trackUUID: draft.trackUUID, title: content.title, status: .unchanged, reason: nil, removed: 0, added: 0), content.id, nil)
        }
        let removedIDs = Set(removals.map(\.id))
        let hotKinds = rows.filter { !removedIDs.contains($0.id) && $0.kind > 0 && $0.kind != 4 }.map(\.kind)
            + inserts.map { kind(for: $0.cue.kind) }.filter { $0 > 0 }
        guard Set(hotKinds).count == hotKinds.count else { throw block(String(ui: "같은 핫큐 자리에 큐가 둘 생깁니다")) }
        // rekordbox는 곡당 메모리 큐를 10개까지 둔다(자동 큐 포함).
        let memoryAfter = rows.filter { !removedIDs.contains($0.id) && $0.kind == 0 }.count
            + inserts.filter { $0.cue.kind == .memory }.count
        guard memoryAfter <= 10 else { throw block(String(ui: "메모리 큐가 \(memoryAfter)개가 됩니다(rekordbox는 곡당 10개까지, 자동 큐 포함)")) }
        let limit = (content.length + 1) * 1000
        guard inserts.allSatisfy({ (0...limit).contains(msec($0.cue.time)) && (0...limit).contains(msec($0.cue.loop?.end ?? 0)) }) else {
            throw block(String(ui: "곡 길이를 벗어난 큐가 있습니다"))
        }
        guard inserts.allSatisfy({ $0.cue.loop.map { msec($0.end) } ?? .max > msec($0.cue.time) }) else { throw block(String(ui: "끝이 시작보다 앞인 루프가 있습니다")) }
        // 활성 루프는 곡에 하나까지(라이브러리 전체에 둘 이상인 곡이 없다)
        let activeAfter = rows.filter { !removedIDs.contains($0.id) && $0.activeLoop == 1 }.count
            + inserts.filter { $0.cue.loop?.active == true }.count
        guard activeAfter <= 1 else { throw block(String(ui: "활성 루프가 \(activeAfter)개가 됩니다(곡당 하나)")) }
        // FLAC 탐색 위치(쓰기 전에 모두 계산해 둔다)
        var seekInfo: [EditableCue.ID: String] = [:]
        var outSeekInfo: [EditableCue.ID: String] = [:]
        if let flac {
            for (cue, _) in inserts {
                guard let info = SeekInfo.flacSeekInfo(frames: flac.frames, sample: msec(cue.time) * flac.sampleRate / 1000) else {
                    throw block(String(ui: "FLAC 탐색 위치를 계산하지 못한 큐가 있습니다"))
                }
                seekInfo[cue.id] = info
                // 루프는 끝 지점도 같은 식(기존 rekordbox 루프 끝 전수 일치)
                if let end = cue.loop?.end {
                    guard let outInfo = SeekInfo.flacSeekInfo(frames: flac.frames, sample: msec(end) * flac.sampleRate / 1000) else {
                        throw block(String(ui: "FLAC 탐색 위치를 계산하지 못한 루프가 있습니다"))
                    }
                    outSeekInfo[cue.id] = outInfo
                }
            }
        }

        // VBR MP3 MPEG 칸(루프가 아니면 끝은 0, 0)
        var mpeg: [EditableCue.ID: (inFrame: Int, inAbs: Int, outFrame: Int, outAbs: Int)] = [:]
        if let vbr {
            func position(_ msec: Int) throws -> (mpegFrame: Int, abs: Int) {
                guard let p = SeekInfo.mp3CuePosition(msec: msec, counted: vbr.counted, sampleRate: vbr.sampleRate,
                                                      samplesPerFrame: vbr.samplesPerFrame) else {
                    throw block(String(ui: "VBR MP3 탐색 위치를 계산하지 못한 큐가 있습니다(파일 끝을 넘음)"))
                }
                return p
            }
            for (cue, _) in inserts {
                let start = try position(msec(cue.time))
                let end = try cue.loop.map { try position(msec($0.end)) }
                mpeg[cue.id] = (start.mpegFrame, start.abs, end?.mpegFrame ?? 0, end?.abs ?? 0)
            }
        }

        // 곡 UUID(= contentCue.ID = 큐의 ContentUUID)
        let contentUUID = draft.trackUUID

        if cueRecords.isEmpty, try scalar(db, "SELECT count(*) FROM contentCue WHERE ID = ?", [.text(contentUUID)]) != 0 {
            throw block(String(ui: "같은 ID의 큐 기록(contentCue)이 이미 있는 구조는 지원하지 않으니 rekordbox에서 큐를 확인하고 직접 편집하세요"))
        }

        // 쓰기
        for row in removals {
            guard try db.run("DELETE FROM djmdCue WHERE ID = ? AND ContentID = ?", [.text(row.id), .text(content.id)]) == 1 else {
                throw DJCError.writeVerificationFailed(String(ui: "큐 행을 지우지 못했습니다(\(content.title))"))
            }
        }
        var newObjects: [CueJSON.Object] = []
        var insertedIDs: Set<String> = []
        var insertedSeek: [String: [String]] = [:]
        for (cue, replacing) in inserts.sorted(by: { $0.cue.time < $1.cue.time }) {
            let id = try newCueID(db)
            let uuid = UUID().uuidString.lowercased()
            let inMsec = msec(cue.time)
            let kind = kind(for: cue.kind)
            // 루프는 rekordbox처럼 Color 255·ColorTableIndex 0·ActiveLoop·BeatLoopSize·CueMicrosec 0·Comment ''를 적는다
            // (2026-09-26 실험: Flip Flop 활성 루프 핫큐·ときめき分類学 루프 핫큐, 기존 루프 105개와 같은 모양).
            let loop = cue.loop
            let outMsec = loop.map { msec($0.end) }
            // 옮긴 큐는 지정해 둔 색을 이어받는다.
            var color = loop == nil ? -1 : 255
            var colorTableIndex: Int? = loop == nil ? nil : 0
            if let old = replacing, (old.kind == 0) == (kind == 0),
               (old.color.map { $0 != -1 && $0 != 255 } ?? false) || (old.colorTableIndex ?? 0) > 0 {
                color = old.color ?? -1
                colorTableIndex = old.colorTableIndex
            }
            let comment: String? = cue.name.isEmpty ? (loop == nil ? nil : "") : cue.name
            let activeLoop: Int? = loop.map { $0.active ? 1 : 0 }
            let beatLoopSize: Int? = loop.map { EditableCue.Loop.beatLoopSize(beats: $0.beats) }
            let cueMicrosec: Int? = loop == nil ? nil : 0
            let inSeek = seekInfo[cue.id]
            let outSeek = inSeek == nil ? nil : outSeekInfo[cue.id] ?? "0,0,0"
            let mp = mpeg[cue.id] ?? (0, 0, 0, 0)
            func bind(_ value: Int?) -> CipherDatabase.Value { value.map { .int($0) } ?? .null }
            try db.run("""
                INSERT INTO djmdCue (ID, ContentID, InMsec, InFrame, InMpegFrame, InMpegAbs, OutMsec, OutFrame, OutMpegFrame,
                    OutMpegAbs, Kind, Color, ColorTableIndex, ActiveLoop, Comment, BeatLoopSize, CueMicrosec, InPointSeekInfo,
                    OutPointSeekInfo, ContentUUID, UUID, rb_data_status, rb_local_data_status, rb_local_deleted, rb_local_synced,
                    usn, rb_local_usn, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 0, 0, 0, NULL, NULL, ?, ?)
                """, [.text(id), .text(content.id), .int(inMsec), .int(inMsec * 150 / 1000), .int(mp.inFrame), .int(mp.inAbs),
                      .int(outMsec ?? -1), .int((outMsec ?? 0) * 150 / 1000), .int(mp.outFrame), .int(mp.outAbs), .int(kind), .int(color),
                      bind(colorTableIndex), bind(activeLoop), comment.map { .text($0) } ?? .null, bind(beatLoopSize), bind(cueMicrosec),
                      inSeek.map { .text($0) } ?? .null, outSeek.map { .text($0) } ?? .null,
                      .text(contentUUID), .text(uuid), .text(stamp.db), .text(stamp.db)])
            // JSON에는 NULL 칸과 빈 코멘트를 적지 않는다(rekordbox JSON에 "Comment":""는 한 번도 없다).
            newObjects.append(CueJSON.newObject([
                ("ID", .string(id)), ("ContentID", .string(content.id)), ("ContentUUID", .string(contentUUID)),
                ("InMsec", .int(inMsec)), ("InFrame", .int(inMsec * 150 / 1000)), ("InMpegFrame", .int(mp.inFrame)), ("InMpegAbs", .int(mp.inAbs)),
                ("InPointSeekInfo", inSeek.map { .string($0) }),
                ("OutMsec", .int(outMsec ?? -1)), ("OutFrame", .int((outMsec ?? 0) * 150 / 1000)), ("OutMpegFrame", .int(mp.outFrame)), ("OutMpegAbs", .int(mp.outAbs)),
                ("OutPointSeekInfo", outSeek.map { .string($0) }),
                ("Kind", .int(kind)), ("Color", .int(color)), ("ColorTableIndex", colorTableIndex.map { .int($0) }),
                ("ActiveLoop", activeLoop.map { .int($0) }),
                ("Comment", comment.flatMap { $0.isEmpty ? nil : .string($0) }),
                ("BeatLoopSize", beatLoopSize.map { .int($0) }), ("CueMicrosec", cueMicrosec.map { .int($0) }),
                ("UUID", .string(uuid)),
                ("created_at", .string(stamp.json)), ("updated_at", .string(stamp.json)),
            ]))
            insertedIDs.insert(id)
            insertedSeek[id] = [mp.inFrame, mp.inAbs, mp.outFrame, mp.outAbs].map(String.init) + [inSeek ?? "NULL", outSeek ?? "NULL"]
        }
        let kept = zip(objectIDs, objects).filter { !removedIDs.contains($0.0) }
        let json = CueJSON.serialize(kept.map(\.1) + newObjects)
        let count = kept.count + newObjects.count

        usn += 1
        let cueUSN = usn
        usn += 1
        let contentUSN = usn
        if let record = cueRecords.first {
            try db.run("""
                UPDATE contentCue SET Cues = ?, rb_cue_count = ?,
                    \(savedStatus),
                    rb_local_usn = ?, updated_at = ? WHERE ID = ?
                """, [.text(json), .int(count), .int(cueUSN), .text(stamp.db), .text(record.id)])
        } else {
            try db.run("""
                INSERT INTO contentCue (ID, ContentID, Cues, rb_cue_count, UUID, rb_data_status, rb_local_data_status,
                    rb_local_deleted, rb_local_synced, usn, rb_local_usn, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, 0, 0, 0, 0, NULL, ?, ?, ?)
                """, [.text(contentUUID), .text(content.id), .text(json), .int(count), .text(UUID().uuidString.lowercased()),
                      .int(cueUSN), .text(stamp.db), .text(stamp.db)])
        }
        let cueUpdated = (Int(content.cueUpdated ?? "") ?? 0) + removals.count + inserts.count
        try db.run("""
            UPDATE djmdContent SET CueUpdated = ?,
                \(savedStatus),
                rb_local_usn = ?, updated_at = ? WHERE ID = ?
            """, [.text(String(cueUpdated)), .int(contentUSN), .text(stamp.db), .text(content.id)])

        let untouched = Set(rows.map(\.id)).subtracting(removedIDs)
        let expectation = Expectation(
            contentUUID: contentUUID,
            editable: key(expectedCues(after: draft), withSource: false),
            untouchedIDs: untouched,
            insertedIDs: insertedIDs,
            insertedSeek: insertedSeek,
            untouchedJSON: Dictionary(uniqueKeysWithValues: kept.map { ($0.0, CueJSON.serialize([$0.1])) }),
            cueUSN: cueUSN, contentUSN: contentUSN)
        return (Outcome(trackUUID: draft.trackUUID, title: content.title, status: .written, reason: nil,
                        removed: removals.count, added: inserts.count), content.id, expectation)
    }
}
