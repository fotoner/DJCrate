import DJCDomain
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

@Suite("USB용 로컬 큐 읽기")
struct UsbCueSourceTests {
    @Test("djmdCue 칸을 읽고 지운 행·다른 곡은 뺀다")
    func readsCueColumnsAndSkipsDeleted() throws {
        let fixture = try RekordboxFixture()
        let track = try fixture.add(TrackSpec(id: "5001"))
        let other = try fixture.add(TrackSpec(id: "5002"))
        try fixture.addCue(track: track, id: "m1", kind: 0, inMsec: 1_234, comment: "시작", color: 255,
                           createdAt: "2026-02-03 04:05:06.789 +00:00")
        try fixture.addCue(track: track, id: "h1", kind: 6, inMsec: 2_000, outMsec: 6_000, comment: nil, colorTableIndex: 3,
                           activeLoop: 1, beatLoopSize: 8 << 16 | 1, createdAt: "2026-02-03 04:05:07 +00:00",
                           inMpegFrame: 77, inMpegAbs: 88)
        try fixture.addCue(track: track, id: "gone", kind: 1, inMsec: 500, deleted: true)
        try fixture.addCue(track: other, id: "elsewhere", kind: 0, inMsec: 100)

        let db = try CipherDatabase(path: fixture.database.path, key: RekordboxKey.derive())
        defer { db.close() }
        let cues = try UsbCueSource(database: db).cues(contentID: track.id)
        #expect(cues.map(\.id) == ["m1", "h1"])
        let memory = try #require(cues.first { $0.id == "m1" })
        #expect(memory.kind == 0 && memory.inMsec == 1_234 && memory.outMsec == -1)
        #expect(memory.comment == "시작" && memory.color == 255 && memory.colorTableIndex == nil)
        #expect(memory.activeLoop == 0 && memory.beatLoopSize == 0)
        #expect(memory.createdAtRaw == "2026-02-03 04:05:06.789 +00:00")
        #expect(memory.createdAt == UsbCuePlacement.parseCreatedAt("2026-02-03 04:05:06.789 +00:00"))
        #expect(memory.createdAt != nil)
        let hot = try #require(cues.first { $0.id == "h1" })
        #expect(hot.kind == 6 && hot.inMsec == 2_000 && hot.outMsec == 6_000)
        #expect(hot.comment == "" && hot.colorTableIndex == 3 && hot.color == nil)
        #expect(hot.activeLoop == 1 && hot.beatLoopSize == 8 << 16 | 1)
        #expect(hot.inMpegFrame == 77 && hot.inMpegAbs == 88)
        #expect(try UsbCueSource(database: db).cues(contentID: "404").isEmpty)
    }

    @Test("SeekInfo 글자를 풀고 0·NULL은 nil")
    func parsesSeekInfo() throws {
        let fixture = try RekordboxFixture()
        let track = try fixture.add(TrackSpec(id: "6001"))
        try fixture.addCue(track: track, id: "flac", kind: 1, inMsec: 1_000, outMsec: 5_000, seek: ("123,456,4096", "789,1011,4096"))
        try fixture.addCue(track: track, id: "zero", kind: 0, inMsec: 2_000, seek: ("0,0,0", "0,0,0"))
        try fixture.addCue(track: track, id: "null", kind: 0, inMsec: 3_000, outMsec: nil, inMpegFrame: nil, inMpegAbs: nil)

        let db = try CipherDatabase(path: fixture.database.path, key: RekordboxKey.derive())
        defer { db.close() }
        let cues = Dictionary(uniqueKeysWithValues: try UsbCueSource(database: db).cues(contentID: track.id).map { ($0.id, $0) })
        #expect(cues["flac"]?.inSeek == UsbSeekInfo(frame: 123, offset: 456, block: 4_096))
        #expect(cues["flac"]?.outSeek == UsbSeekInfo(frame: 789, offset: 1_011, block: 4_096))
        #expect(cues["zero"]?.inSeek == nil && cues["zero"]?.outSeek == nil)
        #expect(cues["null"]?.inSeek == nil && cues["null"]?.outSeek == nil)
        #expect(cues["null"]?.outMsec == -1 && cues["null"]?.inMpegFrame == 0 && cues["null"]?.inMpegAbs == 0)
    }
}
