import DJCDomain
import Foundation

extension UsbEditEngine {
    /// 편집을 계획하고 준비 폴더(`staging`, 없거나 빈 폴더)에 파일·DB를 만든다.
    /// - localDatabase: 로컬 스냅샷 사본을 연 연결(곡 더하기·갱신·음원 지우기 확인에 쓴다. 없으면 그 편집만 막는다)
    /// - existingFiles: USB 루트(파일 이름·크기·해시·분석 파일 PPTH를 읽기만 한다)
    /// - highWater: 지난 쓰기 저널의 ID highWater(지운 ID를 다시 쓰지 않게)
    /// - snapshotTakenAt: 로컬 사본을 뜬 시각(`UsbSnapshotTime`). 이 뒤에 바뀐 분석 파일은 그 곡만 막는다
    /// - localAppVersion: 이 Mac의 rekordbox 버전(확인한 버전이 아니면 곡 더하기·갱신을 막는다)
    public static func plan(source: UsbEditSource, edits: [UsbLibraryEdit], localDatabase: CipherDatabase?, share: URL?,
                            volume: UsbVolumeInfo, existingFiles root: UsbRoot, fileSystem: any UsbFileSystem = PosixUsbFileSystem(),
                            staging: URL, session: String, highWater: [String: Int] = [:], snapshotTakenAt: Date? = nil,
                            localAppVersion: String? = nil, progress: (Int, Int) -> Void = { _, _ in },
                            isCancelled: () -> Bool = { false }) throws -> UsbEditResult {
        var result = UsbEditResult(formatsBlocked: source.formatsBlocked, mismatches: source.mismatches, notes: source.notes)
        var whole = source.blocks + UsbVolumePolicy.blocks(volume, purpose: .edit)
        let selections = edits.enumerated().compactMap { offset, edit -> (index: Int, draft: UsbSyncSelectionDraft)? in
            if case let .syncSelection(draft) = edit { (offset + 1, draft) } else { nil }
        }
        if let selection = selections.first {
            if let block = UsbSyncSelectionStage.gateBlock(baseFiles: selection.draft.baseFiles, formats: source.formats)
                ?? UsbSyncSelectionStage.draftBlock(selection.draft) { whole.append(block) }
            if selections.count != 1 || !source.formatsBlocked.isEmpty { whole.append(UsbSyncSelectionStage.incompleteBlock) }
        }
        if whole.isEmpty, source.writable.isEmpty {
            // 고칠 수 있는 형식이 하나도 없다(예: Device Library만 있는 USB가 막힘)
            whole = UsbFormat.allCases.compactMap { source.formatsBlocked[$0] }
        }
        guard whole.isEmpty, let snapshot = source.snapshot else {
            result.blocks = unique(whole.isEmpty ? [corruptBlock] : whole)
            result.outcomes = edits.indices.map { ($0 + 1, .blocked(result.blocks[0])) }
            return result
        }
        let writable = source.writable
        if let selection = selections.first {
            guard let localDatabase, try UsbLocalSource(database: localDatabase).localDBID() == selection.draft.localDBID else {
                let block = UsbBlock(code: "syncSelectionLibraryChanged", scope: .volume,
                                     message: String(ui: "동기화 선택을 만든 로컬 라이브러리와 현재 사본이 다릅니다. 새 스냅샷을 읽고 동기화하세요"))
                result.blocks = [block]
                result.outcomes = edits.indices.map { ($0 + 1, .blocked(block)) }
                return result
            }
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: staging.path), (try? fm.contentsOfDirectory(atPath: staging.path))?.isEmpty != true {
            throw UsbError.readFailed(detail: "staging not empty")
        }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        // 1. 편집마다 계획(앞 편집을 적용한 모델 위에서)
        var planner = UsbEditPlanner(source: source, root: root, fileSystem: fileSystem, staging: staging, localDatabase: localDatabase,
                                     share: share, snapshotTakenAt: snapshotTakenAt, localAppVersion: localAppVersion,
                                     clusterSize: volume.clusterSize ?? 32_768, highWater: highWater)
        planner.skipsUnaddableTracks = selections.contains { !$0.draft.enabledOnly }
        var planned: [UsbPlannedEdit] = []
        for (offset, edit) in edits.enumerated() {
            if isCancelled() { throw UsbError.cancelled }
            planned.append(try planner.plan(edit, index: offset + 1, progress: { _, _ in }, isCancelled: isCancelled))
            progress(offset + 1, edits.count)
        }

        // 2. 모델 적용: OneLibrary는 USB DB 사본에 편집마다 한 단계(실패한 편집은 그 단계만 되돌린다)
        let steps = planned.compactMap { edit in
            edit.op.map { op in OneLibraryEditStep(id: edit.index) { try UsbEditModel.apply(op, to: $0, writable: writable) } }
        }
        var context = UsbExportAssembly.Context(staging: staging)
        var applied = source.current, skipped: [Int: String] = [:]
        var oneLibraryChanged = false
        if !steps.isEmpty {
            if writable.contains(.oneLibrary), let copy = snapshot.oneLibrary {
                let folder = try context.prepare(UsbLayout.oneLibrary).deletingLastPathComponent()
                let url = try UsbSnapshot.copyDatabase(copy, into: folder)
                // 계획은 Mac의 USB DB 사본에 적용한다. 다시 읽기가 어긋나면 USB는 열지도 않았으니 "되돌렸다"가 아니라 계획 확인 실패로 알린다
                let applyResult: OneLibraryApplyResult
                do {
                    applyResult = try OneLibraryWriter.apply(from: source.current, steps: steps, database: url)
                } catch let UsbError.writeRolledBack(reason) {
                    throw UsbError.planCheckFailed(detail: "onelibrary " + reason)
                }
                (applied, skipped) = (applyResult.applied, applyResult.skipped)
                let before = source.current.projected(to: .oneLibrary), after = applied.projected(to: .oneLibrary)
                // 철자(NFC·NFD)만 바꾼 목록 이름도 바뀐 것이다(Swift 문자열 ==는 같다고 본다, #233)
                oneLibraryChanged = after != before || UsbEditModel.playlistNamesRespelled(before, after)
                if oneLibraryChanged {
                    try context.database(.oneLibrary, UsbLayout.oneLibrary, data: Data(contentsOf: url))
                } else {
                    try? fm.removeItem(at: url)
                }
            } else {
                (applied, skipped) = applyWithoutOneLibrary(source.current, steps: steps)
            }
        }

        // 3. 결과: 건너뛴 편집은 막힘, 나머지는 파일·규칙을 모은다
        var rules: Set<UsbProvisionalRule> = []
        var writtenRemovals: [Int] = []
        for index in planned.indices {
            let edit = planned[index]
            if edit.op != nil, let reason = skipped[edit.index] {
                planned[index].outcome = .blocked(UsbEditPlanner.applyFailed(reason))
                continue
            }
            result.trackBlocks += edit.trackBlocks
            result.notes += edit.notes
            guard edit.op != nil, edit.outcome == .written else { continue }
            rules.formUnion(edit.rules)
            result.warnings += edit.warnings
            result.audioSizeFromDatabase.formUnion(edit.audioSizeFromDatabase)
            context.copies += edit.files.copies
            context.writes += edit.files.writes
            context.target.merge(edit.files.target) { _, new in new }
            if edit.isRemoval { writtenRemovals.append(index) }
        }

        // 동기화 계획이 USB에 넣지 않고 건너뛴 곡(iTunes 목록의 연결되지 않은 곡 등)도 넣지 못한 곡으로 함께 알린다
        if let selection = selections.first {
            result.trackBlocks += selection.draft.skippedTracks.filter(\.isSkippableInSync)
        }

        // 4. Device Library: 적용 결과 모델에서 새로 만든다(두 형식이 같은 편집 집합을 갖게).
        // USB의 pdb에 NFC가 아닌 이름·제목이 있으면 모델이 같아도 다시 만들어 NFC로 고친다(#233, 쓰는 편집이 있을 때만 USB에 간다)
        if writable.contains(.deviceLibrary), let report = source.pdbReport,
           applied.projected(to: .deviceLibrary) != source.current.projected(to: .deviceLibrary) || source.deviceLibraryNeedsNFC {
            let pdb = try PdbWriter.files(applied, mode: .edit(previousExportSequence: report.exportHeader.sequence,
                                                               previousExtSequence: report.extHeader?.sequence ?? 0))
            let problems = try PdbRoundTrip.check(export: pdb.export, exportExt: pdb.exportExt)
            guard problems.isEmpty else { throw UsbError.writeRefused([roundTripBlock(problems[0])]) }
            let reread = try PdbReader.read(export: pdb.export, exportExt: pdb.exportExt).0
            let differences = UsbLibraryDiff.compare(reread, pdb.written, options: .init(formats: [.deviceLibrary])).differences
            guard differences.isEmpty else { throw UsbError.planCheckFailed(detail: "pdb reread: " + OneLibraryWriter.summary(differences)) }
            try context.database(.deviceLibrary, UsbLayout.exportPdb, data: pdb.export, write: true)
            try context.database(.deviceLibrary, UsbLayout.exportExtPdb, data: pdb.exportExt, write: true)
            rules.formUnion(pdb.rules)
            rules.insert(.pdbRegeneratedEdit)
            result.pdbWritten = pdb.written
            result.formatsWritten.insert(.deviceLibrary)
        }
        if oneLibraryChanged { result.formatsWritten.insert(.oneLibrary) }

        // 5. 지울 파일: 편집 전 참조 − 편집 뒤 참조(두 형식 합집합). 한 형식이 막혀 있으면 모두 미룬다
        let removal = try planRemovals(before: source.current, after: applied, root: root, fileSystem: fileSystem, localDatabase: localDatabase)
        var removals: [UsbFileRemoval] = []
        if !source.formatsBlocked.isEmpty, !removal.removals.isEmpty || !writtenRemovals.isEmpty {
            // 막힌 형식은 뺀 곡을 아직 가리키므로 그 곡의 파일은 남는다(곡 빼기는 그 형식을 고칠 수 있을 때 파일까지 마친다)
            let reason = String(ui: "고칠 수 없는 형식이 있어 파일 지우기를 미뤘습니다")
            result.notes.append(reason)
            for index in writtenRemovals { planned[index].outcome = .deferred(reason) }
        } else {
            removals = removal.removals
            result.notes += removal.notes
        }
        if !removals.isEmpty { rules.insert(.trackRemovalFiles) }

        result.outcomes = planned.map { ($0.index, $0.outcome) }
        result.applied = applied
        let appliedPlaylistIDs = Set(applied.playlists.map(\.id))
        result.createdPlaylistIDs = planner.newPlaylists.filter { appliedPlaylistIDs.contains($0.value) }
        var syncVerification: UsbSyncSelectionVerification?
        // 선택 파일이 없는 USB에서 동기화를 끄기만 하면 쓸 것이 없다(바뀐 것 없음으로 남는다).
        if let selection = selections.first, !UsbSyncSelectionStage.writesNothing(selection.draft, formats: writable) {
            // 넣지 못한 곡만 빼고 쓴 것은 완료다(rekordbox와 같다). 편집이 막혔거나 곡이 스냅샷에 없으면 선택을 갱신하지 않는다
            let incomplete = result.trackBlocks.contains { !$0.isSkippableInSync }
                || planned.contains { if case .blocked = $0.outcome { true } else { false } }
            if incomplete {
                result.blocks = [UsbSyncSelectionStage.incompleteBlock]
                result.outcomes = edits.indices.map { ($0 + 1, .blocked(UsbSyncSelectionStage.incompleteBlock)) }
                result.applied = source.current
                result.createdPlaylistIDs = [:]
                result.formatsWritten = []
                return result
            }
            guard let contract = UsbSyncXMLWriteContract.production else {
                result.blocks = [UsbSyncSelectionStage.unverifiedBlock]
                return result
            }
            do {
                syncVerification = try UsbSyncSelectionStage.stage(selection.draft, formats: writable, model: applied,
                                                                  createdIDs: result.createdPlaylistIDs, root: root, fileSystem: fileSystem,
                                                                  into: &context, contract: contract)
                planned[selection.index - 1].outcome = .written
                result.outcomes = planned.map { ($0.index, $0.outcome) }
                result.formatsWritten.formUnion(writable)
                // 선택만 바꾸는 쓰기도 최종 USB DB가 계획 때 모델인지를 검증한다.
                for (path, stamp) in snapshot.fingerprint.files where UsbWriter.databaseOrder.contains(path) && context.target[path] == nil {
                    context.target[path] = UsbTreeStamp(size: stamp.size, sha256: stamp.sha256)
                }
            } catch let UsbError.writeRefused(blocks) {
                result.blocks = unique(blocks)
                result.outcomes = edits.indices.map { ($0 + 1, .blocked(result.blocks.first ?? UsbSyncSelectionStage.incompleteBlock)) }
                result.applied = source.current
                result.createdPlaylistIDs = [:]
                result.formatsWritten = []
                return result
            }
        }
        let written = planned.contains { if case .written = $0.outcome { true } else if case .deferred = $0.outcome { true } else { false } }
        guard written, !(context.databases.isEmpty && context.copies.isEmpty && context.writes.isEmpty && removals.isEmpty) else {
            // 바꾼 것이 없다(적용했지만 결과가 같음)
            result.outcomes = result.outcomes.map { entry in
                if case .written = entry.outcome { (entry.edit, .unchanged) } else { entry }
            }
            result.formatsWritten = []
            return result
        }
        var ids = planner.ids
        UsbEditPlanner.observe(applied, into: &ids)
        let highWater = Dictionary(uniqueKeysWithValues: ids.highWater.map { ($0.key.rawValue, $0.value) })
        // 지운 파일은 검증(G)이 없어졌는지 본다(쓰기가 건너뛴 지우기는 쓰기 절차가 뺀다)
        let mustNotExist = Set(removals.map(\.path)).subtracting(context.target.keys)
        result.changes = UsbChangeSet(session: session, label: "edit", purpose: .edit, formats: result.formatsWritten, requiredRules: rules,
                                      databases: context.databases, copies: context.copies, writes: context.writes, removals: removals,
                                      base: snapshot.fingerprint, target: UsbTargetFingerprint(mustExist: context.target, mustNotExist: mustNotExist),
                                      stagingDirectory: staging.path, idHighWater: highWater, syncSelection: syncVerification)
        // 편집이 건드리지 않은 곡까지 USB 전체를 보는 검증이 쓰던 USB에 이미 있던 문제로 쓰기를 되돌리지 않게
        result.preexistingProblems = try UsbInvariantVerifier.problems(snapshot: snapshot, root: root, fileSystem: fileSystem,
                                                                       checkFormatCounts: source.formatsBlocked.isEmpty)
        return result
    }

    /// OneLibrary가 없거나 막혀 쓰지 않는 USB: 같은 단계를 모델에만 적용한다(OneLibrary 작성기와 같은 다듬기)
    static func applyWithoutOneLibrary(_ current: UsbLibrary, steps: [OneLibraryEditStep]) -> (UsbLibrary, [Int: String]) {
        var accepted = current, skipped: [Int: String] = [:]
        for step in steps {
            do {
                accepted = OneLibraryWriter.normalized(try step.target(accepted), from: accepted)
            } catch {
                skipped[step.id] = String(describing: error)
            }
        }
        return (accepted, skipped)
    }

    // MARK: - 지울 파일

    public struct RemovalPlan: Sendable {
        public var removals: [UsbFileRemoval] = []
        public var notes: [String] = []
    }

    /// 파일 하나가 참조되는 까닭
    enum FileReference {
        case audio(UsbTrack)
        case analysis(UsbTrack)
        case artwork
    }

    /// 모델이 가리키는 USB 파일(충돌 키 → 상대 경로·까닭): 음원, 분석 파일 셋(.DAT와 형제 .EXT·.2EX), 아트워크(그림과 _m)
    static func references(_ model: UsbLibrary) -> [(key: String, path: String, reference: FileReference)] {
        var result: [(key: String, path: String, reference: FileReference)] = []
        var seen: Set<String> = []
        func add(_ path: String, _ reference: FileReference) {
            let relative = UsbLayout.nfc(UsbEditPlanner.relative(path))
            guard !relative.isEmpty, seen.insert(UsbLayout.collisionKey(relative)).inserted else { return }
            result.append((UsbLayout.collisionKey(relative), relative, reference))
        }
        for track in model.tracks.sorted(by: { $0.id < $1.id }) {
            add(track.path, .audio(track))
            let dat = track.analysisDataPath
            guard dat.uppercased().hasSuffix(".DAT") else { continue }
            let base = String(dat.dropLast(4))
            for ext in [".DAT", ".EXT", ".2EX"] { add(base + ext, .analysis(track)) }
        }
        for image in model.images.sorted(by: { $0.id < $1.id }) {
            for path in [image.oneLibraryPath, image.pdbPath].compactMap({ $0 }) {
                add(path, .artwork)
                add(UsbEditPlanner.mediumArtworkPath(path), .artwork)
            }
        }
        return result
    }

    /// 편집 전에는 참조됐고 편집 뒤에는 아무도(어느 형식도) 참조하지 않는 파일. USB 실파일의 크기·SHA-256을 계획에 적고,
    /// 분석 파일은 그 곡의 것일 때만(PPTH), 음원은 로컬 원본이 같을 때만(크기·SHA-1) 넣는다. 나머지는 남기고 알린다
    public static func planRemovals(before: UsbLibrary, after: UsbLibrary, root: UsbRoot, fileSystem: any UsbFileSystem,
                             localDatabase: CipherDatabase?) throws -> RemovalPlan {
        let kept = Set(references(after).map(\.key))
        var plan = RemovalPlan()
        var checkedAnalysis: [Int: Bool] = [:]
        for (key, path, reference) in references(before) where !kept.contains(key) {
            let url = root.url.appending(path: path)
            guard UsbWriter.isSafeRelativePath(path), let info = try fileSystem.stat(url), info.kind == .file else { continue }
            guard try UsbRemovalPolicy.allows(path, root: root, fileSystem: fileSystem) else {
                plan.notes.append(String(ui: "지워도 되는 파일이 아니라 지우지 않았습니다: \(path)"))
                continue
            }
            switch reference {
            case .artwork:
                guard UsbEditPlanner.isArtworkFile(path) else {
                    plan.notes.append(String(ui: "지워도 되는 파일이 아니라 지우지 않았습니다: \(path)"))
                    continue
                }
                plan.removals.append(UsbFileRemoval(path: path, expectedSHA256: try fileSystem.sha256(url, uncached: true), expectedSize: info.size,
                                                    expectedPPTH: nil, localOriginal: nil, localOriginalSHA1: nil))
            case let .analysis(track):
                // 같은 곡의 셋은 함께 판정한다: 셋 중 하나라도 다른 곡 것이면(번호가 엉킨 USB) 셋 모두 남긴다
                if checkedAnalysis[track.id] == nil {
                    checkedAnalysis[track.id] = try analysisBelongs(track, root: root, fileSystem: fileSystem)
                    if checkedAnalysis[track.id] == false {
                        plan.notes.append(String(ui: "분석 파일이 다른 곡 것이라 지우지 않았습니다: \(UsbEditPlanner.relative(track.analysisDataPath))"))
                    }
                }
                guard checkedAnalysis[track.id] == true else { continue }
                plan.removals.append(UsbFileRemoval(path: path, expectedSHA256: try fileSystem.sha256(url, uncached: true), expectedSize: info.size,
                                                    expectedPPTH: track.path, localOriginal: nil, localOriginalSHA1: nil))
            case let .audio(track):
                // 로컬 원본이 있고 같은 내용일 때만 지운다(되돌릴 때 원본에서 다시 복사한다)
                guard let localDatabase, let localID = try UsbEditPlanner.localMatch(track, database: localDatabase),
                      let row = try? UsbLocalSource(database: localDatabase).track(localID), let source = row.folderPath,
                      let local = try? UsbExportAssembly.fileHashes(source, content: localID),
                      let usb = try? UsbExportAssembly.fileHashes(url.path, content: "usb:\(track.id)"),
                      local.size == usb.size, local.sha1 == usb.sha1 else {
                    plan.notes.append(String(ui: "로컬 원본과 같은지 확인하지 못해 음원을 USB에 남겼습니다: \(path)"))
                    continue
                }
                plan.removals.append(UsbFileRemoval(path: path, expectedSHA256: usb.sha256, expectedSize: usb.size, expectedPPTH: nil,
                                                    localOriginal: source, localOriginalSHA1: local.sha1))
            }
        }
        return plan
    }

    /// 곡의 분석 파일 셋(있는 것)의 PPTH가 모두 그 곡 경로인지
    static func analysisBelongs(_ track: UsbTrack, root: UsbRoot, fileSystem: any UsbFileSystem) throws -> Bool {
        let base = String(UsbEditPlanner.relative(track.analysisDataPath).dropLast(4))
        for ext in [".DAT", ".EXT", ".2EX"] {
            let url = root.url.appending(path: base + ext)
            guard let info = try fileSystem.stat(url), info.kind == .file else { continue }
            let ppth = UsbExportAssembly.ppthReader(try fileSystem.read(url, maxBytes: Int(info.size)))
            if ppth.map(UsbLayout.nfc) != UsbLayout.nfc(track.path) { return false }
        }
        return true
    }
}
