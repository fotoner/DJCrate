import DJCDomain
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// USB 쓰기 절차(임시 폴더를 USB 루트로, 가드는 디스크 이미지 FAT32)
@Suite("USB 쓰기")
struct UsbWriterTests {
    func expected(_ changes: UsbChangeSet) -> [String: String] {
        changes.target.mustExist.mapValues { $0.sha256 ?? "" }
    }

    func index(_ calls: [String], _ predicate: (String) -> Bool) -> Int? { calls.firstIndex(where: predicate) }

    @Test("드라이 런은 USB를 그대로 둔다")
    func dryRunLeavesTreeUnchanged() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let fs = fixture.fileSystem()
        let report = try fixture.write(fixture.exportChanges(), fileSystem: fs, options: UsbWriteOptions(dryRun: true))
        #expect(report.outcome == .dryRun)
        #expect(fixture.tree().isEmpty)
        #expect(fixture.directories().isEmpty)
        #expect(fixture.backupFolders().isEmpty)
        #expect(fixture.journal()?.state == .dryRun)
        let mutating: Set<String> = ["makeDirectory", "writeNew", "copyDataNew", "rename", "remove", "removeDirectoryIfEmpty", "setModificationDate"]
        #expect(!fs.calls.contains { call in !call.contains("mac:") && mutating.contains(String(call.split(separator: " ")[0])) })
    }

    @Test("드라이 런 저널은 바로 이어지는 실제 쓰기를 막지 않는다", arguments: [false, true])
    func dryRunJournalDoesNotBlockNextWrite(edit: Bool) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        if edit { fixture.seedEdit() }
        let changes = edit ? try fixture.editChanges() : fixture.exportChanges()
        let before = fixture.tree()
        let dry = try fixture.write(changes, options: UsbWriteOptions(dryRun: true))
        #expect(dry.outcome == .dryRun)
        let journal = try #require(fixture.journal())
        #expect(journal.state == .dryRun)
        #expect(journal.isClosed)
        #expect(UsbWriter.pendingJournal(paths: fixture.paths, volumeKey: fixture.volumeKey) == nil)
        #expect(fixture.tree() == before)
        let report = try fixture.write(changes)
        #expect(report.outcome == .written)
        #expect(fixture.journal()?.state == .verified)
    }

    @Test("반복 드라이 런은 새 ID를 소비하지 않고 이전 쓰기의 ID 상한을 보존한다", arguments: [false, true])
    func dryRunPreservesCommittedHighWater(committed: Bool) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let previous = committed ? ["content": 9, "playlist": 7] : [:]
        if committed {
            var initial = fixture.exportChanges()
            initial.idHighWater = previous
            try fixture.write(initial)
        }
        var changes = committed ? try fixture.smallEditChanges() : fixture.exportChanges()
        changes.idHighWater = ["content": 10, "playlist": 8]
        let before = fixture.tree()
        for _ in 0..<2 {
            let report = try fixture.write(changes, options: UsbWriteOptions(dryRun: true))
            #expect(report.outcome == .dryRun)
            #expect(fixture.journal()?.idHighWater == previous)
            #expect(fixture.tree() == before)
        }
        let report = try fixture.write(changes)
        #expect(report.outcome == .written)
        #expect(fixture.journal()?.idHighWater == changes.idHighWater)
    }

    @Test("쓰면 트리가 목표와 같다")
    func writeProducesTargetTree() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let changes = fixture.exportChanges()
        let events = PhaseLog()
        let report = try UsbWriter.write(changes, root: fixture.root, paths: fixture.paths, guard: fixture.writeGuard(),
                                         fileSystem: fixture.fileSystem(), ppthReader: UsbChangeSetFixture.ppthReader,
                                         progress: { events.append($0.phase) })
        #expect(report.outcome == .written)
        #expect(fixture.tree() == expected(changes))
        #expect(report.filesCreated == 9)
        #expect(report.filesReused == 0)
        #expect(report.resultDatabases.count == 3)
        #expect(report.resultDatabases[UsbLayout.oneLibrary] == changes.databases[0].sha256)
        #expect(report.backup != nil)
        // 음원·아트워크는 원본 수정 시각을 옮긴다.
        let audio = try FileManager.default.attributesOfItem(atPath: fixture.usb(UsbChangeSetFixture.exportAudio[1]).path)
        #expect(audio[.modificationDate] as? Date == UsbChangeSetFixture.audioDate)
        let art = try FileManager.default.attributesOfItem(atPath: fixture.usb(UsbChangeSetFixture.exportArtwork[0]).path)
        #expect(art[.modificationDate] as? Date == UsbChangeSetFixture.audioDate)
        // 백업 폴더에 보고서와 닫는 저널 사본
        let backup = URL(filePath: try #require(report.backup))
        #expect(FileManager.default.fileExists(atPath: backup.appending(path: "report.json").path))
        let copy = try UsbJournal.decoder().decode(UsbJournal.self, from: Data(contentsOf: backup.appending(path: "journal.json")))
        #expect(copy.state == .verified)
        #expect(Set(events.phases).isSuperset(of: [.backup, .files, .commit, .cleanup, .verify]))
    }

    @Test("macOS가 만든 ._ 파일은 우리가 만든 이름만 정확히 지운다")
    func appleDoubleRemovedExactly() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.write("Contents/keep.mp3", Data("user".utf8))
        fixture.write("Contents/._keep.mp3", Data(count: 4096))
        let changes = fixture.exportChanges()
        let report = try fixture.write(changes, fileSystem: fixture.fileSystem(appleDouble: true))
        let tree = fixture.tree()
        #expect(fixture.appleDoubleCount(in: tree) == 1)
        #expect(tree["Contents/._keep.mp3"] != nil)
        #expect(report.appleDoubleRemoved > 0)
        var withoutUser = tree
        withoutUser["Contents/keep.mp3"] = nil
        withoutUser["Contents/._keep.mp3"] = nil
        #expect(withoutUser == expected(changes))
    }

    @Test("임시 이름은 대상 이름과 무관하게 .djc-part-로 시작한다")
    func tempNameIndependentOfTargetName() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let changes = fixture.exportChanges()
        let fs = fixture.fileSystem()
        try fixture.write(changes, fileSystem: fs)
        let target = UsbChangeSetFixture.exportAudio[0]
        let rename = try #require(fs.calls.first { $0.hasPrefix("rename ") && $0.hasSuffix("-> " + target) })
        let temp = String(rename.dropFirst("rename ".count).components(separatedBy: " -> ")[0])
        #expect((temp as NSString).lastPathComponent.hasPrefix(".djc-part-" + changes.session + "-"))
        #expect((temp as NSString).deletingLastPathComponent == (target as NSString).deletingLastPathComponent)
        #expect(fs.calls.contains("copyDataNew " + temp))
    }

    @Test("OneLibrary 사이드카는 DB rename 전에 지운다")
    func sidecarsDeletedBeforeOneLibraryRename() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.seedEdit(extraSidecar: true)
        let changes = try fixture.editChanges(removals: false)
        let fs = fixture.fileSystem()
        try fixture.write(changes, fileSystem: fs)
        let calls = fs.calls
        let tempWrite = try #require(index(calls) { $0.hasPrefix("writeNew PIONEER/rekordbox/.djc-part-") })
        let sidecar = try #require(index(calls) { $0 == "remove " + UsbLayout.oneLibrary + "-wal" })
        let rename = try #require(index(calls) { $0.hasPrefix("rename ") && $0.hasSuffix("-> " + UsbLayout.oneLibrary) })
        #expect(tempWrite < sidecar)
        #expect(sidecar < rename)
        #expect(!fixture.exists(UsbLayout.oneLibrary + "-wal"))
        #expect(fixture.journal()?.deletedSidecars == [UsbLayout.oneLibrary + "-wal"])
    }

    @Test("RENAME_SWAP·renamex_np를 쓰지 않는다")
    func neverCallsRenameSwap() throws {
        let folder = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/RekordboxKit/Usb/Write")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".swift") }
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: folder.appending(path: file), encoding: .utf8)
            let code = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            #expect(!code.contains { $0.contains("renamex_np") || $0.contains("RENAME_SWAP") || $0.contains("renameatx_np") }, "\(file)")
        }
    }

    @Test("이미 같은 파일은 다시 쓰지 않는다")
    func reuseDoesNotWrite() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.seedEdit()
        let changes = try fixture.editChanges(removals: false)
        let fs = fixture.fileSystem()
        let report = try fixture.write(changes, fileSystem: fs)
        #expect(report.filesReused == 2)
        for path in [UsbChangeSetFixture.keepAudio, UsbChangeSetFixture.keepArtwork[0]] {
            #expect(!fs.calls.contains { $0.hasPrefix("rename ") && $0.hasSuffix("-> " + path) })
        }
        let journal = try #require(fixture.journal())
        #expect(journal.entries.filter { $0.disposition == .reused }.map(\.destination).sorted()
            == [UsbChangeSetFixture.keepArtwork[0], UsbChangeSetFixture.keepAudio].sorted())
        #expect(fixture.tree().filter { changes.target.mustExist[$0.key] != nil } == expected(changes))
    }

    @Test("재사용할 음원은 크기만이 아니라 내용(목표 SHA-256, 없으면 원본 SHA-1)도 본다", arguments: ["sha256", "sha1"])
    func reuseCopyChecksContentHash(hash: String) throws {
        for changed in [false, true] {
            let fixture = UsbChangeSetFixture()
            defer { fixture.remove() }
            fixture.seedEdit()
            let original = try #require(fixture.data(UsbChangeSetFixture.keepAudio))
            var changes = try fixture.editChanges(removals: false)
            let keep = try #require(changes.copies.firstIndex { $0.destination == UsbChangeSetFixture.keepAudio })
            if hash == "sha1" {
                changes.target.mustExist[UsbChangeSetFixture.keepAudio] = nil
                changes.copies[keep].sourceSHA1 = UsbChangeSetFixture.sha1(original)
            }
            guard changed else {
                // 같은 내용이면 재사용한다
                #expect(try fixture.write(changes).filesReused == 2)
                continue
            }
            // 계획 뒤 같은 크기의 다른 내용으로 바뀌었다: 파일 단계에서 멈추고 되돌린다(DB까지 가지 않는다)
            fixture.write(UsbChangeSetFixture.keepAudio, UsbChangeSetFixture.random(original.count))
            let before = fixture.tree()
            let fs = fixture.fileSystem()
            #expect {
                try fixture.write(changes, fileSystem: fs)
            } throws: { error in
                if case UsbError.writeRolledBack = error { true } else { false }
            }
            #expect(!fs.calls.contains { $0.hasPrefix("writeNew PIONEER/rekordbox/") })
            #expect(fixture.tree() == before)
            #expect(fixture.journal()?.state == .rolledBack)
        }
    }

    @Test("덮어쓸 파일의 지금 해시·PPTH를 확인한다")
    func overwriteChecksExistingHashAndPPTH() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.seedEdit()
        let before = fixture.tree()
        // PPTH가 다른 곡이면 되돌린다.
        let wrongPPTH = try fixture.editChanges(removals: false, ppth: "/Contents/Other/x.mp3")
        #expect(throws: UsbError.self) { try fixture.write(wrongPPTH) }
        #expect(fixture.tree() == before)
        #expect(fixture.journal()?.state == .rolledBack)
        // 해시가 계획과 다르면 되돌린다.
        var wrongHash = try fixture.editChanges(removals: false)
        wrongHash.writes[0].expectedExistingSHA256 = String(repeating: "0", count: 64)
        #expect(throws: UsbError.self) { try fixture.write(wrongHash) }
        #expect(fixture.tree() == before)
        // 맞으면 덮는다.
        let good = try fixture.editChanges(removals: false)
        try fixture.write(good)
        #expect(fixture.tree()[UsbChangeSetFixture.keepAnalysis[0]] == good.writes[0].sha256)
    }

    /// 뺄 곡의 분석 파일 셋만 지우는 수정 묶음
    func analysisRemovalChanges(_ fixture: UsbChangeSetFixture) throws -> UsbChangeSet {
        var changes = try fixture.editChanges(removals: false)
        for path in UsbChangeSetFixture.goneAnalysis {
            let data = fixture.data(path)!
            changes.removals.append(UsbFileRemoval(path: path, expectedSHA256: UsbChangeSetFixture.sha256(data), expectedSize: Int64(data.count),
                                                   expectedPPTH: "/Contents/A/B/x.mp3", localOriginal: nil, localOriginalSHA1: nil))
            changes.target.mustExist[path] = nil
            changes.target.mustNotExist.insert(path)
        }
        return changes
    }

    @Test("지울 분석 파일의 PPTH가 다른 곡이면 셋 모두 남긴다")
    func removalSkippedWhenPPTHDiffers() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.seedEdit()
        for path in UsbChangeSetFixture.goneAnalysis { fixture.write(path, UsbChangeSetFixture.anlz(ppth: "/Contents/C/D/y.mp3")) }
        let changes = try analysisRemovalChanges(fixture)
        let before = fixture.tree()
        let report = try fixture.write(changes)
        #expect(report.outcome == .written)
        #expect(report.filesRemoved == 0)
        for path in UsbChangeSetFixture.goneAnalysis { #expect(fixture.tree()[path] == before[path]) }
        #expect(report.notes.filter { $0.hasPrefix("분석 파일이 다른 곡 것이라 지우지 않았습니다") }.count == 1)
        let journal = try #require(fixture.journal())
        #expect(journal.removals.count == 3)
        #expect(journal.removals.allSatisfy { $0.state == .skipped && $0.reason == .ppthDiffers })
    }

    @Test("지울 파일의 크기·해시가 계획과 다르면 남긴다")
    func removalSkippedWhenHashDiffers() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.seedEdit()
        var changes = try analysisRemovalChanges(fixture)
        for index in changes.removals.indices { changes.removals[index].expectedPPTH = "/" + UsbChangeSetFixture.goneAudio }
        // 계획 뒤 한 파일이 바뀌었다
        fixture.write(UsbChangeSetFixture.goneAnalysis[1], UsbChangeSetFixture.anlz(ppth: "/" + UsbChangeSetFixture.goneAudio))
        let before = fixture.tree()
        let report = try fixture.write(changes)
        #expect(report.outcome == .written)
        #expect(report.filesRemoved == 0)
        for path in UsbChangeSetFixture.goneAnalysis { #expect(fixture.tree()[path] == before[path]) }
        #expect(fixture.journal()?.removals.allSatisfy { $0.state == .skipped } == true)
        #expect(fixture.journal()?.removals.contains { $0.reason == .hashDiffers } == true)
    }

    @Test("지우기: 허용 목록·해시·PPTH가 맞으면 지우고 빈 우리 폴더도 지운다")
    func removalsDeleteFilesAndEmptyFolders() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.seedEdit()
        let changes = try fixture.editChanges()
        let report = try fixture.write(changes, fileSystem: fixture.fileSystem(appleDouble: true))
        #expect(report.filesRemoved == 6)
        #expect(!fixture.directories().contains("Contents/Gone"))
        #expect(!fixture.directories().contains("PIONEER/USBANLZ/P002"))
        #expect(fixture.directories().contains("PIONEER/Artwork/00001"))
        #expect(fixture.appleDoubleCount() == 0)
        for path in changes.target.mustNotExist { #expect(!fixture.exists(path)) }
    }

    @Test("쓰는 도중 볼륨이 사라지면 복원하지 않고 멈춘다")
    func volumeLostStopsWithoutRestore() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let changes = fixture.exportChanges()
        let fs = fixture.fileSystem()
        fs.unmountAt = (op: .writeNew, occurrence: 3)
        var stateAtLoss: UsbJournal.State?
        var writeCount = 0
        fs.onOperation = { op, url in
            if op == .writeNew, fs.relative(url) != nil {
                writeCount += 1
                if writeCount == 3 { stateAtLoss = fixture.journal()?.state }
            }
        }
        #expect {
            try fixture.write(changes, fileSystem: fs)
        } throws: { error in
            if case UsbError.volumeLost = error { true } else { false }
        }
        let calls = fs.calls
        let usbWrites = calls.indices.filter { calls[$0].hasPrefix("writeNew ") && !calls[$0].contains("mac:") }
        #expect(usbWrites.count == 3)
        let lost = try #require(usbWrites.last)
        let after = calls[(lost + 1)...].filter { !$0.contains("mac:") }
        #expect(after.allSatisfy { $0.hasPrefix("mountedOn") || $0.hasPrefix("stat .") })
        let journal = try #require(fixture.journal())
        #expect(!journal.isClosed)
        #expect(journal.state == stateAtLoss)
        #expect(journal.state != .restorePending)
        // 다시 붙인 뒤 회복하면 쓰기 전이나 목표 중 하나
        let report = try fixture.recover()
        #expect([UsbWriteReport.Outcome.rolledBack, .recovered].contains(report.outcome))
        let tree = fixture.tree()
        #expect(tree.isEmpty || tree == expected(changes))
        #expect(fixture.journal()?.isClosed == true)
    }

    @Test("복원 도중 볼륨이 사라지면 그 자리에서 멈춘다")
    func volumeLostDuringRestoreStops() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let changes = fixture.exportChanges()
        let fs = fixture.fileSystem()
        fs.failAt = (operation: .rename, occurrence: 4, mode: .error)
        fs.unmountAt = (op: .remove, occurrence: 1)
        var stateAtFailure: UsbJournal.State?
        fs.onOperation = { op, url in
            if op == .remove, fs.relative(url) != nil, stateAtFailure == nil { stateAtFailure = fixture.journal()?.state }
        }
        #expect {
            try fixture.write(changes, fileSystem: fs)
        } throws: { error in
            if case UsbError.volumeLost = error { true } else { false }
        }
        let calls = fs.calls
        let lost = try #require(calls.firstIndex { $0.hasPrefix("remove ") && !$0.contains("mac:") })
        #expect(calls[(lost + 1)...].filter { !$0.contains("mac:") }.allSatisfy { $0.hasPrefix("mountedOn") || $0.hasPrefix("stat .") })
        let journal = try #require(fixture.journal())
        #expect(journal.state == stateAtFailure)
        // 자동 되돌리기도 첫 USB 연산 전에 방향(restorePending)을 내린다. 다시 붙이면 회복이 일부 되돌린 DB를 앞으로 쓰지 않는다.
        #expect(journal.state == .restorePending)
        #expect(!journal.isClosed)
    }

    @Test("rekordbox를 A·D 전·DB마다(DB 폴더를 만들기 전에도)·F 전에 다시 본다", arguments: [false, true])
    func rekordboxRecheckedBeforeFilesEachDBCleanup(export: Bool) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        if !export { fixture.seedEdit() }
        let changes = export ? fixture.exportChanges() : try fixture.editChanges()
        let fs = fixture.fileSystem()
        fixture.recorder = fs
        try fixture.write(changes, fileSystem: fs)
        let calls = fs.calls.filter { $0 == "guard.rekordbox" || !$0.contains("mac:") }
        func isRekordbox(_ i: Int) -> Bool { calls[i] == "guard.rekordbox" }
        func isMutating(_ call: String) -> Bool {
            ["copyDataNew", "writeNew", "rename", "remove", "makeDirectory"].contains(String(call.split(separator: " ")[0]))
        }
        /// 그 호출 바로 앞(USB 파일 연산 사이에서)에 rekordbox 확인이 있는지
        func checkedBefore(_ i: Int) -> Bool {
            var j = i - 1
            while j >= 0, !isRekordbox(j) {
                if isMutating(calls[j]) { return false }
                j -= 1
            }
            return j >= 0
        }
        let firstFile = try #require(calls.firstIndex { $0.hasPrefix("copyDataNew ") || $0.hasPrefix("makeDirectory ") })
        #expect(checkedBefore(firstFile))
        #expect(calls.prefix(firstFile).filter { $0 == "guard.rekordbox" }.count >= 2)
        for db in FixtureOrder.databases {
            let rename = try #require(calls.firstIndex { $0.hasPrefix("rename ") && $0.hasSuffix("-> " + db) })
            var first = try #require(calls[..<rename].lastIndex { $0.hasPrefix("writeNew PIONEER/rekordbox/.djc-part-") })
            // 내보내기의 첫 DB는 DB 폴더를 만든 뒤 임시 파일을 쓴다: 그 폴더 만들기가 이 DB 단계의 첫 USB 쓰기다
            if let folder = calls[..<first].lastIndex(where: { $0 == "makeDirectory " + UsbLayout.rekordboxDir }),
               !calls[(folder + 1)..<first].contains(where: isMutating) {
                first = folder
            }
            #expect(checkedBefore(first), "\(db)")
        }
        if export {
            // 내보내기는 DB 폴더를 E 단계에서 처음 만든다: 그 폴더를 만들기 전에도 본다
            let folder = try #require(calls.firstIndex { $0 == "makeDirectory " + UsbLayout.rekordboxDir })
            #expect(checkedBefore(folder))
        } else {
            let firstRemoval = try #require(calls.firstIndex { $0 == "remove " + UsbChangeSetFixture.goneAudio })
            #expect(checkedBefore(firstRemoval))
        }
    }

    @Test("백업 파일마다 fullSync, 저널 backedUp이 첫 USB 쓰기보다 먼저 디스크에")
    func macBackupsFullSynced_journalDurableBeforeFiles() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.seedEdit(extraSidecar: true, extraAppleDouble: true)
        let changes = try fixture.editChanges()
        let fs = fixture.fileSystem()
        var firstWriteState: UsbJournal.State?
        var manifestPresent = false
        fs.onOperation = { op, url in
            guard firstWriteState == nil, fs.relative(url) != nil,
                  [.makeDirectory, .writeNew, .copyDataNew, .rename, .remove, .setModificationDate].contains(op) else { return }
            let journal = fixture.journal()
            firstWriteState = journal?.state
            if let backup = journal?.backupDirectory {
                manifestPresent = FileManager.default.fileExists(atPath: backup + "/manifest.json")
            }
        }
        try fixture.write(changes, fileSystem: fs)
        #expect(firstWriteState == .backedUp)
        #expect(manifestPresent)
        let calls = fs.calls
        let copies = calls.enumerated().filter { $0.element.hasPrefix("copyDataNew mac:") }
        #expect(copies.count >= 6)
        for copy in copies {
            let name = String(copy.element.dropFirst("copyDataNew ".count))
            #expect(calls[(copy.offset + 1)...].contains("fullSync " + name), "\(name)")
        }
    }

    @Test("백업은 볼륨마다 최근 다섯 개, 고정한 것은 남긴다")
    func pruneKeepsFiveExceptPinned() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let volumeFolder = fixture.paths.backups.appending(path: fixture.volumeKey)
        func makeBackup(_ index: Int, _ state: UsbJournal.State) throws -> URL {
            let folder = volumeFolder.appending(path: String(format: "2026-01-%02dT000000-t", index))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let manifest = UsbManifest(volumeUUID: fixture.volumeKey, volumeName: "DJCTEST", appVersion: "t", session: "s\(index)",
                                       createdAt: Date(timeIntervalSince1970: Double(index) * 1000))
            try UsbJournal.encoder().encode(manifest).write(to: folder.appending(path: "manifest.json"))
            var journal = UsbJournal(changes: fixture.exportChanges(), volumeUUID: fixture.volumeKey, volumeName: "DJCTEST", now: .now)
            journal.state = state
            journal.backupDirectory = folder.path
            try UsbJournal.encoder().encode(journal).write(to: folder.appending(path: "journal.json"))
            return folder
        }
        // 1: 옛 rolledBack, 2: 열린 저널이 가리킴, 3: needsReplan(더 새 verified가 있어 풀림), 4: verified, 5–8: rolledBack
        let folders = try ([(1, .rolledBack), (2, .filesWritten), (3, .needsReplan), (4, .verified), (5, .rolledBack),
                           (6, .rolledBack), (7, .rolledBack), (8, .rolledBack)] as [(Int, UsbJournal.State)]).map { try makeBackup($0.0, $0.1) }
        var open = UsbJournal(changes: fixture.exportChanges(), volumeUUID: fixture.volumeKey, volumeName: "DJCTEST", now: .now)
        open.state = .filesWritten
        open.backupDirectory = folders[1].path
        try FileManager.default.createDirectory(at: fixture.paths.sessions, withIntermediateDirectories: true)
        try UsbJournal.encoder().encode(open).write(to: fixture.paths.sessions.appending(path: fixture.volumeKey + ".json"))
        UsbWriter.prune(paths: fixture.paths, volumeKey: fixture.volumeKey)
        let left = Set(fixture.backupFolders().map(\.lastPathComponent))
        #expect(left == Set([folders[1], folders[3], folders[4], folders[5], folders[6], folders[7]].map(\.lastPathComponent)))

        // 마지막 verified는 다섯 개 밖이어도 남는다. 더 새 verified가 없는 needsReplan도 남는다.
        let other = UsbChangeSetFixture()
        defer { other.remove() }
        let otherFolder = other.paths.backups.appending(path: other.volumeKey)
        _ = otherFolder
        try FileManager.default.removeItem(at: volumeFolder)
        let second = try ([(1, .verified), (2, .needsReplan), (3, .rolledBack), (4, .rolledBack), (5, .rolledBack),
                          (6, .rolledBack), (7, .rolledBack), (8, .rolledBack)] as [(Int, UsbJournal.State)]).map { try makeBackup($0.0, $0.1) }
        open.state = .verified
        try UsbJournal.encoder().encode(open).write(to: fixture.paths.sessions.appending(path: fixture.volumeKey + ".json"))
        UsbWriter.prune(paths: fixture.paths, volumeKey: fixture.volumeKey)
        #expect(Set(fixture.backupFolders().map(\.lastPathComponent)) == Set((second[0...1] + second[3...]).map(\.lastPathComponent)))
    }

    @Test("커밋 전 취소는 만든 것만 지우고 되돌린다")
    func cancelBeforeCommitRollsBackCreatedOnly() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.seedEdit()
        let changes = try fixture.editChanges()
        let before = fixture.tree()
        let fs = fixture.fileSystem()
        let checks = Counter()
        #expect {
            try fixture.write(changes, fileSystem: fs, isCancelled: { checks.next() > 2 })
        } throws: { error in
            if case UsbError.cancelled = error { true } else { false }
        }
        #expect(fixture.tree() == before)
        #expect(!fs.calls.contains { $0.hasPrefix("writeNew PIONEER/rekordbox/") })
        #expect(fs.calls.contains { $0.hasPrefix("remove ") && $0.hasSuffix(UsbChangeSetFixture.newAudio) })
        let journal = try #require(fixture.journal())
        #expect(journal.state == .rolledBack)
        let backup = try #require(journal.backupDirectory)
        let report = try JSONDecoder().decode(UsbWriteReport.self, from: Data(contentsOf: URL(filePath: backup).appending(path: "report.json")))
        #expect(report.outcome == .rolledBack)
    }
}

/// 진행 이벤트를 모으는 도우미
final class PhaseLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UsbProgress.Phase] = []
    func append(_ phase: UsbProgress.Phase) { lock.withLock { values.append(phase) } }
    var phases: [UsbProgress.Phase] { lock.withLock { values } }
}

/// 여러 번 불리는 취소 확인을 세는 도우미
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}
