import DJCDomain
import Foundation

/// 내보낼 파일 하나: 로컬 원본 → USB 상대 경로. 옮기기(음원·아트워크 복사, 분석 파일 변환)는 쓰기 단계가 한다.
public struct UsbPlannedFile: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// 로컬 음원 절대 경로
        case audio(source: String)
        /// share 아래 artwork_s.jpg(a·b) 또는 artwork_m.jpg(a_m·b_m) 절대 경로
        case artwork(source: String)
        /// share 아래 로컬 분석 파일(.2EX는 있을 때만)
        case analysis(localDAT: String, localEXT: String, local2EX: String?, localContentID: String)
    }

    public var kind: Kind
    /// USB 루트 기준 상대 경로(앞 "/" 없음). 분석 파일은 .DAT 경로
    public var destination: String
    public var contentID: Int

    public init(kind: Kind, destination: String, contentID: Int) {
        self.kind = kind
        self.destination = destination
        self.contentID = contentID
    }
}

/// 목표 USB 모델과 옮길 파일
public struct UsbExportModel: Sendable {
    public var library: UsbLibrary
    public var files: [UsbPlannedFile]

    public init(library: UsbLibrary, files: [UsbPlannedFile]) {
        self.library = library
        self.files = files
    }
}

/// 로컬 스냅샷 사본 + 내보내기 계획 → 목표 USB 모델(ID·칸 값 모두)과 파일 작업 목록.
/// content·image·재생 목록 ID는 계획 값, artist·album·genre·key·label은 곡 순서대로 처음 나올 때 번호를 준다.
public enum UsbLibraryBuilder {
    /// 새 USB: 모든 곡·목록은 `formats`에 있다
    public static func build(plan: UsbExportPlan, formats: Set<UsbFormat>, local: UsbLocalSource, share: URL,
                             myTagMasterDBID: Int64, createdDate: String) throws -> UsbExportModel {
        var library = UsbLibrary(formats: formats, property: UsbProperty(
            deviceName: "", dbVersion: OneLibraryCompatibility.databaseVersion, numberOfContents: 0, createdDate: createdDate,
            backgroundColorType: 0, myTagMasterDBID: myTagMasterDBID))
        // rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기): 색은 쓰이지 않아도 모두, 메뉴·My Tag는 로컬 행 그대로
        library.colors = try local.colors()
        library.menuItems = try local.menuItems()
        library.categories = try local.categories()
        library.sorts = try local.sorts()
        library.myTags = try local.myTags()
        var names = NameAllocator(existing: nil)
        return try assemble(plan: plan, into: library, formats: formats, names: &names, local: local, share: share)
    }

    /// 기존 USB에 곡 더하기: 기존 행·ID는 그대로 두고 새 곡·목록만 더한다.
    /// 새 artist·album·genre·key·label은 같은 이름(NFC)이 이미 있으면 그 행을 쓰고, 없으면 산 행·죽은 ID 중 가장 큰 값 다음 번호.
    /// highWater: 지운 뒤 모델에 남지 않은 ID(지난 쓰기 저널·기기 기록)까지 넘는 번호를 주려고 받는다
    public static func add(plan: UsbExportPlan, into existing: UsbLibrary, local: UsbLocalSource, share: URL,
                           highWater: [UsbIDKind: Int] = [:]) throws -> UsbExportModel {
        let formats = existing.formats.isEmpty ? UsbFormat.defaultSet : existing.formats
        let used = Set(existing.tracks.map(\.id))
        if let clash = plan.tracks.first(where: { used.contains($0.contentID) }) {
            // 계획을 뜬 뒤 USB 모델이 바뀌었다
            throw UsbError.writeRefused([UsbBlock(code: "contentIDInUse", scope: .track("usb:\(clash.contentID)"),
                                                  message: String(ui: "USB에 이미 있는 곡 번호와 겹칩니다. USB를 다시 읽은 뒤 다시 내보내세요"))])
        }
        var names = NameAllocator(existing: existing, highWater: highWater)
        return try assemble(plan: plan, into: existing, formats: formats, names: &names, local: local, share: share)
    }

    /// 1 … 2³¹−1(기기가 부호 있는 32비트로 읽어도 양수)
    public static func randomMyTagMasterDBID() -> Int64 {
        Int64.random(in: 1...Int64(Int32.max))
    }

    // MARK: - 조립

    private static func assemble(plan: UsbExportPlan, into base: UsbLibrary, formats: Set<UsbFormat>, names: inout NameAllocator,
                                 local: UsbLocalSource, share: URL) throws -> UsbExportModel {
        var library = base
        var files: [UsbPlannedFile] = []
        for trackPlan in plan.tracks {
            let row = try local.track(trackPlan.localContentID)
            library.tracks.append(track(row, plan: trackPlan, formats: formats, names: &names))
            if let imageID = trackPlan.imageID, let folder = trackPlan.artworkFolder {
                library.images.append(UsbImage(
                    id: imageID,
                    oneLibraryPath: formats.contains(.oneLibrary) ? UsbArtworkLayout.oneLibraryPath(imageID: imageID, folder: folder) : nil,
                    pdbPath: formats.contains(.deviceLibrary) ? UsbArtworkLayout.pdbPath(imageID: imageID, folder: folder) : nil))
            }
            files += plannedFiles(row, plan: trackPlan, formats: formats, share: share)
        }
        library.playlists += plan.playlists.map { playlist in
            UsbPlaylist(id: playlist.playlistID, name: playlist.name, parentID: playlist.parentID, attribute: playlist.isFolder ? 1 : 0,
                        imageID: nil, presentIn: formats, sortOrder: perFormat(formats, playlist.sortOrder),
                        entries: perFormat(formats, playlist.contentIDs))
        }
        library.artists += names.artists.added
        library.albums += names.albums
        library.genres += names.genres.added
        library.keys += names.keys.added
        library.labels += names.labels.added
        // OneLibrary 곡 수(Device Library에만 있는 곡은 세지 않는다). OneLibrary가 없으면 모든 곡
        library.property.numberOfContents = formats.contains(.oneLibrary)
            ? library.tracks.filter { $0.presentIn.contains(.oneLibrary) }.count : library.tracks.count
        return UsbExportModel(library: library.canonicalized(), files: files)
    }

    private static func perFormat<T>(_ formats: Set<UsbFormat>, _ value: T) -> [UsbFormat: T] {
        Dictionary(uniqueKeysWithValues: formats.map { ($0, value) })
    }

    /// 로컬 곡 한 행 → USB 곡(OneLibrary content 46칸과 pdb용 칸)
    private static func track(_ row: UsbLocalTrackRow, plan: UsbTrackPlan, formats: Set<UsbFormat>, names: inout NameAllocator) -> UsbTrack {
        let rating = row.rating ?? 0, playCount = row.djPlayCount ?? 0
        var track = UsbTrack(
            id: plan.contentID, presentIn: formats, titleForSearch: nil, imageID: plan.imageID, rating: rating,
            path: UsbLayout.nfc(plan.contentsPath), fileName: UsbLayout.nfc(plan.fileName), fileSize: row.fileSize ?? 0,
            djPlayCount: playCount, analysisDataPath: plan.analysisPath, hasModified: 0,
            cueUpdateCount: row.cueUpdated ?? "", analysisDataUpdateCount: row.analysisUpdated ?? "",
            // Device Library에는 hasModified 칸이 없다
            deviceFields: Dictionary(uniqueKeysWithValues: formats.map {
                ($0, UsbTrackDeviceFields(rating: rating, playCount: playCount, hasModified: $0 == .oneLibrary ? 0 : nil))
            }))
        applyInfo(row, to: &track, names: &names)
        applyAnalysis(row, to: &track)
        return track
    }

    /// 곡 정보 칸(제목·이름 번호·날짜·형식·곡 정보 갱신 횟수)을 로컬 값으로. USB 곡 정보 갱신도 이것을 쓴다.
    /// 경로·파일 이름·분석 경로·그림·기기 칸(평점·재생 수·hasModified)·큐·분석 갱신 횟수는 건드리지 않는다
    static func applyInfo(_ row: UsbLocalTrackRow, to track: inout UsbTrack, names: inout NameAllocator) {
        // 아티스트 번호는 곡마다 곡 아티스트 → 앨범 아티스트 → 작곡가 → 리믹서 → 원곡자 순으로 처음 나올 때 준다
        track.artistID = names.artists.id(local: row.artistID, name: row.artistName)
        let albumArtistID = names.artists.id(local: row.albumArtistID, name: row.albumArtistName)
        track.composerID = names.artists.id(local: row.composerID, name: row.composerName)
        track.remixerID = names.artists.id(local: row.remixerID, name: row.remixerName)
        track.originalArtistID = names.artists.id(local: row.orgArtistID, name: row.orgArtistName)
        track.albumID = names.album(local: row.albumID, name: row.albumName, artistID: albumArtistID, compilation: row.albumCompilation ?? 0)
        track.title = row.title ?? ""
        track.subtitle = row.subtitle ?? ""
        track.bpmx100 = row.bpm ?? 0
        track.lengthSeconds = row.length ?? 0
        track.trackNo = row.trackNo ?? 0
        track.discNo = row.discNo ?? 0
        // 작사가는 글자로만 있어 아티스트 행을 만들지 않는다(값이 있으면 계획이 확인 안 된 규칙으로 표시)
        track.lyricistArtistID = 0
        track.lyricist = row.lyricist ?? ""
        track.genreID = names.genres.id(local: row.genreID, name: row.genreName)
        track.labelID = names.labels.id(local: row.labelID, name: row.labelName)
        track.keyID = names.keys.id(local: row.keyID, name: row.keyName)
        track.colorID = Int(sqliteInteger(row.colorID) ?? 0)
        track.comment = row.comment ?? ""
        track.releaseYear = row.releaseYear ?? 0
        track.releaseDate = row.releaseDate ?? ""
        track.dateCreated = row.dateCreated ?? ""
        track.dateAdded = row.stockDate ?? ""
        track.fileType = row.fileType ?? 0
        track.bitrate = row.bitRate ?? 0
        track.bitDepth = row.bitDepth ?? 0
        track.sampleRate = row.sampleRate ?? 0
        track.isrc = row.isrc ?? ""
        track.hotCueAutoLoad = isOn(row.hotCueAutoLoad)
        track.kuvoDeliver = isOn(row.deliveryControl)
        track.kuvoDeliveryComment = row.deliveryComment ?? ""
        track.masterDbId = sqliteInteger(row.masterDBID) ?? 0
        track.masterContentId = sqliteInteger(row.masterSongID) ?? 0
        track.informationUpdateCount = row.trackInfoUpdated ?? ""
    }

    /// 분석 파일에서 오는 칸(분석 비트·PVDI 연결)을 로컬 값으로. 분석 파일을 다시 쓸 때만 부른다
    static func applyAnalysis(_ row: UsbLocalTrackRow, to track: inout UsbTrack) {
        track.analysedBits = row.analysed ?? 0
        track.contentLink = contentLinkBase | ((row.contentLink ?? 0) & contentLinkPVDI)
    }

    // rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)
    static let contentLinkBase = 0x0C0700
    /// 로컬 .2EX에 PVDI가 있음
    static let contentLinkPVDI = 0x100000

    /// "on"(대소문자 무시)만 켬
    static func isOn(_ text: String?) -> Bool {
        text?.lowercased() == "on"
    }

    /// SQLite `CAST(x AS INTEGER)`처럼 읽는다(`UsbSQLiteCast.integer`)
    public static func sqliteInteger(_ text: String?) -> Int64? { UsbSQLiteCast.integer(text) }

    // MARK: - 파일 작업

    private static func plannedFiles(_ row: UsbLocalTrackRow, plan: UsbTrackPlan, formats: Set<UsbFormat>, share: URL) -> [UsbPlannedFile] {
        var files: [UsbPlannedFile] = []
        func relative(_ path: String) -> String { String(path.drop { $0 == "/" }) }
        // 같은 음원을 함께 쓰는 곡과 USB에 이미 있는 음원은 옮기지 않는다
        if plan.audioDisposition == .create, let source = row.folderPath {
            files.append(UsbPlannedFile(kind: .audio(source: source), destination: relative(plan.contentsPath), contentID: plan.contentID))
        }
        if let imageID = plan.imageID, let folder = plan.artworkFolder, let imagePath = row.imagePath,
           let image = UsbExportCandidates.sharePath(share, imagePath) {
            let directory = (image as NSString).deletingLastPathComponent
            let small = directory + "/artwork_s.jpg", medium = directory + "/artwork_m.jpg"
            let paths = UsbArtworkLayout.paths(imageID: imageID, folder: folder)
            // Device Library는 a, OneLibrary는 b 그림을 가리킨다
            var pairs: [(String, String)] = []
            if formats.contains(.deviceLibrary) { pairs += [(small, paths.a), (medium, paths.aMedium)] }
            if formats.contains(.oneLibrary) { pairs += [(small, paths.b), (medium, paths.bMedium)] }
            files += pairs.map { UsbPlannedFile(kind: .artwork(source: $0.0), destination: $0.1, contentID: plan.contentID) }
        }
        if let analysis = row.analysisDataPath, let dat = UsbExportCandidates.sharePath(share, analysis) {
            let stem = (dat as NSString).deletingPathExtension
            let twoEx = stem + ".2EX"
            files.append(UsbPlannedFile(
                kind: .analysis(localDAT: dat, localEXT: stem + ".EXT", local2EX: UsbExportCandidates.regularFile(twoEx) == nil ? nil : twoEx,
                                localContentID: row.id),
                destination: relative(plan.analysisPath), contentID: plan.contentID))
        }
        return files
    }
}

// MARK: - 이름 표 번호

/// artist·genre·key·label 한 표의 USB 번호. 같은 로컬 ID는 같은 USB 번호를 받는다.
/// 새 USB는 로컬 ID로만 합친다(이름이 같은 다른 로컬 행은 따로 둔다). 기존 USB에 더할 때는 같은 이름(NFC) 행을 다시 쓴다.
struct NamedRowAllocator {
    private let reuseNames: Bool
    private var byLocalID: [String: Int] = [:]
    private var byName: [String: Int] = [:]
    private var next: Int
    private(set) var added: [UsbNamedRow] = []

    init(existing: [UsbNamedRow]?, deadIDs: Set<Int>, highWater: Int = 0) {
        reuseNames = existing != nil
        next = max(((existing ?? []).map(\.id) + deadIDs).max() ?? 0, highWater) + 1
        for row in existing ?? [] where byName[UsbLayout.nfc(row.name)] == nil { byName[UsbLayout.nfc(row.name)] = row.id }
    }

    /// 로컬 ID가 비었거나 이름 행이 없으면 nil(NULL)
    mutating func id(local: String?, name: String?) -> Int? {
        guard let local, !local.isEmpty, let name else { return nil }
        if let id = byLocalID[local] { return id }
        let key = UsbLayout.nfc(name)
        let id: Int
        if reuseNames, let reused = byName[key] {
            id = reused
        } else {
            id = next
            next += 1
            added.append(UsbNamedRow(id: id, name: name, nameForSearch: nil))
            if reuseNames { byName[key] = id }
        }
        byLocalID[local] = id
        return id
    }
}

struct NameAllocator {
    var artists: NamedRowAllocator
    var genres: NamedRowAllocator
    var keys: NamedRowAllocator
    var labels: NamedRowAllocator
    private(set) var albums: [UsbAlbum] = []
    private var albumByLocalID: [String: Int] = [:]
    private var albumByName: [AlbumKey: Int] = [:]
    private var nextAlbum: Int
    private let reuseAlbums: Bool

    struct AlbumKey: Hashable { var name: String; var artistID: Int? }

    /// highWater: 모델 밖에서 본 가장 큰 번호(종류별). 새 번호는 늘 이보다 크다
    init(existing: UsbLibrary?, highWater: [UsbIDKind: Int] = [:]) {
        let dead = existing?.deadIDs ?? [:]
        func ids(_ kind: UsbIDKind) -> Set<Int> { dead[kind.rawValue] ?? [] }
        artists = NamedRowAllocator(existing: existing?.artists, deadIDs: ids(.artist), highWater: highWater[.artist] ?? 0)
        genres = NamedRowAllocator(existing: existing?.genres, deadIDs: ids(.genre), highWater: highWater[.genre] ?? 0)
        keys = NamedRowAllocator(existing: existing?.keys, deadIDs: ids(.key), highWater: highWater[.key] ?? 0)
        labels = NamedRowAllocator(existing: existing?.labels, deadIDs: ids(.label), highWater: highWater[.label] ?? 0)
        reuseAlbums = existing != nil
        nextAlbum = max(((existing?.albums.map(\.id) ?? []) + ids(.album)).max() ?? 0, highWater[.album] ?? 0) + 1
        for album in existing?.albums ?? [] {
            let key = AlbumKey(name: UsbLayout.nfc(album.name), artistID: album.artistID)
            if albumByName[key] == nil { albumByName[key] = album.id }
        }
    }

    /// 같은 로컬 앨범은 같은 번호. 기존 USB에 같은 이름·같은 앨범 아티스트 앨범이 있으면 그 행
    mutating func album(local: String?, name: String?, artistID: Int?, compilation: Int) -> Int? {
        guard let local, !local.isEmpty, let name else { return nil }
        if let id = albumByLocalID[local] { return id }
        let key = AlbumKey(name: UsbLayout.nfc(name), artistID: artistID)
        let id: Int
        if reuseAlbums, let reused = albumByName[key] {
            id = reused
        } else {
            id = nextAlbum
            nextAlbum += 1
            albums.append(UsbAlbum(id: id, name: name, artistID: artistID, imageID: nil, isCompilation: compilation, nameForSearch: nil))
            if reuseAlbums { albumByName[key] = id }
        }
        albumByLocalID[local] = id
        return id
    }
}
