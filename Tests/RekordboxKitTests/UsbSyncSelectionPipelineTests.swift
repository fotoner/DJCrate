import DJCDomain
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// 동기화 선택은 일부 목록만 쓴 결과를 완전한 동기화로 기록하지 않는다. 모든 USB·DB는 합성 임시 폴더다.
@Suite("USB 동기화 선택 쓰기 묶음")
struct UsbSyncSelectionPipelineTests {
    static let formats = Set(UsbFormat.allCases)
    static let contract = UsbSyncSelectionXMLTests.contract

    func model() -> UsbLibrary {
        var library = UsbLibrary.empty
        library.playlists = [
            UsbPlaylist(id: 11, name: "합성 폴더", parentID: 0, attribute: 1, imageID: nil, presentIn: Self.formats,
                        sortOrder: [.deviceLibrary: 0, .oneLibrary: 0], entries: [:]),
            UsbPlaylist(id: 12, name: "합성 목록", parentID: 11, attribute: 0, imageID: nil, presentIn: Self.formats,
                        sortOrder: [.deviceLibrary: 0, .oneLibrary: 0], entries: [.deviceLibrary: [], .oneLibrary: []]),
        ]
        return library
    }

    func draft(baseFiles: [UsbFormat: Data] = [:], selected: Set<String> = ["itunes:A"]) -> UsbSyncSelectionDraft {
        .init(localDBID: 42, sourceNodes: [.init(id: "itunes:F", parentID: nil, isFolder: true, timestamp: 0),
                                          .init(id: "itunes:A", parentID: "itunes:F", isFolder: false, timestamp: 0)],
              selection: .init(selectedIDs: selected), enabled: true,
              playlistRefs: ["itunes:F": .new("folder"), "itunes:A": .new("list")], baseFiles: baseFiles)
    }

    @Test("두 형식 중 한 형식의 선택 파일만 있으면 새로 만들거나 고치지 않고 앞 목록 편집까지 함께 막는다")
    func oneFormatSelectionFileStopsWholeBatch() throws {
        let env = try UsbEditEngineTests.exported()
        let base = UsbSyncSelectionFileTests.file([])
        env.usb.write(UsbSyncSelectionFile.relativePath(for: .deviceLibrary), base)
        let before = env.usb.tree()
        let draft = UsbSyncSelectionDraft(localDBID: 1, sourceNodes: [], selection: ITunesSyncSelection(), enabled: true,
                                           playlistRefs: [:], baseFiles: [.deviceLibrary: base])
        let result = try env.plan([
            .playlist(edit: .rename(playlist: .id("1"), name: "합성 새 이름")),
            .syncSelection(draft: draft),
        ])
        #expect(result.blocks.map(\.code).contains("syncSelectionPartialFiles"))
        #expect(result.changes == nil)
        #expect(result.outcomes.allSatisfy { if case .blocked = $0.outcome { true } else { false } })
        #expect(env.usb.tree() == before)
    }

    @Test("동기화 파일 두 이름만 후단 파일로 허용한다")
    func onlyNativeSelectionPathsAllowPostCommit() throws {
        #expect(UsbSyncSelectionStage.isSelectionPath("PIONEER/rekordbox/playlists3.sync"))
        #expect(UsbSyncSelectionStage.isSelectionPath("PIONEER/rekordbox/playlists3Plus.sync"))
        #expect(!UsbSyncSelectionStage.isSelectionPath("PIONEER/rekordbox/other.sync"))
        #expect(!UsbSyncSelectionStage.isSelectionPath("PIONEER/CDP/playlists3.sync"))
    }

    @Test("선택 파일은 실제 적용된 새 폴더와 목록 번호만 쓴다")
    func stageUsesAppliedCreatedPlaylistIDs() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        var context = UsbExportAssembly.Context(staging: fixture.folder.appending(path: "sync-staging"))
        let expected = try UsbSyncSelectionStage.stage(draft(), formats: Self.formats, model: model(),
                                                       createdIDs: ["folder": 11, "list": 12], root: fixture.root,
                                                       fileSystem: fixture.fileSystem(), into: &context, contract: Self.contract)
        #expect(expected.playlistIDs == [.deviceLibrary: ["itunes:F": 11, "itunes:A": 12], .oneLibrary: ["itunes:F": 11, "itunes:A": 12]])
        #expect(context.writes.count == 2 && context.writes.allSatisfy { $0.afterDatabases == true })
        for write in context.writes {
            let parsed = try UsbSyncSelectionFile.parse(Data(contentsOf: URL(filePath: write.staged)))
            #expect(parsed.nodes.map(\.deviceID) == ["0", "11", "12"])
            #expect(parsed.nodes.map(\.checkType) == [2, 2, 1])
            #expect(context.target[write.destination]?.sha256 == write.sha256)
        }
    }

    @Test("#233: 두 형식 번호가 다른 목록은 형식마다 그 형식 번호를 Dev_ID로 쓰고, 초안 참조는 대표 번호로 남긴다")
    func stageWritesPerFormatDeviceIDs() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        var library = model()
        library.playlists[0].formatIDs = [.deviceLibrary: 21]
        library.playlists[1].formatIDs = [.deviceLibrary: 22]
        var context = UsbExportAssembly.Context(staging: fixture.folder.appending(path: "sync-staging"))
        let expected = try UsbSyncSelectionStage.stage(draft(), formats: Self.formats, model: library,
                                                       createdIDs: ["folder": 11, "list": 12], root: fixture.root,
                                                       fileSystem: fixture.fileSystem(), into: &context, contract: Self.contract)
        #expect(expected.playlistIDs == [.deviceLibrary: ["itunes:F": 21, "itunes:A": 22], .oneLibrary: ["itunes:F": 11, "itunes:A": 12]])
        #expect(expected.draft.playlistRefs == ["itunes:F": .id("11"), "itunes:A": .id("12")])
        for format in UsbFormat.allCases {
            let write = try #require(context.writes.first { $0.destination == UsbSyncSelectionFile.relativePath(for: format) })
            let parsed = try UsbSyncSelectionFile.parse(Data(contentsOf: URL(filePath: write.staged)))
            #expect(parsed.nodes.map(\.deviceID) == (format == .deviceLibrary ? ["0", "21", "22"] : ["0", "11", "12"]))
        }
        // 쓴 뒤 검증처럼 대표 번호 참조를 다시 풀어도 형식별 번호가 같다
        #expect(try UsbSyncSelectionStage.resolve(expected.draft, model: library, formats: Self.formats, createdIDs: [:]) == expected.playlistIDs)
    }

    @Test("선택한 목록이나 부모 생성이 건너뛰어지면 두 파일 모두 준비하지 않는다")
    func missingAppliedPlaylistStopsBothFiles() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        var context = UsbExportAssembly.Context(staging: fixture.folder.appending(path: "sync-staging"))
        #expect(throws: (any Error).self) {
            try UsbSyncSelectionStage.stage(draft(), formats: Self.formats, model: model(), createdIDs: ["list": 12],
                                            root: fixture.root, fileSystem: fixture.fileSystem(), into: &context,
                                            contract: Self.contract)
        }
        #expect(context.writes.isEmpty)
    }

    @Test("새 내보내기는 원본 ID에 배정된 최종 목록 번호로 선택 파일을 만든다")
    func newExportUsesAllocatedPlaylistIDs() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let base = draft()
        let newDraft = UsbSyncSelectionDraft(localDBID: base.localDBID, sourceNodes: base.sourceNodes, selection: base.selection,
                                             enabled: true, playlistRefs: [:], baseFiles: [:])
        var context = UsbExportAssembly.Context(staging: fixture.folder.appending(path: "sync-staging"))
        let expected = try UsbSyncSelectionStage.stage(newDraft, formats: Self.formats, model: model(), createdIDs: [:],
                                                       allocatedIDs: ["itunes:F": 11, "itunes:A": 12], root: nil,
                                                       fileSystem: fixture.fileSystem(), into: &context, contract: Self.contract)
        #expect(expected.playlistIDs[.oneLibrary] == ["itunes:F": 11, "itunes:A": 12])
        #expect(context.writes.allSatisfy { $0.disposition == .create && $0.expectedExistingSHA256 == nil })
    }

    @Test("선택 그룹 전체 선택도 모든 실제 하위를 resolve한다")
    func groupSelectionRequiresEveryDescendant() throws {
        #expect(throws: (any Error).self) {
            try UsbSyncSelectionStage.resolve(draft(selected: [UsbSyncSourceNode.iTunesSelectionID]), model: model(),
                                               formats: Self.formats, createdIDs: ["folder": 11])
        }
    }

    @Test("선택 창을 연 뒤 같은 크기의 원문이 달라져도 계획을 거부한다")
    func changedRawSelectionIsRejected() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let base = Data("old-choice".utf8)
        fixture.write(UsbSyncSelectionFile.relativePath(for: .deviceLibrary), Data("new-choice".utf8))
        let request = draft(baseFiles: [.deviceLibrary: base])
        #expect(try !UsbSyncSelectionStage.matchesBase(request, formats: [.deviceLibrary], root: fixture.root,
                                                       fileSystem: fixture.fileSystem()))
    }

    @Test("일반 파일 쓰기 API로도 검증 기대값 없이 선택 파일을 쓸 수 없다")
    func rawFileWriteCannotBypassProductionGate() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        var changes = fixture.exportChanges()
        let staged = fixture.stage("sync.xml", Data("synthetic".utf8))
        changes.writes.append(.init(staged: staged.path, destination: UsbSyncSelectionFile.relativePath(for: .deviceLibrary),
                                   sha256: staged.sha256, size: staged.size, modificationDate: nil, disposition: .create,
                                   afterDatabases: true))
        #expect {
            try fixture.write(changes)
        } throws: { error in
            if case let UsbError.writeRefused(blocks) = error { blocks.contains { $0.code == "syncSelectionIncomplete" } } else { false }
        }
        #expect(fixture.tree().isEmpty && fixture.backupFolders().isEmpty)
    }

    @Test("새 선택 파일은 기존 파일 단계에 들어가지 않는다")
    func selectionFilesArePlacedAfterDatabases() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        var changes = fixture.exportChanges()
        let staged = fixture.stage("sync.xml", Data("synthetic".utf8))
        let path = UsbSyncSelectionFile.relativePath(for: .deviceLibrary)
        changes.writes.append(.init(staged: staged.path, destination: path, sha256: staged.sha256, size: staged.size,
                                   modificationDate: nil, disposition: .create, afterDatabases: true))
        #expect(!UsbWriteRun.orderedItems(changes).contains { $0.destination == path })
    }

    @Test("옛 저널에는 후단 파일 플래그와 선택 검증 기대값이 없어도 읽는다")
    func olderJournalRemainsReadable() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let changes = fixture.exportChanges()
        let original = UsbJournal(changes: changes, volumeUUID: fixture.volumeKey, volumeName: fixture.volume.name, now: .now)
        let encoded = try UsbJournal.encoder().encode(original)
        let restored = try UsbJournal.decoder().decode(UsbJournal.self, from: encoded)
        #expect(restored == original)
        #expect(restored.changes.syncSelection == nil && restored.changes.writes.allSatisfy { $0.afterDatabases == nil })
    }

    /// 생산 계약을 열지 않고 내부 단계의 파일 원자성만 보는 합성 묶음이다.
    func nativeChanges(_ fixture: UsbChangeSetFixture) throws -> UsbChangeSet {
        fixture.seedEdit()
        var changes = try fixture.editChanges(removals: false)
        let original = UsbSyncSelectionDraft(localDBID: 42, sourceNodes: [], selection: .init(), enabled: true,
                                             playlistRefs: [:], baseFiles: [:])
        var baseFiles: [UsbFormat: Data] = [:]
        for format in Self.formats {
            let bytes = try UsbSyncSelectionXML.render(draft: original, format: format, playlistIDs: [:],
                                                       contract: Self.contract)
            baseFiles[format] = bytes
            fixture.write(UsbSyncSelectionFile.relativePath(for: format), bytes)
        }
        let request = UsbSyncSelectionDraft(localDBID: 42, sourceNodes: [], selection: .init(), enabled: false,
                                            playlistRefs: [:], baseFiles: baseFiles)
        var context = UsbExportAssembly.Context(staging: fixture.folder.appending(path: "sync-staging"))
        let verification = try UsbSyncSelectionStage.stage(request, formats: Self.formats, model: .empty, createdIDs: [:],
                                                           root: fixture.root, fileSystem: fixture.fileSystem(), into: &context,
                                                           contract: Self.contract)
        changes.writes += context.writes
        changes.target.mustExist.merge(context.target) { _, new in new }
        changes.syncSelection = verification
        return changes
    }

    func preparedRun(_ changes: UsbChangeSet, fixture: UsbChangeSetFixture, fileSystem: FaultyUsbFileSystem) throws -> UsbWriteRun {
        let run = try UsbWriteRun.open(root: fixture.root, paths: fixture.paths, guard: fixture.writeGuard(), fileSystem: fileSystem,
                                       ppthReader: UsbChangeSetFixture.ppthReader, now: .now, progress: { _ in })
        // write()를 거치지 않으므로 그 첫 단계처럼 보고서에 세션을 적는다. 복원은 다른 세션의 report.json을 거부한다.
        run.report = UsbWriteReport(outcome: .written, session: changes.session)
        var plan = UsbWriteRun.Plan()
        plan.databases = changes.databases.map {
            .init(destination: $0.destination, disposition: changes.base?.files[$0.destination] == nil ? .created : .overwritten,
                  oldSHA256: changes.base?.files[$0.destination]?.sha256)
        }
        do {
            try run.stage(changes, plan: plan)
            try run.backup(changes)
            return run
        } catch {
            run.close()
            throw error
        }
    }

    @Test("내부 단계는 DB 셋 교체를 마친 뒤 선택 파일 두 개를 확정하고 함께 복원한다")
    func internalStagesPlaceSelectionAfterDBAndRestoreAll() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let changes = try nativeChanges(fixture)
        let before = fixture.tree()
        let fs = fixture.fileSystem()
        let run = try preparedRun(changes, fixture: fixture, fileSystem: fs)
        defer { run.close() }
        try run.writeFiles(changes, isCancelled: { false })
        for format in Self.formats {
            let path = UsbSyncSelectionFile.relativePath(for: format)
            #expect(fixture.tree()[path] == before[path])
        }
        try run.commitDatabases(changes)
        let lastDB = try #require(fs.calls.lastIndex { $0.hasPrefix("rename ") && $0.hasSuffix("-> " + UsbLayout.exportExtPdb) })
        for format in Self.formats {
            let path = UsbSyncSelectionFile.relativePath(for: format)
            let index = try #require(fs.calls.firstIndex { $0.hasPrefix("rename ") && $0.hasSuffix("-> " + path) })
            #expect(index > lastDB)
            #expect(fixture.tree()[path] == changes.target.mustExist[path]?.sha256)
        }
        #expect(try run.rollback(mode: .write).isEmpty)
        #expect(fixture.tree() == before)
    }

    @Test("두 번째 선택 파일을 확정하다 실패하면 DB와 첫 번째 선택도 쓰기 전으로 복원한다")
    func secondSelectionFailureRestoresWholeBatch() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let changes = try nativeChanges(fixture)
        let before = fixture.tree()
        let fs = fixture.fileSystem()
        fs.failAt = (operation: .rename, occurrence: 1, mode: .error)
        fs.failMatching = { $0 == UsbSyncSelectionFile.relativePath(for: .deviceLibrary) }
        let run = try preparedRun(changes, fixture: fixture, fileSystem: fs)
        defer { run.close() }
        try run.writeFiles(changes, isCancelled: { false })
        #expect(throws: (any Error).self) { try run.commitDatabases(changes) }
        #expect(try run.rollback(mode: .write).isEmpty)
        #expect(fixture.tree() == before)
    }

    @Test("선택 파일 한쪽만 확정된 열린 저널은 앞으로 잇지 않고 전체를 복원한다")
    func interruptedNativeJournalRecoversByCompleteRollback() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let changes = try nativeChanges(fixture)
        let before = fixture.tree()
        let fs = fixture.fileSystem()
        fs.failAt = (operation: .rename, occurrence: 1, mode: .crash)
        fs.failMatching = { $0 == UsbSyncSelectionFile.relativePath(for: .deviceLibrary) }
        let run = try preparedRun(changes, fixture: fixture, fileSystem: fs)
        try run.writeFiles(changes, isCancelled: { false })
        #expect(throws: (any Error).self) { try run.commitDatabases(changes) }
        run.close()
        let recovered = try fixture.recover()
        #expect(recovered.outcome == .rolledBack)
        #expect(fixture.tree() == before)
        #expect(fixture.journal()?.state == .rolledBack)
    }

    @Test("있던 선택 파일을 다른 앱이 지웠으면 회복이 조용히 다시 만들지 않는다")
    func deletedOriginalSelectionRequiresExplicitRestore() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let changes = try nativeChanges(fixture)
        let original = fixture.tree()
        let fs = fixture.fileSystem()
        let run = try preparedRun(changes, fixture: fixture, fileSystem: fs)
        try run.writeFiles(changes, isCancelled: { false })
        run.close()
        let path = UsbSyncSelectionFile.relativePath(for: .deviceLibrary)
        try FileManager.default.removeItem(at: fixture.usb(path))
        let externallyChanged = fixture.tree()
        #expect {
            try fixture.recover()
        } throws: { error in
            if case UsbError.restorePending = error { true } else { false }
        }
        #expect(fixture.tree() == externallyChanged)
        #expect(!fixture.exists(path))
        #expect(fixture.journal()?.state == .restorePending)
        expectRefusal("recoveryNeeded") { _ = try fixture.restore() }
        #expect(fixture.tree() == externallyChanged)
        #expect(try fixture.restore(discardDeviceChanges: true).outcome == .restored)
        #expect(fixture.tree() == original)
        #expect(fixture.journal()?.state == .restored)
    }
}
