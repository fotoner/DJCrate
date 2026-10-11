import Foundation

/// 로컬 분석 파일 셋의 상태
public enum UsbAnalysisState: String, Codable, Sendable {
    /// .DAT·.EXT·.2EX 모두 있음
    case complete
    /// .DAT만
    case datOnly
    /// .DAT·.EXT만
    case missing2EX
    /// .DAT가 없거나 분석 경로가 비었음
    case missing
}

/// 로컬 아트워크 원본(share 아래 artwork_s.jpg·artwork_m.jpg 절대 경로와 크기)
public struct UsbArtworkSource: Codable, Hashable, Sendable {
    public var smallPath: String
    public var mediumPath: String
    public var smallBytes: Int
    public var mediumBytes: Int

    public init(smallPath: String, mediumPath: String, smallBytes: Int, mediumBytes: Int) {
        self.smallPath = smallPath
        self.mediumPath = mediumPath
        self.smallBytes = smallBytes
        self.mediumBytes = mediumBytes
    }
}

/// 내보낼 로컬 곡 하나(스냅샷 사본과 share에서 읽은 값)
public struct UsbExportCandidate: Codable, Hashable, Sendable {
    public var localContentID: String
    public var masterSongID: String
    public var masterDBID: String
    /// 곡 아티스트(앨범 아티스트가 아님)
    public var artistName: String?
    public var albumName: String?
    /// djmdContent.FileNameL. USB 파일 이름은 음원 경로의 끝 성분으로 짓고, 경로가 없을 때만 이 값을 쓴다(`UsbPathRules.audioFileName`)
    public var fileNameL: String
    /// 로컬 음원 절대 경로(없으면 nil)
    public var sourcePath: String?
    public var isStreaming: Bool
    public var fileType: Int
    /// djmdContent.FileSize
    public var fileSize: Int64
    /// 음원 파일 stat 크기(파일이 없으면 nil)
    public var actualFileSize: Int64?
    public var analysis: UsbAnalysisState
    /// 로컬 분석 파일(.DAT·.EXT·.2EX 중 있는 것) 중 가장 늦은 mtime
    public var analysisModifiedAt: Date?
    /// nil = 그림 없음
    public var artwork: UsbArtworkSource?
    /// ImagePath는 있는데 작은·중간 그림 파일이 없음
    public var artworkPathSetButMissing: Bool
    public var cues: [UsbCueTraits]
    public var metadata: UsbTrackMetadataFlags
    /// 로컬 분석 파일 크기(있는 것만). 용량 어림에 쓴다. nil이면 파일마다 한 클러스터로 어림한다
    public var analysisFileBytes: [Int64]?

    public init(localContentID: String, masterSongID: String, masterDBID: String, artistName: String?, albumName: String?,
                fileNameL: String, sourcePath: String?, isStreaming: Bool, fileType: Int, fileSize: Int64, actualFileSize: Int64?,
                analysis: UsbAnalysisState, analysisModifiedAt: Date?, artwork: UsbArtworkSource?, artworkPathSetButMissing: Bool,
                cues: [UsbCueTraits], metadata: UsbTrackMetadataFlags, analysisFileBytes: [Int64]? = nil) {
        self.localContentID = localContentID
        self.masterSongID = masterSongID
        self.masterDBID = masterDBID
        self.artistName = artistName
        self.albumName = albumName
        self.fileNameL = fileNameL
        self.sourcePath = sourcePath
        self.isStreaming = isStreaming
        self.fileType = fileType
        self.fileSize = fileSize
        self.actualFileSize = actualFileSize
        self.analysis = analysis
        self.analysisModifiedAt = analysisModifiedAt
        self.artwork = artwork
        self.artworkPathSetButMissing = artworkPathSetButMissing
        self.cues = cues
        self.metadata = metadata
        self.analysisFileBytes = analysisFileBytes
    }
}

/// 내보낼 재생 목록·폴더 하나(로컬 트리 순서대로 준다)
public struct UsbPlaylistInput: Codable, Hashable, Sendable {
    public var localID: String
    public var name: String
    /// nil = 맨 위
    public var parentLocalID: String?
    /// 0 목록, 1 폴더, 4 스마트
    public var attribute: Int
    /// 목록 순서
    public var trackLocalIDs: [String]

    public init(localID: String, name: String, parentLocalID: String?, attribute: Int, trackLocalIDs: [String]) {
        self.localID = localID
        self.name = name
        self.parentLocalID = parentLocalID
        self.attribute = attribute
        self.trackLocalIDs = trackLocalIDs
    }
}

/// 이미 무언가 있는 USB의 상태. 계획기는 USB를 직접 읽지 않고 이것만 본다(아무것도 없는 빈 USB면 nil).
/// 폴더 키는 USB 루트 기준 상대 경로의 성분마다 `UsbLayout.collisionKey`를 씌워 "/"로 이은 것이다(예: "contents/artist", 맨 위는 "").
public struct UsbExistingState: Sendable {
    /// USB에 rekordbox 라이브러리(DB)가 있음. false = Contents/만 있는 USB
    public var hasLibrary: Bool
    /// 폴더 키 → 그 안 이름(파일·폴더)의 collisionKey
    public var usedCollisionKeys: [String: Set<String>]
    /// 경로 키 → 실제 철자 경로(폴더·파일 모두, 예: "contents/artist" → "Contents/ARTIST",
    /// "contents/artist/album/x.mp3" → "Contents/ARTIST/Album/X.MP3"). 같은 내용을 다시 쓸 때 USB의 철자를 가리키는 데 쓴다.
    /// 파일 철자를 넣지 않으면 후보 철자로 가리킨다(FAT는 대소문자를 가리지 않아 같은 파일이지만 DB의 철자가 USB와 달라진다)
    public var folderSpelling: [String: String]
    public var ids: UsbIDAllocator
    public var artworkLayout: UsbArtworkLayout
    /// USBANLZ 아래 폴더(분석 이름 방식이 준 이름) → 있는 파일 번호와 그 파일의 곡 경로(PPTH)
    public var analysisSlots: [String: [(slot: Int, ppth: String)]]
    /// 부모 목록 ID(맨 위 0) → 기존 형제 순번의 가장 작은 값(0 또는 1)
    public var siblingBase: [Int: Int]
    /// 부모 목록 ID → 기존 형제 순번의 가장 큰 값
    public var siblingMax: [Int: Int]

    public init(hasLibrary: Bool, usedCollisionKeys: [String: Set<String>] = [:], folderSpelling: [String: String] = [:],
                ids: UsbIDAllocator = UsbIDAllocator(), artworkLayout: UsbArtworkLayout = UsbArtworkLayout(),
                analysisSlots: [String: [(slot: Int, ppth: String)]] = [:], siblingBase: [Int: Int] = [:], siblingMax: [Int: Int] = [:]) {
        self.hasLibrary = hasLibrary
        self.usedCollisionKeys = usedCollisionKeys
        self.folderSpelling = folderSpelling
        self.ids = ids
        self.artworkLayout = artworkLayout
        self.analysisSlots = analysisSlots
        self.siblingBase = siblingBase
        self.siblingMax = siblingMax
    }

    /// 내보내기: PIONEER/ 아래는 비었지만 Contents/에 파일이 있는 USB. ID·아트워크·분석 파일·형제 순번은 새 USB와 같다.
    /// folderSpelling에는 Contents/ 아래 폴더와 파일의 철자를 모두 넣는다
    public static func contentsOnly(usedCollisionKeys: [String: Set<String>], folderSpelling: [String: String]) -> UsbExistingState {
        UsbExistingState(hasLibrary: false, usedCollisionKeys: usedCollisionKeys, folderSpelling: folderSpelling)
    }

    /// 상대 경로 → 폴더 키
    public static func key(forPath path: String) -> String {
        path.split(separator: "/").map { UsbLayout.collisionKey(String($0)) }.joined(separator: "/")
    }
}

public struct UsbExportRequest: Sendable {
    /// content 순서 = 내보낸 순서
    public var candidates: [UsbExportCandidate]
    public var playlists: [UsbPlaylistInput]
    public var existing: UsbExistingState?
    public var formats: Set<UsbFormat>
    public var naming: any UsbAnalysisNaming
    /// 로컬 스냅샷 사본을 뜬 시각(`UsbSnapshotTime.resolve`). 이 뒤에 바뀐 분석 파일은 사본과 어긋나 막는다
    public var snapshotTakenAt: Date
    public var clusterSize: Int
    /// 이름이 겹칠 때만 부른다: 후보 음원과 USB의 그 파일(루트 기준 상대 경로)이 같은 내용인지(크기·SHA-256)
    public var sameContent: @Sendable (_ candidateID: String, _ usbRelativePath: String) -> Bool

    public init(candidates: [UsbExportCandidate], playlists: [UsbPlaylistInput] = [], existing: UsbExistingState? = nil,
                formats: Set<UsbFormat> = UsbFormat.defaultSet, naming: any UsbAnalysisNaming = RekordboxAnalysisNaming(),
                snapshotTakenAt: Date, clusterSize: Int = 32_768,
                sameContent: @escaping @Sendable (_ candidateID: String, _ usbRelativePath: String) -> Bool = { _, _ in false }) {
        self.candidates = candidates
        self.playlists = playlists
        self.existing = existing
        self.formats = formats
        self.naming = naming
        self.snapshotTakenAt = snapshotTakenAt
        self.clusterSize = clusterSize
        self.sameContent = sameContent
    }
}

public struct UsbTrackPlan: Codable, Hashable, Sendable {
    public enum Disposition: String, Codable, Sendable {
        /// 새로 쓴다
        case create
        /// 같은 내용이 이미 있어 쓰지 않는다
        case reuse
    }

    public var localContentID: String
    public var contentID: Int
    /// "/Contents/A/B/F"(NFC)
    public var contentsPath: String
    /// 경로 끝 성분(OneLibrary·pdb 파일 이름)
    public var fileName: String
    public var audioDisposition: Disposition
    /// USBANLZ 아래 폴더
    public var analysisFolder: String
    public var analysisSlot: Int
    /// "/PIONEER/USBANLZ/<폴더>/ANLZ%04X.DAT"
    public var analysisPath: String
    public var imageID: Int?
    public var artworkFolder: Int?
    public var rules: Set<UsbProvisionalRule>
    /// 계획 때 본 실제 음원 크기(복사 크기 검사에 쓴다). 두 DB의 파일 크기 칸은 로컬 `FileSize`라 다를 수 있다
    /// (`audioChangedSinceAnalysis`). nil이면 `FileSize`로 본다
    public var audioSize: Int64?

    public init(localContentID: String, contentID: Int, contentsPath: String, fileName: String, audioDisposition: Disposition,
                analysisFolder: String, analysisSlot: Int, analysisPath: String, imageID: Int?, artworkFolder: Int?,
                rules: Set<UsbProvisionalRule>, audioSize: Int64? = nil) {
        self.localContentID = localContentID
        self.contentID = contentID
        self.contentsPath = contentsPath
        self.fileName = fileName
        self.audioDisposition = audioDisposition
        self.analysisFolder = analysisFolder
        self.analysisSlot = analysisSlot
        self.analysisPath = analysisPath
        self.imageID = imageID
        self.artworkFolder = artworkFolder
        self.rules = rules
        self.audioSize = audioSize
    }
}

public struct UsbPlaylistPlan: Codable, Hashable, Sendable {
    public var localID: String
    public var playlistID: Int
    /// 맨 위 0
    public var parentID: Int
    public var name: String
    public var isFolder: Bool
    public var sortOrder: Int
    public var contentIDs: [Int]
    /// 이름의 pdbLongAscii 등(계획 requiredRules에도 합친다)
    public var rules: Set<UsbProvisionalRule>

    public init(localID: String, playlistID: Int, parentID: Int, name: String, isFolder: Bool, sortOrder: Int, contentIDs: [Int],
                rules: Set<UsbProvisionalRule>) {
        self.localID = localID
        self.playlistID = playlistID
        self.parentID = parentID
        self.name = name
        self.isFolder = isFolder
        self.sortOrder = sortOrder
        self.contentIDs = contentIDs
        self.rules = rules
    }
}

/// 쓰기에 필요한 USB 공간(바이트)
public struct UsbSpaceEstimate: Codable, Hashable, Sendable {
    /// 새로 쓰는 파일(음원·분석 파일·아트워크·DB)
    public var newBytes: Int64
    /// DB를 바꾸는 동안 옛 파일과 임시 파일이 함께 있는 만큼
    public var tempBytes: Int64
    public var margin: Int64
    public var total: Int64

    public init(newBytes: Int64, tempBytes: Int64, margin: Int64) {
        self.newBytes = newBytes
        self.tempBytes = tempBytes
        self.margin = margin
        total = newBytes + tempBytes + margin
    }

    public static let minimumMargin: Int64 = 64 << 20

    /// 여유분 = max(64 MiB, 가용 용량의 1%). 가용 용량을 아는 쪽(쓰기)이 다시 계산한다
    public static func margin(available: Int64) -> Int64 {
        max(minimumMargin, available / 100)
    }

    public static func roundUp(_ bytes: Int64, cluster: Int) -> Int64 {
        let cluster = Int64(max(cluster, 1))
        return (bytes + cluster - 1) / cluster * cluster
    }

    /// DB 파일 하나 어림: 곡당 4 KiB + 64 KiB
    public static func databaseBytes(trackCount: Int) -> Int64 {
        Int64(trackCount) * 4_096 + 65_536
    }
}

public struct UsbExportPlan: Sendable {
    public var tracks: [UsbTrackPlan]
    public var playlists: [UsbPlaylistPlan]
    public var blocked: [UsbBlock]
    public var requiredRules: Set<UsbProvisionalRule>
    /// 규칙별 곡 수(보고용, 곡 단위 규칙만)
    public var ruleCounts: [UsbProvisionalRule: Int]
    public var space: UsbSpaceEstimate
    /// 막지는 않는 알림(그림 파일 없음 등)
    public var warnings: [UsbBlock]
}

/// 로컬 곡·목록을 USB 어디에·어떤 ID로·어떤 이름으로 둘지, 무엇을 막을지 정한다(입출력 없음).
public enum UsbExportPlanner {
    /// 음원 크기 한계(FAT32 한계이나 exFAT에서도 같게 막음: 사용자 결정)
    static let fat32FileLimit: Int64 = 4_294_967_296

    public static func plan(_ request: UsbExportRequest) -> UsbExportPlan {
        var state = PlanState(request: request)
        var seen: Set<String> = []
        // 같은 곡을 두 번 주면 처음 것만 계획한다.
        for candidate in request.candidates where seen.insert(candidate.localContentID).inserted { state.add(candidate) }
        state.addPlaylists()
        return state.finish()
    }
}

// MARK: - 계획 상태

private struct PlanState {
    let request: UsbExportRequest
    let existing: UsbExistingState?
    var ids: UsbIDAllocator
    var artwork: UsbArtworkLayout
    let artworkStartFolder: Int
    var tracks: [UsbTrackPlan] = []
    var playlists: [UsbPlaylistPlan] = []
    var blocked: [UsbBlock] = []
    var warnings: [UsbBlock] = []
    var planRules: Set<UsbProvisionalRule> = []
    var contentIDs: [String: Int] = [:]
    /// 폴더 키 → (이름 키 → 철자). 이 계획이 만드는 폴더
    var folders: [String: [String: String]] = [:]
    /// 폴더 키 → (이름 키 → (철자, 음원 원본)). 이 계획이 쓰는 파일
    var files: [String: [String: (name: String, source: String?)]] = [:]
    /// 분석 폴더 → 이 계획이 쓰는 번호
    var analysisSlots: [String: [(slot: Int, ppth: String)]] = [:]
    /// 폴더 키 → 이 계획이 더하는 항목 이름(폴더 항목 수 추정용)
    var directoryEntries: [String: Set<String>] = [:]
    var newBytes: Int64 = 0

    init(request: UsbExportRequest) {
        self.request = request
        existing = request.existing
        ids = request.existing?.ids ?? UsbIDAllocator()
        artwork = request.existing?.artworkLayout ?? UsbArtworkLayout()
        artworkStartFolder = artwork.folder
    }

    var cluster: Int { request.clusterSize }

    func trackBlock(_ code: String, _ candidate: UsbExportCandidate, _ message: String) -> UsbBlock {
        UsbBlock(code: code, scope: .track(candidate.localContentID), message: message)
    }

    // MARK: 곡

    mutating func add(_ candidate: UsbExportCandidate) {
        let checks = blocks(candidate)
        guard checks.isEmpty else {
            blocked += checks
            return
        }
        guard let path = resolvePath(candidate) else {
            blocked.append(trackBlock("pathCollisionExhausted", candidate,
                                      String(ui: "같은 이름의 파일이 너무 많아 내보낼 수 없습니다. 파일 이름을 바꾼 뒤 다시 시도하세요")))
            return
        }
        // ID는 곡이 계획에 들어갈 때만 쓴다(막힌 곡은 번호를 받지 않는다).
        var trialIDs = ids
        let contentID = trialIDs.next(.content)
        guard let folder = request.naming.folder(contentsPath: path.contentsPath, contentID: contentID) else {
            blocked.append(trackBlock("namingUnavailable", candidate, String(ui: "이 곡의 분석 파일 위치를 정할 수 없습니다")))
            return
        }
        ids = trialIDs
        commit(path, for: candidate)

        var rules = path.rules
        rules.formUnion(request.naming.rules(contentsPath: path.contentsPath))
        let slot = UsbAnalysisSlot.choose(existing: existing?.analysisSlots[folder] ?? [], contentsPath: path.contentsPath,
                                          reserved: Set((analysisSlots[folder] ?? []).map(\.slot)))
        if slot.slot > 0 { rules.insert(.analysisSlotCollision) }
        analysisSlots[folder, default: []].append((slot.slot, path.contentsPath))
        addAnalysisEntries(folder: folder, slot: slot.slot)

        var imageID: Int?, artworkFolder: Int?
        if let source = candidate.artwork {
            let id = ids.next(.image)
            let placed = artwork.place(bytes: 2 * (source.smallBytes + source.mediumBytes))
            imageID = id
            artworkFolder = placed
            addArtworkEntries(imageID: id, folder: placed)
            newBytes += 2 * (UsbSpaceEstimate.roundUp(Int64(source.smallBytes), cluster: cluster)
                + UsbSpaceEstimate.roundUp(Int64(source.mediumBytes), cluster: cluster))
        } else {
            rules.insert(.artworkMissing)
            if candidate.artworkPathSetButMissing {
                warnings.append(trackBlock("artworkMissingFile", candidate, String(ui: "앨범아트 파일이 없어 앨범아트 없이 내보냅니다")))
            }
        }
        if candidate.cues.contains(where: { $0.kind == 4 }) {
            warnings.append(trackBlock("kind4CueDropped", candidate, String(ui: "USB에 쓸 수 없는 종류의 큐가 있어 빼고 내보냅니다")))
        }
        rules.formUnion(UsbCueRules.rules(fileType: candidate.fileType, cues: candidate.cues))
        // 곡 문자열·경로·아티스트·앨범 이름의 긴 ASCII는 rekordbox 7.2.x 경계 실험(2026-10-08)으로 모양을 확인해 규칙을 싣지 않는다
        rules.formUnion(UsbTrackRules.rules(fileType: candidate.fileType, metadata: candidate.metadata))
        // 분석 뒤 음원 크기가 바뀐 곡(태그 편집 등)도 rekordbox처럼 지금 파일을 그대로 복사하고 두 DB에는 로컬 FileSize를 적는다
        // (2026-10-08 빈 USB 실험 704곡 중 196곡, §5). 분석 파일·큐는 옛 파일 기준이라 CDJ 확인 항목으로 알린다
        if let actual = candidate.actualFileSize, actual != candidate.fileSize { rules.insert(.audioChangedSinceAnalysis) }

        if path.disposition == .create {
            newBytes += UsbSpaceEstimate.roundUp(candidate.actualFileSize ?? candidate.fileSize, cluster: cluster)
        }
        let analysisBytes = candidate.analysisFileBytes ?? [1, 1, 1]
        newBytes += analysisBytes.reduce(0) { $0 + UsbSpaceEstimate.roundUp(max($1, 1), cluster: cluster) }

        contentIDs[candidate.localContentID] = contentID
        tracks.append(UsbTrackPlan(localContentID: candidate.localContentID, contentID: contentID, contentsPath: path.contentsPath,
                                   fileName: path.fileName, audioDisposition: path.disposition, analysisFolder: folder,
                                   analysisSlot: slot.slot, analysisPath: UsbAnalysisSlot.analysisPath(folder: folder, slot: slot.slot),
                                   imageID: imageID, artworkFolder: artworkFolder, rules: rules, audioSize: candidate.actualFileSize))
    }

    /// 경로와 무관한 막힘. 스트리밍 곡은 그 하나만 낸다.
    func blocks(_ candidate: UsbExportCandidate) -> [UsbBlock] {
        if candidate.isStreaming {
            return [trackBlock("streaming", candidate, String(ui: "스트리밍 곡은 USB로 내보낼 수 없습니다"))]
        }
        var result: [UsbBlock] = []
        if candidate.sourcePath == nil || candidate.actualFileSize == nil {
            result.append(trackBlock("audioMissing", candidate,
                                     String(ui: "음원 파일이 없습니다. rekordbox에서 파일 위치를 다시 잡은 뒤 내보내세요")))
        }
        if UsbTrackRules.knownFileTypes[candidate.fileType] == nil {
            result.append(trackBlock("fileTypeUnknown", candidate, String(ui: "알 수 없는 음원 형식이라 내보낼 수 없습니다")))
        }
        if let actual = candidate.actualFileSize {
            if actual >= UsbExportPlanner.fat32FileLimit {
                result.append(trackBlock("fileTooLarge", candidate, String(ui: "4GB 이상 음원은 USB에 넣을 수 없습니다. 음원을 줄이거나 내보낼 곡에서 빼세요")))
            }
        }
        if candidate.analysis != .complete {
            result.append(trackBlock("analysisIncomplete", candidate, String(ui: "rekordbox에서 트랙 분석을 다시 한 뒤 내보내세요")))
        }
        if let modified = candidate.analysisModifiedAt, modified > request.snapshotTakenAt {
            result.append(trackBlock("analysisNewerThanSnapshot", candidate,
                                     String(ui: "rekordbox 분석이 스냅샷 뒤에 바뀌었습니다. 새 스냅샷을 뜬 뒤 다시 시도하세요")))
        }
        return result
    }

    // MARK: 경로

    struct ResolvedPath {
        var folders: [(parentKey: String, key: String, name: String)]
        var directoryKey: String
        var contentsPath: String
        var fileName: String
        var disposition: UsbTrackPlan.Disposition
        var source: String?
        var rules: Set<UsbProvisionalRule>
    }

    /// 성분 규칙 → 폴더 철자 맞추기 → 파일 이름 충돌 처리. 번호가 다 찼으면 nil
    func resolvePath(_ candidate: UsbExportCandidate) -> ResolvedPath? {
        let artist = UsbPathRules.folderComponent(candidate.artistName, unknown: "UnknownArtist")
        let album = UsbPathRules.folderComponent(candidate.albumName, unknown: "UnknownAlbum")
        let file = UsbPathRules.fileName(UsbPathRules.audioFileName(sourcePath: candidate.sourcePath, fileNameL: candidate.fileNameL))
        var rules = artist.rules.union(album.rules).union(file.rules)

        var parentKey = "", parentSpelling = ""
        var chain: [(parentKey: String, key: String, name: String)] = []
        for name in [UsbLayout.contents, artist.value, album.value] {
            let nameKey = UsbLayout.collisionKey(name)
            let key = parentKey.isEmpty ? nameKey : parentKey + "/" + nameKey
            let spelling = folders[parentKey]?[nameKey]
                ?? existing?.folderSpelling[key].flatMap { $0.split(separator: "/").last.map(String.init) }
                ?? name
            if spelling != name { rules.insert(.pathCollision) }
            chain.append((parentKey, nameKey, spelling))
            parentSpelling = parentSpelling.isEmpty ? spelling : parentSpelling + "/" + spelling
            parentKey = key
        }

        let names = [file.value] + (2...99).map { UsbPathRules.withSuffix(file.value, number: $0) }
        for (index, name) in names.enumerated() {
            let nameKey = UsbLayout.collisionKey(name)
            var disposition = UsbTrackPlan.Disposition.create
            var finalName = name
            if let planned = files[parentKey]?[nameKey] {
                // 같은 음원 파일을 가리키는 곡끼리는 한 파일을 함께 쓴다.
                guard let source = candidate.sourcePath, planned.source == source else { continue }
                disposition = .reuse
                finalName = planned.name
            } else if existing?.usedCollisionKeys[parentKey]?.contains(nameKey) == true {
                // USB에 있는 파일은 그 철자로 가리킨다. 기기가 대소문자를 가려 찾는지 확인하지 않았으니 철자가 다르면 규칙에 싣는다.
                let onDisk = existing?.folderSpelling[parentKey + "/" + nameKey].flatMap { $0.split(separator: "/").last.map(String.init) }
                    ?? name
                guard request.sameContent(candidate.localContentID, parentSpelling + "/" + onDisk) else { continue }
                disposition = .reuse
                finalName = onDisk
                if UsbLayout.nfc(onDisk) != name { rules.insert(.pathCollision) }
            }
            if index > 0 { rules.insert(.pathCollision) }
            return ResolvedPath(folders: chain, directoryKey: parentKey, contentsPath: UsbLayout.nfc("/" + parentSpelling + "/" + finalName),
                                fileName: UsbLayout.nfc(finalName), disposition: disposition, source: candidate.sourcePath, rules: rules)
        }
        return nil
    }

    mutating func commit(_ path: ResolvedPath, for candidate: UsbExportCandidate) {
        for folder in path.folders {
            if folders[folder.parentKey]?[folder.key] == nil {
                folders[folder.parentKey, default: [:]][folder.key] = folder.name
                if existing?.usedCollisionKeys[folder.parentKey]?.contains(folder.key) != true {
                    directoryEntries[folder.parentKey, default: []].insert(folder.name)
                }
            }
        }
        let nameKey = UsbLayout.collisionKey(path.fileName)
        if files[path.directoryKey]?[nameKey] == nil {
            files[path.directoryKey, default: [:]][nameKey] = (path.fileName, path.source)
            if path.disposition == .create { directoryEntries[path.directoryKey, default: []].insert(path.fileName) }
        }
    }

    mutating func addAnalysisEntries(folder: String, slot: Int) {
        let parts = folder.split(separator: "/").map(String.init)
        var parent = UsbExistingState.key(forPath: UsbLayout.analysisRoot)
        for part in parts {
            directoryEntries[parent, default: []].insert(part)
            parent += "/" + UsbLayout.collisionKey(part)
        }
        let stem = UsbAnalysisSlot.fileStem(slot: slot)
        directoryEntries[parent, default: []].formUnion([stem + ".DAT", stem + ".EXT", stem + ".2EX"])
    }

    mutating func addArtworkEntries(imageID: Int, folder: Int) {
        let paths = UsbArtworkLayout.paths(imageID: imageID, folder: folder)
        let directory = (paths.a as NSString).deletingLastPathComponent
        directoryEntries[UsbExistingState.key(forPath: UsbLayout.artworkRoot), default: []].insert((directory as NSString).lastPathComponent)
        directoryEntries[UsbExistingState.key(forPath: directory), default: []]
            .formUnion([paths.a, paths.aMedium, paths.b, paths.bMedium].map { ($0 as NSString).lastPathComponent })
    }

    // MARK: 재생 목록

    mutating func addPlaylists() {
        let inputs = request.playlists
        let known = Set(inputs.map(\.localID))
        var children: [String: [UsbPlaylistInput]] = [:]
        var roots: [UsbPlaylistInput] = []
        for input in inputs {
            if let parent = input.parentLocalID, known.contains(parent), parent != input.localID {
                children[parent, default: []].append(input)
            } else {
                roots.append(input)
            }
        }
        var nextSort: [Int: Int] = [:]
        var visited: Set<String> = []

        func visit(_ input: UsbPlaylistInput, parentID: Int, state: inout PlanState) {
            guard visited.insert(input.localID).inserted else { return }
            // 인텔리전트(스마트) 목록은 규칙을 USB에 옮기는 방법을 확인하지 않았다.
            guard input.attribute == 0 || input.attribute == 1 else {
                let message = String(ui: "인텔리전트 재생 목록은 아직 내보낼 수 없습니다. 일반 목록으로 복사한 뒤 내보내세요")
                state.blocked.append(UsbBlock(code: "smartPlaylist", scope: .playlist(input.localID), message: message))
                return
            }
            let id = state.ids.next(.playlist)
            let sortOrder = nextSort[parentID]
                ?? state.existing?.siblingMax[parentID].map { $0 + 1 }
                ?? state.existing?.siblingBase[parentID]
                ?? 0
            nextSort[parentID] = sortOrder + 1
            let isFolder = input.attribute == 1
            let rules = UsbTrackRules.pdbStringRules([input.name])
            state.planRules.formUnion(rules)
            state.planRules.insert(.playlistSiblingBase)
            if isFolder { state.planRules.insert(.playlistFolderRow) }
            state.playlists.append(UsbPlaylistPlan(
                localID: input.localID, playlistID: id, parentID: parentID, name: input.name, isFolder: isFolder, sortOrder: sortOrder,
                contentIDs: isFolder ? [] : input.trackLocalIDs.compactMap { state.contentIDs[$0] }, rules: rules))
            if isFolder {
                for child in children[input.localID] ?? [] { visit(child, parentID: id, state: &state) }
            }
        }
        for root in roots { visit(root, parentID: 0, state: &self) }
    }

    // MARK: 마무리

    mutating func finish() -> UsbExportPlan {
        if existing == nil || existing?.hasLibrary == false { planRules.insert(.myTagMasterDBID) }
        if artwork.foldersUsed.count >= 2 || artwork.foldersUsed.contains(where: { $0 != artworkStartFolder }) {
            planRules.insert(.artworkFolderSplit)
        }
        if let block = directoryLimitBlock() { blocked.append(block) }

        var ruleCounts: [UsbProvisionalRule: Int] = [:]
        for track in tracks {
            for rule in track.rules { ruleCounts[rule, default: 0] += 1 }
        }
        let databases = (request.formats.contains(.oneLibrary) ? 1 : 0) + (request.formats.contains(.deviceLibrary) ? 2 : 0)
        let database = UsbSpaceEstimate.roundUp(UsbSpaceEstimate.databaseBytes(trackCount: tracks.count), cluster: cluster)
        let space = UsbSpaceEstimate(newBytes: newBytes + Int64(databases) * database, tempBytes: databases > 0 ? 2 * database : 0,
                                     margin: UsbSpaceEstimate.minimumMargin)
        return UsbExportPlan(tracks: tracks, playlists: playlists, blocked: blocked,
                             requiredRules: planRules.union(tracks.flatMap(\.rules)), ruleCounts: ruleCounts, space: space,
                             warnings: warnings)
    }

    /// 한 폴더에 들어갈 항목(".", ".." 포함)이 한계를 넘으면 볼륨 막힘 하나
    func directoryLimitBlock() -> UsbBlock? {
        for (directory, names) in directoryEntries {
            let existingNames = existing?.usedCollisionKeys[directory] ?? []
            let newNames = names.filter { !existingNames.contains(UsbLayout.collisionKey($0)) }
            let count = 2 + existingNames.reduce(0) { $0 + UsbFatDirectory.entries(forName: $1) }
                + newNames.reduce(0) { $0 + UsbFatDirectory.entries(forName: $1) }
            if count > UsbFatDirectory.entryLimit {
                return UsbBlock(code: "directoryEntryLimit", scope: .volume,
                                message: String(ui: "한 폴더에 파일이 너무 많습니다. 곡 수를 나눠 내보내세요"))
            }
        }
        return nil
    }
}
