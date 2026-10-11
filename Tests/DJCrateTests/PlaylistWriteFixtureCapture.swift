import CryptoKit
import DJCDomain
import DJCTestKit
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

/// 재생 목록 반영 자가 테스트(`--write-selftest`)·화면 확인용 합성 라이브러리: 합성 곡 다섯(테스트 음원, 곡 102만 키 8A·`djmdKey`에 8A·6A·5A),
/// 폴더 "합성 폴더" 안 목록 "합성 목록"(곡 둘), 맨 위 목록 "맨 위 목록"(곡 하나), `masterPlaylists6.xml`. 실데이터는 쓰지 않는다.
/// 그림 편집(#66) 시험용으로 넷째 곡은 분석한 곡(그림 없음), 다섯째 곡은 분석한 곡 + 합성 그림 셋·`artwork.jpg` 파일 행(상태 256)이다.
/// 평점·곡 색(#65) 시험용으로 여섯째 곡은 동기화 상태 0(쓰기를 확인한 곡)이고 어느 목록에도 없으며, `djmdColor`에 rekordbox 여덟 색이 있다.
/// 곡마다 평점·색은 rekordbox처럼 0·'0'이고 첫 곡만 평점 3·Red다.
/// `DJC_PLAYLIST_FIXTURE=<폴더> swift test --filter PlaylistWriteFixtureCapture` → `DJC_REKORDBOX_DIR=<폴더>`로 앱을 띄운다.
struct PlaylistWriteFixtureCapture {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DJC_PLAYLIST_FIXTURE"] != nil))
    func fixture() throws {
        guard let path = ProcessInfo.processInfo.environment["DJC_PLAYLIST_FIXTURE"] else { return }
        let fixture = try RekordboxFixture()
        let root = URL(filePath: path)
        for (index, title) in ["합성 곡 하나", "합성 곡 둘", "합성 곡 셋", "합성 곡 넷", "합성 곡 다섯", "합성 곡 여섯"].enumerated() {
            var track = TrackSpec(id: String(101 + index))
            track.title = title
            if index == 5 { track.dataStatus = 0 }
            if index >= 3 {
                track.analysisDataPath = "/PIONEER/USBANLZ/\(track.uuid.prefix(3))/\(track.uuid.dropFirst(3))/ANLZ0000.DAT"
                track.imagePath = ""
            }
            try fixture.add(track)
            if index == 4 { try putArtwork(fixture, track) }
        }
        // 키 고르기·쓰기 시험용 키 줄(Camelot, 살아 있음)과 곡 102의 키(8A). 나머지 곡은 키가 없다(`KeyID` NULL).
        for (id, name) in [("1486464042", "8A"), ("3730904205", "6A"), ("1010000005", "5A")] {
            try fixture.insert("djmdKey", ["ID": .text(id), "ScaleName": .text(name), "Seq": .int(1), "UUID": .text("k-\(id)"),
                                           "rb_data_status": .int(256), "rb_local_deleted": .int(0), "rb_local_usn": .int(157_637)])
        }
        try fixture.execute("UPDATE djmdContent SET KeyID = '1486464042' WHERE ID = '102'")
        for color in TrackColor.rekordboxDefaults {
            try fixture.insert("djmdColor", ["ID": .text(color.id), "SortKey": .int(Int(color.id) ?? 0), "Commnt": .text(color.name),
                                             "UUID": .text("c-\(color.id)"), "rb_data_status": .int(256), "rb_local_deleted": .int(0)])
        }
        try fixture.execute("UPDATE djmdContent SET Rating = 0, ColorID = '0'")
        try fixture.execute("UPDATE djmdContent SET Rating = 3, ColorID = '2' WHERE ID = '101'")
        try fixture.add(PlaylistSpec(id: "1001", name: "합성 폴더", seq: 1, isFolder: true))
        try fixture.add(PlaylistSpec(id: "1002", name: "합성 목록", parentID: "1001", seq: 1, contentIDs: ["101", "102"]))
        try fixture.add(PlaylistSpec(id: "1003", name: "맨 위 목록", seq: 2, contentIDs: ["103"]))
        // rekordbox가 남기는 모양(NODE Id는 16진수, 맨 위 = 0)
        let xml = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#, "",
            #"<MASTER_PLAYLIST Version="3.0.0" AutomaticSync="0">"#,
            #"  <PRODUCT Name="rekordbox" Version="7.2.18" Company="AlphaTheta"/>"#,
            "  <PLAYLISTS>",
            #"    <NODE Id="3E9" ParentId="0" Attribute="1" Timestamp="1790400600945" Lib_Type="0" CheckType="0"/>"#,
            #"    <NODE Id="3EA" ParentId="3E9" Attribute="0" Timestamp="1790400600945" Lib_Type="0" CheckType="0"/>"#,
            #"    <NODE Id="3EB" ParentId="0" Attribute="0" Timestamp="1790400600945" Lib_Type="0" CheckType="0"/>"#,
            "  </PLAYLISTS>", "</MASTER_PLAYLIST>", "",
        ].joined(separator: "\r\n")
        try xml.write(to: fixture.root.appending(path: "masterPlaylists6.xml"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: fixture.root.appending(path: "share/PIONEER/USBANLZ"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture.root, to: root)
    }

    /// rekordbox가 분석할 때 만든 것 같은 합성 그림 셋과 `artwork.jpg` 파일 행(동기화 상태 256)
    func putArtwork(_ fixture: RekordboxFixture, _ track: TrackSpec) throws {
        let files = try #require(TrackArtwork.make(ImageFixture.image(width: 600, height: 600, blue: 210)))
        let path = TrackArtwork.imagePath(uuid: track.uuid)
        let folder = fixture.shareRoot.appending(path: String(TrackArtwork.folder(uuid: track.uuid).dropFirst()))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, data) in zip(["artwork.jpg", "artwork_m.jpg", "artwork_s.jpg"], [files.full, files.medium, files.small]) {
            try data.write(to: folder.appending(path: name))
        }
        let id = "\(track.uuid)_" + (path.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? path)
        try fixture.insert("contentFile", [
            "ID": .text(id), "ContentID": .text(track.id), "Path": .text(path),
            "Hash": .text(Insecure.MD5.hash(data: files.full).map { String(format: "%02x", $0) }.joined()), "Size": .int(files.full.count),
            "rb_local_path": .text(folder.appending(path: "artwork.jpg").path), "rb_file_hash_dirty": .int(0), "rb_local_file_status": .int(0),
            "rb_in_progress": .int(0), "rb_process_type": .int(0), "rb_priority": .int(0), "rb_file_size_dirty": .int(0),
            "UUID": .text(UUID().uuidString.lowercased()), "rb_data_status": .int(256), "rb_local_data_status": .int(0),
            "rb_local_deleted": .int(0), "rb_local_synced": .int(1), "usn": .int(100), "rb_local_usn": .int(14),
        ])
        try fixture.execute("UPDATE djmdContent SET ImagePath = ? WHERE ID = ?", [.text(path), .text(track.id)])
    }
}
