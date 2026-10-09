import DJCDomain
import Foundation

/// 목록 DB와 선택 파일을 한 쓰기 묶음으로 준비한다. 확인한 계약이 없으면 백업·USB 쓰기 전에 멈춘다.
public enum UsbSyncSelectionStage {
    public static var productionBlock: UsbBlock? {
        UsbSyncXMLWriteContract.production == nil ? unverifiedBlock : nil
    }

    /// 생산 쓰기의 관문. 선택 파일은 USB에 있는 형식마다 하나씩이다. 모두 있으면 고쳐 쓰고, 모두 없으면 새로 만든다
    /// (2026-10-08 빈 USB 실험: rekordbox도 첫 SYNC에서 두 형식의 파일을 함께 만들었다). 두 형식 중 한쪽만 있으면
    /// 어느 쪽이 맞는지 모르므로 막는다.
    /// - baseFiles: 선택 창을 열 때 읽은 두 선택 파일(없는 형식은 키가 없다)
    /// - formats: USB에 있는(내보내기는 만들) 형식
    public static func gateBlock(baseFiles: [UsbFormat: Data], formats: Set<UsbFormat>) -> UsbBlock? {
        if let productionBlock { return productionBlock }
        let present = formats.filter { baseFiles[$0] != nil }
        return present.isEmpty || present == formats ? nil : partialFilesBlock
    }

    /// 선택 파일이 없는 USB에서 동기화를 끄기만 하는 초안. rekordbox도 이때는 파일을 만들지 않는다.
    public static func writesNothing(_ draft: UsbSyncSelectionDraft, formats: Set<UsbFormat>) -> Bool {
        draft.enabledOnly && !draft.enabled && formats.allSatisfy { draft.baseFiles[$0] == nil }
    }

    public static func isSelectionPath(_ path: String) -> Bool {
        UsbFormat.allCases.contains { UsbLayout.collisionKey(UsbSyncSelectionFile.relativePath(for: $0)) == UsbLayout.collisionKey(path) }
    }

    static var unverifiedBlock: UsbBlock {
        UsbBlock(code: "syncWriteUnverified", scope: .volume,
                 message: String(ui: "rekordbox의 동기화 선택 파일 갱신 규칙을 아직 확인하지 못했습니다. rekordbox에서 선택을 바꿔 동기화한 전후 파일을 확인한 뒤 다시 시도하세요"))
    }

    static var partialFilesBlock: UsbBlock {
        UsbBlock(code: "syncSelectionPartialFiles", scope: .volume,
                 message: String(ui: "이 USB에는 두 형식 중 한 형식의 동기화 선택 파일만 있습니다. rekordbox의 동기화 관리자에서 이 USB를 다시 동기화해 두 파일을 맞춘 뒤 다시 시도하세요"))
    }

    static var sourceNodeBlock: UsbBlock {
        UsbBlock(code: "syncSelectionSourceNode", scope: .volume,
                 message: String(ui: "masterPlaylists6.xml에서 동기화할 목록을 찾지 못했습니다. rekordbox를 한 번 켰다가 종료하고 새 스냅샷을 읽은 뒤 동기화하세요"))
    }

    static var incompleteBlock: UsbBlock {
        UsbBlock(code: "syncSelectionIncomplete", scope: .volume,
                 message: String(ui: "동기화할 목록이나 곡을 모두 쓸 수 없어 동기화 선택도 갱신하지 않았습니다. 막힌 항목의 이유를 해결한 뒤 다시 시도하세요"))
    }

    /// rekordbox가 SYNC 없이 다시 쓴 선택 파일(끝에 뿌리 행이 덧붙음)에서 켜짐만 바꾸려 할 때
    static var pendingRekordboxSyncBlock: UsbBlock {
        UsbBlock(code: "syncSelectionPendingRekordboxSync", scope: .volume,
                 message: String(ui: "rekordbox가 동기화 없이 고쳐 쓴 USB 동기화 선택이라 켜짐만 바꿀 수 없습니다. rekordbox에서 이 USB를 한 번 동기화한 뒤 다시 시도하세요"))
    }

    /// 쓰기 전에 초안만 보고 아는 막힘. 켜짐만 바꾸는 초안의 원문이 rekordbox가 SYNC 없이 다시 쓴 모양이면 막는다.
    public static func draftBlock(_ draft: UsbSyncSelectionDraft) -> UsbBlock? {
        guard draft.enabledOnly else { return nil }
        let pending = draft.baseFiles.values.contains { (try? UsbSyncSelectionFile.parse($0))?.isCanonicalWithTrailingDuplicateRoots == true }
        return pending ? pendingRekordboxSyncBlock : nil
    }

    static var changedBlock: UsbBlock {
        UsbBlock(code: "syncSelectionChanged", scope: .volume,
                 message: String(ui: "USB의 동기화 선택이 그 사이 바뀌었습니다. USB를 다시 읽은 뒤 동기화하세요"))
    }

    static func precheckBlocks(_ changes: UsbChangeSet, root: UsbRoot, stagingRoot: UsbRoot,
                               fileSystem: any UsbFileSystem) throws -> [UsbBlock] {
        let syncWrites = changes.writes.filter { isSelectionPath($0.destination) || $0.afterDatabases == true }
        let syncCopies = changes.copies.filter { isSelectionPath($0.destination) }
        let syncRemovals = changes.removals.filter { isSelectionPath($0.path) }
        guard changes.syncSelection != nil || !syncWrites.isEmpty || !syncCopies.isEmpty || !syncRemovals.isEmpty else { return [] }
        guard let production = UsbSyncXMLWriteContract.production else { return [unverifiedBlock] }
        guard let expected = changes.syncSelection, expected.contract == production, syncCopies.isEmpty, syncRemovals.isEmpty,
              expected.formats == changes.formats,
              Set(syncWrites.map(\.destination)) == Set(expected.formats.map(UsbSyncSelectionFile.relativePath(for:))),
              syncWrites.allSatisfy({ $0.afterDatabases == true && $0.disposition != .reuse }),
              !expected.formats.isEmpty else { return [incompleteBlock] }
        if let block = gateBlock(baseFiles: expected.draft.baseFiles, formats: expected.formats) ?? draftBlock(expected.draft) {
            return [block]
        }
        if try !matchesBase(expected.draft, formats: expected.formats, root: root, fileSystem: fileSystem) { return [changedBlock] }
        for format in expected.formats {
            let path = UsbSyncSelectionFile.relativePath(for: format)
            guard let write = syncWrites.first(where: { $0.destination == path }),
                  write.disposition == (expected.draft.baseFiles[format] == nil ? .create : .overwrite),
                  write.expectedExistingSHA256 == expected.draft.baseFiles[format].map(UsbExportAssembly.sha256),
                  changes.target.mustExist[path] == UsbTreeStamp(size: write.size, sha256: write.sha256) else { return [incompleteBlock] }
            do {
                let bytes = try readStagedSelection(write, stagingRoot: stagingRoot, fileSystem: fileSystem)
                try UsbSyncSelectionXML.verify(data: bytes, draft: expected.draft, format: format,
                                               playlistIDs: expected.playlistIDs[format] ?? [:], contract: production)
            } catch { return [incompleteBlock] }
        }
        return []
    }

    /// 준비 파일도 신뢰한 Mac 준비 루트 아래에서 성분별로 연다. 루트 위의 Mac 경로는 호출자가 정한다.
    static func readStagedSelection(_ write: UsbFileWrite, stagingRoot: UsbRoot,
                                    fileSystem fs: any UsbFileSystem) throws -> Data {
        let prefix = stagingRoot.url.path + "/"
        guard isSelectionPath(write.destination), write.staged.hasPrefix(prefix),
              write.size > 0, write.size <= 16 << 20 else { throw UsbSyncSelectionFile.ParseError.unsafePath }
        let relative = String(write.staged.dropFirst(prefix.count))
        // 세션의 준비 폴더(준비 루트/세션/PIONEER/…)도 받는다. 세션 아래 경로는 USB 쪽 경로와 같아야 한다.
        let parts = relative.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let tail = UsbWriter.isSafeRelativePath(relative) ? relative
            : parts.count == 2 && UsbWriter.isSafeSession(parts[0]) ? parts[1] : nil
        guard let tail, UsbWriter.isSafeRelativePath(tail), UsbLayout.collisionKey(tail) == UsbLayout.collisionKey(write.destination),
              let file = try fs.readFile(root: stagingRoot, relativePath: relative, maxBytes: 16 << 20),
              file.stat.kind == .file, file.stat.size == write.size, Int64(file.data.count) == write.size,
              UsbExportAssembly.sha256(file.data) == write.sha256 else {
            throw UsbSyncSelectionFile.ParseError.changedDuringRead
        }
        return file.data
    }

    /// 선택을 읽은 원문과 파일 존재 여부까지 같아야 한다. 시각·정체·읽기 중 변경은 안전 읽기 입구가 확인한다.
    static func matchesBase(_ draft: UsbSyncSelectionDraft, formats: Set<UsbFormat>, root: UsbRoot,
                            fileSystem fs: any UsbFileSystem) throws -> Bool {
        for format in formats {
            let bytes = try UsbSyncSelectionBundle.readFile(root: root, format: format, fileSystem: fs)
            guard bytes == draft.baseFiles[format] else { return false }
        }
        return true
    }

    /// 생성 편집이 실제 적용된 뒤의 번호만 resolve한다. 부모 폴더도 선택 트리와 같은 계층이어야 한다.
    /// 해제한 목록은 파일에 행이 없으므로 체크·부분 체크로 쓸 원본만 돌려준다. 형식마다 그 형식 DB의 번호(Dev_ID)를 돌려준다.
    /// 초안의 참조는 합친 모델의 대표 번호다(두 형식 번호가 다를 수 있다, #233).
    static func resolve(_ draft: UsbSyncSelectionDraft, model: UsbLibrary, formats: Set<UsbFormat>, createdIDs: [String: Int],
                        allocatedIDs: [String: Int] = [:]) throws -> [UsbFormat: [String: Int]] {
        try resolveWithRepresentatives(draft, model: model, formats: formats, createdIDs: createdIDs, allocatedIDs: allocatedIDs).formatIDs
    }

    /// `resolve`와 같고, 원본 → 합친 모델의 대표 번호도 돌려준다
    static func resolveWithRepresentatives(_ draft: UsbSyncSelectionDraft, model: UsbLibrary, formats: Set<UsbFormat>,
                                           createdIDs: [String: Int], allocatedIDs: [String: Int] = [:])
        throws -> (formatIDs: [UsbFormat: [String: Int]], representatives: [String: Int]) {
        guard !draft.enabledOnly else { return (Dictionary(uniqueKeysWithValues: formats.map { ($0, [:]) }), [:]) }
        let groups = [UsbSyncSourceNode.rekordboxSelectionID, UsbSyncSourceNode.iTunesSelectionID]
        let nodes = draft.sourceNodes.filter { !groups.contains($0.id) }
        guard Set(nodes.map(\.id)).count == nodes.count else { throw UsbError.writeRefused([incompleteBlock]) }
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let selectionNodes = groups.map { ITunesSyncSelection.Node(id: $0, parentID: "0", isFolder: true) } + nodes.map { node in
            let group = node.id.hasPrefix("itunes:") ? groups[1] : groups[0]
            let parent = node.parentID.flatMap { $0 == "0" ? nil : $0 } ?? group
            return ITunesSyncSelection.Node(id: node.id, parentID: parent, isFolder: node.isFolder)
        }
        let expanded = draft.selection.expandedIDs(in: selectionNodes)
        var required = expanded.intersection(byID.keys)
        var pending = Array(required)
        while let id = pending.popLast() {
            guard let parent = byID[id]?.parentID, byID[parent] != nil else { continue }
            if required.insert(parent).inserted { pending.append(parent) }
        }
        var merged: [String: Int] = allocatedIDs
        for (id, ref) in draft.playlistRefs {
            switch ref {
            case .root: break
            case let .id(value): merged[id] = Int(value)
            case let .new(key): merged[id] = createdIDs[key]
            }
        }
        var result: [UsbFormat: [String: Int]] = [:], representatives: [String: Int] = [:]
        for format in formats {
            let playlists = Dictionary(model.playlists.filter { $0.presentIn.contains(format) }.map { ($0.id, $0) },
                                       uniquingKeysWith: { first, _ in first })
            var ids: [String: Int] = [:]
            for id in required {
                guard let usbID = merged[id], let playlist = playlists[usbID], (playlist.attribute == 1) == byID[id]?.isFolder else {
                    throw UsbError.writeRefused([incompleteBlock])
                }
                let parent = byID[id]?.parentID.flatMap { merged[$0] } ?? 0
                guard playlist.parentID == parent else { throw UsbError.writeRefused([incompleteBlock]) }
                ids[id] = playlist.id(in: format)
                representatives[id] = usbID
            }
            guard Set(ids.values).count == ids.count, ids.values.allSatisfy({ $0 > 0 }) else { throw UsbError.writeRefused([incompleteBlock]) }
            result[format] = ids
        }
        return (result, representatives)
    }

    /// contract는 내부 인자다. 생산 호출은 production만 쓰고 합성 시험만 내부 준비 함수를 직접 부른다.
    static func stage(_ draft: UsbSyncSelectionDraft, formats: Set<UsbFormat>, model: UsbLibrary, createdIDs: [String: Int],
                      allocatedIDs: [String: Int] = [:], root: UsbRoot?, fileSystem: any UsbFileSystem,
                      into context: inout UsbExportAssembly.Context,
                      contract: UsbSyncXMLWriteContract) throws -> UsbSyncSelectionVerification {
        guard !formats.isEmpty else { throw UsbError.writeRefused([incompleteBlock]) }
        if let root, try !matchesBase(draft, formats: formats, root: root, fileSystem: fileSystem) {
            throw UsbError.writeRefused([changedBlock])
        }
        let (ids, representatives) = try resolveWithRepresentatives(draft, model: model, formats: formats, createdIDs: createdIDs,
                                                                    allocatedIDs: allocatedIDs)
        // 쓴 뒤 검증·회복은 모델에서 찾은 번호만 본다. 같은 묶음의 새 목록 key는 최종 번호(대표 번호)로 바꿔 둔다.
        let resolvedDraft = UsbSyncSelectionDraft(localDBID: draft.localDBID, sourceNodes: draft.sourceNodes, selection: draft.selection,
                                                 enabled: draft.enabled, playlistRefs: representatives.mapValues { .id(String($0)) },
                                                 baseFiles: draft.baseFiles, enabledOnly: draft.enabledOnly)
        var rendered: [(UsbFormat, Data)] = []
        for format in UsbFormat.allCases where formats.contains(format) {
            let bytes: Data
            do {
                bytes = try UsbSyncSelectionXML.render(draft: resolvedDraft, format: format, playlistIDs: ids[format] ?? [:], contract: contract)
                try UsbSyncSelectionXML.verify(data: bytes, draft: resolvedDraft, format: format, playlistIDs: ids[format] ?? [:], contract: contract)
            } catch UsbSyncSelectionXML.RenderError.missingSourceNode {
                throw UsbError.writeRefused([sourceNodeBlock])
            } catch UsbSyncSelectionXML.RenderError.pendingRekordboxSync {
                throw UsbError.writeRefused([pendingRekordboxSyncBlock])
            } catch {
                throw UsbError.writeRefused([incompleteBlock])
            }
            rendered.append((format, bytes))
        }
        // 두 형식이 모두 렌더되는 것을 먼저 확인하고 준비 파일을 만든다.
        for (format, bytes) in rendered {
            let path = UsbSyncSelectionFile.relativePath(for: format)
            let existing = draft.baseFiles[format].map { (sha256: UsbExportAssembly.sha256($0), ppth: Optional<String>.none) }
            try context.stage(bytes, at: path, modified: nil, replacing: existing)
            context.writes[context.writes.count - 1].afterDatabases = true
        }
        return UsbSyncSelectionVerification(draft: resolvedDraft, formats: formats, playlistIDs: ids, contract: contract)
    }
}

/// 기본 쓰기 절차도 XML의 선택·Dev_ID·원본 ID를 다시 읽어 본다(호출자가 검증기를 빠뜨려도 같다).
struct UsbSyncSelectionVerifier: UsbWriteVerifier {
    func verify(root: UsbRoot, changes: UsbChangeSet, fileSystem: any UsbFileSystem, scratch: URL) throws -> [String] {
        guard let expected = changes.syncSelection else { return [] }
        var problems: [String] = []
        for format in UsbFormat.allCases where expected.formats.contains(format) {
            let path = UsbSyncSelectionFile.relativePath(for: format)
            do {
                guard let bytes = try UsbSyncSelectionBundle.readFile(root: root, format: format, fileSystem: fileSystem) else {
                    throw UsbSyncSelectionFile.ParseError.changedDuringRead
                }
                try UsbSyncSelectionXML.verify(data: bytes, draft: expected.draft, format: format,
                                               playlistIDs: expected.playlistIDs[format] ?? [:], contract: expected.contract)
            } catch {
                // 원문·ID 값은 오류 문자열로 내보내지 않는다.
                problems.append("sync selection semantics: \(path)")
            }
        }
        // USB 위에서 DB를 열지 않고 Mac 사본으로 실제 목록 계층·종류·Dev_ID를 한 번 더 본다.
        do {
            let snapshot = try UsbSnapshot.take(root: root, into: scratch.appending(path: "sync-selection-model"))
            let source = try UsbEditEngine.read(snapshot)
            guard source.blocks.isEmpty, source.formatsBlocked.isEmpty, expected.formats.isSubset(of: source.formats) else {
                return problems + ["sync selection model format"]
            }
            // 초안 참조는 대표 번호다. 다시 읽은 모델에서 형식마다 같은 Dev_ID로 풀리는지 본다(#233: 두 형식 번호가 다를 수 있다)
            for format in expected.formats {
                let actual = try UsbSyncSelectionStage.resolve(expected.draft, model: source.current, formats: [format], createdIDs: [:])
                if actual[format] != expected.playlistIDs[format] { problems.append("sync selection model references") }
            }
        } catch {
            problems.append("sync selection model")
        }
        return problems
    }
}
