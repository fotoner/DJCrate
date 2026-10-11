import DJCDomain
import Foundation

/// 로컬 스냅샷 사본의 djmdCue에서 USB 분석 파일에 적을 큐를 읽는다(읽기 전용).
public struct UsbCueSource {
    let database: CipherDatabase

    public init(database: CipherDatabase) {
        self.database = database
    }

    /// 지우지 않은 큐(`rb_local_deleted = 0`)를 행 순서대로. 순서는 `UsbCuePlacement`가 다시 정한다.
    public func cues(contentID: String) throws -> [UsbCueInput] {
        var cues: [UsbCueInput] = []
        try database.query("""
            SELECT ID, Kind, InMsec, OutMsec, Comment, ColorTableIndex, Color, ActiveLoop, BeatLoopSize, created_at,
                   InPointSeekInfo, OutPointSeekInfo, InMpegFrame, InMpegAbs
            FROM djmdCue WHERE ContentID = ? AND rb_local_deleted = 0 ORDER BY rowid
            """, [.text(contentID)]) { row in
            cues.append(UsbCueInput(
                id: row.string(0) ?? "", kind: row.int(1) ?? 0, inMsec: row.int(2) ?? 0, outMsec: row.int(3) ?? -1,
                comment: row.string(4) ?? "", colorTableIndex: row.int(5), color: row.int(6),
                activeLoop: row.int(7) ?? 0, beatLoopSize: row.int(8) ?? 0, createdAtRaw: row.string(9) ?? "",
                inSeek: UsbSeekInfo.parse(row.string(10)), outSeek: UsbSeekInfo.parse(row.string(11)),
                inMpegFrame: row.int(12) ?? 0, inMpegAbs: row.int(13) ?? 0))
        }
        return cues
    }
}
