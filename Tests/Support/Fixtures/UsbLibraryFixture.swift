import DJCDomain
import Foundation
import RekordboxKit

/// 합성 USB 라이브러리 폴더: OneLibrary·Device Library·분석 파일 셋·아트워크·음원(작은 합성 파일)을 규격 자리에 둔다.
/// 형식 작성기 대신 `OneLibraryFixture`·`PdbBuilder`·`AnlzBuilder`로 조립한다. 모든 값(제목·경로·ID)은 지어낸 것이다.
/// 기본값으로 만든 두 형식은 서로 맞는다(합치면 불일치가 없다). 칸을 바꾼 뒤 `write(to:)`로 쓴다.
public struct UsbLibraryFixture: Sendable {
    public struct Playlist: Sendable {
        public var id: Int
        public var name: String
        public var oneLibraryEntries: [Int]
        public var deviceLibraryEntries: [Int]
        /// 목록이 있는 형식(한 형식에만 있는 목록 시험용)
        public var formats: Set<UsbFormat> = UsbFormat.defaultSet
        /// Device Library 쪽 이름(nil이면 같게. 다르면 같은 번호 목록이 형식마다 다름)
        public var deviceLibraryName: String?
        /// 순서 번호(nil이면 목록 배열 자리)
        public var sortOrder: Int?
        /// Device Library 쪽 번호(nil이면 `id`. rekordbox는 두 형식 번호를 따로 매긴다, #233)
        public var deviceLibraryID: Int?
        /// 부모 번호(OneLibrary 쪽, 0 = 맨 위)
        public var parentID = 0
        /// Device Library 쪽 부모 번호(nil이면 `parentID`)
        public var deviceLibraryParentID: Int?
        public var isFolder = false

        public init(id: Int, name: String, entries: [Int]) {
            self.init(id: id, name: name, oneLibraryEntries: entries, deviceLibraryEntries: entries)
        }

        public init(id: Int, name: String, oneLibraryEntries: [Int], deviceLibraryEntries: [Int]) {
            self.id = id
            self.name = name
            self.oneLibraryEntries = oneLibraryEntries
            self.deviceLibraryEntries = deviceLibraryEntries
        }
    }

    public var trackIDs: [Int] = [1, 2, 3]
    /// Device Library에만 있는 곡(형식 불일치 시험용)
    public var deviceOnlyTrackIDs: [Int] = []
    public var formats: Set<UsbFormat> = UsbFormat.defaultSet
    public var playlists: [Playlist] = [Playlist(id: 10, name: "시험 목록", entries: [1, 2])]
    /// 분류 하나와 그 아래 태그 하나
    public var myTags: [UsbMyTag] = [
        UsbMyTag(id: 7, parentID: 0, sequenceNo: 0, name: "시험 분류", isCategory: true),
        UsbMyTag(id: 8, parentID: 7, sequenceNo: 0, name: "시험 태그", isCategory: false),
    ]
    public var myTagLinks: [(tagID: Int64, trackID: Int)] = [(8, 1)]
    public var myTagMasterDBID: Int64 = 123_456
    /// Device Library 쪽 값(nil이면 OneLibrary와 같게)
    public var deviceMyTagMasterDBID: Int64?
    /// 곡마다 masterDbId(없으면 1_000_001)
    public var masterDbIDs: [Int: Int64] = [:]
    /// 곡마다 두 DB에 적을 분석 경로(없으면 `analysisPath(_:)`)
    public var analysisPaths: [Int: String] = [:]
    /// 곡마다 .DAT 핫큐 A(ms). 없는 곡은 핫큐가 없다
    public var hotCueA: [Int: Int] = [1: 1_000, 2: 2_000, 3: 3_000]
    public var writeAnalysis = true
    public var writeArtwork = true
    public var writeAudio = true
    /// export.pdb 머리 0x10(rekordbox가 정상으로 닫으면 5)
    public var pdbFlag10: UInt32 = 5
    /// 모르는 표(unknown9)에 넣을 산 행 수
    public var pdbUnknownRows = 0
    /// OneLibrary를 -wal과 함께 둔다(연결을 닫기 전에 복사)
    public var oneLibraryWAL = false
    /// OneLibrary property.dbVersion(확인한 값은 "1000")
    public var oneLibraryDBVersion = "1000"
    /// 곡마다 그림 id(없으면 곡 id). 두 곡이 한 그림을 함께 쓰는 시험용
    public var imageIDs: [Int: Int] = [:]
    /// Device Library 재생 기록(표 11·12) 하나에 넣을 곡
    public var pdbHistoryEntries: [Int] = []
    /// pdb 표 19의 두 번째 문자열(DJCrate 작성기는 늘 비워 쓴다)
    public var pdbPropertyName = ""

    public init() {}

    public static func trackPath(_ id: Int) -> String { "/Contents/시험 아티스트/시험 앨범/test\(id).mp3" }

    public static func analysisPath(_ id: Int) -> String { String(format: "/PIONEER/USBANLZ/P000/%08X/ANLZ0000.DAT", id) }

    public func analysisPath(_ id: Int) -> String { analysisPaths[id] ?? Self.analysisPath(id) }

    /// 작은 합성 음원 바이트
    public static func audio(_ id: Int) -> Data { Data((0..<256).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ id) }) }

    public static func artwork(_ id: Int, medium: Bool) -> Data { Data([0xFF, 0xD8, 0xFF, UInt8(truncatingIfNeeded: id), medium ? 1 : 0, 0xFF, 0xD9]) }

    /// .DAT: PPTH · PVBR · PQTZ · PWAV · PCOB(핫) · PCOB(메모리)
    public static func dat(path: String, hotCueA: Int?) -> Data {
        let hot = hotCueA.map { [UsbCueInput(id: "a", kind: 1, inMsec: $0)] } ?? []
        return AnlzBuilder.file([AnlzBuilder.ppth(path), AnlzBuilder.opaque("PVBR", bytes: 1_600),
                                 BeatGridTags.pqtz(AnlzBuilder.beats(bpm: 128, first: 50, count: 8)), AnlzBuilder.opaque("PWAV", bytes: 400),
                                 AnlzCueTags.pcob(kind: AnlzCueTags.hotList, cues: hot), AnlzCueTags.pcob(kind: AnlzCueTags.memoryList, cues: [])])
    }

    public static func ext(path: String) -> Data {
        AnlzBuilder.ext(beats: AnlzBuilder.beats(bpm: 128, first: 50, count: 8), path: path)
    }

    public static func twoEx(path: String) -> Data { AnlzBuilder.local2EX(path: path, pvdi: false) }

    public func imageID(_ track: Int) -> Int { imageIDs[track] ?? track }

    /// 곡들이 쓰는 그림 id(순서대로 한 번씩)
    var images: [Int] {
        var seen: Set<Int> = []
        return (trackIDs + deviceOnlyTrackIDs).map(imageID).filter { seen.insert($0).inserted }
    }

    public func write(to tree: UsbTreeFixture) throws {
        if formats.contains(.oneLibrary) { try writeOneLibrary(to: tree) }
        if formats.contains(.deviceLibrary) { writeDeviceLibrary(to: tree) }
        if writeArtwork {
            // Device Library는 a, OneLibrary는 b 그림을 가리킨다(한 형식만 있는 USB에는 그 형식 그림만 있다)
            let prefixes = (formats.contains(.deviceLibrary) ? ["a"] : []) + (formats.contains(.oneLibrary) ? ["b"] : [])
            for image in images {
                for prefix in prefixes {
                    for medium in [false, true] {
                        tree.write(String(format: "PIONEER/Artwork/00001/%@%d%@.jpg", prefix, image, medium ? "_m" : ""),
                                   Self.artwork(image, medium: medium))
                    }
                }
            }
        }
        for id in trackIDs + deviceOnlyTrackIDs {
            let path = Self.trackPath(id)
            if writeAudio { tree.write(String(path.dropFirst()), Self.audio(id)) }
            if writeAnalysis {
                let base = String(analysisPath(id).dropFirst().dropLast(4))
                tree.write(base + ".DAT", Self.dat(path: path, hotCueA: hotCueA[id]))
                tree.write(base + ".EXT", Self.ext(path: path))
                tree.write(base + ".2EX", Self.twoEx(path: path))
            }
        }
    }

    private func writeOneLibrary(to tree: UsbTreeFixture) throws {
        let fixture = try OneLibraryFixture()
        for id in trackIDs {
            var spec = OneLibraryTrackSpec(id: id)
            spec.fileSize = Self.audio(id).count
            spec.masterDbId = Int(masterDbIDs[id] ?? 1_000_001)
            spec.analysisDataFilePath = analysisPath(id)
            spec.imageID = writeArtwork ? imageID(id) : nil
            try fixture.add(track: spec)
        }
        if writeArtwork {
            for image in images {
                try fixture.insert("image", ["image_id": .int(image), "path": .text(String(format: "/PIONEER/Artwork/00001/b%d.jpg", image))])
            }
        }
        for (index, playlist) in playlists.enumerated() where playlist.formats.contains(.oneLibrary) {
            try fixture.add(playlist: playlist.id, name: playlist.name, parentID: playlist.parentID, attribute: playlist.isFolder ? 1 : 0,
                            sequenceNo: playlist.sortOrder ?? index, entries: playlist.isFolder ? [] : playlist.oneLibraryEntries)
        }
        for tag in myTags {
            try fixture.add(myTag: tag.id, name: tag.name, parentID: tag.parentID, sequenceNo: tag.sequenceNo, isCategory: tag.isCategory)
        }
        for link in myTagLinks { try fixture.link(myTag: link.tagID, content: link.trackID) }
        try fixture.setProperty(dbVersion: oneLibraryDBVersion, numberOfContents: trackIDs.count, createdDate: "2026-01-02",
                                myTagMasterDBID: myTagMasterDBID)
        if oneLibraryWAL {
            // 연결이 열린 동안에는 쓴 내용이 -wal에만 있다
            tree.write(UsbLayout.oneLibrary, try Data(contentsOf: fixture.url))
            tree.write(UsbLayout.oneLibrary + "-wal", try Data(contentsOf: URL(filePath: fixture.url.path + "-wal")))
        }
        fixture.close()
        if !oneLibraryWAL { tree.write(UsbLayout.oneLibrary, try Data(contentsOf: fixture.url)) }
    }

    private func writeDeviceLibrary(to tree: UsbTreeFixture) {
        var export = PdbBuilder(kind: .export)
        export.flag10 = pdbFlag10
        for id in trackIDs + deviceOnlyTrackIDs {
            var spec = PdbTrackSpec(id: id)
            spec.fileSize = Int64(Self.audio(id).count)
            spec.masterDbId = masterDbIDs[id] ?? 1_000_001
            spec[.analyzePath] = analysisPath(id)
            spec.artworkID = writeArtwork ? imageID(id) : 0
            export.add(.tracks, PdbBuilder.trackRow(spec))
        }
        if writeArtwork {
            for image in images { export.add(.artwork, PdbBuilder.idNameRow(image, String(format: "/PIONEER/Artwork/00001/a%d.jpg", image))) }
        }
        if !pdbHistoryEntries.isEmpty {
            export.add(.historyPlaylists, PdbBuilder.idNameRow(1, "HISTORY 001"))
            for (index, track) in pdbHistoryEntries.enumerated() {
                export.add(.historyEntries, PdbBuilder.historyEntryRow(trackID: track, playlistID: 1, index: index + 1))
            }
        }
        for (index, playlist) in playlists.enumerated() where playlist.formats.contains(.deviceLibrary) {
            let id = playlist.deviceLibraryID ?? playlist.id
            export.add(.playlistTree, PdbBuilder.playlistTreeRow(id: id, name: playlist.deviceLibraryName ?? playlist.name,
                                                                 parentID: playlist.deviceLibraryParentID ?? playlist.parentID,
                                                                 sortOrder: playlist.sortOrder ?? index, isFolder: playlist.isFolder))
            for (position, track) in (playlist.isFolder ? [] : playlist.deviceLibraryEntries).enumerated() {
                export.add(.playlistEntries, PdbBuilder.playlistEntryRow(index: position + 1, trackID: track, playlistID: id))
            }
        }
        for _ in 0..<pdbUnknownRows { export.add(PdbTableType.unknown9.rawValue, PdbBuilder.opaqueRow()) }
        export.add(.history19, PdbBuilder.propertyRow(count: trackIDs.count + deviceOnlyTrackIDs.count, date: "2026-01-03", name: pdbPropertyName))
        var ext = PdbBuilder(kind: .exportExt)
        for tag in myTags {
            ext.add(.tags, PdbBuilder.tagRow(id: tag.id, name: tag.name, parentID: tag.parentID, position: tag.sequenceNo,
                                             isCategory: tag.isCategory))
        }
        for link in myTagLinks { ext.add(.tagTracks, PdbBuilder.tagTrackRow(trackID: link.trackID, tagID: link.tagID)) }
        ext.add(.myTagProperty, PdbBuilder.myTagPropertyRow(masterDBID: deviceMyTagMasterDBID ?? myTagMasterDBID))
        tree.write(UsbLayout.exportPdb, export.build().data)
        tree.write(UsbLayout.exportExtPdb, ext.build().data)
    }
}
