import Foundation
import RekordboxKit

/// USB 큐 읽기 시험용 djmdCue 행. 기존 `add(_:)`는 created_at을 고정값으로 넣어서, 칸마다 값을 줄 수 있게 따로 넣는다.
extension RekordboxFixture {
    /// djmdCue 행 하나를 넣고 ID를 돌려준다. NULL로 둘 칸은 nil.
    @discardableResult
    public func addCue(track: TrackSpec, id: String = String(Int.random(in: 1_000_000...9_999_999)), kind: Int, inMsec: Int,
                       outMsec: Int? = -1, comment: String? = nil, colorTableIndex: Int? = nil, color: Int? = nil,
                       activeLoop: Int? = nil, beatLoopSize: Int? = nil, createdAt: String = "2026-01-01 00:00:00.000 +00:00",
                       seek: (in: String?, out: String?) = (nil, nil), inMpegFrame: Int? = 0, inMpegAbs: Int? = 0,
                       deleted: Bool = false) throws -> String {
        func value(_ number: Int?) -> CipherDatabase.Value { number.map { .int($0) } ?? .null }
        func value(_ text: String?) -> CipherDatabase.Value { text.map { .text($0) } ?? .null }
        try insert("djmdCue", [
            "ID": .text(id), "ContentID": .text(track.id), "Kind": .int(kind), "InMsec": .int(inMsec), "OutMsec": value(outMsec),
            "Comment": value(comment), "ColorTableIndex": value(colorTableIndex), "Color": value(color),
            "ActiveLoop": value(activeLoop), "BeatLoopSize": value(beatLoopSize),
            "InPointSeekInfo": value(seek.in), "OutPointSeekInfo": value(seek.out),
            "InMpegFrame": value(inMpegFrame), "InMpegAbs": value(inMpegAbs),
            "ContentUUID": .text(track.uuid), "UUID": .text(UUID().uuidString.lowercased()),
            "rb_local_deleted": .int(deleted ? 1 : 0), "created_at": .text(createdAt),
        ])
        return id
    }
}
