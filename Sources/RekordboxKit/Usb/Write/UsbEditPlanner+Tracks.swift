import DJCDomain
import Foundation

/// 로컬을 읽는 편집: 곡 갱신·곡 더하기
extension UsbEditPlanner {
    /// 로컬 사본·share·스냅샷 시각과 로컬 rekordbox 버전(확인한 버전만)
    func requireLocal() throws -> (database: CipherDatabase, share: URL, snapshot: Date) {
        guard let share, let snapshotTakenAt else {
            throw UsbEditBlocked(block: UsbBlock(code: "localLibraryMissing", scope: .volume,
                                                 message: String(ui: "로컬 라이브러리 사본이 없어 곡을 더하거나 갱신할 수 없습니다. --db로 스냅샷 사본을 주세요")))
        }
        return (try requireLocalDatabase(), share, snapshotTakenAt)
    }

    /// 목록 동기화는 곡의 식별 키만 읽으므로 share·분석 파일을 필요로 하지 않는다
    func requireLocalDatabase() throws -> CipherDatabase {
        guard let localDatabase else {
            throw UsbEditBlocked(block: UsbBlock(code: "localLibraryMissing", scope: .volume,
                                                 message: String(ui: "로컬 라이브러리 사본이 없어 USB 편집을 계획하지 못했습니다. --db로 스냅샷 사본을 주세요")))
        }
        guard let version = localAppVersion, (try? RekordboxCompatibility.checkApp(version: version)) != nil else {
            let shown = localAppVersion ?? String(ui: "찾지 못함")
            throw UsbEditBlocked(block: UsbBlock(code: "localVersionUnverified", scope: .volume,
                                                 message: String(ui: "로컬 rekordbox 버전(\(shown))은 USB 갱신을 확인하지 않았습니다")))
        }
        try UsbExportCandidates.refuseLive(localDatabase, liveDatabase: UsbExportCandidates.liveDatabase)
        return localDatabase
    }

    /// USB 곡의 로컬 짝(이 곡을 내보낸 라이브러리 DB ID·곡 ID·파일 이름이 같은 곡 하나). 없거나 둘 이상이면 nil
    static func localMatch(_ track: UsbTrack, database: CipherDatabase) throws -> String? {
        var keys: [UsbLocalTrackKey] = []
        try database.query("""
            SELECT ID, MasterSongID, FileNameL, FolderPath FROM djmdContent
            WHERE rb_local_deleted = 0 AND CAST(MasterSongID AS INTEGER) = ? AND CAST(MasterDBID AS INTEGER) = ?
            """, [.int(Int(track.masterContentId)), .int(Int(track.masterDbId))]) { row in
            keys.append(UsbLocalTrackKey(contentID: row.string(0) ?? "", masterSongID: row.string(1) ?? "", fileNameL: row.string(2) ?? "",
                                         folderPath: row.string(3)))
        }
        let key = UsbTrackKey(masterDbId: track.masterDbId, masterContentId: track.masterContentId, fileName: track.fileName)
        return UsbTrackMatch.match(key, localDBID: track.masterDbId, local: keys)
    }

    // MARK: - 곡 갱신

    mutating func planRefresh(_ usbIDs: [Int], parts: Set<UsbRefreshPart>, into planned: inout UsbPlannedEdit) throws {
        let (database, share, snapshot) = try requireLocal()
        let local = UsbLocalSource(database: database)
        var names = NameAllocator(existing: working, highWater: ids.highWater)
        var upsert = UsbTrackUpsert()
        var strings: [String] = []
        var blocked: [UsbBlock] = []
        let requested = Self.unique(usbIDs)
        for id in requested {
            // 곡 하나가 막히면 그 곡만 뺀다(곡 더하기와 같게). 그 곡을 보며 준비한 파일·이름·번호도 되돌린다
            let saved = (planned, names, upsert, strings, ids, artwork)
            do {
                try refreshTrack(id, parts: parts, database: database, share: share, snapshot: snapshot, local: local, names: &names,
                                 upsert: &upsert, strings: &strings, into: &planned)
            } catch let error as UsbEditBlocked {
                (planned, names, upsert, strings, ids, artwork) = saved
                blocked.append(error.block)
            }
        }
        // 요청한 곡이 모두 막혔을 때만 편집을 막는다
        if !blocked.isEmpty, blocked.count == requested.count { throw UsbEditBlocked(block: blocked[0]) }
        planned.trackBlocks += blocked
        guard !upsert.replaced.isEmpty else { return }
        let rows = newRows(names)
        (upsert.artists, upsert.albums, upsert.genres, upsert.keys, upsert.labels) = (rows.artists, rows.albums, rows.genres, rows.keys, rows.labels)
        planned.op = .upsert(upsert)
        planned.rules.formUnion([.editRefreshTracks])
        planned.rules.formUnion(UsbTrackRules.pdbStringRules(strings))
    }

    /// 곡 하나 갱신. 바꿀 것이 있으면 `upsert.replaced`에 더한다. 막히면 `UsbEditBlocked`
    mutating func refreshTrack(_ id: Int, parts: Set<UsbRefreshPart>, database: CipherDatabase, share: URL, snapshot: Date, local: UsbLocalSource,
                               names: inout NameAllocator, upsert: inout UsbTrackUpsert, strings: inout [String],
                               into planned: inout UsbPlannedEdit) throws {
        guard let track = working.tracks.first(where: { $0.id == id }), !track.presentIn.isDisjoint(with: writable) else {
            throw Self.vanished(.track("usb:\(id)"))
        }
        if refreshed.contains(id) { return }
        guard let localID = try Self.localMatch(track, database: database) else {
            throw UsbEditBlocked(block: UsbBlock(code: "localTrackNotFound", scope: .track("usb:\(id)"),
                                                 message: String(ui: "로컬 라이브러리에서 이 곡을 찾지 못했습니다. USB에서 빼고 다시 넣으세요")))
        }
        let row = try local.track(localID)
        let status = UsbSyncStatus.compare(localInfo: row.trackInfoUpdated, localAnalysis: row.analysisUpdated, localCue: row.cueUpdated,
                                           usbInfo: track.informationUpdateCount, usbAnalysis: track.analysisDataUpdateCount,
                                           usbCue: track.cueUpdateCount, hasModified: track.hasModified,
                                           hasCueRows: try deviceCues(id) > 0)
        switch status {
        case .deviceModified:
            planned.notes.append(String(ui: "기기에서 고친 곡이라 건너뜀. 먼저 기기 변경을 가져오세요(곡 \(id))"))
            return
        case .upToDate, .missingLocal: return
        case .localNewer: break
        }
        let rewritesAnalysis = !parts.isDisjoint(with: [.cues, .grid])
        if rewritesAnalysis, let modified = UsbExportCandidates.analysisFiles(share: share, path: row.analysisDataPath).modified,
           modified > snapshot {
            throw UsbEditBlocked(block: UsbBlock(code: "analysisNewerThanSnapshot", scope: .track("usb:\(id)"),
                                                 message: String(ui: "rekordbox 분석이 스냅샷 뒤에 바뀌었습니다. 새 스냅샷을 뜬 뒤 다시 시도하세요")))
        }
        try checkAudio(track, row: row)
        var updated = track
        if parts.contains(.info) { UsbLibraryBuilder.applyInfo(row, to: &updated, names: &names) }
        let filesBefore = planned.files.writes.count
        if rewritesAnalysis {
            let analysis = try refreshAnalysis(track, localID: localID, row: row, database: database, share: share, into: &planned)
            // 분석 파일을 고치지 않았으면(다른 곡 것) 갱신 횟수도 USB 값 그대로 둔다. 아니면 DB만 최신이라고 적어 다음 갱신이 고치지 않는다
            if analysis != .foreignPPTH {
                if parts.contains(.cues) { updated.cueUpdateCount = row.cueUpdated ?? "" }
                if parts.contains(.grid) { updated.analysisDataUpdateCount = row.analysisUpdated ?? "" }
            }
            if analysis == .written { UsbLibraryBuilder.applyAnalysis(row, to: &updated) }
        }
        if parts.contains(.artwork) { try refreshArtwork(&updated, row: row, share: share, images: &upsert.images, into: &planned) }
        guard updated != track || planned.files.writes.count > filesBefore else { return }
        // Device Library에 쓸 때만 트랙 행을 미리 만들어 보고 pdb 문자열 규칙을 싣는다
        if writable.contains(.deviceLibrary), updated.presentIn.contains(.deviceLibrary) {
            let rows = newRows(names)
            try deviceRowCheck(updated, newRows: rows)
            strings += Self.pdbStrings(updated, in: working, extra: rows)
        }
        upsert.replaced.append(updated)
        refreshed.insert(id)
    }

    /// 이름 표에 새로 생긴 행
    func newRows(_ names: NameAllocator) -> (artists: [UsbNamedRow], albums: [UsbAlbum], genres: [UsbNamedRow], keys: [UsbNamedRow],
                                             labels: [UsbNamedRow]) {
        (names.artists.added, names.albums, names.genres.added, names.keys.added, names.labels.added)
    }

    /// OneLibrary 사본의 기기 큐 행 수(곡 id별). OneLibrary가 없으면 0
    mutating func deviceCues(_ id: Int) throws -> Int {
        if deviceCueRows == nil {
            var counts: [Int: Int] = [:]
            if let copy = source.snapshot?.oneLibrary {
                let db = try CipherDatabase(path: copy.path, key: .passphrase(RekordboxKey.oneLibrary()), mode: .readOnly)
                defer { db.close() }
                try db.query("SELECT content_id, count(*) FROM cue GROUP BY content_id") { counts[$0.int(0) ?? 0] = $0.int(1) ?? 0 }
            }
            deviceCueRows = counts
        }
        return deviceCueRows?[id] ?? 0
    }

    /// 음원은 다시 쓰지 않는다: 로컬 원본과 USB 파일의 크기·SHA-1이 같아야 한다
    func checkAudio(_ track: UsbTrack, row: UsbLocalTrackRow) throws {
        let changed = UsbEditBlocked(block: UsbBlock(code: "audioChanged", scope: .track("usb:\(track.id)"),
                                                     message: String(ui: "음원이 바뀌었습니다. USB에서 빼고 다시 넣으세요")))
        guard let source = row.folderPath, let local = try? UsbExportAssembly.fileHashes(source, content: row.id),
              let url = try? root.url(for: Self.relative(track.path)),
              let usb = try? UsbExportAssembly.fileHashes(url.path, content: "usb:\(track.id)"),
              local.size == usb.size, local.sha1 == usb.sha1 else { throw changed }
    }

    /// 분석 파일 갱신 결과
    enum AnalysisRefresh {
        /// 바뀐 파일을 준비했다
        case written
        /// USB 파일이 이미 같다
        case identical
        /// 덮어쓸 USB 파일이 다른 곡 것이라 고치지 않았다
        case foreignPPTH
    }

    /// 분석 파일 셋을 로컬에서 다시 만들어 DB에 적힌 자리(폴더·번호 그대로)에 덮어쓴다. USB `.DAT`의 PPTH가 이 곡이 아니면
    /// 고치지 않고 알린다
    func refreshAnalysis(_ track: UsbTrack, localID: String, row: UsbLocalTrackRow, database: CipherDatabase, share: URL,
                         into planned: inout UsbPlannedEdit) throws -> AnalysisRefresh {
        let incomplete = UsbEditBlocked(block: UsbBlock(code: "analysisIncomplete", scope: .track("usb:\(track.id)"),
                                                        message: String(ui: "rekordbox에서 트랙 분석을 다시 한 뒤 내보내세요")))
        guard let analysisPath = row.analysisDataPath, !analysisPath.isEmpty,
              let local = try? UsbAnlzTransform.readLocal(share: share, analysisDataPath: analysisPath) else { throw incomplete }
        let dat = UsbLayout.nfc(Self.relative(track.analysisDataPath))
        guard dat.uppercased().hasSuffix(".DAT"), UsbWriter.isSafeRelativePath(dat) else { throw incomplete }
        let base = String(dat.dropLast(4))
        let result = try UsbAnlzTransform.transform(localDAT: local.dat, localEXT: local.ext, local2EX: local.twoEx, contentsPath: track.path,
                                                    cues: UsbCueSource(database: database).cues(contentID: localID), fileType: track.fileType)
        let files = [(".DAT", result.dat), (".EXT", result.ext)] + (result.twoEx.map { [(".2EX", $0)] } ?? [])
        // 덮어쓸 파일이 다른 곡 것이면(번호가 엉킨 USB) 그 곡 셋을 고치지 않는다
        for (ext, _) in files {
            let url = root.url.appending(path: base + ext)
            guard let info = try fileSystem.stat(url), info.kind == .file else { continue }
            let ppth = UsbExportAssembly.ppthReader(try fileSystem.read(url, maxBytes: Int(info.size)))
            if ppth.map(UsbLayout.nfc) != UsbLayout.nfc(track.path) {
                planned.notes.append(String(ui: "분석 파일이 다른 곡 것이라 고치지 않았습니다: \(dat)"))
                return .foreignPPTH
            }
        }
        var changed = false
        for (ext, data) in files {
            let url = root.url.appending(path: base + ext)
            if let info = try fileSystem.stat(url), info.kind == .file {
                let hash = try fileSystem.sha256(url, uncached: true)
                if hash == UsbExportAssembly.sha256(data) { continue }
                try planned.files.stage(data, at: base + ext, modified: nil, replacing: (hash, track.path))
            } else {
                try planned.files.stage(data, at: base + ext, modified: nil)
            }
            changed = true
        }
        planned.rules.formUnion(result.rules)
        planned.warnings += result.warnings.compactMap { UsbExportAssembly.analysisWarning($0, track: "usb:\(track.id)") }
        return changed ? .written : .identical
    }

    /// 로컬 그림이 바뀌었으면 같은 image id·폴더의 a·b·_m을 덮어쓰고, 그림이 새로 생긴 곡(또는 다른 곡과 함께 쓰는 그림)은 새 image id
    mutating func refreshArtwork(_ track: inout UsbTrack, row: UsbLocalTrackRow, share: URL, images: inout [UsbImage],
                                 into planned: inout UsbPlannedEdit) throws {
        guard let source = UsbExportCandidates.artworkFiles(share: share, imagePath: row.imagePath).source else { return }
        let small = try UsbExportAssembly.readLocal(source.smallPath, "artwork", content: row.id)
        let medium = try UsbExportAssembly.readLocal(source.mediumPath, "artwork", content: row.id)
        let modified = try UsbExportAssembly.modificationDate(source.smallPath, "artwork", content: row.id)
        let formats = track.presentIn.intersection(writable)
        func place(_ path: String, _ data: Data) throws {
            let relative = Self.relative(path)
            let url = try root.url(for: relative)
            if let info = try fileSystem.stat(url), info.kind == .file {
                let hash = try fileSystem.sha256(url, uncached: true)
                if hash != UsbExportAssembly.sha256(data) {
                    try planned.files.stage(data, at: relative, modified: modified, replacing: (hash, nil))
                }
            } else {
                try planned.files.stage(data, at: relative, modified: modified)
            }
        }
        let trackID = track.id
        if let imageID = track.imageID, let image = working.images.first(where: { $0.id == imageID }),
           !isShared(imageID, except: trackID) {
            let existing = [(UsbFormat.deviceLibrary, image.pdbPath), (.oneLibrary, image.oneLibraryPath)]
            // 덮어쓸 자리는 DB에 적힌 경로다. 아트워크 파일 모양이 아니면(`..` 등) 준비 폴더·USB의 다른 곳을 가리킬 수 있어 고치지 않는다
            for case let (format, path?) in existing where formats.contains(format) {
                guard Self.isArtworkFile(Self.relative(path)), Self.isArtworkFile(Self.relative(Self.mediumArtworkPath(path))) else {
                    throw UsbEditBlocked(block: UsbBlock(code: "artworkPathRefused", scope: .track("usb:\(track.id)"),
                                                         message: String(ui: "USB에 적힌 앨범아트 경로가 앨범아트 폴더 모양이 아니라 앨범아트를 고치지 않았습니다. rekordbox에서 USB를 다시 내보내세요")))
                }
            }
            for (format, path) in existing {
                guard formats.contains(format), let path else { continue }
                try place(path, small)
                try place(Self.mediumArtworkPath(path), medium)
            }
            return
        }
        let id = ids.next(.image)
        var layout = try artworkLayout()
        let folder = layout.place(bytes: 2 * (small.count + medium.count))
        artwork = layout
        let image = UsbImage(id: id, oneLibraryPath: formats.contains(.oneLibrary) ? UsbArtworkLayout.oneLibraryPath(imageID: id, folder: folder) : nil,
                             pdbPath: formats.contains(.deviceLibrary) ? UsbArtworkLayout.pdbPath(imageID: id, folder: folder) : nil)
        for path in [image.pdbPath, image.oneLibraryPath].compactMap({ $0 }) {
            try place(path, small)
            try place(Self.mediumArtworkPath(path), medium)
        }
        images.append(image)
        track.imageID = id
    }

    /// 그 그림을 이 곡 말고도 곡·앨범·목록이 가리키는지
    func isShared(_ imageID: Int, except trackID: Int) -> Bool {
        working.tracks.contains { $0.id != trackID && $0.imageID == imageID } || working.albums.contains { $0.imageID == imageID }
            || working.playlists.contains { $0.imageID == imageID }
    }

    /// ".../a12.jpg" → ".../a12_m.jpg"
    static func mediumArtworkPath(_ path: String) -> String {
        let stem = (path as NSString).deletingPathExtension, ext = (path as NSString).pathExtension
        return stem + "_m" + (ext.isEmpty ? "" : "." + ext)
    }

    /// Device Library 작성기가 이 곡 때문에 쓰기 전체를 거부하지 않게 미리 본다(행 크기·확장자·ISRC·칸 범위·긴 이름)
    func deviceRowCheck(_ track: UsbTrack, newRows: (artists: [UsbNamedRow], albums: [UsbAlbum], genres: [UsbNamedRow], keys: [UsbNamedRow],
                                                     labels: [UsbNamedRow])) throws {
        var library = working
        library.artists += newRows.artists
        library.albums += newRows.albums
        library.genres += newRows.genres
        library.keys += newRows.keys
        library.labels += newRows.labels
        library.tracks = library.tracks.filter { $0.id != track.id } + [track]
        let scope = UsbBlock.Scope.track("usb:\(track.id)")
        if !PdbRowSize.fitsEmptyPage(rowSize: PdbRowSize.track(track, library: library.projected(to: .deviceLibrary))) {
            throw UsbEditBlocked(block: UsbBlock(code: "trackRowTooLarge", scope: scope,
                                                 message: String(ui: "곡 정보가 너무 길어 Device Library에 쓸 수 없습니다. rekordbox에서 주석 등 곡 정보를 줄인 뒤 다시 시도하세요")))
        }
        if !PdbWriter.fileTypeMatchesExtension(track) {
            throw UsbEditBlocked(block: UsbBlock(code: "fileTypeMismatchForDeviceLibrary", scope: scope,
                                                 message: String(ui: "파일 확장자가 음원 형식과 달라 Device Library에 쓸 수 없습니다. rekordbox에서 트랙 정보를 다시 읽은 뒤 다시 시도하세요")))
        }
        if let refusal = UsbExportAssembly.trackRowRefusal(track) {
            throw UsbEditBlocked(block: UsbBlock(code: refusal.code, scope: scope, message: refusal.message))
        }
        // 긴 이름은 먼 모양으로 쓴다. 빈 쪽에도 안 들어가는 행만 막는다
        if newRows.artists.contains(where: { !PdbRowSize.fitsEmptyPage(rowSize: PdbRowSize.artist(name: $0.name)) })
            || newRows.albums.contains(where: { !PdbRowSize.fitsEmptyPage(rowSize: PdbRowSize.album(name: $0.name)) }) {
            throw UsbEditBlocked(block: UsbBlock(code: "nameTooLongForDeviceLibrary", scope: scope,
                                                 message: String(ui: "아티스트·앨범 이름이 너무 길어 아직 내보낼 수 없습니다. rekordbox에서 이름을 줄인 뒤 다시 시도하세요")))
        }
    }

    /// 곡이 가리키는 이름 중 긴 ASCII를 rekordbox에서 본 적 없는 칸(장르·키·레이블, 긴 ASCII 판정용). 출력·로그에 쓰지 않는다.
    /// 트랙 행 문자열·아티스트·앨범 이름의 긴 ASCII는 rekordbox 7.2.x 경계 실험(2026-10-08)으로 확인해 세지 않는다
    static func pdbStrings(_ track: UsbTrack, in model: UsbLibrary,
                           extra: (artists: [UsbNamedRow], albums: [UsbAlbum], genres: [UsbNamedRow], keys: [UsbNamedRow], labels: [UsbNamedRow]))
        -> [String] {
        var strings: [String] = []
        for (id, table) in [(track.genreID, model.genres + extra.genres), (track.keyID, model.keys + extra.keys),
                            (track.labelID, model.labels + extra.labels)] {
            if let id { strings += table.filter { $0.id == id }.map(\.name) }
        }
        return strings
    }

    // MARK: - 곡 더하기

    mutating func planAdd(_ localIDs: [String], playlist ref: PlaylistRef?, into planned: inout UsbPlannedEdit,
                          progress: (Int, Int) -> Void, isCancelled: () -> Bool) throws {
        let (database, share, snapshot) = try requireLocal()
        let wanted = Self.unique(localIDs)
        guard !wanted.isEmpty else { return }
        // 넣을 목록을 먼저 본다(항목 편집 규칙)
        var entryTarget: (UsbPlaylist, [UsbFormat], [Int])?
        if let ref { entryTarget = try self.entryTarget(ref) }
        var candidates = try UsbExportCandidates.load(database: database, share: share, contentIDs: wanted)
        let found = Set(candidates.map(\.localContentID))
        for id in wanted where !found.contains(id) {
            planned.trackBlocks.append(UsbBlock(code: "localTrackMissing", scope: .track(id),
                                                message: String(ui: "스냅샷에서 이 곡을 찾지 못했습니다. 새 스냅샷을 뜬 뒤 다시 내보내세요")))
        }
        // 파일 이름 정제·번호 꼬리도 같은 짝으로 본다(동기화마다 곡이 중복해 늘지 않게)
        let pairs = try localPairs(for: wanted, database: database)
        candidates.removeAll { candidate in
            if pairs.ambiguous.contains(candidate.localContentID) {
                planned.trackBlocks.append(Self.syncPairingBlock(candidate.localContentID, ambiguous: true))
                return true
            }
            let onUsb = !(pairs.matches[candidate.localContentID] ?? []).isEmpty
            if onUsb {
                planned.trackBlocks.append(UsbBlock(code: "alreadyOnUsb", scope: .track(candidate.localContentID),
                                                    message: String(ui: "이미 USB에 있는 곡입니다. 곡 정보를 바꾸려면 갱신을 쓰세요")))
            }
            return onUsb
        }
        let existing = try existingState()
        let rootURL = root.url
        let sources = Dictionary(candidates.map { ($0.localContentID, $0.sourcePath ?? "") }) { first, _ in first }
        var request = UsbExportRequest(
            candidates: candidates, playlists: [], existing: existing, formats: writable, naming: RekordboxAnalysisNaming(),
            snapshotTakenAt: snapshot, clusterSize: clusterSize,
            sameContent: { id, relative in UsbExportCandidates.sameContent(sourcePath: sources[id] ?? "", usbFile: rootURL.appending(path: relative)) })
        var base = working
        base.formats = writable
        var rowBlocks: [UsbBlock] = []
        let local = UsbLocalSource(database: database)
        var plan = UsbExportPlanner.plan(request)
        // 분석 폴더 이름은 곡 경로로 정해진다. 계획이 고른 폴더의 USB 자리를 읽은 뒤 다시 계획한다(경로·ID는 그대로, 파일 번호만 바뀔 수 있다)
        if try loadAnalysisSlots(plan.tracks.map(\.analysisFolder), into: &request) { plan = UsbExportPlanner.plan(request) }
        var model = try UsbLibraryBuilder.add(plan: plan, into: base, local: local, share: share, highWater: ids.highWater)
        while true {
            // 새 곡만 본다(있던 곡은 왕복 검사를 지났다). 막힌 곡은 빼고 다시 계획해 번호가 빈틈없게 한다
            let inPlan = Set(plan.tracks.map(\.localContentID))
            let found = UsbExportAssembly.rowSizeBlocks(model: model, plan: plan, formats: writable).filter {
                if case let .track(id) = $0.scope { inPlan.contains(id) } else { false }
            }
            rowBlocks += found
            let removed = Set(found.compactMap { block -> String? in if case let .track(id) = block.scope { id } else { nil } })
            if removed.isEmpty { break }
            request.candidates.removeAll { removed.contains($0.localContentID) }
            plan = UsbExportPlanner.plan(request)
            model = try UsbLibraryBuilder.add(plan: plan, into: base, local: local, share: share, highWater: ids.highWater)
        }
        planned.trackBlocks += plan.blocked.filter { $0.scope != .volume } + rowBlocks
        if let block = plan.blocked.first(where: { $0.scope == .volume }) { throw UsbEditBlocked(block: block) }
        guard !plan.tracks.isEmpty else {
            // 동기화는 넣지 못한 곡만 알리고 나머지를 쓴다(뒤의 목록 동기화가 그 곡을 빼고 맞춘다)
            if skipsUnaddableTracks, !planned.trackBlocks.isEmpty, planned.trackBlocks.allSatisfy(\.isSkippableInSync) { return }
            throw UsbEditBlocked(block: planned.trackBlocks.first
                ?? UsbBlock(code: "noTracks", scope: .volume, message: String(ui: "더할 곡이 없습니다. 막힌 곡의 이유를 확인한 뒤 다시 시도하세요")))
        }
        let staged = try UsbExportAssembly.stageTracks(model: model, plan: plan, localDatabase: database, into: &planned.files,
                                                       progress: progress, isCancelled: isCancelled)
        let newIDs = Set(plan.tracks.map(\.contentID))
        var upsert = UsbTrackUpsert()
        upsert.added = model.library.tracks.filter { newIDs.contains($0.id) }.map { track in
            var track = track
            track.presentIn = writable
            return track
        }
        func fresh<Row>(_ rows: [Row], _ old: [Row], id: KeyPath<Row, Int>) -> [Row] {
            let known = Set(old.map { $0[keyPath: id] })
            return rows.filter { !known.contains($0[keyPath: id]) }
        }
        upsert.artists = fresh(model.library.artists, working.artists, id: \.id)
        upsert.albums = fresh(model.library.albums, working.albums, id: \.id)
        upsert.genres = fresh(model.library.genres, working.genres, id: \.id)
        upsert.keys = fresh(model.library.keys, working.keys, id: \.id)
        upsert.labels = fresh(model.library.labels, working.labels, id: \.id)
        upsert.images = fresh(model.library.images, working.images, id: \.id)
        if let (playlist, formats, entries) = entryTarget {
            let added = plan.tracks.map(\.contentID)
            upsert.entries = change(playlist.id, formats: formats, before: entries, after: entries + added)
        }
        planned.op = .upsert(upsert)
        planned.addedLocalTracks = Dictionary(uniqueKeysWithValues: plan.tracks.map { ($0.localContentID, $0.contentID) })
        planned.audioSizeFromDatabase = UsbExportAssembly.audioSizeFromDatabase(plan)
        planned.rules = plan.requiredRules.union(staged.rules).union([.editAddTracks])
        planned.warnings += plan.warnings + staged.warnings
        record(plan, candidates: candidates)
    }

    /// 곡 더하기가 볼 USB 상태. 처음에는 USB를 훑어 만들고, 그 뒤로는 이번 묶음에서 더한 곡을 반영한다.
    /// 분석 파일 자리는 여기서 읽지 않는다(곡 경로로 폴더가 정해진 뒤 `loadAnalysisSlots`가 그 폴더만 본다)
    mutating func existingState() throws -> UsbExistingState {
        if existing == nil {
            let contents = try UsbExportAssembly.existingContents(root: root)
            existing = UsbExistingState(hasLibrary: true, usedCollisionKeys: contents?.usedCollisionKeys ?? [:],
                                        folderSpelling: contents?.folderSpelling ?? [:])
        }
        var state = existing!
        state.ids = ids
        state.artworkLayout = try artworkLayout()
        existing = state
        return state
    }

    /// 아직 읽지 않은 분석 폴더의 자리를 USB에서 읽어 계획 요청과 다음 편집이 볼 상태에 넣는다(모든 분석 파일을 열지 않게 그 폴더만).
    /// 이미 파일이 있는 폴더가 하나라도 있었으면 true(다시 계획해야 한다)
    mutating func loadAnalysisSlots(_ folders: [String], into request: inout UsbExportRequest) throws -> Bool {
        guard var state = request.existing else { return false }
        var found = false
        for folder in Set(folders) where state.analysisSlots[folder] == nil {
            let slots = try analysisSlots(folder)
            state.analysisSlots[folder] = slots
            existing?.analysisSlots[folder] = slots
            found = found || !slots.isEmpty
        }
        request.existing = state
        return found
    }

    /// 분석 폴더 하나의 (번호, PPTH): USB에 있는 `.DAT`와 DB가 그 폴더를 가리키는 곡
    func analysisSlots(_ folder: String) throws -> [(slot: Int, ppth: String)] {
        var slots: [(slot: Int, ppth: String)] = []
        let prefix = UsbLayout.collisionKey(UsbLayout.analysisRoot + "/" + folder + "/")
        for track in working.tracks {
            let path = Self.relative(track.analysisDataPath)
            guard UsbLayout.collisionKey(path).hasPrefix(prefix), let slot = Self.slot(path) else { continue }
            slots.append((slot, track.path))
        }
        let directory = root.url.appending(path: UsbLayout.analysisRoot + "/" + folder)
        guard let info = try fileSystem.stat(directory), info.kind == .directory else { return slots }
        for name in try fileSystem.list(directory) where name.uppercased().hasSuffix(".DAT") && !UsbLayout.isAppleDouble(name) {
            guard let slot = Self.slot(name) else { continue }
            let url = directory.appending(path: name)
            guard let file = try fileSystem.stat(url), file.kind == .file else { continue }
            // PPTH를 읽지 못한 파일도 자리는 차지한다(덮어쓰지 않게)
            let ppth = UsbExportAssembly.ppthReader(try fileSystem.read(url, maxBytes: Int(file.size))) ?? "\u{0}unreadable \(name)"
            slots.append((slot, ppth))
        }
        return slots
    }

    /// "…/ANLZ000A.DAT" → 10
    static func slot(_ path: String) -> Int? {
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension.uppercased()
        guard stem.count == 8, stem.hasPrefix("ANLZ") else { return nil }
        return Int(stem.dropFirst(4), radix: 16)
    }

    /// USB 아트워크 폴더별 사용량과 마지막 폴더(이름·크기만 본다). 처음 쓸 때 만든다
    mutating func artworkLayout() throws -> UsbArtworkLayout {
        if let artwork { return artwork }
        var usage: [Int: Int] = [:]
        let base = root.url.appending(path: UsbLayout.artworkRoot)
        if let info = try fileSystem.stat(base), info.kind == .directory {
            for name in try fileSystem.list(base) {
                guard name.count == 5, let number = Int(name), number > 0 else { continue }
                let folder = base.appending(path: name)
                guard let entry = try fileSystem.stat(folder), entry.kind == .directory else { continue }
                var total = 0
                for file in try fileSystem.list(folder) where !UsbLayout.isAppleDouble(file) {
                    if let stat = try fileSystem.stat(folder.appending(path: file)), stat.kind == .file { total += Int(stat.size) }
                }
                usage[number] = total
            }
        }
        let layout = UsbArtworkLayout(folderUsage: usage, currentFolder: usage.keys.max() ?? 1)
        artwork = layout
        return layout
    }

    /// 더한 곡을 다음 편집이 볼 상태에 반영한다(번호·음원 경로·분석 자리·아트워크 사용량)
    mutating func record(_ plan: UsbExportPlan, candidates: [UsbExportCandidate]) {
        guard var state = existing else { return }
        let byID = Dictionary(candidates.map { ($0.localContentID, $0) }) { first, _ in first }
        var layout = artwork ?? UsbArtworkLayout()
        for track in plan.tracks {
            ids.observe(.content, track.contentID)
            if let image = track.imageID { ids.observe(.image, image) }
            let path = Self.relative(track.contentsPath)
            let parent = (path as NSString).deletingLastPathComponent
            state.usedCollisionKeys[UsbExistingState.key(forPath: parent), default: []].insert(UsbLayout.collisionKey(track.fileName))
            var folder = ""
            for component in parent.split(separator: "/").map(String.init) {
                let key = UsbExistingState.key(forPath: folder)
                state.usedCollisionKeys[key, default: []].insert(UsbLayout.collisionKey(component))
                folder = folder.isEmpty ? component : folder + "/" + component
                if state.folderSpelling[UsbExistingState.key(forPath: folder)] == nil { state.folderSpelling[UsbExistingState.key(forPath: folder)] = folder }
            }
            state.folderSpelling[UsbExistingState.key(forPath: path)] = path
            state.analysisSlots[track.analysisFolder, default: []].append((track.analysisSlot, track.contentsPath))
            if track.imageID != nil, let source = byID[track.localContentID]?.artwork {
                _ = layout.place(bytes: 2 * (source.smallBytes + source.mediumBytes))
            }
        }
        artwork = layout
        existing = state
    }
}
