import DJCDomain
import Foundation
@testable import RekordboxKit
import Testing

/// 쓰기 보고·시점 스냅샷 정보는 백업 폴더(`djc-*.json`)·스냅샷 폴더(`snapshot.json`)에 저장된다.
/// 값 타입을 DJCDomain으로 옮긴 뒤에도(#167) 옛 이름으로 만든 값의 JSON이 바이트 단위로 같아야 옛 파일을 읽는다.
/// 기대 문자열은 옮기기 전 코드로 인코딩해 고정했다.
@Suite("rekordbox 값 인코딩 고정")
struct RekordboxValueEncodingTests {
    private func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func roundTrip<T: Codable>(_ type: T.Type, _ text: String) throws -> String {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try json(decoder.decode(type, from: Data(text.utf8)))
    }

    static let writeReport = #"{"analysisOutcomes":[{"added":64,"removed":0,"status":"written","title":"분석","trackUUID":"u3"}],"artworkAdded":["u3"],"artworkOutcomes":[{"added":0,"artwork":"replace","removed":0,"status":"written","title":"그림","trackUUID":"u4"}],"backup":"\/tmp\/backups\/2026-10-09T120000-write","createdAt":"2026-10-09T12:00:00Z","createdFiles":["PIONEER\/USBANLZ\/a\/b\/ANLZ0000.DAT"],"dryRun":false,"finalUpdateCount":42,"gainOutcomes":[{"added":-350,"reason":"막힘","removed":0,"status":"blocked","title":"게인","trackUUID":"u2"}],"gridOutcomes":[{"added":1,"removed":1,"status":"unchanged","title":"그리드","trackUUID":"u1"}],"iTunesSyncWritten":true,"mergeOutcomes":[{"added":0,"removed":2,"status":"written","title":"합치기","trackUUID":"m1"}],"outcomes":[{"added":2,"removed":1,"status":"written","title":"곡","trackUUID":"u1"}],"playlistOutcomes":[{"edit":{"rename":{"name":"새 이름","playlist":"123"}},"name":"새 이름","playlistID":"123","status":"written"},{"edit":{"addTracks":{"contentIDs":["1","2"],"playlist":"new:k"}},"name":"목록","reason":"없음","status":"blocked"}],"tagOutcomes":[{"added":2,"fields":["title","musicalKey"],"removed":0,"status":"written","title":"태그","trackUUID":"u5"}],"warnings":["경고"]}"#

    static let trackReport = #"{"added":[{"contentID":"77","cueReason":"큐 막힘","cuesWritten":3,"keyBase":{"album":"","albumArtist":"","artist":"가수","color":"","comment":"","composer":"","genre":"","musicalKey":"","rating":"","title":"곡","trackNumber":"","year":""},"keyReason":"키 막힘","path":"\/m\/a.mp3","title":"곡","uuid":"n1","written":true}],"backup":"\/tmp\/b","createdFiles":["c"],"deleted":[{"keyWritten":"8A","path":"\/m\/b.mp3","reason":"막힘","title":"뺄 곡","written":false}],"dryRun":true,"finalUpdateCount":7,"removedFiles":["r"]}"#

    static let trackAddPlan = #"{"album":"앨범","artwork":"AQID","comment":"","composer":"작곡","dateCreated":"2026-01-02","discNumber":1,"duration":181.5,"fileID":"9","fileName":"a.mp3","fileSize":1000,"fileType":1,"genre":"Anison","isrc":"JP","length":182,"lyricist":"","path":"\/m\/a.mp3","stockDate":"2026-10-09","title":"곡","trackNumber":3,"year":2024}"#

    static let pointMetadata = #"{"cloned":true,"cloudUpdateCount":4,"createdAt":"2026-10-09T12:00:00Z","items":["master.db","share\/PIONEER\/USBANLZ"],"kind":"beforeRestore","libraryID":"db-1","localUpdateCount":5,"name":"복원 직전","pinned":true,"restoredFrom":"이전","source":{"modified":1790000000.5,"size":12345},"trackCount":10,"version":1}"#

    @Test("초안 쓰기 보고: 옛 JSON과 같고 다시 읽어도 같다")
    func writeReport() throws {
        let created = Date(timeIntervalSince1970: 1_791_547_200)
        var tag = RekordboxWriter.Outcome(trackUUID: "u5", title: "태그", status: .written, removed: 0, added: 2)
        tag.fields = ["title", "musicalKey"]
        var artwork = RekordboxWriter.Outcome(trackUUID: "u4", title: "그림", status: .written, removed: 0, added: 0)
        artwork.artwork = .replace
        var report = RekordboxWriter.Report(outcomes: [.init(trackUUID: "u1", title: "곡", status: .written, removed: 1, added: 2)],
                                            backup: "/tmp/backups/2026-10-09T120000-write", dryRun: false,
                                            createdAt: ISO8601DateFormatter().string(from: created))
        report.finalUpdateCount = 42
        report.gridOutcomes = [.init(trackUUID: "u1", title: "그리드", status: .unchanged, removed: 1, added: 1)]
        report.gainOutcomes = [.init(trackUUID: "u2", title: "게인", status: .blocked, reason: "막힘", removed: 0, added: -350)]
        report.analysisOutcomes = [.init(trackUUID: "u3", title: "분석", status: .written, removed: 0, added: 64)]
        report.createdFiles = ["PIONEER/USBANLZ/a/b/ANLZ0000.DAT"]
        report.playlistOutcomes = [
            PlaylistOutcome(edit: .rename(playlist: .id("123"), name: "새 이름"), playlistID: "123", name: "새 이름", status: .written),
            PlaylistOutcome(edit: .addTracks(playlist: .new("k"), contentIDs: ["1", "2"]), name: "목록", status: .blocked, reason: "없음"),
        ]
        report.artworkAdded = ["u3"]
        report.tagOutcomes = [tag]
        report.mergeOutcomes = [.init(trackUUID: "m1", title: "합치기", status: .written, removed: 2, added: 0)]
        report.artworkOutcomes = [artwork]
        report.warnings = ["경고"]
        report.iTunesSyncWritten = true
        #expect(try json(report) == Self.writeReport)
        #expect(try roundTrip(RekordboxWriter.Report.self, Self.writeReport) == Self.writeReport)
    }

    @Test("곡 넣기·빼기 보고: 옛 JSON과 같고 다시 읽어도 같다")
    func trackReport() throws {
        var base = TagFields()
        base.title = "곡"
        base.artist = "가수"
        var added = RekordboxTrackWriter.Outcome(path: "/m/a.mp3", contentID: "77", title: "곡", written: true)
        added.uuid = "n1"
        added.cuesWritten = 3
        added.cueReason = "큐 막힘"
        added.keyReason = "키 막힘"
        added.keyBase = base
        var deleted = RekordboxTrackWriter.Outcome(path: "/m/b.mp3", title: "뺄 곡", written: false, reason: "막힘")
        deleted.keyWritten = "8A"
        let report = RekordboxTrackWriter.Report(added: [added], deleted: [deleted], backup: "/tmp/b", dryRun: true, removedFiles: ["r"],
                                                 createdFiles: ["c"], finalUpdateCount: 7)
        #expect(try json(report) == Self.trackReport)
        #expect(try roundTrip(RekordboxTrackWriter.Report.self, Self.trackReport) == Self.trackReport)
    }

    @Test("곡 넣기 계획: 옛 JSON과 같고 다시 읽어도 같다")
    func trackAddPlan() throws {
        let plan = TrackAddPlan(path: "/m/a.mp3", fileName: "a.mp3", title: "곡", artist: nil, album: "앨범", albumArtist: nil, genre: "Anison",
                                composer: "작곡", comment: "", year: 2024, trackNumber: 3, discNumber: 1, isrc: "JP", lyricist: "", fileType: 1,
                                fileSize: 1000, fileID: "9", length: 182, duration: 181.5, dateCreated: "2026-01-02", stockDate: "2026-10-09",
                                artwork: Data([1, 2, 3]))
        #expect(try json(plan) == Self.trackAddPlan)
        #expect(try roundTrip(TrackAddPlan.self, Self.trackAddPlan) == Self.trackAddPlan)
    }

    @Test("시점 스냅샷 정보: 옛 JSON과 같고 다시 읽어도 같다")
    func pointSnapshotMetadata() throws {
        var metadata = RekordboxPointSnapshot.Metadata(name: "복원 직전", kind: .beforeRestore, createdAt: Date(timeIntervalSince1970: 1_791_547_200),
                                                       pinned: true, libraryID: "db-1", localUpdateCount: 5, cloudUpdateCount: 4, trackCount: 10,
                                                       items: ["master.db", "share/PIONEER/USBANLZ"], cloned: true)
        metadata.restoredFrom = "이전"
        metadata.source = RekordboxPointSnapshot.SourceStamp(size: 12345, modified: 1_790_000_000.5)
        #expect(try json(metadata) == Self.pointMetadata)
        #expect(try roundTrip(RekordboxPointSnapshot.Metadata.self, Self.pointMetadata) == Self.pointMetadata)
    }
}
