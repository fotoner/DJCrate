import DJCDomain
import Foundation

/// Device Library를 쓰는 방식
public enum PdbWriteMode: Sendable, Hashable {
    /// 새 USB: 쪽 순번은 1부터
    case fresh
    /// 있던 파일을 다시 만든다: 모든 쪽 순번 = 옛 파일 머리 순번 + 새 파일의 상대 순번(늘 옛 머리보다 크다)
    case edit(previousExportSequence: UInt32, previousExtSequence: UInt32)
}

/// 작성기가 만든 두 파일
public struct PdbFiles: Sendable {
    public var export: Data
    public var exportExt: Data
    /// 인코더가 낸 규칙의 합집합(Encoded.rules를 버리지 않는다). 지금은 pdbLongAscii(긴 ASCII를 본 적 없는 칸),
    /// pdbFarOffsetRows(경계 실험이 보지 못한 이름 끝 247의 앨범 이름), pdbStringNFC(NFC로 바꿔 쓴 이름·제목이 있음)
    public var rules: Set<UsbProvisionalRule>
    /// 트랙 행 문자열(0–20: 경로·파일 이름 포함)에서 나온 규칙, content id별(규칙이 있는 곡만).
    /// 목록·아티스트·앨범·장르·레이블·키·태그·columns 이름에서 나온 것은 rules에만
    public var rulesByTrack: [Int: Set<UsbProvisionalRule>]
    /// 두 파일을 다시 읽으면 나올 모델: 입력의 Device Library 투영에 작성기가 정하는 칸을 채운 것
    /// (트랙 행 관찰값, 표 19의 곡 수·버전·날짜·두 번째 문자열, 평점·재생 수는 기기 칸 값, 카테고리·정렬 Disable,
    /// 목록 폴더 여부, 0인 참조는 nil, Device Library 경로가 없는 아트워크는 뺌, 사람이 읽는 문자열은 NFC).
    /// 쓴 뒤 확인은 다시 읽은 모델과 이 모델을 `UsbLibraryDiff`(formats: [.deviceLibrary])로 비교한다.
    /// 입력이 Device Library 읽기에서 온 모델이면 입력의 투영과 같다.
    public var written: UsbLibrary

    public init(export: Data, exportExt: Data, rules: Set<UsbProvisionalRule>, rulesByTrack: [Int: Set<UsbProvisionalRule>], written: UsbLibrary) {
        self.export = export
        self.exportExt = exportExt
        self.rules = rules
        self.rulesByTrack = rulesByTrack
        self.written = written
    }
}

/// `UsbLibrary` → `export.pdb`·`exportExt.pdb`(rekordbox가 새로 내보낸 모양). 모델의 Device Library 투영만 쓴다.
/// 아티스트·앨범 먼 오프셋 행과 긴 ASCII(0x40)는 rekordbox 7.2.x 경계 실험(2026-10-08)대로 쓴다.
/// 사람이 읽는 문자열은 rekordbox와 달리 NFC로 쓴다(CDJ-2000NXS가 NFD 한글을 "~"로 보임, #233, `PdbRowEncoder` 칸 표).
/// My Tag 먼 오프셋 행·기기 기록·My Tag 연결·모르는 표의 행은 쓰지 않고 막는다.
public enum PdbWriter {
    /// 모델의 .deviceLibrary 투영에서 두 파일을 만든다. 곡 0개면 던진다.
    /// 호출하는 쪽(USB 내보내기·고치기)은 `rules`를 변경 묶음 `requiredRules`에 반드시 합친다 — 계획기(`UsbExportPlanner`)가 모르는 이름(장르·My Tag 등)의 긴 ASCII도 실물 게이트에 걸리게.
    /// 막힘 문구는 일반 문구라, 호출하는 쪽이 같은 조건(곡 0개·확장자·행 크기 등)을 할 일이 적힌 문구로 먼저 막는다.
    /// 표 19 날짜는 모델의 `pdbDate`(고칠 때 보존한 값), 없으면 OneLibrary `createdDate`(내보낸 날), 그것도 없으면 오늘.
    public static func files(_ library: UsbLibrary, mode: PdbWriteMode) throws -> PdbFiles {
        let model = library.projected(to: .deviceLibrary)
        try refuseUnwritable(model)
        let date = library.property.pdbDate ?? (library.property.createdDate.isEmpty ? today() : library.property.createdDate)

        var rules: Set<UsbProvisionalRule> = []
        var rulesByTrack: [Int: Set<UsbProvisionalRule>] = [:]
        var extras: [Int: UsbPdbTrackExtras] = [:]
        var export: [Int: [PdbEncodedRow]] = [:]
        let tracks = model.tracks.sorted { $0.id < $1.id }
        export[PdbTableType.tracks.rawValue] = try tracks.map { track in
            let scope = UsbBlock.Scope.track("usb:\(track.id)")
            guard fileTypeMatchesExtension(track) else { throw refused("pdbFileTypeMismatch", scope: scope) }
            let (row, kinds) = try encoding(scope) { try PdbRowEncoder.track(track) }
            if !row.rules.isEmpty { rulesByTrack[track.id] = row.rules }
            extras[track.id] = observedExtras(kinds, flagStrings: PdbRowEncoder.trackFlagStrings(track))
            return try fitting(row, scope)
        }
        func rows<Row>(_ values: [Row], sortedBy less: (Row, Row) -> Bool, _ encode: (Row) throws -> PdbEncodedRow) throws -> [PdbEncodedRow] {
            try values.sorted(by: less).map { value in try fitting(encoding(.format(.deviceLibrary)) { try encode(value) }, .format(.deviceLibrary)) }
        }
        export[PdbTableType.genres.rawValue] = try rows(model.genres, sortedBy: byID) { try PdbRowEncoder.idName(id: $0.id, name: $0.name) }
        export[PdbTableType.artists.rawValue] = try rows(model.artists, sortedBy: byID, PdbRowEncoder.artist)
        export[PdbTableType.albums.rawValue] = try rows(model.albums, sortedBy: { $0.id < $1.id }, PdbRowEncoder.album)
        export[PdbTableType.labels.rawValue] = try rows(model.labels, sortedBy: byID) { try PdbRowEncoder.idName(id: $0.id, name: $0.name) }
        export[PdbTableType.keys.rawValue] = try rows(model.keys, sortedBy: byID, PdbRowEncoder.key)
        export[PdbTableType.colors.rawValue] = try rows(model.colors, sortedBy: byID, PdbRowEncoder.color)
        let playlists = model.playlists.sorted { $0.id < $1.id }
        export[PdbTableType.playlistTree.rawValue] = try rows(playlists, sortedBy: { $0.id < $1.id }) {
            try PdbRowEncoder.playlistTree(id: $0.id, name: $0.name, parentID: $0.parentID, sortOrder: $0.sortOrder[.deviceLibrary] ?? 0,
                                           isFolder: $0.attribute == 1)
        }
        let entries = playlists.flatMap { playlist in
            (playlist.entries[.deviceLibrary] ?? []).enumerated().map { (index: $0.offset + 1, trackID: $0.element, playlistID: playlist.id) }
        }
        export[PdbTableType.playlistEntries.rawValue] = try entries.map { entry in
            try encoding(.format(.deviceLibrary)) {
                try PdbRowEncoder.playlistEntry(index: entry.index, trackID: entry.trackID, playlistID: entry.playlistID)
            }
        }
        let images = model.images.filter { $0.pdbPath != nil }
        export[PdbTableType.artwork.rawValue] = try rows(images, sortedBy: { $0.id < $1.id }) {
            try PdbRowEncoder.artwork(id: $0.id, path: $0.pdbPath ?? "")
        }
        export[PdbTableType.columns.rawValue] = try rows(model.menuItems, sortedBy: { $0.id < $1.id }, PdbRowEncoder.column)
        export[PdbTableType.category.rawValue] = try rows(model.categories, sortedBy: { ($0.sequenceNo, $0.id) < ($1.sequenceNo, $1.id) },
                                                          PdbRowEncoder.category)
        export[PdbTableType.sort.rawValue] = try rows(model.sorts, sortedBy: { ($0.sequenceNo, $0.id) < ($1.sequenceNo, $1.id) }, PdbRowEncoder.sort)
        export[PdbTableType.history19.rawValue] = [try encoding(.format(.deviceLibrary)) {
            try PdbRowEncoder.property(trackCount: tracks.count, date: date)
        }]
        var ext: [Int: [PdbEncodedRow]] = [:]
        ext[PdbExtTableType.myTagProperty.rawValue] = [try encoding(.format(.deviceLibrary)) {
            try PdbRowEncoder.myTagProperty(masterDBID: model.property.myTagMasterDBID)
        }]
        ext[PdbExtTableType.tags.rawValue] = try orderedTags(model.myTags).map { tag in
            try fitting(encoding(.format(.deviceLibrary)) { try PdbRowEncoder.tag(tag) }, .format(.deviceLibrary))
        }
        for row in export.values.joined() { rules.formUnion(row.rules) }
        for row in ext.values.joined() { rules.formUnion(row.rules) }

        let bases: (export: UInt32, ext: UInt32) = switch mode {
        case .fresh: (0, 0)
        case let .edit(previousExportSequence, previousExtSequence): (previousExportSequence, previousExtSequence)
        }
        let exportLayout = PdbLayout(kind: .export, rows: export), extLayout = PdbLayout(kind: .exportExt, rows: ext)
        // 옛 머리 순번은 USB에서 읽은 값이다: 새 순번이 u32를 넘으면 늘 옛 머리보다 크게 쓸 수 없어 막는다
        guard exportLayout.sequenceFits(base: bases.export), extLayout.sequenceFits(base: bases.ext) else {
            throw refused("pdbSequenceOverflow")
        }
        return PdbFiles(
            export: exportLayout.data(sequenceBase: bases.export),
            exportExt: extLayout.data(sequenceBase: bases.ext),
            rules: rules, rulesByTrack: rulesByTrack,
            written: written(model, date: date, extras: extras))
    }

    // MARK: - 막힘

    /// 곡이 없는 파일, 옮기는 방법을 정하지 않은 행(기기 기록·모르는 표·My Tag 연결)은 쓰지 않는다
    static func refuseUnwritable(_ model: UsbLibrary) throws {
        // rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기): 표 19 곡 수 = 산 트랙 수, 관찰한 파일에는 늘 곡이 있었다
        guard !model.tracks.isEmpty else { throw refused("pdbNoTracks") }
        guard model.histories.isEmpty, model.unknownRows.isEmpty else {
            throw refused(UsbProvisionalRule.carriedDeviceRows.rawValue, rule: .carriedDeviceRows)
        }
        guard model.myTagLinks.isEmpty else { throw refused(UsbProvisionalRule.myTagLinks.rawValue, rule: .myTagLinks) }
    }

    /// file_type이 파일 이름 확장자와 맞는지(대소문자 무시, 12는 aif도)
    /// rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)
    static func fileTypeMatchesExtension(_ track: UsbTrack) -> Bool {
        guard let expected = UsbTrackRules.knownFileTypes[track.fileType] else { return false }
        let actual = (track.fileName as NSString).pathExtension.lowercased()
        return actual == expected || (expected == "aiff" && actual == "aif")
    }

    static func refused(_ code: String, scope: UsbBlock.Scope = .format(.deviceLibrary), rule: UsbProvisionalRule? = nil) -> UsbError {
        .writeRefused([UsbBlock(code: code, scope: scope,
                                message: rule?.summary ?? String(ui: "USB에 쓰지 않았습니다. 조건을 확인한 뒤 다시 시도하세요"), rule: rule)])
    }

    /// 행 인코더 오류를 막힘으로 바꾼다
    static func encoding<T>(_ scope: UsbBlock.Scope, _ make: () throws -> T) throws -> T {
        do {
            return try make()
        } catch let error as PdbRowError {
            switch error {
            case .farOffset: throw refused(UsbProvisionalRule.pdbFarOffsetRows.rawValue, scope: scope, rule: .pdbFarOffsetRows)
            case .rowTooLarge: throw refused("pdbRowTooLarge", scope: scope)
            case let .valueOutOfRange(field): throw refused("pdbValueOutOfRange.\(field)", scope: scope)
            case .isrcNotASCII: throw refused("pdbISRCNotASCII", scope: scope)
            }
        }
    }

    /// 빈 쪽에도 들어가지 않는 행은 막는다(긴 문자열의 길이 칸이 16비트를 넘는 행도 여기서 걸린다)
    static func fitting(_ row: PdbEncodedRow, _ scope: UsbBlock.Scope) throws -> PdbEncodedRow {
        guard PdbRowSize.fitsEmptyPage(rowSize: row.bytes.count) else { throw refused("pdbRowTooLarge", scope: scope) }
        return row
    }

    // MARK: - 순서

    static func byID(_ a: UsbNamedRow, _ b: UsbNamedRow) -> Bool { a.id < b.id }

    /// 분류를 순서대로, 분류마다 그 태그를 순서대로. 분류가 없는 태그는 끝에 (부모, 순서, id) 순
    static func orderedTags(_ tags: [UsbMyTag]) -> [UsbMyTag] {
        let bySequence: (UsbMyTag, UsbMyTag) -> Bool = { ($0.sequenceNo, $0.id) < ($1.sequenceNo, $1.id) }
        var result: [UsbMyTag] = [], placed: Set<Int64> = []
        for category in tags.filter(\.isCategory).sorted(by: bySequence) where placed.insert(category.id).inserted {
            result.append(category)
            for tag in tags.filter({ !$0.isCategory && $0.parentID == category.id }).sorted(by: bySequence) where placed.insert(tag.id).inserted {
                result.append(tag)
            }
        }
        let rest = tags.filter { !placed.contains($0.id) }.sorted { ($0.parentID, $0.sequenceNo, $0.id) < ($1.parentID, $1.sequenceNo, $1.id) }
        return result + rest
    }

    // MARK: - 쓴 모델

    /// 작성기가 쓰는 트랙 행 관찰값(뜻 모를 문자열은 모두 빈 값, 참·거짓 문자열은 곡마다 "ON"·'')
    static func observedExtras(_ kinds: [PdbStringKind], flagStrings: [Int: String] = [:]) -> UsbPdbTrackExtras {
        UsbPdbTrackExtras(subtype: UInt16(PdbRowEncoder.trackSubtype), bitmask: UInt32(PdbRowEncoder.trackBitmask),
                          u5: UInt16(PdbRowEncoder.trackU5), u7: UInt16(PdbRowEncoder.trackU7),
                          unknownStrings: Dictionary(uniqueKeysWithValues: PdbRows.trackUnknownStrings.map { ($0, "") }), stringKinds: kinds,
                          flagStrings: flagStrings)
    }

    static func written(_ model: UsbLibrary, date: String, extras: [Int: UsbPdbTrackExtras]) -> UsbLibrary {
        var result = model
        func present(_ id: Int?) -> Int? { id == 0 ? nil : id }
        result.formats = [.deviceLibrary]
        result.tracks = model.tracks.map { track in
            var track = track
            let device = track.deviceFields[.deviceLibrary]
            track.rating = device?.rating ?? track.rating
            track.djPlayCount = device?.playCount ?? track.djPlayCount
            track.deviceFields = [.deviceLibrary: UsbTrackDeviceFields(rating: track.rating, playCount: track.djPlayCount, hasModified: nil)]
            track.composerID = present(track.composerID)
            track.imageID = present(track.imageID)
            track.keyID = present(track.keyID)
            track.originalArtistID = present(track.originalArtistID)
            track.labelID = present(track.labelID)
            track.remixerID = present(track.remixerID)
            track.genreID = present(track.genreID)
            track.albumID = present(track.albumID)
            track.artistID = present(track.artistID)
            return track
        }
        result.albums = model.albums.map { album in
            var album = album
            album.artistID = present(album.artistID)
            return album
        }
        result.images = model.images.filter { $0.pdbPath != nil }
        result.playlists = model.playlists.map { playlist in
            var playlist = playlist
            playlist.attribute = playlist.attribute == 1 ? 1 : 0
            playlist.sortOrder = [.deviceLibrary: playlist.sortOrder[.deviceLibrary] ?? 0]
            playlist.entries = [.deviceLibrary: playlist.entries[.deviceLibrary] ?? []]
            return playlist
        }
        result.categories = model.categories.map { category in
            var category = category
            let disable = PdbRowEncoder.categoryDisable(category)
            category.infoOrder = category.infoOrder ?? 0
            category.disable = disable
            category.isVisible = disable != 1
            return category
        }
        // 분류 행의 부모 칸은 늘 0으로 쓴다
        result.myTags = model.myTags.map { tag in
            var tag = tag
            if tag.isCategory { tag.parentID = 0 }
            return tag
        }
        result.sorts = model.sorts.map { sort in
            var sort = sort
            let disable = PdbRowEncoder.sortDisable(sort)
            sort.disable = disable
            sort.isVisible = disable != 1
            sort.isSelectedAsSubColumn = disable == 2
            return sort
        }
        result.property.dbVersion = PdbRowEncoder.propertyVersion
        result.property.numberOfContents = model.tracks.count
        result.property.pdbDate = date
        result.property.pdbDeviceName = ""
        result.trackRowExtras = extras
        result.deadIDs = [:]
        return nfcText(result).canonicalized()
    }

    // MARK: - 철자(#233)

    /// 작성기가 NFC로 쓰는 문자열 칸(`PdbRowEncoder` 칸 표와 같은 칸)마다 `transform`을 부른다.
    /// 트랙 경로·파일 이름·분석 파일 경로·아트워크 경로는 USB 파일 철자라 넣지 않는다
    static func mapText(_ model: inout UsbLibrary, _ transform: (String) -> String) {
        for index in model.tracks.indices {
            model.tracks[index].lyricist = transform(model.tracks[index].lyricist)
            model.tracks[index].subtitle = transform(model.tracks[index].subtitle)
            model.tracks[index].comment = transform(model.tracks[index].comment)
            model.tracks[index].title = transform(model.tracks[index].title)
        }
        for table in [\UsbLibrary.artists, \.genres, \.keys, \.labels, \.colors] {
            for index in model[keyPath: table].indices { model[keyPath: table][index].name = transform(model[keyPath: table][index].name) }
        }
        for index in model.albums.indices { model.albums[index].name = transform(model.albums[index].name) }
        for index in model.playlists.indices { model.playlists[index].name = transform(model.playlists[index].name) }
        for index in model.myTags.indices { model.myTags[index].name = transform(model.myTags[index].name) }
        for index in model.menuItems.indices { model.menuItems[index].name = transform(model.menuItems[index].name) }
    }

    /// 작성기가 쓸 철자(사람이 읽는 문자열을 NFC로)
    static func nfcText(_ model: UsbLibrary) -> UsbLibrary {
        var result = model
        mapText(&result, UsbNameSpelling.deviceLibraryText)
        return result
    }

    /// 다시 쓰면 철자가 바뀌는 문자열(NFC가 아닌 이름·제목)이 있는지. USB에서 읽은 Device Library 모델에 주면
    /// rekordbox가 NFD로 쓴 이름이 남아 있는지를 알려 준다(편집이 그 USB의 Device Library를 다시 만들어 고치게, `UsbEditSource`)
    public static func needsNFC(_ model: UsbLibrary) -> Bool {
        var copy = model, found = false
        mapText(&copy) { value in
            if !found, UsbNameSpelling.changesUnderNFC(value) { found = true }
            return value
        }
        return found
    }

    /// 오늘(이 Mac의 시간대) "YYYY-MM-DD"
    static func today() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}
