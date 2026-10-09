import CryptoKit
import DJCDomain
import DJCTestKit
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

/// USB 수정 엔진: 합성 USB(DJCrate 내보내기로 만든 것·rekordbox가 만든 것 같은 것)와 합성 로컬 라이브러리.
/// USB는 임시 폴더(디스크 이미지로 보이는 가짜 가드)이고 모든 값은 지어낸 것이다.
@Suite("USB 수정 엔진")
struct UsbEditEngineTests {
    /// 로컬 곡 셋(101·102·103, 아티스트·앨범 하나)과 그 곡의 목록(900)을 내보낸 USB. USB 목록 id 1, 곡 id 1·2·3
    static func exported(_ ids: [String] = ["101", "102", "103"], playlist: Bool = true) throws -> UsbEditFixture {
        let env = try UsbEditFixture()
        try env.addLocal(ids)
        if playlist {
            try env.local.local.addPlaylist(id: "900", name: "합성 목록", seq: 1, contentIDs: ids)
            try env.export(tracks: [], playlists: ["900"])
        } else {
            try env.export(tracks: ids)
        }
        return env
    }

    /// rekordbox가 만든 것 같은 합성 USB(Device Library My Tag 연결은 DJCrate가 다시 쓸 수 없어 기본으로 뺀다)
    static func rekordboxStyle(_ configure: (inout UsbLibraryFixture) -> Void = { _ in }) throws -> UsbEditFixture {
        let env = try UsbEditFixture()
        var library = UsbLibraryFixture()
        library.myTagLinks = []
        configure(&library)
        try env.write(library)
        return env
    }

    static func isBlocked(_ outcome: UsbOutcome?, _ code: String) -> Bool {
        if case let .blocked(block) = outcome { block.code == code } else { false }
    }

    static func sha256(_ data: Data?) -> String? {
        data.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
    }

    // MARK: - USB 전체 막힘

    @Test("두 형식의 곡 번호가 다르면 모든 편집을 막는다")
    func trackIDMismatchBlocksAll() throws {
        let env = try Self.rekordboxStyle { $0.deviceOnlyTrackIDs = [9] }
        let result = try env.plan([.playlist(edit: .rename(playlist: .id("10"), name: "합성 새 이름")), .removeTracks(usbContentIDs: [1])],
                                  withLocal: false)
        #expect(result.blocks.map(\.code) == ["formatTrackMismatch"])
        #expect(result.blocks.first?.message.contains("rekordbox에서 다시 내보내세요") == true)
        #expect(result.changes == nil)
        #expect(result.outcomes.count == 2 && result.outcomes.allSatisfy { Self.isBlocked($0.outcome, "formatTrackMismatch") })
    }

    @Test("OneLibrary 사본이 손상되면 모든 편집을 막는다")
    func integrityFailureBlocks() throws {
        let env = try Self.exported(["101"], playlist: false)
        var data = try #require(env.usb.data(UsbLayout.oneLibrary))
        let at = data.count - 200
        data.replaceSubrange(at..<at + 16, with: Data(repeating: 0x5A, count: 16))
        env.usb.write(UsbLayout.oneLibrary, data)
        let result = try env.plan([.removeTracks(usbContentIDs: [1])], withLocal: false)
        #expect(result.blocks.map(\.code) == ["libraryCorrupt"])
        #expect(result.blocks[0].message.contains("손상"))
        #expect(result.changes == nil)
    }

    @Test("APFS 볼륨은 형식 이름과 할 일을 적어 막는다(exFAT은 고친다)")
    func apfsEditMessage() throws {
        let env = try Self.exported(["101"], playlist: false)
        let result = try env.plan([.removeTracks(usbContentIDs: [1])], withLocal: false, volume: FakeUsbVolume.apfs())
        let block = try #require(result.blocks.first { $0.code == "unsupportedFileSystem" })
        #expect(block.message.contains("APFS") && block.message.contains("FAT32나 exFAT로 포맷"))
        let exfat = try env.plan([.removeTracks(usbContentIDs: [1])], withLocal: false, volume: FakeUsbVolume.exfat())
        #expect(!exfat.blocks.contains { $0.code == "unsupportedFileSystem" })
        #expect(result.changes == nil)
    }

    @Test("모르는 OneLibrary 버전은 고치지 않는다")
    func oneLibraryUnsupportedBlocks() throws {
        let env = try Self.rekordboxStyle { $0.oneLibraryDBVersion = "1001" }
        let result = try env.plan([.removeTracks(usbContentIDs: [1])], withLocal: false)
        #expect(result.blocks.map(\.code).contains("oneLibraryUnsupported"))
        #expect(result.changes == nil)
    }

    @Test("부모를 찾을 수 없는 목록이 있으면 목록 편집(과 다른 편집)을 막는다")
    func orphanPlaylistBlocksEdits() throws {
        let env = try Self.rekordboxStyle {
            var orphan = UsbLibraryFixture.Playlist(id: 11, name: "합성 고아 목록", entries: [1])
            orphan.formats = [.deviceLibrary]
            orphan.parentID = 99
            $0.playlists.append(orphan)
        }
        let result = try env.plan([.playlist(edit: .rename(playlist: .id("10"), name: "합성 새 이름"))], withLocal: false)
        #expect(Self.isBlocked(result.outcome(1), "formatPlaylistConflict"))
        #expect(result.changes == nil)
    }

    // MARK: - Device Library만 막힘

    @Test("pdb 머리 0x10이 4면 Device Library만 막고 OneLibrary는 쓴다")
    func flag10Four_DLBlocked_OneLibraryWritten() throws {
        let env = try Self.exported()
        env.setPdbFlag(4)
        let pdbBefore = env.usb.data(UsbLayout.exportPdb)
        let (result, report) = try env.edit([.playlist(edit: .create(key: "n", name: "합성 새 목록", isFolder: false, parent: .root))],
                                            withLocal: false)
        #expect(result.formatsBlocked[.deviceLibrary]?.code == "pdbNotClosed")
        #expect(result.formatsWritten == [.oneLibrary])
        #expect(result.outcome(1) == .written)
        #expect(result.changes?.databases.map(\.destination) == [UsbLayout.oneLibrary])
        #expect(report.outcome == .written)
        #expect(env.usb.data(UsbLayout.exportPdb) == pdbBefore)
        #expect(try env.read(.oneLibrary)?.playlists.map(\.name) == ["합성 목록", "합성 새 목록"])
    }

    @Test("모르는 표에 산 행이 있으면 Device Library만 막는다(기기 행 규칙)")
    func unknownTableRows_DLBlocked() throws {
        let env = try Self.rekordboxStyle { $0.pdbUnknownRows = 2 }
        let result = try env.plan([.playlist(edit: .create(key: "n", name: "합성 새 목록", isFolder: false, parent: .root))], withLocal: false)
        let block = try #require(result.formatsBlocked[.deviceLibrary])
        #expect(block.code == "carriedDeviceRows" && block.rule == .carriedDeviceRows)
        #expect(result.formatsWritten == [.oneLibrary])
        #expect(result.outcome(1) == .written)
    }

    @Test("다시 쓸 수 없는 Device Library(My Tag 연결)면 그 형식만 막고 이유를 적는다")
    func roundTripFailure_DLBlocked() throws {
        let env = try Self.rekordboxStyle { $0.myTagLinks = [(8, 1)] }
        let result = try env.plan([.playlist(edit: .create(key: "n", name: "합성 새 목록", isFolder: false, parent: .root))], withLocal: false)
        let block = try #require(result.formatsBlocked[.deviceLibrary])
        #expect(block.code == "pdbRoundTripFailed")
        #expect(block.message.contains("myTagLinks"))
        #expect(result.formatsWritten == [.oneLibrary])
    }

    @Test("pdb 표 19의 두 번째 문자열에 값이 있으면 다시 쓸 수 없어 Device Library만 막는다")
    func pdbDeviceNameBlocksDeviceLibrary() throws {
        let env = try Self.rekordboxStyle { $0.pdbPropertyName = "SYNTH" }
        let result = try env.plan([.playlist(edit: .create(key: "n", name: "합성 새 목록", isFolder: false, parent: .root))], withLocal: false)
        #expect(result.formatsBlocked[.deviceLibrary]?.code == "pdbRoundTripFailed")
        #expect(result.formatsWritten == [.oneLibrary])
    }

    @Test("한 형식이 막히면 파일 지우기를 미루고 OneLibrary에서만 곡을 뺀다")
    func fileDeletionDeferredWhenFormatBlocked() throws {
        let env = try Self.exported()
        env.setPdbFlag(4)
        let track = try #require(try env.read().tracks.first { $0.id == 2 })
        let (result, report) = try env.edit([.removeTracks(usbContentIDs: [2])])
        guard case .deferred = result.outcome(1) else { Issue.record("미루지 않음: \(String(describing: result.outcome(1)))"); return }
        #expect(result.changes?.removals.isEmpty == true)
        #expect(result.notes.contains { $0.contains("미뤘습니다") })
        #expect(report.outcome == .written)
        #expect(env.usb.exists(String(track.path.dropFirst())))
        #expect(env.usb.exists(String(track.analysisDataPath.dropFirst())))
        #expect(try env.read(.oneLibrary)?.tracks.map(\.id) == [1, 3])
        #expect(try env.read(.deviceLibrary)?.tracks.map(\.id) == [1, 2, 3])
    }

    @Test("USB에 남은 -wal은 사본에서 합쳐 읽고 막지 않는다(쓸 때 USB의 -wal은 지운다)")
    func walLeftIsMergedNotBlocked() throws {
        let env = try Self.rekordboxStyle { $0.oneLibraryWAL = true }
        #expect(env.usb.exists(UsbLayout.oneLibrary + "-wal"))
        let result = try env.plan([.playlist(edit: .rename(playlist: .id("10"), name: "합성 새 이름"))], withLocal: false)
        #expect(result.blocks.isEmpty)
        #expect(result.notes.contains { $0.contains("-wal") })
        #expect(result.outcome(1) == .written)
        let report = try env.write(result)
        #expect(report.outcome == .written)
        #expect(!env.usb.exists(UsbLayout.oneLibrary + "-wal"))
        #expect(try env.read(.oneLibrary)?.playlists.map(\.name) == ["합성 새 이름"])
    }

    // MARK: - 곡 갱신

    @Test("로컬과 같은 곡은 바꾸지 않는다")
    func upToDateUnchanged() throws {
        let env = try Self.exported(["101", "102"], playlist: false)
        let result = try env.plan([.refreshTracks(usbContentIDs: [1], parts: Set(UsbRefreshPart.allCases))])
        #expect(result.outcome(1) == .unchanged)
        #expect(result.changes == nil)
    }

    @Test("기기에서 고친 곡(hasModified·기기 큐 행)은 통째로 건너뛰고 알린다")
    func deviceModifiedSkipped() throws {
        let env = try Self.exported(["101", "102"], playlist: false)
        try env.updateLocal("101", "TrackInfoUpdated = '2', Title = '합성 새 제목'")
        try env.updateLocal("102", "TrackInfoUpdated = '2', Title = '합성 새 제목 둘'")
        try env.oneLibrarySQL("UPDATE content SET hasModified = 1 WHERE content_id = 1")
        try env.oneLibrarySQL("INSERT INTO cue (cue_id, content_id, kind) VALUES (1, 2, 0)")
        let result = try env.plan([.refreshTracks(usbContentIDs: [1], parts: [.info]), .refreshTracks(usbContentIDs: [2], parts: [.info])])
        #expect(result.outcome(1) == .unchanged && result.outcome(2) == .unchanged)
        #expect(result.notes.filter { $0.contains("기기에서 고친 곡") }.count == 2)
        #expect(result.changes == nil)
    }

    @Test("곡 정보 갱신은 로컬 값으로 바꾸고 평점·재생 수·hasModified·기록은 USB 값을 지킨다")
    func deviceOwnedFieldsPreserved() throws {
        let env = try Self.exported(["101", "102"], playlist: false)
        try env.oneLibrarySQL("UPDATE content SET rating = 3, djPlayCount = 7 WHERE content_id = 1")
        try env.oneLibrarySQL("INSERT INTO history (history_id, sequenceNo, name, attribute, history_id_parent) VALUES (1, 1, 'HISTORY', 0, 0)")
        try env.oneLibrarySQL("INSERT INTO history_content (history_id, content_id, sequenceNo) VALUES (1, 2, 1)")
        try env.updateLocal("101", "TrackInfoUpdated = '2', Title = '합성 새 제목', Rating = 1, DJPlayCount = 99")
        let (result, report) = try env.edit([.refreshTracks(usbContentIDs: [1], parts: [.info])])
        #expect(result.outcome(1) == .written)
        #expect(report.outcome == .written)
        let oneLibrary = try #require(try env.read(.oneLibrary))
        let track = try #require(oneLibrary.tracks.first { $0.id == 1 })
        #expect(track.title == "합성 새 제목" && track.informationUpdateCount == "2")
        #expect(track.rating == 3 && track.djPlayCount == 7 && track.hasModified == 0)
        #expect(oneLibrary.histories.map(\.entries) == [[2]])
        let device = try #require(try env.read(.deviceLibrary)?.tracks.first { $0.id == 1 })
        #expect(device.title == "합성 새 제목")
        #expect(device.rating == 0 && device.djPlayCount == 0)
    }

    @Test("두 곡이 함께 쓰는 아티스트를 한 곡만 로컬에서 바꾸면 새 아티스트 행을 만들고 다른 곡은 그대로")
    func sharedArtistRenamedOnlyForOneTrack() throws {
        let env = try Self.exported(["101", "102"], playlist: false)
        let before = try env.read()
        let shared = try #require(before.tracks.first { $0.id == 1 }?.artistID)
        try env.local.local.addArtist(id: "2", name: "합성 새 아티스트")
        try env.updateLocal("101", "TrackInfoUpdated = '2', ArtistID = '2'")
        let (result, _) = try env.edit([.refreshTracks(usbContentIDs: [1], parts: [.info])])
        #expect(result.outcome(1) == .written)
        let after = try env.read()
        let renamed = try #require(after.tracks.first { $0.id == 1 }?.artistID)
        #expect(renamed != shared && renamed > (before.artists.map(\.id).max() ?? 0))
        #expect(after.tracks.first { $0.id == 2 }?.artistID == shared)
        #expect(after.artists.first { $0.id == renamed }?.name == "합성 새 아티스트")
        #expect(after.artists.contains { $0.id == shared })
    }

    @Test("아티스트 이름이 바뀌어도 기존 곡의 음원·분석 경로는 옮기지 않는다")
    func pathsNotMovedOnArtistRename() throws {
        let env = try Self.exported(["101", "102"], playlist: false)
        let before = try #require(try env.read().tracks.first { $0.id == 1 })
        try env.local.local.addArtist(id: "2", name: "합성 새 아티스트")
        try env.updateLocal("101", "TrackInfoUpdated = '2', ArtistID = '2'")
        let (result, _) = try env.edit([.refreshTracks(usbContentIDs: [1], parts: [.info])])
        #expect(result.changes?.copies.isEmpty == true && result.changes?.removals.isEmpty == true)
        let after = try #require(try env.read().tracks.first { $0.id == 1 })
        #expect(after.path == before.path && after.fileName == before.fileName && after.analysisDataPath == before.analysisDataPath)
    }

    @Test("큐 갱신은 DB가 적은 분석 파일 자리에 덮어쓰고, 그 파일이 다른 곡 것이면 고치지 않는다")
    func anlzOverwriteRequiresPPTH() throws {
        let env = try Self.exported(["101", "102"], playlist: false)
        var spec = TrackSpec(id: "101")
        spec.uuid = UUID().uuidString.lowercased()
        try env.local.local.addCue(track: spec, kind: 1, inMsec: 1_500)
        try env.updateLocal("101", "CueUpdated = '2'")
        let track = try #require(try env.read().tracks.first { $0.id == 1 })
        let dat = String(track.analysisDataPath.dropFirst())

        let result = try env.plan([.refreshTracks(usbContentIDs: [1], parts: [.cues])])
        #expect(result.outcome(1) == .written)
        let write = try #require(result.changes?.writes.first { $0.destination == dat })
        #expect(write.disposition == .overwrite && write.expectedExistingPPTH == track.path && write.expectedExistingSHA256 != nil)
        #expect(result.changes?.writes.allSatisfy { $0.destination.hasPrefix(String(dat.dropLast(4))) } == true)

        // 곡 1의 분석 파일 자리에 곡 2의 파일이 있으면(번호가 엉킨 USB) 고치지 않는다
        let other = try #require(try env.read().tracks.first { $0.id == 2 })
        for ext in [".DAT", ".EXT", ".2EX"] {
            env.usb.write(String(dat.dropLast(4)) + ext, try #require(env.usb.data(String(other.analysisDataPath.dropFirst().dropLast(4)) + ext)))
        }
        let swapped = try env.plan([.refreshTracks(usbContentIDs: [1], parts: [.cues])])
        #expect(swapped.changes?.writes.isEmpty ?? true)
        #expect(swapped.notes.contains { $0.contains("분석 파일이 다른 곡 것이라 고치지 않았습니다") })
        // 분석 파일을 고치지 않았으니 갱신 횟수도 USB 값 그대로(DB만 최신이라고 적지 않는다)
        #expect(swapped.changes == nil && swapped.outcome(1) == .unchanged)
        #expect(swapped.applied?.tracks.first { $0.id == 1 }?.cueUpdateCount == track.cueUpdateCount)
        // 곡 정보는 고치고 큐 갱신 횟수만 USB 값으로 둔다
        try env.updateLocal("101", "TrackInfoUpdated = '2', Title = '합성 새 제목'")
        let mixed = try env.plan([.refreshTracks(usbContentIDs: [1], parts: [.info, .cues])])
        #expect(mixed.outcome(1) == .written && mixed.changes?.writes.isEmpty == true)
        let applied = try #require(mixed.applied?.tracks.first { $0.id == 1 })
        #expect(applied.title == "합성 새 제목" && applied.cueUpdateCount == track.cueUpdateCount)
    }

    @Test("여러 곡 갱신에서 한 곡만 막히면 그 곡만 빼고 나머지를 쓰고, 모두 막히면 편집을 막는다")
    func refreshBlocksOnlyThatTrack() throws {
        let env = try Self.exported(["101", "102"], playlist: false)
        let row = try env.local.local.rows("SELECT FolderPath FROM djmdContent WHERE ID = '102'")
        let path = try #require(row.first?["FolderPath"])
        var data = try Data(contentsOf: URL(filePath: path))
        data[0] ^= 0xFF
        try data.write(to: URL(filePath: path))
        try env.updateLocal("101", "TrackInfoUpdated = '2', Title = '합성 새 제목'")
        try env.updateLocal("102", "TrackInfoUpdated = '2', Title = '합성 새 제목 둘'")
        let (result, report) = try env.edit([.refreshTracks(usbContentIDs: [1, 2], parts: [.info])])
        #expect(result.outcome(1) == .written && report.outcome == .written)
        #expect(result.trackBlocks.map(\.code) == ["audioChanged"])
        let after = try env.read()
        #expect(after.tracks.first { $0.id == 1 }?.title == "합성 새 제목")
        #expect(after.tracks.first { $0.id == 2 }?.title != "합성 새 제목 둘")
        let all = try env.plan([.refreshTracks(usbContentIDs: [2, 99], parts: [.info])])
        #expect(Self.isBlocked(all.outcome(1), "audioChanged"))
        #expect(all.changes == nil && all.trackBlocks.isEmpty)
    }

    @Test("큐 갱신을 쓰면 USB 분석 파일에 새 큐가 들어가고 갱신 횟수도 로컬 값")
    func cueRefreshWritten() throws {
        let env = try Self.exported(["101"], playlist: false)
        var spec = TrackSpec(id: "101")
        spec.uuid = UUID().uuidString.lowercased()
        try env.local.local.addCue(track: spec, kind: 1, inMsec: 1_500)
        try env.updateLocal("101", "CueUpdated = '2'")
        let track = try #require(try env.read().tracks.first { $0.id == 1 })
        let before = env.usb.data(String(track.analysisDataPath.dropFirst()))
        let (result, report) = try env.edit([.refreshTracks(usbContentIDs: [1], parts: [.cues])])
        #expect(result.outcome(1) == .written && report.outcome == .written)
        #expect(report.filesOverwritten >= 1)
        #expect(env.usb.data(String(track.analysisDataPath.dropFirst())) != before)
        #expect(try env.read().tracks.first { $0.id == 1 }?.cueUpdateCount == "2")
    }

    @Test("로컬 음원이 USB 파일과 다르면 갱신을 막는다")
    func audioChangedBlocks() throws {
        let env = try Self.exported(["101"], playlist: false)
        let row = try env.local.local.rows("SELECT FolderPath FROM djmdContent WHERE ID = '101'")
        let path = try #require(row.first?["FolderPath"])
        var data = try Data(contentsOf: URL(filePath: path))
        data[0] ^= 0xFF
        try data.write(to: URL(filePath: path))
        try env.updateLocal("101", "TrackInfoUpdated = '2'")
        let result = try env.plan([.refreshTracks(usbContentIDs: [1], parts: [.info])])
        #expect(Self.isBlocked(result.outcome(1), "audioChanged"))
        #expect(result.changes == nil)
    }

    /// 로컬 곡의 FileSize를 실제 음원보다 작게 적는다(rekordbox 분석 뒤 태그를 고쳐 파일이 커진 곡). 실제 크기를 돌려준다
    static func shrinkRecordedSize(_ env: UsbEditFixture, _ id: String, by delta: Int = 7) throws -> Int {
        let row = try env.local.local.rows("SELECT FolderPath FROM djmdContent WHERE ID = '\(id)'")
        let path = try #require(row.first?["FolderPath"])
        let actual = try Data(contentsOf: URL(filePath: path)).count
        try env.updateLocal(id, "FileSize = ?", [.int(actual - delta)])
        return actual
    }

    /// 두 형식에서 읽은 곡(로컬 곡 ID로 찾는다, 마스터 곡 ID = "8" + 로컬 ID)
    static func usbTracks(_ env: UsbEditFixture, local id: String) throws -> [UsbTrack] {
        try [UsbFormat.oneLibrary, .deviceLibrary].map { format in
            try #require(try env.read(format)?.tracks.first { $0.masterContentId == Int64("8" + id) })
        }
    }

    @Test("분석 뒤 크기가 바뀐 음원도 rekordbox처럼 지금 파일을 그대로 내보내고 두 DB에는 로컬 FileSize를 적는다")
    func exportAudioChangedSinceAnalysis() throws {
        let env = try UsbEditFixture()
        try env.addLocal(["101", "102"])
        let actual = try Self.shrinkRecordedSize(env, "102")
        let db = try env.local.open()
        let build = try env.local.build(db, try env.local.request(db, ids: ["101", "102"]))
        db.close()
        #expect(build.plan.blocked.isEmpty && build.plan.tracks.count == 2)
        #expect(build.plan.requiredRules.contains(.audioChangedSinceAnalysis) && build.plan.ruleCounts[.audioChangedSinceAnalysis] == 1)
        // 쓰기(모든 검증기 통과는 export가 확인한다)
        try env.export(tracks: ["101", "102"])
        let tracks = try Self.usbTracks(env, local: "102")
        #expect(tracks.allSatisfy { $0.fileSize == Int64(actual - 7) })
        #expect(env.usb.data(String(tracks[0].path.dropFirst()))?.count == actual)
        // 다른 곡은 그대로 맞는다. 크기 비교를 빼지 않으면 이 곡만 형식과 무관하게 한 번 잡힌다
        let scratch = env.usb.folder.appending(path: "problems")
        #expect(try UsbInvariantVerifier.problems(on: env.usb.root, fileSystem: env.usb.fileSystem(), scratch: scratch)
            == ["audioSize content \(tracks[0].id)"])
        // 갱신: USB 음원이 지금 로컬 음원과 같아 막지 않고, 파일 크기 칸도 로컬 FileSize 그대로다
        try env.updateLocal("102", "TrackInfoUpdated = '2', Title = '합성 새 제목'")
        let (result, report) = try env.edit([.refreshTracks(usbContentIDs: [tracks[0].id], parts: [.info])])
        #expect(result.outcome(1) == .written && report.outcome == .written && result.trackBlocks.isEmpty)
        #expect(try Self.usbTracks(env, local: "102").allSatisfy { $0.title == "합성 새 제목" && $0.fileSize == Int64(actual - 7) })
    }

    @Test("곡 더하기도 분석 뒤 크기가 바뀐 음원을 실제 크기로 복사해 더하고, 음원 파일이 없는 곡만 막는다")
    func addAudioChangedSinceAnalysis() throws {
        let env = try Self.exported(["101"], playlist: false)
        try env.addLocal(["102", "103"])
        let actual = try Self.shrinkRecordedSize(env, "102")
        let missing = try #require(try env.local.local.rows("SELECT FolderPath FROM djmdContent WHERE ID = '103'").first?["FolderPath"])
        try FileManager.default.removeItem(atPath: missing)
        let (result, report) = try env.edit([.addTracks(localContentIDs: ["102", "103"], playlist: nil)])
        #expect(result.outcome(1) == .written && report.outcome == .written)
        #expect(result.trackBlocks.map(\.code) == ["audioMissing"])
        let changes = try #require(result.changes)
        #expect(changes.requiredRules.contains(.audioChangedSinceAnalysis))
        let tracks = try Self.usbTracks(env, local: "102")
        #expect(result.audioSizeFromDatabase == [tracks[0].id])
        #expect(changes.copies.first { $0.destination == String(tracks[0].path.dropFirst()) }?.size == Int64(actual))
        #expect(tracks.allSatisfy { $0.fileSize == Int64(actual - 7) })
        #expect(env.usb.data(String(tracks[0].path.dropFirst()))?.count == actual)
    }

    @Test("사본 이름의 시각 뒤에 로컬 분석 파일이 바뀐 곡은 그 곡 갱신만 막는다")
    func refreshUsesSnapshotTimeFromName() throws {
        let env = try Self.exported(["101", "102"], playlist: false)
        let copy = env.usb.folder.appending(path: "named/master-2026-01-02T030405.db")
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: env.local.database, to: copy)
        let snapshot = try UsbSnapshotTime.resolve(explicit: nil, database: copy)
        #expect(snapshot.source == .fileName)
        env.snapshotTakenAt = snapshot.date
        let later = snapshot.date.addingTimeInterval(3_600), earlier = snapshot.date.addingTimeInterval(-3_600)
        for (id, date) in [("101", later), ("102", earlier)] {
            let dat = env.localAnalysis(id)
            for url in [dat, dat.deletingPathExtension().appendingPathExtension("EXT"), dat.deletingPathExtension().appendingPathExtension("2EX")] {
                try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            }
            try env.updateLocal(id, "CueUpdated = '2'")
        }
        let result = try env.plan([.refreshTracks(usbContentIDs: [1], parts: [.cues]), .refreshTracks(usbContentIDs: [2], parts: [.cues])])
        #expect(Self.isBlocked(result.outcome(1), "analysisNewerThanSnapshot"))
        #expect(result.outcome(2) == .written)
    }

    @Test("로컬 사본이 없거나 확인하지 않은 rekordbox 버전이면 곡 갱신·더하기만 막는다")
    func localRequirements() throws {
        let env = try Self.exported(["101", "102"], playlist: false)
        let missing = try env.plan([.refreshTracks(usbContentIDs: [1], parts: [.info]), .removeTracks(usbContentIDs: [2])], withLocal: false)
        #expect(Self.isBlocked(missing.outcome(1), "localLibraryMissing"))
        #expect(missing.outcome(2) == .written)
        env.appVersion = "6.8.5"
        let old = try env.plan([.addTracks(localContentIDs: ["101"], playlist: nil)])
        guard case let .blocked(block) = old.outcome(1) else { Issue.record("막지 않음"); return }
        #expect(block.code == "localVersionUnverified" && block.message.contains("6.8.5"))
    }

    // MARK: - 곡 빼기

    @Test("재생 기록(OneLibrary·Device Library)에 있는 곡은 빼지 않는다")
    func historyReferencedBlocked() throws {
        let env = try Self.exported()
        try env.oneLibrarySQL("INSERT INTO history (history_id, sequenceNo, name, attribute, history_id_parent) VALUES (1, 1, 'HISTORY', 0, 0)")
        try env.oneLibrarySQL("INSERT INTO history_content (history_id, content_id, sequenceNo) VALUES (1, 2, 1)")
        let result = try env.plan([.removeTracks(usbContentIDs: [2]), .removeTracks(usbContentIDs: [3])])
        #expect(Self.isBlocked(result.outcome(1), "historyReferenced"))
        #expect(result.outcome(2) == .written)

        let device = try Self.rekordboxStyle { $0.pdbHistoryEntries = [2] }
        let deviceResult = try device.plan([.removeTracks(usbContentIDs: [2])], withLocal: false)
        #expect(deviceResult.formatsBlocked[.deviceLibrary]?.code == "carriedDeviceRows")
        #expect(Self.isBlocked(deviceResult.outcome(1), "historyReferenced"))
    }

    @Test("남는 곡이 0이 되면 빼지 않는다")
    func lastTrackBlocked() throws {
        let env = try Self.exported(["101"], playlist: false)
        let result = try env.plan([.removeTracks(usbContentIDs: [1])])
        #expect(Self.isBlocked(result.outcome(1), "lastTrack"))
        #expect(result.changes == nil)
    }

    @Test("곡을 빼면 목록 항목·고아 행·파일을 치우고 색 행은 모두 남긴다")
    func orphansCleaned_colors8Kept() throws {
        let env = try UsbEditFixture()
        try env.local.addTrack(id: "101", artist: ("1", "합성 아티스트"), album: ("30", "합성 앨범"))
        try env.local.addTrack(id: "102", artist: ("2", "합성 아티스트 둘"), album: ("31", "합성 앨범 둘"))
        try env.local.local.addPlaylist(id: "900", name: "합성 목록", seq: 1, contentIDs: ["101", "102"])
        try env.export(tracks: [], playlists: ["900"])
        let before = try env.read()
        let removed = try #require(before.tracks.first { $0.id == 2 })
        let (result, report) = try env.edit([.removeTracks(usbContentIDs: [2])])
        #expect(result.outcome(1) == .written && report.outcome == .written)
        #expect(result.changes?.requiredRules.contains(.trackRemovalFiles) == true)
        // 검증(G)이 지운 파일이 실제로 없어졌는지 보게 목표 지문에 적는다
        let changes = try #require(result.changes)
        #expect(!changes.removals.isEmpty && changes.target.mustNotExist == Set(changes.removals.map(\.path)))
        let after = try env.read()
        #expect(after.tracks.map(\.id) == [1])
        #expect(after.playlists.first?.entries[.oneLibrary] == [1] && after.playlists.first?.entries[.deviceLibrary] == [1])
        #expect(!after.artists.contains { $0.id == removed.artistID } && !after.albums.contains { $0.id == removed.albumID })
        #expect(!after.images.contains { $0.id == removed.imageID })
        #expect(after.colors.count == 8 && before.colors.count == 8)
        #expect(after.property.numberOfContents == 1)
        #expect(!env.usb.exists(String(removed.path.dropFirst())))
        #expect(!env.usb.exists(String(removed.analysisDataPath.dropFirst())))
        #expect(report.filesRemoved >= 5)
    }

    @Test("뺀 곡의 ID는 다시 쓰지 않는다(지난 쓰기의 highWater)")
    func idsNotReused() throws {
        let env = try Self.exported(playlist: false)
        try env.addLocal(["104"])
        try env.edit([.removeTracks(usbContentIDs: [3])])
        let highWater = try #require(env.usb.journal()?.changes.idHighWater)
        #expect(highWater["content"] == 3)
        let result = try env.plan([.addTracks(localContentIDs: ["104"], playlist: nil)], highWater: highWater)
        #expect(result.outcome(1) == .written)
        #expect(result.applied?.tracks.map(\.id) == [1, 2, 4])
    }

    @Test("음원은 로컬 원본이 같을 때만 지운다(로컬 사본이 없으면 남기고 알린다)")
    func audioDeletedOnlyIfLocalOriginalMatches() throws {
        let env = try Self.exported(playlist: false)
        let tracks = try env.read().tracks
        let withLocal = try env.plan([.removeTracks(usbContentIDs: [2])])
        let audio = try #require(withLocal.changes?.removals.first { $0.path == String(tracks[1].path.dropFirst()) })
        #expect(audio.localOriginal != nil && audio.localOriginalSHA1 != nil)
        let withoutLocal = try env.plan([.removeTracks(usbContentIDs: [3])], withLocal: false)
        #expect(!(withoutLocal.changes?.removals.contains { $0.path == String(tracks[2].path.dropFirst()) } ?? true))
        #expect(withoutLocal.notes.contains { $0.contains("음원을 USB에 남겼습니다") })
        #expect(withoutLocal.changes?.removals.contains { $0.path.hasPrefix("PIONEER/USBANLZ") } == true)
        // 로컬 원본이 있지만 내용이 다르면 남기고 알린다
        let row = try env.local.local.rows("SELECT FolderPath FROM djmdContent WHERE ID = '101'")
        let path = try #require(row.first?["FolderPath"])
        var data = try Data(contentsOf: URL(filePath: path))
        data[0] ^= 0xFF
        try data.write(to: URL(filePath: path))
        let changed = try env.plan([.removeTracks(usbContentIDs: [1])])
        #expect(changed.outcome(1) == .written)
        #expect(!(changed.changes?.removals.contains { $0.path == String(tracks[0].path.dropFirst()) } ?? true))
        #expect(changed.notes.contains { $0.contains("음원을 USB에 남겼습니다") })
    }

    @Test("같은 음원을 다른 곡이 가리키면 지우지 않는다")
    func sharedAudioPathKept() throws {
        let env = try UsbEditFixture()
        try env.addLocal(["101", "102"])
        try env.local.local.execute("""
            UPDATE djmdContent SET FolderPath = (SELECT FolderPath FROM djmdContent WHERE ID = '101'),
                FileNameL = (SELECT FileNameL FROM djmdContent WHERE ID = '101'), FileSize = (SELECT FileSize FROM djmdContent WHERE ID = '101')
            WHERE ID = '102'
            """)
        try env.export(tracks: ["101", "102"])
        let tracks = try env.read().tracks
        #expect(tracks.count == 2 && tracks[0].path == tracks[1].path)
        let result = try env.plan([.removeTracks(usbContentIDs: [2])])
        #expect(!(result.changes?.removals.contains { $0.path == String(tracks[0].path.dropFirst()) } ?? true))
        #expect(result.changes?.removals.contains { $0.path.hasSuffix(".DAT") } == true)
    }

    @Test("다른 곡이 가리키는 그림은 남긴다")
    func artworkKeptIfReferenced() throws {
        let env = try Self.rekordboxStyle { $0.imageIDs = [2: 1] }
        let result = try env.plan([.removeTracks(usbContentIDs: [1])], withLocal: false)
        #expect(result.outcome(1) == .written)
        #expect(!(result.changes?.removals.contains { $0.path.hasPrefix("PIONEER/Artwork") } ?? true))
        let last = try env.plan([.removeTracks(usbContentIDs: [3])], withLocal: false)
        #expect(last.changes?.removals.filter { $0.path.hasPrefix("PIONEER/Artwork") }.count == 4)
    }

    @Test("지울 파일은 두 형식 참조의 합집합으로 정한다(한 형식에만 남은 곡의 파일은 지우지 않는다)")
    func unionAcrossFormatsKeepsFile() throws {
        let env = try Self.exported(playlist: false)
        let before = try env.read()
        var after = before
        after.tracks[1].presentIn = [.deviceLibrary]
        let kept = try UsbEditEngine.planRemovals(before: before, after: after, root: env.usb.root, fileSystem: env.usb.fileSystem(),
                                                  localDatabase: nil)
        #expect(kept.removals.isEmpty)
        after.tracks.remove(at: 1)
        let removed = try UsbEditEngine.planRemovals(before: before, after: after, root: env.usb.root, fileSystem: env.usb.fileSystem(),
                                                     localDatabase: nil)
        #expect(!removed.removals.isEmpty)
    }

    @Test("빼는 곡의 분석 파일이 다른 곡 것이면(PPTH) 그 셋을 지우지 않고 곡 행만 두 형식에서 뺀다")
    func removeTrackKeepsAnlzWhenPPTHIsOtherTrack() throws {
        let folder = "/PIONEER/USBANLZ/P000/0000000A"
        let env = try Self.rekordboxStyle {
            $0.analysisPaths = [1: folder + "/ANLZ0001.DAT", 2: folder + "/ANLZ0000.DAT"]
        }
        // 곡 1 자리(ANLZ0001)에 곡 2의 분석 파일이 한 벌 더 있다
        for ext in ["DAT", "EXT", "2EX"] {
            env.usb.write(String(folder.dropFirst()) + "/ANLZ0001." + ext, try #require(env.usb.data(String(folder.dropFirst()) + "/ANLZ0000." + ext)))
        }
        let stale = (0..<3).map { index in Self.sha256(env.usb.data(String(folder.dropFirst()) + "/ANLZ0001." + ["DAT", "EXT", "2EX"][index])) }
        let result = try env.plan([.removeTracks(usbContentIDs: [1])], withLocal: false)
        #expect(!(result.changes?.removals.contains { $0.path.contains("ANLZ0001") } ?? true))
        #expect(result.notes.contains { $0.contains("분석 파일이 다른 곡 것이라 지우지 않았습니다") })
        let report = try env.write(result)
        #expect(report.outcome == .written)
        #expect((0..<3).map { Self.sha256(env.usb.data(String(folder.dropFirst()) + "/ANLZ0001." + ["DAT", "EXT", "2EX"][$0])) } == stale)
        #expect(try env.read(.oneLibrary)?.tracks.map(\.id) == [2, 3])
        #expect(try env.read(.deviceLibrary)?.tracks.map(\.id) == [2, 3])
    }

    // MARK: - 곡 더하기

    @Test("새 곡·이름 행 번호는 highWater 위에서 시작한다")
    func idsAboveHighWater() throws {
        let env = try Self.exported(["101", "102"], playlist: false)
        try env.local.addTrack(id: "103", artist: ("5", "합성 새 아티스트"), album: ("35", "합성 새 앨범"))
        let result = try env.plan([.addTracks(localContentIDs: ["103"], playlist: nil)], highWater: ["content": 10, "artist": 20, "image": 30])
        #expect(result.outcome(1) == .written)
        let added = try #require(result.applied?.tracks.first { $0.id > 2 })
        #expect(added.id == 11)
        #expect(added.artistID == 21)
        #expect(added.imageID == 31)
        #expect(result.changes?.requiredRules.contains(.editAddTracks) == true)
    }

    @Test("같은 경로의 파일이 있으면 같은 내용은 그 파일을 가리키고 다른 내용은 번호를 붙인다")
    func pathCollisionReusesOrSuffixes() throws {
        let env = try Self.exported(["101"], playlist: false)
        let existing = try #require(try env.read().tracks.first)
        let original = try #require(try env.local.local.rows("SELECT FolderPath, FileNameL FROM djmdContent WHERE ID = '101'").first)
        // 같은 이름·다른 내용
        try env.local.addTrack(id: "102", artist: ("1", "합성 아티스트"), album: ("30", "합성 앨범"), fileName: original["FileNameL"])
        // 같은 이름·같은 내용(다른 곡)
        try env.local.addTrack(id: "103", artist: ("1", "합성 아티스트"), album: ("30", "합성 앨범"), fileName: original["FileNameL"],
                               audioData: try Data(contentsOf: URL(filePath: try #require(original["FolderPath"]))))
        let result = try env.plan([.addTracks(localContentIDs: ["102", "103"], playlist: nil)])
        #expect(result.outcome(1) == .written)
        let added = try #require(result.applied?.tracks.filter { $0.id > 1 })
        #expect(added.count == 2)
        #expect(added[0].path != existing.path && added[0].path.contains(" (2)"))
        #expect(added[1].path == existing.path)
        #expect(result.changes?.copies.first { $0.destination == String(existing.path.dropFirst()) }?.disposition == .reuse)
        #expect(result.changes?.requiredRules.contains(.pathCollision) == true)
    }

    @Test("새 분석 폴더에 다른 곡의 파일이 있으면 다음 번호를 쓴다")
    func slotNextWhenOtherPPTH() throws {
        let env = try Self.exported(["101"], playlist: false)
        try env.addLocal(["102"])
        // 분석 폴더는 곡 경로의 rekordbox 해시다. 먼저 계획만 해 경로를 알고, 그 폴더에 다른 곡의 파일을 둔다
        let first = try #require(try env.plan([.addTracks(localContentIDs: ["102"], playlist: nil)]).applied?.tracks.first { $0.id == 2 })
        let folder = try #require(RekordboxAnalysisNaming().folder(contentsPath: first.path, contentID: 2))
        #expect(first.analysisDataPath == "/PIONEER/USBANLZ/\(folder)/ANLZ0000.DAT")
        env.usb.write("PIONEER/USBANLZ/\(folder)/ANLZ0000.DAT", UsbLibraryFixture.dat(path: "/Contents/합성 다른 곡.mp3", hotCueA: nil))
        let result = try env.plan([.addTracks(localContentIDs: ["102"], playlist: nil)])
        let added = try #require(result.applied?.tracks.first { $0.id == 2 })
        #expect(added.path == first.path)
        #expect(added.analysisDataPath == "/PIONEER/USBANLZ/\(folder)/ANLZ0001.DAT")
        #expect(result.changes?.requiredRules.contains(.analysisSlotCollision) == true)
        #expect(try env.write(result).outcome == .written)
    }

    @Test("새 그림은 USB의 마지막 아트워크 폴더에 이어 둔다")
    func artworkContinuesLastFolder() throws {
        let env = try Self.exported(["101"], playlist: false)
        try env.addLocal(["102"])
        env.usb.write("PIONEER/Artwork/00002/a99.jpg", Data([0xFF, 0xD8, 0xFF, 0xD9]))
        let result = try env.plan([.addTracks(localContentIDs: ["102"], playlist: nil)])
        let image = try #require(result.applied?.images.first { $0.id == result.applied?.tracks.first { $0.id == 2 }?.imageID })
        #expect(image.oneLibraryPath?.hasPrefix("/PIONEER/Artwork/00002/") == true)
        #expect(image.pdbPath?.hasPrefix("/PIONEER/Artwork/00002/") == true)
    }

    @Test("USB에 NFC로 정확히 같은 이름 행이 있으면 다시 쓰고 대소문자가 다르면 새 행")
    func nameReuseNFCExact() throws {
        let env = try UsbEditFixture()
        try env.local.addTrack(id: "101", artist: ("1", "Caf\u{E9}"), album: ("30", "합성 앨범"))
        try env.export(tracks: ["101"])
        let existing = try #require(try env.read().tracks.first?.artistID)
        try env.local.addTrack(id: "102", artist: ("2", "Cafe\u{301}"), album: ("30", "합성 앨범"))
        try env.local.addTrack(id: "103", artist: ("3", "caf\u{E9}"), album: ("30", "합성 앨범"))
        let result = try env.plan([.addTracks(localContentIDs: ["102", "103"], playlist: nil)])
        let tracks = try #require(result.applied?.tracks)
        #expect(tracks.first { $0.id == 2 }?.artistID == existing)
        #expect(tracks.first { $0.id == 3 }?.artistID != existing)
        #expect(try env.write(result).outcome == .written)
    }

    @Test("곡 더하기에 목록을 주면 그 목록 끝에 넣는다(이미 USB에 있는 곡은 다시 넣지 않는다)")
    func addTracksIntoPlaylist() throws {
        let env = try Self.exported(["101", "102"])
        try env.addLocal(["103"])
        let result = try env.plan([.addTracks(localContentIDs: ["103", "101"], playlist: .id("1"))])
        #expect(result.outcome(1) == .written)
        #expect(result.trackBlocks.map(\.code) == ["alreadyOnUsb"])
        #expect(try env.write(result).outcome == .written)
        let after = try env.read()
        #expect(after.playlists.first?.entries[.oneLibrary] == [1, 2, 3] && after.playlists.first?.entries[.deviceLibrary] == [1, 2, 3])
    }

    // MARK: - 한 편집만 막힘

    @Test("OneLibrary 단계가 실패한 편집만 막고 나머지는 쓰며 Device Library에도 그 편집이 없다")
    func oneLibraryStepSkippedAlsoSkippedInPdb() throws {
        let env = try Self.exported()
        // 기기가 남긴 큐 행이 가리키는 곡은 OneLibrary 작성기가 빼지 않는다
        try env.oneLibrarySQL("INSERT INTO cue (cue_id, content_id, kind) VALUES (1, 2, 0)")
        let (result, report) = try env.edit([
            .playlist(edit: .rename(playlist: .id("1"), name: "합성 바뀐 이름")),
            .removeTracks(usbContentIDs: [2]),
            .playlist(edit: .create(key: "p2", name: "합성 새 목록", isFolder: false, parent: .root)),
        ])
        #expect(result.outcome(1) == .written && result.outcome(3) == .written)
        #expect(Self.isBlocked(result.outcome(2), "applyFailed"))
        #expect(report.outcome == .written)
        let device = try #require(try env.read(.deviceLibrary))
        #expect(device.tracks.map(\.id) == [1, 2, 3])
        #expect(device.playlists.map(\.name).sorted() == ["합성 바뀐 이름", "합성 새 목록"])
        #expect(try env.read(.oneLibrary)?.tracks.map(\.id) == [1, 2, 3])
        try UsbEditInvariantTests.check(env, result)
    }

    @Test("savepoint: 한 편집이 막혀도 앞뒤 편집은 쓴다")
    func savepointOneEditBlockedOthersWritten() throws {
        let env = try Self.exported()
        try env.oneLibrarySQL("INSERT INTO cue (cue_id, content_id, kind) VALUES (1, 3, 0)")
        let (result, _) = try env.edit([.removeTracks(usbContentIDs: [1]), .removeTracks(usbContentIDs: [3]),
                                        .playlist(edit: .rename(playlist: .id("1"), name: "합성 바뀐 이름"))])
        #expect(result.outcome(1) == .written && result.outcome(3) == .written)
        #expect(Self.isBlocked(result.outcome(2), "applyFailed"))
        #expect(try env.read().tracks.map(\.id) == [2, 3])
    }

    @Test("대상이 USB에 없으면 그 편집만 막는다")
    func vanishedTargetBlocked() throws {
        let env = try Self.exported()
        let result = try env.plan([.removeTracks(usbContentIDs: [99]), .playlist(edit: .rename(playlist: .id("999"), name: "합성")),
                                   .playlist(edit: .addTracks(playlist: .new("없음"), contentIDs: ["1"])),
                                   .playlist(edit: .addTracks(playlist: .id("1"), contentIDs: ["99"])),
                                   .refreshTracks(usbContentIDs: [99], parts: [.info]),
                                   .removeTracks(usbContentIDs: [3])])
        for index in 1...5 { #expect(Self.isBlocked(result.outcome(index), "targetMissing")) }
        #expect(result.outcome(6) == .written)
    }

    // MARK: - 한 형식에만 있는 칸

    @Test("다시 만들어도 pdb 전용 칸과 OneLibrary 전용 칸을 지우지 않는다")
    func rebuildKeepsFormatOnlyFields() throws {
        let env = try UsbEditFixture()
        try env.local.local.addCategory(id: "1", menuItemID: "1", seq: 1, disable: 1, infoOrder: 2)
        try env.local.local.addSort(id: "1", menuItemID: "2", seq: 1, disable: 2)
        try env.addLocal(["101", "102"])
        try env.local.local.setMetadata(track: TrackSpec(id: "101"), lyricist: "시험 작사")
        try env.local.local.addPlaylist(id: "900", name: "합성 목록", seq: 1, contentIDs: ["101", "102"])
        try env.export(tracks: [], playlists: ["900"])
        try env.oneLibrarySQL("UPDATE content SET titleForSearch = 'SEARCH' WHERE content_id = 1")
        try env.oneLibrarySQL("UPDATE artist SET nameForSearch = 'SEARCH'")
        try env.oneLibrarySQL("UPDATE album SET image_id = 1")
        try env.oneLibrarySQL("UPDATE playlist SET image_id = 1")
        let deviceBefore = try #require(try env.read(.deviceLibrary))
        let oneBefore = try #require(try env.read(.oneLibrary))
        #expect(deviceBefore.tracks.first { $0.id == 1 }?.lyricist == "시험 작사")
        #expect(deviceBefore.categories.contains { $0.infoOrder == 2 && $0.disable == 1 })
        #expect(deviceBefore.sorts.contains { $0.disable == 2 })

        try env.edit([.playlist(edit: .rename(playlist: .id("1"), name: "합성 바뀐 이름"))])
        try env.edit([.removeTracks(usbContentIDs: [2])])
        let device = try #require(try env.read(.deviceLibrary))
        let one = try #require(try env.read(.oneLibrary))
        #expect(device.tracks.first { $0.id == 1 }?.lyricist == "시험 작사")
        #expect(device.categories == deviceBefore.categories && device.sorts == deviceBefore.sorts)
        #expect(device.property.pdbDate == deviceBefore.property.pdbDate && device.property.pdbDeviceName == deviceBefore.property.pdbDeviceName)
        #expect(device.trackRowExtras[1] == deviceBefore.trackRowExtras[1])
        #expect(one.tracks.first { $0.id == 1 }?.titleForSearch == "SEARCH")
        #expect(one.artists.allSatisfy { $0.nameForSearch == "SEARCH" })
        #expect(one.albums.allSatisfy { $0.imageID == 1 } && one.playlists.allSatisfy { $0.imageID == 1 })
        #expect(one.albums.map(\.id) == oneBefore.albums.map(\.id))

        // 합친 모델을 새 내보내기 모양으로 다시 만들어도 같은 값(lab usb-rebuild와 같은 경로)
        let merged = try env.read()
        let folder = env.usb.folder.appending(path: "rebuild")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try OneLibraryWriter.create(merged, at: folder.appending(path: "exportLibrary.db"))
        let files = try PdbWriter.files(merged, mode: .fresh)
        let rebuilt = try PdbReader.read(export: files.export, exportExt: files.exportExt).0
        #expect(rebuilt.tracks.first { $0.id == 1 }?.lyricist == "시험 작사")
        #expect(rebuilt.categories == device.categories && rebuilt.property.pdbDate == device.property.pdbDate)
        let rebuiltOne = try OneLibraryReader.read(copyAt: folder.appending(path: "exportLibrary.db"))
        #expect(rebuiltOne.tracks.first { $0.id == 1 }?.titleForSearch == "SEARCH")

        // rekordbox가 만든 USB: 표 19 날짜가 OneLibrary createdDate와 달라도(작성기가 createdDate로 다시 만들지 않고) 그대로
        let made = try Self.rekordboxStyle()
        let madeDate = try #require(try made.read(.deviceLibrary)?.property.pdbDate)
        let created = try #require(try made.read(.oneLibrary)?.property.createdDate)
        #expect(madeDate != created)
        let (renamed, _) = try made.edit([.playlist(edit: .rename(playlist: .id("10"), name: "합성 새 이름"))], withLocal: false)
        #expect(renamed.formatsWritten.contains(.deviceLibrary))
        #expect(try made.read(.deviceLibrary)?.property.pdbDate == madeDate)
        let (removed, _) = try made.edit([.removeTracks(usbContentIDs: [3])], withLocal: false)
        #expect(removed.formatsWritten.contains(.deviceLibrary))
        #expect(try made.read(.deviceLibrary)?.property.pdbDate == madeDate)
        #expect(try made.read(.oneLibrary)?.property.createdDate == created)
    }

    // MARK: - 긴 ASCII

    @Test("긴 ASCII 문자열(127자 이상)은 rekordbox에서 본 칸(곡 문자열·경로·아티스트·앨범)이 아닐 때만 pdbLongAscii로 싣는다")
    func longAsciiRulesFromEdits() throws {
        let long = String(repeating: "a", count: 127), short = String(repeating: "a", count: 126)
        let env = try Self.exported(["101", "102"])
        // 곡 제목의 긴 ASCII는 rekordbox 7.2.x 경계 실험(2026-10-08)으로 확인한 모양이라 싣지 않는다
        try env.updateLocal("101", "TrackInfoUpdated = '2', Title = ?", [.text(long)])
        #expect(try env.plan([.refreshTracks(usbContentIDs: [1], parts: [.info])]).changes?.requiredRules.contains(.pdbLongAscii) == false)
        // 장르 이름은 본 적 없는 칸이라 싣는다
        try env.local.local.addGenre(id: "40", name: long)
        try env.updateLocal("101", "TrackInfoUpdated = '3', GenreID = '40'")
        #expect(try env.plan([.refreshTracks(usbContentIDs: [1], parts: [.info])]).changes?.requiredRules.contains(.pdbLongAscii) == true)
        #expect(try env.plan([.playlist(edit: .rename(playlist: .id("1"), name: long))]).changes?.requiredRules.contains(.pdbLongAscii) == true)
        #expect(try env.plan([.playlist(edit: .rename(playlist: .id("1"), name: short))]).changes?.requiredRules.contains(.pdbLongAscii) == false)
        // 경로 성분은 48자까지라 아티스트·앨범·파일 이름을 모두 길게(순수 ASCII) 준다. 긴 경로는 확인한 모양이다
        let artist = String(repeating: "a", count: 40), album = String(repeating: "b", count: 40)
        let file = String(repeating: "c", count: 40) + ".mp3"
        try env.local.addTrack(id: "103", artist: ("7", artist), album: ("37", album), fileName: file)
        #expect(try env.plan([.addTracks(localContentIDs: ["103"], playlist: nil)]).changes?.requiredRules.contains(.pdbLongAscii) == false)

        // Device Library를 쓰지 않으면(막힘) pdb 문자열 규칙을 싣지 않는다
        let blocked = try Self.exported(["101", "102"])
        blocked.setPdbFlag(4)
        try blocked.local.local.addGenre(id: "40", name: long)
        try blocked.updateLocal("101", "TrackInfoUpdated = '2', GenreID = '40'")
        let refresh = try blocked.plan([.refreshTracks(usbContentIDs: [1], parts: [.info])])
        #expect(refresh.outcome(1) == .written && refresh.changes?.requiredRules.contains(.pdbLongAscii) == false)
        let create = try blocked.plan([.playlist(edit: .create(key: "l", name: long, isFolder: false, parent: .root))])
        #expect(create.outcome(1) == .written && create.changes?.requiredRules.contains(.pdbLongAscii) == false)
    }

    // MARK: - 쓰기 전부터 있던 문제

    @Test("쓰기 전부터 분석 파일 번호가 엉킨 곡이 있어도 그 곡을 건드리지 않는 편집은 쓴다(새로 생긴 문제만 센다)")
    func preexistingInvariantProblemsIgnored() throws {
        let env = try Self.exported()
        let tracks = try env.read().tracks
        let first = String(tracks[0].analysisDataPath.dropFirst().dropLast(4)), second = String(tracks[1].analysisDataPath.dropFirst().dropLast(4))
        for ext in [".DAT", ".EXT", ".2EX"] { env.usb.write(first + ext, try #require(env.usb.data(second + ext))) }
        let rename = try env.plan([.playlist(edit: .rename(playlist: .id("1"), name: "합성 바뀐 이름"))], withLocal: false)
        #expect(rename.preexistingProblems == ["ppth content 1 onelibrary", "ppth content 1 pdb"])
        #expect(try env.write(rename).outcome == .written)
        let (removal, report) = try env.edit([.removeTracks(usbContentIDs: [3])])
        #expect(removal.outcome(1) == .written && report.outcome == .written)
        #expect(try env.read().tracks.map(\.id) == [1, 2])
    }

    @Test("불변식 검증기는 쓰기 전부터 있던 문제를 빼고 새로 생긴 문제만 센다")
    func invariantVerifierCountsOnlyNewProblems() throws {
        let env = try Self.exported()
        let tracks = try env.read().tracks
        let first = String(tracks[0].analysisDataPath.dropFirst().dropLast(4)), second = String(tracks[1].analysisDataPath.dropFirst().dropLast(4))
        for ext in [".DAT", ".EXT", ".2EX"] { env.usb.write(first + ext, try #require(env.usb.data(second + ext))) }
        let scratch = env.usb.folder.appending(path: "verify-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let fileSystem = env.usb.fileSystem()
        let before = try UsbInvariantVerifier.problems(on: env.usb.root, fileSystem: fileSystem, scratch: scratch)
        #expect(before == ["ppth content 1 onelibrary", "ppth content 1 pdb"])
        let changes = try #require(try env.plan([.playlist(edit: .rename(playlist: .id("1"), name: "합성 바뀐 이름"))], withLocal: false).changes)
        let verifier = UsbInvariantVerifier(preexistingProblems: before)
        #expect(try verifier.verify(root: env.usb.root, changes: changes, fileSystem: fileSystem, scratch: scratch).isEmpty)
        #expect(try UsbInvariantVerifier().verify(root: env.usb.root, changes: changes, fileSystem: fileSystem, scratch: scratch).count == 2)
        // 새로 생긴 문제는 센다
        try FileManager.default.removeItem(at: env.usb.usb(String(tracks[1].path.dropFirst())))
        #expect(try verifier.verify(root: env.usb.root, changes: changes, fileSystem: fileSystem, scratch: scratch) == ["missing audio content 2"])
    }
}
