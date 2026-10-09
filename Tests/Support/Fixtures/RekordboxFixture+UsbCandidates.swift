import DJCDomain
import Foundation
import RekordboxKit

/// USB 내보내기 후보 시험용: 곡 행의 USB 칸과 share 아래 분석 파일·아트워크를 합성한다.
/// 마스터 DB ID는 시험마다 지어낸 값을 넣는다(`RekordboxFixture.masterDBID`를 쓰지 않는다).
public extension RekordboxFixture {
    /// 곡의 MasterSongID·MasterDBID·FileNameL
    func setIdentity(track: TrackSpec, masterSongID: String, masterDBID: String, fileNameL: String) throws {
        try execute("UPDATE djmdContent SET MasterSongID = ?, MasterDBID = ?, FileNameL = ? WHERE ID = ?",
                    [.text(masterSongID), .text(masterDBID), .text(fileNameL), .text(track.id)])
    }

    func setFileSize(track: TrackSpec, _ size: Int64) throws {
        try execute("UPDATE djmdContent SET FileSize = ? WHERE ID = ?", [.int(Int(size)), .text(track.id)])
    }

    /// djmdContent.AnalysisDataPath(share 기준, "/PIONEER/USBANLZ/…/ANLZxxxx.DAT")
    func setAnalysisPath(track: TrackSpec, _ path: String?) throws {
        try execute("UPDATE djmdContent SET AnalysisDataPath = ? WHERE ID = ?", [path.map { .text($0) } ?? .null, .text(track.id)])
    }

    /// share 아래 분석 파일 셋을 만든다(nil이면 그 파일은 없음). 경로는 `AnalysisDataPath`에서 확장자만 바꾼다.
    func writeLocalAnalysis(analysisPath: String, dat: Data?, ext: Data?, twoEx: Data?, modified: Date? = nil) throws {
        let datURL = shareRoot.appending(path: String(analysisPath.drop(while: { $0 == "/" })))
        try FileManager.default.createDirectory(at: datURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        for (data, url) in [(dat, datURL), (ext, datURL.deletingPathExtension().appendingPathExtension("EXT")),
                            (twoEx, datURL.deletingPathExtension().appendingPathExtension("2EX"))] {
            guard let data else { continue }
            try data.write(to: url)
            if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
        }
    }

    /// djmdContent.ImagePath(share 기준 ".../artwork.jpg")와 같은 폴더의 artwork_s.jpg·artwork_m.jpg(nil이면 없음)
    func writeArtwork(track: TrackSpec, imagePath: String, small: Data?, medium: Data?) throws {
        try execute("UPDATE djmdContent SET ImagePath = ? WHERE ID = ?", [.text(imagePath), .text(track.id)])
        let folder = shareRoot.appending(path: String(imagePath.drop(while: { $0 == "/" }))).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let small { try small.write(to: folder.appending(path: "artwork_s.jpg")) }
        if let medium { try medium.write(to: folder.appending(path: "artwork_m.jpg")) }
    }

    /// 빈 값으로만 본 곡 정보 칸
    func setMetadata(track: TrackSpec, labelID: String? = nil, remixerID: String? = nil, orgArtistID: String? = nil,
                     lyricist: String? = nil, colorID: String? = nil, rating: Int? = nil, subtitle: String? = nil,
                     searchStr: String? = nil) throws {
        func value(_ text: String?) -> CipherDatabase.Value { text.map { .text($0) } ?? .null }
        try execute("""
            UPDATE djmdContent SET LabelID = ?, RemixerID = ?, OrgArtistID = ?, Lyricist = ?, ColorID = ?, Rating = ?, Subtitle = ?,
                SearchStr = ? WHERE ID = ?
            """, [value(labelID), value(remixerID), value(orgArtistID), value(lyricist), value(colorID), rating.map { .int($0) } ?? .null,
                  value(subtitle), value(searchStr), .text(track.id)])
    }

    /// pdb 문자열 칸(제목 외)
    func setStrings(track: TrackSpec, comment: String? = nil, isrc: String? = nil, releaseDate: String? = nil,
                    dateCreated: String? = nil, stockDate: String? = nil) throws {
        func value(_ text: String?) -> CipherDatabase.Value { text.map { .text($0) } ?? .null }
        try execute("UPDATE djmdContent SET Commnt = ?, ISRC = ?, ReleaseDate = ?, DateCreated = ?, StockDate = ? WHERE ID = ?",
                    [value(comment), value(isrc), value(releaseDate), value(dateCreated), value(stockDate), .text(track.id)])
    }

    func addArtist(id: String, name: String) throws {
        try insert("djmdArtist", ["ID": .text(id), "Name": .text(name), "rb_local_deleted": .int(0)])
    }

    func addAlbum(id: String, name: String, albumArtistID: String? = nil, compilation: Int = 0) throws {
        try insert("djmdAlbum", ["ID": .text(id), "Name": .text(name), "AlbumArtistID": albumArtistID.map { .text($0) } ?? .null,
                                 "Compilation": .int(compilation), "rb_local_deleted": .int(0)])
    }

    /// 재생 목록·폴더·스마트 목록 하나(Attribute·SmartList를 그대로 넣는다)
    func addPlaylist(id: String, name: String, parentID: String = "root", seq: Int, attribute: Int = 0, smartList: String? = nil,
                     contentIDs: [String] = []) throws {
        try insert("djmdPlaylist", ["ID": .text(id), "Seq": .int(seq), "Name": .text(name), "Attribute": .int(attribute),
                                    "ParentID": .text(parentID), "SmartList": smartList.map { .text($0) } ?? .null,
                                    "UUID": .text(UUID().uuidString.lowercased()), "rb_local_deleted": .int(0)])
        for (index, contentID) in contentIDs.enumerated() {
            try insert("djmdSongPlaylist", ["ID": .text("\(id)-\(index)"), "PlaylistID": .text(id), "ContentID": .text(contentID),
                                            "TrackNo": .int(index + 1), "UUID": .text(UUID().uuidString.lowercased()),
                                            "rb_local_deleted": .int(0)])
        }
    }

    /// 임시 폴더 안 합성 음원(크기만 중요)
    func writeAudio(named name: String, bytes: Int) throws -> URL {
        let url = audio.appending(path: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x55, count: bytes).write(to: url)
        return url
    }
}
