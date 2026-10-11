import DJCDomain
import Foundation

/// 그리드 BPM 변경 때 DB(contentFile 해시·크기, djmdContent BPM) 고치기
extension RekordboxWriter {
    /// BPM을 고친 곡이 쓴 뒤 가져야 할 칸(트랜잭션 안과 커밋 뒤에 다시 읽어 비교한다)
    struct GridExpectation {
        var title: String
        var contentID: String
        /// `djmdContent`의 고친 칸. 같은 쓰기에서 태그도 쓰면 곡 정보 변경 횟수·변경 번호는 태그 쪽 값으로 바꾼다.
        var content: [String: CipherDatabase.Value]
        /// `.DAT`의 `contentFile` 행(ID → 고친 칸). 단일 템포 편집만 고친다.
        var files: [String: [String: CipherDatabase.Value]] = [:]
    }

    /// BPM이 바뀌는 그리드의 DB 쪽(BPM 244→245 실험과 같은 칸):
    /// `contentFile`(.DAT): Hash·Size·상태 256→257·rb_local_usn·updated_at /
    /// `djmdContent`: BPM·AnalysisUpdated+1·TrackInfoUpdated+1·상태 256→257·rb_local_usn·updated_at.
    /// 다구간 편집은 첫 BPM이 바뀔 때만 곡 정보(+1)를 고치고 분석 카운터·파일 행은 보존한다.
    static func applyGridDatabase(_ plan: RekordboxGridWriter.Plan, db: CipherDatabase, usn: inout Int,
                                  stamp: (db: String, json: String)) throws -> GridExpectation? {
        guard let bpm100 = plan.newBPM100 else { return nil }
        func fail(_ reason: String) -> DJCError { .writeVerificationFailed("\(reason) (\(plan.title))") }
        // 고칠 칸의 쓴 뒤 값은 고치기 전 행에서 UPDATE와 같은 식으로 구한다.
        var content: (id: String, trackInfo: String?, analysis: String?, status: CipherDatabase.Value)?
        try db.query("""
            SELECT ID, CAST(CAST(ifnull(TrackInfoUpdated, '0') AS INTEGER) + 1 AS TEXT),
                CAST(CAST(ifnull(AnalysisUpdated, '0') AS INTEGER) + 1 AS TEXT), rb_data_status
            FROM djmdContent WHERE UUID = ? AND rb_local_deleted = 0
            """, [.text(plan.trackUUID)]) { r in
            content = (r.string(0) ?? "", r.string(1), r.string(2), raisedStatus(r.int(3)))
        }
        guard let content else { throw fail(String(ui: "곡을 찾지 못했습니다")) }
        let contentID = content.id
        var expectation = GridExpectation(title: plan.title, contentID: contentID, content: [:])
        if plan.updatesAnalysis {
            usn += 1
            var fileRows: [(id: String, status: CipherDatabase.Value)] = []
            try db.query("SELECT ID, rb_data_status FROM contentFile WHERE ContentID = ? AND Path = ?",
                         [.text(contentID), .text(plan.analysisDataPath)]) { fileRows.append(($0.string(0) ?? "", raisedStatus($0.int(1)))) }
            let files = try db.run("""
                UPDATE contentFile SET Hash = ?, Size = ?, \(savedStatus),
                    rb_local_usn = ?, updated_at = ? WHERE ContentID = ? AND Path = ?
                """, [.text(plan.newDatMD5), .int(plan.newDat.count), .int(usn), .text(stamp.db), .text(contentID), .text(plan.analysisDataPath)])
            guard files <= 1 else { throw fail(String(ui: "분석 파일 기록이 여럿입니다")) }
            for row in fileRows {
                expectation.files[row.id] = ["Hash": .text(plan.newDatMD5), "Size": .int(plan.newDat.count), "rb_data_status": row.status,
                                             "rb_local_usn": .int(usn), "updated_at": .text(stamp.db)]
            }
        }
        usn += 1
        let contentUSN = usn
        // 별도 입력창의 구간 편집은 AnalysisUpdated·contentFile을 그대로 둔다.
        let analysisAssignment = plan.updatesAnalysis
            ? "AnalysisUpdated = CAST(CAST(ifnull(AnalysisUpdated, '0') AS INTEGER) + 1 AS TEXT)," : ""
        let changed = try db.run("""
            UPDATE djmdContent SET BPM = ?,
                \(analysisAssignment)
                TrackInfoUpdated = CAST(CAST(ifnull(TrackInfoUpdated, '0') AS INTEGER) + 1 AS TEXT),
                \(savedStatus),
                rb_local_usn = ?, updated_at = ? WHERE ID = ?
            """, [.int(bpm100), .int(contentUSN), .text(stamp.db), .text(contentID)])
        guard changed == 1 else { throw fail(String(ui: "곡 BPM을 고치지 못했습니다")) }
        expectation.content = ["BPM": .int(bpm100), "TrackInfoUpdated": content.trackInfo.map { .text($0) } ?? .null,
                               "rb_data_status": content.status, "rb_local_usn": .int(contentUSN), "updated_at": .text(stamp.db)]
        if plan.updatesAnalysis { expectation.content["AnalysisUpdated"] = content.analysis.map { .text($0) } ?? .null }
        try verifyGrid(db: db, expectation)
        return expectation
    }

    /// BPM을 고친 곡의 곡 행·파일 행이 쓴 그대로인지 다시 읽어 확인한다(트랜잭션 안과 커밋 뒤).
    static func verifyGrid(db: CipherDatabase, _ expected: GridExpectation) throws {
        do {
            try RekordboxTrackWriter.verify(db, table: "djmdContent", id: expected.contentID, expected.content)
            for (id, columns) in expected.files { try RekordboxTrackWriter.verify(db, table: "contentFile", id: id, columns) }
        } catch DJCError.writeVerificationFailed {
            throw DJCError.writeVerificationFailed("\(String(ui: "곡 BPM 확인 실패")) (\(expected.title))")
        }
    }

    /// `rb_data_status`를 rekordbox처럼 256 → 257로 올린 값(그 밖은 그대로)
    static func raisedStatus(_ status: Int?) -> CipherDatabase.Value {
        guard let status else { return .null }
        return .int(savedState(status))
    }

    /// DB 사본의 rekordbox 변경 카운터(읽기 전용).

    public static func gridDrafts(in backup: URL) -> [GridDraft] {
        let folder = backup.appending(path: "grid-drafts")
        return ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? JSONDecoder().decode(GridDraft.self, from: $0) }
    }

    public static func contents(of backup: URL) -> (report: Report?, drafts: [CueDraft]) {
        let report = (try? Data(contentsOf: backup.appending(path: "report.json")))
            .flatMap { try? JSONDecoder().decode(Report.self, from: $0) }
        let folder = backup.appending(path: "cue-drafts")
        let drafts = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? JSONDecoder().decode(CueDraft.self, from: $0) }
        return (report, drafts)
    }
}
