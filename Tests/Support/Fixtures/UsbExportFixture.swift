import DJCDomain
import Foundation
import RekordboxKit

/// USB 내보내기 시험 재료: 합성 로컬 라이브러리(`RekordboxFixture`)에 곡마다 음원(FileSize와 같은 크기)·로컬 모양 분석 파일 셋·
/// 아트워크를 둔다. 제목·이름·경로·ID·DBID는 모두 지어낸 값이다(`RekordboxFixture.masterDBID`는 쓰지 않는다).
public final class UsbExportFixture {
    public let local: RekordboxFixture
    /// 지어낸 마스터 DB ID
    public static let dbid = "515151"

    public init() throws {
        local = try RekordboxFixture()
        try local.addColorDefaults()
        try local.addMenuDefaults()
    }

    public var share: URL { local.shareRoot }
    public var database: URL { local.database }

    /// 곡 하나. artist·album은 (로컬 ID, 이름) — 행이 없으면 만든다
    @discardableResult
    public func addTrack(id: String, artist: (id: String, name: String)? = nil, album: (id: String, name: String)? = nil,
                         fileName: String? = nil, bytes: Int = 3_000, audioData: Data? = nil, artwork: Bool = true,
                         pssiMood: Int? = 2, pvdi: Bool = true, analysisModified: Date? = nil) throws -> TrackSpec {
        var track = TrackSpec(id: id)
        track.title = "합성 곡 \(id)"
        if let artist {
            if try !exists("djmdArtist", artist.id) { try local.addArtist(id: artist.id, name: artist.name) }
            track.artistID = artist.id
        }
        if let album {
            if try !exists("djmdAlbum", album.id) { try local.addAlbum(id: album.id, name: album.name) }
            track.albumID = album.id
        }
        let name = fileName ?? "track\(id).mp3"
        let audio = local.audio.appending(path: "\(id)-\(UUID().uuidString.prefix(8))").appending(path: name)
        try FileManager.default.createDirectory(at: audio.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = audioData ?? Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ (Int(id) ?? 1)) })
        try data.write(to: audio)
        track.folderPath = audio.path
        try local.add(track)
        try local.setIdentity(track: track, masterSongID: "8\(id)", masterDBID: Self.dbid, fileNameL: name)
        try local.setFileSize(track: track, Int64(data.count))
        let analysis = "/PIONEER/USBANLZ/l\(id)/m\(id)/ANLZ0000.DAT"
        try local.setAnalysisPath(track: track, analysis)
        try local.writeLocalAnalysis(analysisPath: analysis, dat: AnlzBuilder.localDAT(path: "?/" + name),
                                     ext: AnlzBuilder.localEXT(path: "?/" + name, pssiMood: pssiMood),
                                     twoEx: AnlzBuilder.local2EX(path: "?/" + name, pvdi: pvdi), modified: analysisModified)
        if artwork {
            try local.writeArtwork(track: track, imagePath: "/PIONEER/Artwork/\(id)/artwork.jpg",
                                   small: Data([0xFF, 0xD8, 0x01, UInt8(truncatingIfNeeded: Int(id) ?? 0), 0xFF, 0xD9]),
                                   medium: Data([0xFF, 0xD8, 0x02, UInt8(truncatingIfNeeded: Int(id) ?? 0), 0x00, 0xFF, 0xD9]))
        }
        return track
    }

    private func exists(_ table: String, _ id: String) throws -> Bool {
        try !local.rows("SELECT 1 FROM \(table) WHERE ID = ?", [.text(id)]).isEmpty
    }

    /// 로컬 사본을 읽기 전용으로 연다
    public func open() throws -> CipherDatabase {
        try CipherDatabase(path: database.path, key: RekordboxKey.derive())
    }

    /// 계획 요청(분석 파일 시각 막힘이 없게 기본 스냅샷 시각은 먼 미래)
    public func request(_ db: CipherDatabase, ids: [String], playlists: [String] = [], formats: Set<UsbFormat> = UsbFormat.defaultSet,
                        existing: UsbExistingState? = nil, snapshotTakenAt: Date = .distantFuture,
                        sameContent: @escaping @Sendable (String, String) -> Bool = { _, _ in false }) throws -> UsbExportRequest {
        let tree = playlists.isEmpty ? [] : try UsbExportCandidates.playlistTree(database: db, rootIDs: playlists)
        var seen: Set<String> = []
        let all = (tree.flatMap(\.trackLocalIDs) + ids).filter { seen.insert($0).inserted }
        let candidates = try UsbExportCandidates.load(database: db, share: share, contentIDs: all)
        return UsbExportRequest(candidates: candidates, playlists: tree, existing: existing, formats: formats,
                                snapshotTakenAt: snapshotTakenAt, sameContent: sameContent)
    }

    /// 계획 → 빌더(행 크기 막힘으로 뺀 곡은 다시 계획)
    public func build(_ db: CipherDatabase, _ request: UsbExportRequest, myTagMasterDBID: Int64 = 777_777) throws -> UsbExportBuild {
        try UsbExportAssembly.planAndBuild(request, local: UsbLocalSource(database: db), share: share, myTagMasterDBID: myTagMasterDBID,
                                           createdDate: "2026-09-01")
    }
}
