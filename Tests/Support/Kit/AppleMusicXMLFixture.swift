import Foundation

/// 합성 Apple Music(iTunes) 보관함 XML. 곡 이름·경로는 지어낸 것이다.
public enum AppleMusicXMLFixture {
    public static func xml(tracks: [String: Any], playlists: [[String: Any]] = []) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: [
            "Library Persistent ID": "TEST-LIBRARY", "Tracks": tracks, "Playlists": playlists
        ], format: .xml, options: 0)
    }

    /// 로컬 파일 곡 하나. `extra`로 칸을 더하거나 바꾼다.
    public static func track(_ id: Int, _ extra: [String: Any] = [:]) -> [String: Any] {
        ["Track ID": id, "Name": "합성 곡 \(id)", "Artist": "합성 아티스트", "Track Type": "File",
         "Location": "file://localhost/fixtures/\(id).mp3"].merging(extra) { _, new in new }
    }
}
