import Foundation

/// `djc usb-info --json`(v1)과 앱 사이드바가 쓰는 USB 읽기 결과. 개인 식별값(masterDbId·myTagMasterDBID·볼륨 UUID)은 담지 않는다.
/// 볼륨 이름은 `root`(받은 경로)에만 나올 수 있고 다른 칸에는 없다.
/// 키는 늘 있다: 없는 값은 생략하지 않고 null로 쓴다(뒤 판이 값을 채워도 JSON 모양이 그대로이게).
public struct UsbInfo: Codable, Sendable, Hashable {
    public var schemaVersion = 1
    /// 받은 경로를 절대 경로로 바꾼 것(링크는 풀지 않는다). 볼륨 대상이면 `/Volumes/<이름>`처럼 볼륨 이름이 들어갈 수 있다
    public var root: String
    /// "oneLibrary", "deviceLibrary"(PIONEER/rekordbox의 파일 이름으로 판정)
    public var formats: [String]
    /// 폴더 대상이면 nil
    public var volume: Volume?
    public var oneLibrary: OneLibraryPart?
    public var deviceLibrary: DeviceLibraryPart?
    public var consistency: Consistency
    public var analysis: Analysis
    public var media: Media
    public var settings: [Setting]
    public var localCompatibility: Local?
    public var warnings: [Warning]

    public struct Volume: Codable, Sendable, Hashable {
        /// "FAT32" 등(번역하지 않는 이름)
        public var fileSystem: String
        /// "mbr"·"gpt"·"apm"·"none"·"unknown"
        public var partitionScheme: String
        public var isDiskImage: Bool
        public var writableForExport: Bool
        public var writableForEdit: Bool
        /// 내보내기·고치기 정책 문제 code(`UsbVolumePolicy.problems`, 겹치면 한 번)
        public var problems: [String]

        public init(fileSystem: String, partitionScheme: String, isDiskImage: Bool, writableForExport: Bool, writableForEdit: Bool,
                    problems: [String]) {
            self.fileSystem = fileSystem
            self.partitionScheme = partitionScheme
            self.isDiskImage = isDiskImage
            self.writableForExport = writableForExport
            self.writableForEdit = writableForEdit
            self.problems = problems
        }
    }

    public struct OneLibraryPart: Codable, Sendable, Hashable {
        /// 확인한 모양(표·칸·dbVersion)인지
        public var schemaOK: Bool
        /// "wal"·"rollback", 사본을 열지 못했으면 "unknown"
        public var headerMode: String
        public var walPresent, journalPresent, integrityOK: Bool
        public var tracks, playlists, myTags, histories: Int

        public init(schemaOK: Bool, headerMode: String, walPresent: Bool, journalPresent: Bool, integrityOK: Bool, tracks: Int,
                    playlists: Int, myTags: Int, histories: Int) {
            self.schemaOK = schemaOK
            self.headerMode = headerMode
            self.walPresent = walPresent
            self.journalPresent = journalPresent
            self.integrityOK = integrityOK
            self.tracks = tracks
            self.playlists = playlists
            self.myTags = myTags
            self.histories = histories
        }
    }

    public struct DeviceLibraryPart: Codable, Sendable, Hashable {
        /// export.pdb 머리 0x10(rekordbox가 정상으로 닫으면 5)
        public var exportFlag10: Int
        /// exportExt.pdb 머리 0x10(파일이 없으면 nil)
        public var extFlag10: Int?
        /// 왕복 검사(읽은 모델로 다시 만든 바이트 = 원본)를 했는지. 아직 하지 않는다
        public var roundTripChecked: Bool
        /// 왕복 검사 결과. 검사하지 않았으면 nil
        public var roundTripOK: Bool?
        public var tracks, playlists: Int
        /// 기록 표(history_playlists·history_entries) 산 행 수
        public var historyRows: Int
        /// 모델에 담지 않는(모르는) 표의 산 행 수
        public var unknownTableRows: Int
        /// 구조 문제 수(`PdbReadReport.issues`)
        public var structureIssues: Int

        public init(exportFlag10: Int, extFlag10: Int?, roundTripChecked: Bool, roundTripOK: Bool?, tracks: Int, playlists: Int,
                    historyRows: Int, unknownTableRows: Int, structureIssues: Int) {
            self.exportFlag10 = exportFlag10
            self.extFlag10 = extFlag10
            self.roundTripChecked = roundTripChecked
            self.roundTripOK = roundTripOK
            self.tracks = tracks
            self.playlists = playlists
            self.historyRows = historyRows
            self.unknownTableRows = unknownTableRows
            self.structureIssues = structureIssues
        }

        enum CodingKeys: String, CodingKey {
            case exportFlag10, extFlag10, roundTripChecked, roundTripOK, tracks, playlists, historyRows, unknownTableRows, structureIssues
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(exportFlag10, forKey: .exportFlag10)
            try container.encode(extFlag10, forKey: .extFlag10)
            try container.encode(roundTripChecked, forKey: .roundTripChecked)
            try container.encode(roundTripOK, forKey: .roundTripOK)
            try container.encode(tracks, forKey: .tracks)
            try container.encode(playlists, forKey: .playlists)
            try container.encode(historyRows, forKey: .historyRows)
            try container.encode(unknownTableRows, forKey: .unknownTableRows)
            try container.encode(structureIssues, forKey: .structureIssues)
        }
    }

    /// 두 형식(OneLibrary·Device Library)이 서로 맞는지. 식별값은 같은지만 적는다
    public struct Consistency: Codable, Sendable, Hashable {
        public var trackIDsMatch, pathsMatch: Bool
        /// 두 형식이 다른 재생 목록 수(항목·이름·부모·한쪽에만)
        public var playlistMismatches: Int
        /// 모든 곡의 masterDbId가 한 값인지
        public var masterDbIdConsistent: Bool
        /// 두 형식의 myTagMasterDBID가 같은지
        public var myTagMasterDBIDConsistent: Bool
        /// 고치기를 막는 불일치가 있는지(`UsbFormatMismatch.blocksEditing`)
        public var editBlocked: Bool

        public init(trackIDsMatch: Bool = true, pathsMatch: Bool = true, playlistMismatches: Int = 0, masterDbIdConsistent: Bool = true,
                    myTagMasterDBIDConsistent: Bool = true, editBlocked: Bool = false) {
            self.trackIDsMatch = trackIDsMatch
            self.pathsMatch = pathsMatch
            self.playlistMismatches = playlistMismatches
            self.masterDbIdConsistent = masterDbIdConsistent
            self.myTagMasterDBIDConsistent = myTagMasterDBIDConsistent
            self.editBlocked = editBlocked
        }
    }

    /// 곡마다 DB가 가리키는 분석 파일(.DAT·.EXT·.2EX) 점검
    public struct Analysis: Codable, Sendable, Hashable {
        public var tracksChecked: Int
        /// 없는 분석 파일 수(파일 단위)
        public var missingFiles: Int
        /// .DAT PPTH ≠ 곡 경로(NFC)이거나 PPTH를 읽지 못한 곡 수
        public var ppthMismatches: Int
        /// 파일 번호가 0이 아닌(ANLZ0001 등) 분석 경로 수
        public var slotCollisions: Int

        public init(tracksChecked: Int = 0, missingFiles: Int = 0, ppthMismatches: Int = 0, slotCollisions: Int = 0) {
            self.tracksChecked = tracksChecked
            self.missingFiles = missingFiles
            self.ppthMismatches = ppthMismatches
            self.slotCollisions = slotCollisions
        }
    }

    /// 음원 내용은 열지 않고 DB가 가리키는 일반 파일의 존재만 확인한다
    public struct Media: Codable, Sendable, Hashable {
        public var tracksChecked: Int
        /// 두 형식의 같은 NFC 경로는 한 번만 센다
        public var filesChecked: Int
        public var missingFiles: Int

        public init(tracksChecked: Int = 0, filesChecked: Int = 0, missingFiles: Int = 0) {
            self.tracksChecked = tracksChecked
            self.filesChecked = filesChecked
            self.missingFiles = missingFiles
        }
    }

    /// 알려진 설정 파일의 검증 상태만 담는다(문자열·설정 칸 값은 내지 않는다)
    public struct Setting: Codable, Sendable, Hashable {
        public enum Status: String, Codable, Sendable { case missing, valid, invalid, unreadable }
        public var fileName: String
        public var status: Status
        /// 번역하지 않는 첫 실패 code. 정상·부재면 nil
        public var issue: String?
        /// 종류별 크기가 맞고 읽을 수 있을 때만 CRC를 계산한다
        public var crcOK: Bool?

        public init(fileName: String, status: Status, issue: String? = nil, crcOK: Bool? = nil) {
            self.fileName = fileName
            self.status = status
            self.issue = issue
            self.crcOK = crcOK
        }

        enum CodingKeys: String, CodingKey { case fileName, status, issue, crcOK }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(fileName, forKey: .fileName)
            try container.encode(status, forKey: .status)
            try container.encode(issue, forKey: .issue)
            try container.encode(crcOK, forKey: .crcOK)
        }
    }

    /// 이 Mac의 rekordbox가 DJCrate가 확인한 버전인지
    public struct Local: Codable, Sendable, Hashable {
        public var rekordboxVersion: String?
        public var verified: Bool

        public init(rekordboxVersion: String?, verified: Bool) {
            self.rekordboxVersion = rekordboxVersion
            self.verified = verified
        }

        enum CodingKeys: String, CodingKey { case rekordboxVersion, verified }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(rekordboxVersion, forKey: .rekordboxVersion)
            try container.encode(verified, forKey: .verified)
        }
    }

    public struct Warning: Codable, Sendable, Hashable {
        /// 영어 고정 식별자
        public var code: String
        /// 이유와 할 일(번역)
        public var message: String

        public init(code: String, message: String) {
            self.code = code
            self.message = message
        }
    }

    public init(root: String, formats: [String] = [], volume: Volume? = nil, oneLibrary: OneLibraryPart? = nil,
                deviceLibrary: DeviceLibraryPart? = nil, consistency: Consistency = Consistency(), analysis: Analysis = Analysis(),
                media: Media = Media(), settings: [Setting] = [], localCompatibility: Local? = nil, warnings: [Warning] = []) {
        self.root = root
        self.formats = formats
        self.volume = volume
        self.oneLibrary = oneLibrary
        self.deviceLibrary = deviceLibrary
        self.consistency = consistency
        self.analysis = analysis
        self.media = media
        self.settings = settings
        self.localCompatibility = localCompatibility
        self.warnings = warnings
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, root, formats, volume, oneLibrary, deviceLibrary, consistency, analysis, media, settings, localCompatibility, warnings
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        root = try container.decode(String.self, forKey: .root)
        formats = try container.decode([String].self, forKey: .formats)
        volume = try container.decodeIfPresent(Volume.self, forKey: .volume)
        oneLibrary = try container.decodeIfPresent(OneLibraryPart.self, forKey: .oneLibrary)
        deviceLibrary = try container.decodeIfPresent(DeviceLibraryPart.self, forKey: .deviceLibrary)
        consistency = try container.decode(Consistency.self, forKey: .consistency)
        analysis = try container.decode(Analysis.self, forKey: .analysis)
        // v1의 새 진단 키가 없는 기존 입력도 읽는다
        media = try container.decodeIfPresent(Media.self, forKey: .media) ?? Media()
        settings = try container.decodeIfPresent([Setting].self, forKey: .settings) ?? []
        localCompatibility = try container.decodeIfPresent(Local.self, forKey: .localCompatibility)
        warnings = try container.decode([Warning].self, forKey: .warnings)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(root, forKey: .root)
        try container.encode(formats, forKey: .formats)
        try container.encode(volume, forKey: .volume)
        try container.encode(oneLibrary, forKey: .oneLibrary)
        try container.encode(deviceLibrary, forKey: .deviceLibrary)
        try container.encode(consistency, forKey: .consistency)
        try container.encode(analysis, forKey: .analysis)
        try container.encode(media, forKey: .media)
        try container.encode(settings, forKey: .settings)
        try container.encode(localCompatibility, forKey: .localCompatibility)
        try container.encode(warnings, forKey: .warnings)
    }
}
