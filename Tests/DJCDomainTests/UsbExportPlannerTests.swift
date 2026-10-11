import DJCDomain
import Foundation
import Testing

/// 합성 후보만 쓴다(곡·경로·ID는 지어낸 값).
@Suite("USB 내보내기 계획")
struct UsbExportPlannerTests {
    let snapshot = Date(timeIntervalSince1970: 1_800_000_000)

    func candidate(_ id: String, artist: String? = "Artist", album: String? = "Album", file: String? = nil, size: Int64 = 1_000,
                   artwork: Bool = true, fileType: Int = 1) -> UsbExportCandidate {
        // 음원 경로의 끝 성분 = FileNameL(실제 라이브러리처럼). USB 파일 이름은 경로 끝 성분으로 짓는다.
        UsbExportCandidate(
            localContentID: id, masterSongID: id, masterDBID: "424242", artistName: artist, albumName: album,
            fileNameL: file ?? "track \(id).mp3", sourcePath: "/music/\(id)/" + (file ?? "track \(id).mp3"), isStreaming: false,
            fileType: fileType,
            fileSize: size, actualFileSize: size, analysis: .complete, analysisModifiedAt: snapshot.addingTimeInterval(-3_600),
            artwork: artwork ? UsbArtworkSource(smallPath: "/share/\(id)_s.jpg", mediumPath: "/share/\(id)_m.jpg", smallBytes: 3_000,
                                                mediumBytes: 20_000) : nil,
            artworkPathSetButMissing: false, cues: [], metadata: UsbTrackMetadataFlags())
    }

    func request(_ candidates: [UsbExportCandidate], playlists: [UsbPlaylistInput] = [], existing: UsbExistingState? = nil,
                 naming: any UsbAnalysisNaming = IdentifierAnalysisNaming(), cluster: Int = 4_096,
                 sameContent: @escaping @Sendable (String, String) -> Bool = { _, _ in false }) -> UsbExportRequest {
        UsbExportRequest(candidates: candidates, playlists: playlists, existing: existing, formats: UsbFormat.defaultSet, naming: naming,
                         snapshotTakenAt: snapshot, clusterSize: cluster, sameContent: sameContent)
    }

    func plan(_ candidates: [UsbExportCandidate], playlists: [UsbPlaylistInput] = [], existing: UsbExistingState? = nil,
              sameContent: @escaping @Sendable (String, String) -> Bool = { _, _ in false }) -> UsbExportPlan {
        UsbExportPlanner.plan(request(candidates, playlists: playlists, existing: existing, sameContent: sameContent))
    }

    func codes(_ plan: UsbExportPlan, track id: String) -> [String] {
        plan.blocked.filter { $0.scope == .track(id) }.map(\.code)
    }

    func list(_ id: String, _ name: String, parent: String? = nil, attribute: Int = 0, tracks: [String] = []) -> UsbPlaylistInput {
        UsbPlaylistInput(localID: id, name: name, parentLocalID: parent, attribute: attribute, trackLocalIDs: tracks)
    }

    /// Contents/ 아래 파일만 있는 USB(라이브러리 없음). 폴더·파일 철자를 모두 적는다
    func contentsOnly(_ paths: [String]) -> UsbExistingState {
        var used: [String: Set<String>] = [:], spelling: [String: String] = [:]
        for path in paths {
            let parts = path.split(separator: "/").map(String.init)
            for index in parts.indices {
                let parentKey = parts[..<index].map(UsbLayout.collisionKey).joined(separator: "/")
                used[parentKey, default: []].insert(UsbLayout.collisionKey(parts[index]))
                spelling[parts[...index].map(UsbLayout.collisionKey).joined(separator: "/")] = parts[...index].joined(separator: "/")
            }
        }
        return UsbExistingState.contentsOnly(usedCollisionKeys: used, folderSpelling: spelling)
    }

    // MARK: - 막힘

    @Test("음원 파일이 없으면 audioMissing")
    func blockAudioMissing() {
        var noPath = candidate("1")
        noPath.sourcePath = nil
        var noFile = candidate("2")
        noFile.actualFileSize = nil
        let result = plan([noPath, noFile])
        #expect(codes(result, track: "1") == ["audioMissing"])
        #expect(codes(result, track: "2") == ["audioMissing"])
        #expect(result.blocked.first?.message == "음원 파일이 없습니다. rekordbox에서 파일 위치를 다시 잡은 뒤 내보내세요")
        #expect(result.tracks.isEmpty)
    }

    @Test("스트리밍 곡은 streaming 하나로 막는다")
    func blockStreaming() {
        var streaming = candidate("1", fileType: 26)
        streaming.isStreaming = true
        streaming.sourcePath = "stream:1"
        streaming.actualFileSize = nil
        #expect(codes(plan([streaming]), track: "1") == ["streaming"])
    }

    @Test("분석 파일이 다 없으면 analysisIncomplete")
    func blockAnalysisIncomplete() {
        for state in [UsbAnalysisState.datOnly, .missing2EX, .missing] {
            var track = candidate("1")
            track.analysis = state
            #expect(codes(plan([track]), track: "1") == ["analysisIncomplete"], "\(state)")
        }
    }

    @Test("4GB 이상 파일은 형식과 무관하게 fileTooLarge")
    func blockFileTooLarge() {
        #expect(codes(plan([candidate("1", size: 4_294_967_296)]), track: "1") == ["fileTooLarge"])
        #expect(codes(plan([candidate("1", size: 4_294_967_295)]), track: "1").isEmpty)
    }

    @Test("모르는 음원 형식은 fileTypeUnknown")
    func blockFileTypeUnknown() {
        #expect(codes(plan([candidate("1", fileType: 99)]), track: "1") == ["fileTypeUnknown"])
    }

    @Test("분석 뒤 음원 크기가 바뀐 곡도 막지 않고 실제 크기로 계획하며 CDJ 확인 규칙을 싣는다(rekordbox 7.2.x 빈 USB 실험, 2026-10-08)")
    func audioChangedSinceAnalysisPlanned() throws {
        var changed = candidate("1")
        changed.actualFileSize = 1_001
        let result = plan([changed, candidate("2")])
        #expect(result.blocked.isEmpty)
        let track = try #require(result.tracks.first { $0.localContentID == "1" })
        #expect(track.rules.contains(.audioChangedSinceAnalysis) && track.audioSize == 1_001)
        let same = try #require(result.tracks.first { $0.localContentID == "2" })
        #expect(!same.rules.contains(.audioChangedSinceAnalysis) && same.audioSize == 1_000)
        #expect(result.requiredRules.contains(.audioChangedSinceAnalysis) && result.ruleCounts[.audioChangedSinceAnalysis] == 1)
        #expect(UsbProvisionalRule.audioChangedSinceAnalysis.needsDeviceCheck)
        // 파일이 없으면 여전히 막는다
        var missing = changed
        missing.actualFileSize = nil
        #expect(codes(plan([missing]), track: "1") == ["audioMissing"])
    }

    @Test("스냅샷 뒤 분석이 바뀌었으면 analysisNewerThanSnapshot")
    func blockAnalysisNewerThanSnapshot() {
        var track = candidate("1")
        track.analysisModifiedAt = snapshot.addingTimeInterval(1)
        #expect(codes(plan([track]), track: "1") == ["analysisNewerThanSnapshot"])
        track.analysisModifiedAt = snapshot
        #expect(codes(plan([track]), track: "1").isEmpty)
    }

    @Test("같은 이름이 99까지 다 차면 pathCollisionExhausted")
    func blockPathCollisionExhausted() {
        let names = ["Contents/Artist/Album/x.mp3"] + (2...99).map { "Contents/Artist/Album/x (\($0)).mp3" }
        let result = plan([candidate("1", file: "x.mp3")], existing: contentsOnly(names))
        #expect(codes(result, track: "1") == ["pathCollisionExhausted"])
        #expect(result.tracks.isEmpty)
    }

    struct NoNaming: UsbAnalysisNaming {
        var rule: UsbProvisionalRule? { nil }
        func folder(contentsPath: String, contentID: Int) -> String? { contentID == 1 ? nil : "F/\(contentID)" }
    }

    @Test("분석 폴더 이름을 못 지으면 namingUnavailable, ID를 쓰지 않는다")
    func blockNamingUnavailable() {
        let result = UsbExportPlanner.plan(request([candidate("1"), candidate("2")], naming: NoNaming()))
        #expect(codes(result, track: "1") == ["namingUnavailable"])
        // 막힌 곡의 ID를 건너뛰지 않으니 다음 곡도 1을 받아 다시 막힌다
        #expect(codes(result, track: "2") == ["namingUnavailable"])
        #expect(result.tracks.isEmpty)
    }

    @Test("막힌 곡은 ID를 받지 않고 목록에서만 빠진다")
    func blockedTracksGetNoIDs() {
        var broken = candidate("2")
        broken.analysis = .missing
        let result = plan([candidate("1"), broken, candidate("3")], playlists: [list("p", "목록", tracks: ["1", "2", "3"])])
        #expect(result.tracks.map(\.localContentID) == ["1", "3"])
        #expect(result.tracks.map(\.contentID) == [1, 2])
        #expect(result.playlists.first?.contentIDs == [1, 2])
    }

    @Test("인텔리전트 재생 목록은 막고 그 곡은 곡 선택대로 간다")
    func smartPlaylistBlocked() {
        let result = plan([candidate("1")], playlists: [list("s", "스마트", attribute: 4, tracks: ["1"]), list("p", "목록", tracks: ["1"])])
        #expect(result.blocked.map(\.code) == ["smartPlaylist"])
        #expect(result.blocked.first?.scope == .playlist("s"))
        #expect(result.blocked.first?.message == "인텔리전트 재생 목록은 아직 내보낼 수 없습니다. 일반 목록으로 복사한 뒤 내보내세요")
        #expect(result.playlists.map(\.localID) == ["p"])
        #expect(result.playlists.first?.playlistID == 1)
        #expect(result.tracks.count == 1)
    }

    @Test("폴더 안 목록은 깊이 우선으로 번호를 받는다")
    func folderPlaylistContents() {
        let playlists = [list("f", "폴더", attribute: 1), list("m", "뒤 목록", tracks: ["2"]), list("l", "안 목록", parent: "f", tracks: ["1", "2"])]
        let result = plan([candidate("1"), candidate("2")], playlists: playlists)
        #expect(result.playlists.map(\.localID) == ["f", "l", "m"])
        let byID = Dictionary(uniqueKeysWithValues: result.playlists.map { ($0.localID, $0) })
        #expect(byID["f"]?.playlistID == 1 && byID["f"]?.isFolder == true && byID["f"]?.parentID == 0 && byID["f"]?.contentIDs == [])
        #expect(byID["l"]?.playlistID == 2 && byID["l"]?.parentID == 1 && byID["l"]?.sortOrder == 0 && byID["l"]?.contentIDs == [1, 2])
        #expect(byID["m"]?.playlistID == 3 && byID["m"]?.parentID == 0 && byID["m"]?.sortOrder == 1)
        #expect(result.requiredRules.isSuperset(of: [.playlistFolderRow, .playlistSiblingBase]))
        let flat = plan([candidate("1")], playlists: [list("p", "목록", tracks: ["1"])])
        #expect(flat.requiredRules.contains(.playlistSiblingBase))
        #expect(!flat.requiredRules.contains(.playlistFolderRow))
        #expect(!plan([candidate("1")]).requiredRules.contains(.playlistSiblingBase))
    }

    @Test("한 폴더 항목이 너무 많으면 directoryEntryLimit")
    func blockDirectoryEntryLimit() {
        var existing = UsbExistingState(hasLibrary: true)
        existing.usedCollisionKeys["contents"] = Set((0..<30_000).map { "artist \($0)" })
        let result = plan([candidate("1")], existing: existing)
        #expect(result.blocked.map(\.code) == ["directoryEntryLimit"])
        #expect(result.blocked.first?.scope == .volume)
        #expect(result.blocked.first?.message == "한 폴더에 파일이 너무 많습니다. 곡 수를 나눠 내보내세요")
        existing.usedCollisionKeys["contents"] = Set((0..<1_000).map { "artist \($0)" })
        #expect(plan([candidate("1")], existing: existing).blocked.isEmpty)
    }

    /// rekordbox 7.2.x 빈 USB 내보내기 골든(2026-10-08): `~`는 폴더·파일 이름에서 `_`, 파일 이름은 음원 경로의 끝 성분
    @Test("골든: 경로 성분의 ~는 _로, 파일 이름은 음원 경로의 끝 성분으로")
    func goldenTildeAndAudioFileName() {
        var track = candidate("1", artist: "DJ ~One~", album: "Best ~Of~", file: "old.mp3")
        track.sourcePath = "/music/1/01 Song ~Mix~.mp3"
        let result = plan([track])
        #expect(result.tracks.first?.contentsPath == "/Contents/DJ _One_/Best _Of_/01 Song _Mix_.mp3")
        #expect(result.tracks.first?.fileName == "01 Song _Mix_.mp3")
        #expect(result.tracks.first?.rules.contains(.forbiddenCharacters) == false)
    }

    // MARK: - ID·아트워크

    @Test("content ID는 후보 순서")
    func contentIDsFollowCandidateOrder() {
        let result = plan([candidate("30"), candidate("10"), candidate("20")])
        #expect(result.tracks.map(\.localContentID) == ["30", "10", "20"])
        #expect(result.tracks.map(\.contentID) == [1, 2, 3])
        #expect(result.tracks.map(\.analysisFolder) == ["P000/00000001", "P000/00000002", "P000/00000003"])
        #expect(result.tracks.map(\.analysisPath).first == "/PIONEER/USBANLZ/P000/00000001/ANLZ0000.DAT")
        #expect(result.tracks.allSatisfy { $0.analysisSlot == 0 && $0.audioDisposition == .create })
    }

    @Test("기본 분석 폴더 이름은 rekordbox 경로 해시이고 규칙을 싣지 않는다")
    func defaultNamingIsRekordboxPathHash() {
        let result = UsbExportPlanner.plan(UsbExportRequest(candidates: [candidate("1")], snapshotTakenAt: snapshot))
        let track = result.tracks.first
        #expect(track?.contentsPath == "/Contents/Artist/Album/track 1.mp3")
        #expect(track?.analysisFolder == "P06F/000171CD")
        #expect(track?.analysisPath == "/PIONEER/USBANLZ/P06F/000171CD/ANLZ0000.DAT")
        #expect(!result.requiredRules.contains(.analysisFolderNaming))
    }

    @Test("한 번에 내보내는 두 곡의 해시가 같으면 뒤 곡은 같은 폴더의 다음 번호")
    func rekordboxHashCollisionWithinExport() {
        // 합성 경로 "track 1013"과 "track 7700"은 해시가 같다
        let result = UsbExportPlanner.plan(UsbExportRequest(
            candidates: [candidate("1013"), candidate("7700")], snapshotTakenAt: snapshot))
        #expect(result.tracks.map(\.analysisFolder) == ["P062/00012816", "P062/00012816"])
        #expect(result.tracks.map(\.analysisSlot) == [0, 1])
        #expect(result.tracks.last?.rules.contains(.analysisSlotCollision) == true)
    }

    @Test("그림 있는 곡만 image ID를 차례로 받는다")
    func imageIDsOnlyForTracksWithArtwork() {
        var missingFile = candidate("4", artwork: false)
        missingFile.artworkPathSetButMissing = true
        let result = plan([candidate("1"), candidate("2", artwork: false), candidate("3"), missingFile])
        #expect(result.tracks.map(\.imageID) == [1, nil, 2, nil])
        #expect(result.tracks.map(\.artworkFolder) == [1, nil, 1, nil])
        #expect(result.tracks[1].rules.contains(.artworkMissing))
        #expect(!result.tracks[0].rules.contains(.artworkMissing))
        #expect(result.warnings.map(\.code) == ["artworkMissingFile"])
        #expect(result.warnings.first?.scope == .track("4"))
        #expect(result.blocked.isEmpty)
    }

    @Test("아트워크가 두 폴더에 걸칠 때만 artworkFolderSplit(계획 전체)")
    func artworkSplitRuleOnlyWhenTwoFolders() {
        #expect(!plan([candidate("1"), candidate("2")]).requiredRules.contains(.artworkFolderSplit))
        func big(_ id: String) -> UsbExportCandidate {
            var track = candidate(id)
            track.artwork = UsbArtworkSource(smallPath: "/s", mediumPath: "/m", smallBytes: 100_000, mediumBytes: 150_000)
            return track
        }
        let split = plan([big("1"), big("2"), big("3")])
        #expect(split.tracks.map(\.artworkFolder) == [1, 1, 2])
        #expect(split.requiredRules.contains(.artworkFolderSplit))
        #expect(split.ruleCounts[.artworkFolderSplit] == nil)
    }

    // MARK: - 충돌

    @Test("USB에 같은 내용이 있으면 쓰지 않고 다시 쓴다")
    func collisionReuseSameContent() {
        let calls = Calls()
        let result = plan([candidate("1", file: "x.mp3")], existing: contentsOnly(["Contents/Artist/Album/x.mp3"]),
                          sameContent: { id, path in calls.add(id + "|" + path); return true })
        #expect(result.tracks.first?.audioDisposition == .reuse)
        #expect(result.tracks.first?.contentsPath == "/Contents/Artist/Album/x.mp3")
        #expect(result.tracks.first?.rules.contains(.pathCollision) == false)
        #expect(calls.values == ["1|Contents/Artist/Album/x.mp3"])
    }

    @Test("USB 파일을 다시 쓰면 USB에 있는 철자로 가리키고 철자가 다르면 pathCollision")
    func collisionReuseKeepsUsbFileSpelling() {
        let calls = Calls()
        let result = plan([candidate("1", file: "x.mp3")], existing: contentsOnly(["Contents/Artist/Album/X.MP3"]),
                          sameContent: { id, path in calls.add(id + "|" + path); return true })
        let track = result.tracks.first
        #expect(track?.audioDisposition == .reuse)
        #expect(track?.contentsPath == "/Contents/Artist/Album/X.MP3")
        #expect(track?.fileName == "X.MP3")
        #expect(track?.rules.contains(.pathCollision) == true)
        #expect(calls.values == ["1|Contents/Artist/Album/X.MP3"])
        // 철자를 모르면(파일 철자를 적지 않은 상태) 후보 철자 그대로
        var unknown = contentsOnly(["Contents/Artist/Album/X.MP3"])
        unknown.folderSpelling["contents/artist/album/x.mp3"] = nil
        let fallback = plan([candidate("1", file: "x.mp3")], existing: unknown, sameContent: { _, _ in true }).tracks.first
        #expect(fallback?.contentsPath == "/Contents/Artist/Album/x.mp3")
        #expect(fallback?.audioDisposition == .reuse)
    }

    @Test("내용이 다르면 번호를 붙인다")
    func collisionSuffixDifferentContent() {
        let result = plan([candidate("1", file: "x.mp3")], existing: contentsOnly(["Contents/Artist/Album/x.mp3"]))
        #expect(result.tracks.first?.contentsPath == "/Contents/Artist/Album/x (2).mp3")
        #expect(result.tracks.first?.fileName == "x (2).mp3")
        #expect(result.tracks.first?.audioDisposition == .create)
        #expect(result.tracks.first?.rules.contains(.pathCollision) == true)
        // 같은 계획 안의 다른 곡끼리도
        let inPlan = plan([candidate("1", file: "y.mp3"), candidate("2", file: "Y.MP3")])
        #expect(inPlan.tracks.map(\.fileName) == ["y.mp3", "Y (2).MP3"])
        #expect(inPlan.tracks.map { $0.rules.contains(.pathCollision) } == [false, true])
        // 같은 음원 파일을 가리키는 두 곡은 한 파일을 함께 쓴다
        var twin = candidate("3", file: "y.mp3")
        twin.sourcePath = "/music/1/y.mp3"
        let shared = plan([candidate("1", file: "y.mp3"), twin])
        #expect(shared.tracks.map(\.audioDisposition) == [.create, .reuse])
        #expect(shared.tracks.map(\.fileName) == ["y.mp3", "y.mp3"])
    }

    @Test("대소문자만 다른 폴더는 먼저 있던 철자를 쓴다")
    func folderSpellingReusedCaseInsensitive() {
        let existing = contentsOnly(["Contents/ARTIST/Album/other.mp3"])
        let result = plan([candidate("1", artist: "Artist", file: "x.mp3")], existing: existing)
        #expect(result.tracks.first?.contentsPath == "/Contents/ARTIST/Album/x.mp3")
        #expect(result.tracks.first?.rules.contains(.pathCollision) == true)
        let inPlan = plan([candidate("1", artist: "Foo", file: "a.mp3"), candidate("2", artist: "FOO", file: "b.mp3")])
        #expect(inPlan.tracks.map(\.contentsPath) == ["/Contents/Foo/Album/a.mp3", "/Contents/Foo/Album/b.mp3"])
        #expect(inPlan.tracks.map { $0.rules.contains(.pathCollision) } == [false, true])
    }

    @Test("NFC·NFD로만 다른 이름은 같은 이름")
    func nfcNfdCollide() {
        let result = plan([candidate("1", artist: "Cafe\u{0301}", file: "Caf\u{00E9}.mp3"),
                           candidate("2", artist: "Caf\u{00E9}", file: "Cafe\u{0301}.mp3")])
        #expect(result.tracks.map(\.contentsPath) == ["/Contents/Caf\u{00E9}/Album/Caf\u{00E9}.mp3",
                                                       "/Contents/Caf\u{00E9}/Album/Caf\u{00E9} (2).mp3"])
        #expect(result.tracks.map { $0.rules.contains(.pathCollision) } == [false, true])
    }

    // MARK: - 기존 USB

    @Test("기존 USB의 ID·분석 파일·아트워크를 피한다")
    func existingStateAvoidsIDsAndPaths() {
        var existing = UsbExistingState(hasLibrary: true)
        existing.ids = UsbIDAllocator(highWater: [.content: 10, .image: 4, .playlist: 3])
        existing.artworkLayout = UsbArtworkLayout(folderUsage: [1: 990_000], currentFolder: 1)
        existing.analysisSlots = ["P000/0000000B": [(slot: 0, ppth: "/Contents/Other/Album/other.mp3")]]
        let result = plan([candidate("1")], playlists: [list("p", "목록", tracks: ["1"])], existing: existing)
        let track = result.tracks.first
        #expect(track?.contentID == 11)
        #expect(track?.analysisFolder == "P000/0000000B")
        #expect(track?.analysisSlot == 1)
        #expect(track?.analysisPath == "/PIONEER/USBANLZ/P000/0000000B/ANLZ0001.DAT")
        #expect(track?.rules.contains(.analysisSlotCollision) == true)
        #expect(track?.imageID == 5)
        #expect(track?.artworkFolder == 2)
        #expect(result.playlists.first?.playlistID == 4)
        #expect(!result.requiredRules.contains(.myTagMasterDBID))
        // 같은 곡 경로의 분석 파일은 그 번호를 다시 쓴다
        existing.analysisSlots = ["P000/0000000B": [(slot: 3, ppth: "/Contents/Artist/Album/track 1.mp3")]]
        let reused = plan([candidate("1")], existing: existing).tracks.first
        #expect(reused?.analysisSlot == 3)
        #expect(reused?.rules.contains(.analysisSlotCollision) == true)
    }

    @Test("형제 순번은 기존 형제 다음, 없으면 0부터")
    func siblingBaseFollowsExisting() {
        var existing = UsbExistingState(hasLibrary: true)
        existing.siblingBase = [0: 1]
        existing.siblingMax = [0: 3]
        let playlists = [list("a", "A"), list("b", "B")]
        #expect(plan([], playlists: playlists, existing: existing).playlists.map(\.sortOrder) == [4, 5])
        #expect(plan([], playlists: playlists).playlists.map(\.sortOrder) == [0, 1])
    }

    // MARK: - 용량

    @Test("음원은 클러스터 단위로 올려 센다")
    func spaceClusterRounding() {
        #expect(UsbSpaceEstimate.roundUp(1, cluster: 4_096) == 4_096)
        #expect(UsbSpaceEstimate.roundUp(4_096, cluster: 4_096) == 4_096)
        #expect(UsbSpaceEstimate.roundUp(4_097, cluster: 4_096) == 8_192)
        #expect(UsbSpaceEstimate.roundUp(0, cluster: 4_096) == 0)
        let one = plan([candidate("1", size: 1)]).space.newBytes
        #expect(plan([candidate("1", size: 4_096)]).space.newBytes == one)
        #expect(plan([candidate("1", size: 4_097)]).space.newBytes == one + 4_096)
        // 이미 있는 같은 내용은 새로 쓰지 않는다
        let reuse = plan([candidate("1", file: "x.mp3", size: 100_000)], existing: contentsOnly(["Contents/Artist/Album/x.mp3"]),
                         sameContent: { _, _ in true })
        let create = plan([candidate("1", file: "x.mp3", size: 100_000)])
        #expect(create.space.newBytes - reuse.space.newBytes == UsbSpaceEstimate.roundUp(100_000, cluster: 4_096))
    }

    @Test("교체 중에는 가장 큰 DB가 두 번 있다")
    func tempBytesIncludesLargestDBTwice() {
        let result = plan([candidate("1"), candidate("2"), candidate("3")])
        let database = UsbSpaceEstimate.roundUp(UsbSpaceEstimate.databaseBytes(trackCount: 3), cluster: 4_096)
        #expect(UsbSpaceEstimate.databaseBytes(trackCount: 3) == 3 * 4_096 + 65_536)
        #expect(result.space.tempBytes == 2 * database)
        #expect(result.space.margin == UsbSpaceEstimate.minimumMargin)
        #expect(result.space.total == result.space.newBytes + result.space.tempBytes + result.space.margin)
        #expect(UsbSpaceEstimate.margin(available: 100_000_000_000) == 1_000_000_000)
        #expect(UsbSpaceEstimate.margin(available: 1_000_000) == 64 << 20)
        // Device Library를 빼면 DB 파일 둘(export.pdb·exportExt.pdb)만큼 줄어든다
        var request = request([candidate("1"), candidate("2"), candidate("3")])
        request.formats = [.oneLibrary]
        #expect(result.space.newBytes - UsbExportPlanner.plan(request).space.newBytes == 2 * database)
    }

    // MARK: - 규칙

    @Test("규칙별 곡 수")
    func ruleCountsPerRule() {
        let result = plan([candidate("1", fileType: 11), candidate("2", fileType: 11), candidate("3", artist: nil)])
        #expect(result.ruleCounts[.fileTypeUnverified] == 2)
        #expect(result.ruleCounts[.emptyArtistAlbum] == 1)
        #expect(result.ruleCounts[.analysisFolderNaming] == 3)
        #expect(result.ruleCounts[.myTagMasterDBID] == nil)
        #expect(result.requiredRules.isSuperset(of: [.fileTypeUnverified, .emptyArtistAlbum, .analysisFolderNaming, .myTagMasterDBID]))
    }

    @Test("라이브러리가 없는 USB면 myTagMasterDBID")
    func newUsbHasMyTagMasterDBIDRule() {
        #expect(plan([candidate("1")]).requiredRules.contains(.myTagMasterDBID))
        #expect(plan([candidate("1")], existing: contentsOnly(["Contents/a.mp3"])).requiredRules.contains(.myTagMasterDBID))
        #expect(!plan([candidate("1")], existing: UsbExistingState(hasLibrary: true)).requiredRules.contains(.myTagMasterDBID))
    }

    @Test("큐·곡 칸 규칙과 알 수 없는 큐 경고")
    func cueAndMetadataRules() {
        var track = candidate("1")
        track.cues = [UsbCueTraits(kind: 1, colorTableIndex: 3, inMsec: 1_000, outMsec: -1), UsbCueTraits(kind: 4, inMsec: 2_000, outMsec: -1)]
        track.metadata.hasRating = true
        let result = plan([track])
        #expect(result.tracks.first?.rules.isSuperset(of: [.cueVariant, .metadataSeenEmptyOnly]) == true)
        #expect(result.warnings.map(\.code) == ["kind4CueDropped"])
        #expect(result.blocked.isEmpty)
    }

    /// rekordbox 7.2.x 경계 실험(2026-10-08): 곡 행 경로·아티스트·앨범 이름의 127자 이상 ASCII는 긴 ASCII(0x40)라 규칙을 싣지 않는다
    @Test("Contents 경로·아티스트 이름이 순수 ASCII 127자 이상이어도 pdbLongAscii를 싣지 않는다")
    func longAsciiTrackStringsNotFlagged() {
        let artist = String(repeating: "a", count: 40), album = String(repeating: "b", count: 40)
        let long = plan([candidate("1", artist: artist, album: album, file: String(repeating: "f", count: 31) + ".mp3")])
        #expect(long.tracks.first?.contentsPath.count == 127)
        #expect(long.tracks.first?.rules.contains(.pdbLongAscii) == false)
        #expect(!long.requiredRules.contains(.pdbLongAscii))
        let longArtist = plan([candidate("1", artist: String(repeating: "a", count: 130), file: "x.mp3")])
        #expect(longArtist.tracks.first?.contentsPath == "/Contents/" + String(repeating: "a", count: 48) + "/Album/x.mp3")
        #expect(longArtist.tracks.first?.rules.contains(.pdbLongAscii) == false)
    }

    @Test("재생 목록 이름도 같은 함수로 판정한다")
    func longAsciiPlaylistNameFlagged() {
        let ok = plan([candidate("1")], playlists: [list("p", String(repeating: "n", count: 126), tracks: ["1"])])
        #expect(ok.playlists.first?.rules.isEmpty == true)
        #expect(!ok.requiredRules.contains(.pdbLongAscii))
        let long = plan([candidate("1")], playlists: [list("p", String(repeating: "n", count: 127), tracks: ["1"])])
        #expect(long.playlists.first?.rules == [.pdbLongAscii])
        #expect(long.requiredRules.contains(.pdbLongAscii))
        #expect(long.ruleCounts[.pdbLongAscii] == nil)
    }

    @Test("Contents/만 있는 USB는 새 USB처럼 계획한다")
    func contentsOnlyExistingStateIsNewUsb() {
        let existing = contentsOnly(["Contents/Artist/Album/x.mp3", "Contents/Other/ALBUM B/y.mp3"])
        #expect(!existing.hasLibrary)
        let tracks = [candidate("1", file: "x.mp3"), candidate("2", artist: "Other", album: "Album B", file: "y.mp3"),
                      candidate("3", artist: "Other", album: "Album B", file: "z.mp3")]
        let result = plan(tracks, playlists: [list("p", "목록", tracks: ["1", "2", "3"])], existing: existing,
                          sameContent: { id, _ in id == "1" })
        #expect(result.requiredRules.contains(.myTagMasterDBID))
        #expect(result.tracks.map(\.contentID) == [1, 2, 3])
        #expect(result.playlists.map(\.sortOrder) == [0])
        #expect(result.tracks.map(\.audioDisposition) == [.reuse, .create, .create])
        #expect(result.tracks.map(\.contentsPath) == ["/Contents/Artist/Album/x.mp3", "/Contents/Other/ALBUM B/y (2).mp3",
                                                       "/Contents/Other/ALBUM B/z.mp3"])
        #expect(result.tracks.map { $0.rules.contains(.pathCollision) } == [false, true, true])
    }

    @Test("계획은 곡 아티스트로 폴더를 짓는다")
    func usesTrackArtistNotAlbumArtist() {
        let result = plan([candidate("1", artist: "Track Artist", album: "Album", file: "x.mp3")])
        #expect(result.tracks.first?.contentsPath == "/Contents/Track Artist/Album/x.mp3")
    }
}

/// sameContent 호출 기록(시험용)
final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func add(_ value: String) { lock.withLock { list.append(value) } }
    var values: [String] { lock.withLock { list } }
}
