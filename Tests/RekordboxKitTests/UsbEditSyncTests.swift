import DJCDomain
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

/// USB 목록 동기화도 기존 항목 편집·쓰기 관문을 쓴다. 모든 입력은 임시 폴더의 합성 라이브러리다
extension UsbEditEngineTests {
    @Test("목록 동기화는 로컬 순서와 같은 곡의 반복을 두 USB 형식에 그대로 쓴다")
    func syncPlaylistPreservesOrderAndOccurrences() throws {
        let env = try Self.exported()
        let before = try env.read().tracks
        let edit = UsbLibraryEdit.syncPlaylist(playlist: .id("1"), localContentIDs: ["103", "101", "103"])
        let (result, report) = try env.edit([edit])
        #expect(result.outcome(1) == .written && report.outcome == .written)
        #expect(result.changes?.copies.isEmpty == true && result.changes?.writes.isEmpty == true)
        let after = try env.read()
        #expect(after.tracks == before)
        for format in UsbFormat.allCases { #expect(after.playlists.first?.entries[format] == [3, 1, 3]) }
        let rows = try env.oneLibraryRows("SELECT content_id, sequenceNo FROM playlist_content WHERE playlist_id = 1 ORDER BY sequenceNo")
        #expect(rows.map { $0["content_id"] } == ["3", "1", "3"])
        #expect(rows.map { $0["sequenceNo"] } == ["1", "2", "3"])
        let again = try env.plan([edit])
        #expect(again.outcome(1) == .unchanged && again.changes == nil)
    }

    @Test("곡 더하기 한 번 뒤 여러 목록 동기화는 같은 새 USB 곡 번호를 참조한다")
    func syncPlaylistsShareTracksAddedInSameBatch() throws {
        let env = try Self.exported()
        try env.addLocal(["104"])
        let edits: [UsbLibraryEdit] = [
            .addTracks(localContentIDs: ["104"], playlist: nil),
            .playlist(edit: .create(key: "one", name: "합성 동기화 하나", isFolder: false, parent: .root)),
            .syncPlaylist(playlist: .new("one"), localContentIDs: ["104", "101", "104"]),
            .playlist(edit: .create(key: "two", name: "합성 동기화 둘", isFolder: false, parent: .root)),
            .syncPlaylist(playlist: .new("two"), localContentIDs: ["102", "104"]),
            .syncPlaylist(playlist: .id("1"), localContentIDs: ["103", "104", "101"]),
        ]
        let (result, report) = try env.edit(edits)
        #expect(result.outcomes.allSatisfy { $0.outcome == .written } && report.outcome == .written)
        let after = try env.read()
        #expect(after.tracks.map(\.id) == [1, 2, 3, 4])
        #expect(after.tracks.filter { $0.masterContentId == 8_104 }.count == 1)
        for format in UsbFormat.allCases {
            #expect(after.playlists.first { $0.name == "합성 동기화 하나" }?.entries[format] == [4, 1, 4])
            #expect(after.playlists.first { $0.name == "합성 동기화 둘" }?.entries[format] == [2, 4])
            #expect(after.playlists.first { $0.id == 1 }?.entries[format] == [3, 4, 1])
        }
    }

    @Test("내보내며 정제·번호 꼬리가 붙은 파일 이름도 같은 곡으로 동기화하고 다시 더하지 않는다")
    func syncMatchesSanitizedAndNumberedNames() throws {
        let env = try UsbEditFixture()
        for id in ["101", "102"] {
            try env.local.addTrack(id: id, artist: ("1", "합성 아티스트"), album: ("30", "합성 앨범"), fileName: "same?.mp3")
        }
        try env.local.local.addPlaylist(id: "900", name: "합성 목록", seq: 1, contentIDs: ["101", "102"])
        try env.export(tracks: [], playlists: ["900"])
        let source = try env.read()
        #expect(source.tracks.first { $0.id == 1 }?.fileName != "same?.mp3")
        #expect(source.tracks.first { $0.id == 2 }?.fileName.contains(" (2)") == true)
        let result = try env.plan([
            .addTracks(localContentIDs: ["101", "102"], playlist: nil),
            .syncPlaylist(playlist: .id("1"), localContentIDs: ["102", "101", "102"]),
        ])
        #expect(Self.isBlocked(result.outcome(1), "alreadyOnUsb"))
        #expect(result.outcome(2) == .written)
        #expect(result.applied?.tracks.count == 2)
        for format in UsbFormat.allCases { #expect(result.applied?.playlists.first?.entries[format] == [2, 1, 2]) }
    }

    @Test("USB에 없는 곡은 rekordbox처럼 그 곡만 빼고 목록을 맞추고, 스냅샷에 없는 곡은 목록 전체를 막는다")
    func syncSkipsTracksMissingOnUsbButBlocksUnknownLocalTracks() throws {
        let env = try Self.exported()
        try env.addLocal(["104"])
        let result = try env.plan([
            .syncPlaylist(playlist: .id("1"), localContentIDs: ["103", "104", "101", "104"]),
            .syncPlaylist(playlist: .id("1"), localContentIDs: ["999"]),
        ])
        #expect(result.outcome(1) == .written)
        // 남은 곡의 순서·반복은 그대로, 빠진 곡은 한 번만 알린다
        for format in UsbFormat.allCases { #expect(result.applied?.playlists.first?.entries[format] == [3, 1]) }
        #expect(result.trackBlocks.map(\.code) == ["syncTrackMissing"])
        #expect(result.trackBlocks.first?.scope == .track("104"))
        #expect(Self.isBlocked(result.outcome(2), "localTrackMissing"))
    }

    @Test("새 곡 더하기가 막히면 뒤의 동기화는 그 곡만 빼고 맞추고, 같은 곡을 두 번 알리지 않는다")
    func syncAfterBlockedAddSkipsThatTrackOnly() throws {
        let env = try Self.exported()
        try env.addLocal(["104"])
        try env.updateLocal("104", "AnalysisDataPath = NULL")
        let result = try env.plan([
            .addTracks(localContentIDs: ["104"], playlist: nil),
            .syncPlaylist(playlist: .id("1"), localContentIDs: ["102", "104"]),
        ])
        // 동기화 묶음이 아니면 곡 더하기 편집은 막힌 채 초안에 남는다
        guard case .blocked = result.outcome(1) else { Issue.record("곡 더하기를 막지 않음"); return }
        #expect(result.outcome(2) == .written)
        for format in UsbFormat.allCases { #expect(result.applied?.playlists.first?.entries[format] == [2]) }
        #expect(result.trackBlocks.filter { $0.scope == .track("104") }.count == 1)
        #expect(!result.trackBlocks.contains { $0.code == "syncTrackMissing" })
    }

    @Test("선택하지 않은 로컬 중복 행까지 보고 USB 짝이 모호한 동기화는 막는다")
    func syncDoesNotGuessBetweenLocalDuplicates() throws {
        let env = try Self.exported()
        try env.addLocal(["104"])
        try env.updateLocal("104", "MasterSongID = '8101', FileNameL = 'track101.mp3'")
        let result = try env.plan([.syncPlaylist(playlist: .id("1"), localContentIDs: ["101"])])
        #expect(Self.isBlocked(result.outcome(1), "syncTrackAmbiguous"))
        for format in UsbFormat.allCases { #expect(result.applied?.playlists.first?.entries[format] == [1, 2, 3]) }
        #expect(result.changes == nil)
    }

    @Test("로컬 곡 하나에 USB 곡 둘이 맞으면 어느 곡을 넣을지 추측하지 않는다")
    func syncDoesNotGuessBetweenUsbDuplicates() throws {
        let env = try UsbEditFixture()
        for id in ["101", "102"] {
            try env.local.addTrack(id: id, artist: ("1", "합성 아티스트"), album: ("30", "합성 앨범"), fileName: "same.mp3")
        }
        try env.updateLocal("102", "MasterSongID = '8101'")
        try env.local.local.addPlaylist(id: "900", name: "합성 목록", seq: 1, contentIDs: ["101", "102"])
        try env.export(tracks: [], playlists: ["900"])
        try env.updateLocal("102", "rb_local_deleted = 1")
        let result = try env.plan([.syncPlaylist(playlist: .id("1"), localContentIDs: ["101"])])
        #expect(Self.isBlocked(result.outcome(1), "syncTrackAmbiguous"))
        for format in UsbFormat.allCases { #expect(result.applied?.playlists.first?.entries[format] == [1, 2]) }
        #expect(result.changes == nil)
    }

    @Test("명시적으로 빈 원본 목록을 동기화할 때만 USB 목록을 비우고 곡·파일은 남긴다")
    func syncExplicitEmptyPlaylistKeepsTracks() throws {
        let env = try Self.exported()
        let (result, report) = try env.edit([.syncPlaylist(playlist: .id("1"), localContentIDs: [])])
        #expect(result.outcome(1) == .written && report.outcome == .written)
        #expect(result.changes?.removals.isEmpty == true)
        let after = try env.read()
        #expect(after.tracks.count == 3)
        for format in UsbFormat.allCases { #expect(after.playlists.first?.entries[format] == []) }
    }

    @Test("두 형식의 항목이 다른 목록은 동기화로 덮어쓰지 않는다")
    func syncEntryFormatMismatchStillBlocks() throws {
        let env = try Self.rekordboxStyle {
            $0.playlists = [UsbLibraryFixture.Playlist(id: 10, name: "합성 목록", oneLibraryEntries: [1, 2], deviceLibraryEntries: [2, 1])]
        }
        let result = try env.plan([.syncPlaylist(playlist: .id("10"), localContentIDs: [])], withLocal: false)
        #expect(Self.isBlocked(result.outcome(1), "playlistEntriesDiffer"))
        #expect(result.changes == nil)
    }

    @Test("한 형식이 막힌 USB에서는 동기화 항목도 고칠 수 있는 형식에만 쓴다")
    func syncOnlyMutatesWritableFormats() throws {
        let env = try Self.exported()
        env.setPdbFlag(4)
        let (result, report) = try env.edit([.syncPlaylist(playlist: .id("1"), localContentIDs: ["103", "101"])])
        #expect(result.outcome(1) == .written && report.outcome == .written)
        #expect(result.formatsWritten == [.oneLibrary])
        #expect(try env.read(.oneLibrary)?.playlists.first?.entries[.oneLibrary] == [3, 1])
        #expect(try env.read(.deviceLibrary)?.playlists.first?.entries[.deviceLibrary] == [1, 2, 3])
    }
}
