import DJCDomain
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

@Suite("USB 쓰기 저널")
struct UsbJournalTests {
    func sample(state: UsbJournal.State = .staged, base: UsbFingerprint? = nil) -> UsbJournal {
        let changes = UsbChangeSet(session: "abcdefgh", label: "t", purpose: base == nil ? .export : .edit, formats: [.oneLibrary],
                                   requiredRules: [.artworkMissing], databases: [], copies: [], writes: [], removals: [], base: base,
                                   target: UsbTargetFingerprint(mustExist: ["a": UsbTreeStamp(size: 1, sha256: "00")], mustNotExist: ["b"]),
                                   stagingDirectory: "/tmp/x", idHighWater: ["content": 7])
        var journal = UsbJournal(changes: changes, volumeUUID: "00000000-0000-0000-0000-000000000001", volumeName: "DJCTEST",
                                 now: Date(timeIntervalSince1970: 1_700_000_000))
        journal.state = state
        return journal
    }

    @Test("닫힌 상태는 정확히 여섯")
    func closedStatesExact() {
        #expect(UsbJournal.closedStates == [.verified, .rolledBack, .restored, .recovered, .dryRun, .needsReplan])
        let open = UsbJournal.State.allCases.filter { !UsbJournal.closedStates.contains($0) }
        #expect(Set(open) == [.planned, .staged, .backedUp, .filesWritten, .committing, .committed, .cleaned, .restoreFailed, .restorePending])
        for state in UsbJournal.State.allCases {
            #expect(sample(state: state).isClosed == UsbJournal.closedStates.contains(state))
        }
    }

    @Test("상태는 앞으로만 간다(닫힌 저널은 움직이지 않는다)")
    func stateTransitions() throws {
        var journal = sample(state: .planned)
        for next: UsbJournal.State in [.staged, .backedUp, .filesWritten, .committing, .committing, .committed, .cleaned, .verified] {
            try journal.move(to: next)
        }
        #expect(journal.state == .verified)
        #expect(throws: (any Error).self) { try journal.move(to: .staged) }
        #expect(throws: (any Error).self) { try journal.move(to: .rolledBack) }

        #expect(sample(state: .staged).canMove(to: .dryRun))
        #expect(!sample(state: .backedUp).canMove(to: .dryRun))
        #expect(!sample(state: .staged).canMove(to: .committed))
        #expect(!sample(state: .committed).canMove(to: .filesWritten))
        #expect(!sample(state: .committed).canMove(to: .verified))
        for state: UsbJournal.State in [.backedUp, .filesWritten, .committing, .committed, .cleaned, .restorePending, .restoreFailed] {
            #expect(sample(state: state).canMove(to: .rolledBack))
            #expect(sample(state: state).canMove(to: .needsReplan))
            #expect(sample(state: state).canMove(to: .recovered))
        }
        #expect(sample(state: .restorePending).canMove(to: .restored))
        #expect(!sample(state: .committed).canMove(to: .restored))
        for closed in UsbJournal.closedStates {
            for next in UsbJournal.State.allCases { #expect(!sample(state: closed).canMove(to: next)) }
        }
    }

    @Test("저널은 JSON으로 그대로 돌아온다(DB 항목 포함)")
    func codableRoundTrip() throws {
        var journal = sample(state: .committing)
        journal.entries = [UsbJournal.FileEntry(destination: "Contents/a.mp3", tempName: ".djc-part-abcdefgh-000001",
                                                disposition: .created, oldSHA256: nil, newSHA256: "11", size: 3,
                                                appleDoublePreexisted: false, state: .done)]
        journal.databases = [UsbJournal.DatabaseEntry(destination: UsbLayout.oneLibrary, format: .oneLibrary,
                                                      tempName: ".djc-part-abcdefgh-000002", disposition: .overwritten,
                                                      oldSHA256: "aa", newSHA256: "bb", appleDoublePreexisted: true,
                                                      sidecarsPreexisted: [UsbLayout.oneLibrary + "-wal"], state: .pending)]
        journal.plannedDatabases = [UsbJournal.PlannedDatabase(destination: UsbLayout.oneLibrary, disposition: .overwritten, oldSHA256: "aa")]
        journal.createdDirs = ["Contents"]
        journal.deletedSidecars = [UsbLayout.oneLibrary + "-wal"]
        journal.removals = [UsbJournal.RemovalEntry(path: "Contents/b.mp3", state: .skipped, reason: .ppthDiffers)]
        journal.backupDirectory = "/tmp/backup"
        let data = try UsbJournal.encoder().encode(journal)
        let back = try UsbJournal.decoder().decode(UsbJournal.self, from: data)
        #expect(back == journal)
        #expect(back.databases.first?.sidecarsPreexisted == [UsbLayout.oneLibrary + "-wal"])
        #expect(back.target.mustNotExist == ["b"])
        #expect(back.idHighWater == ["content": 7])
    }

    @Test("형식별 진행: DB 항목에서 교체를 마친 형식과 교체 중인 형식을 읽는다")
    func committedFormatsFromDatabaseEntries() {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        var journal = UsbJournal(changes: fixture.exportChanges(), volumeUUID: "00000000-0000-0000-0000-000000000001", volumeName: "DJCTEST",
                                 now: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(journal.committedFormats.isEmpty)
        #expect(journal.committingFormat == nil)
        func entry(_ destination: String, _ format: UsbFormat, _ state: UsbJournal.EntryState) -> UsbJournal.DatabaseEntry {
            UsbJournal.DatabaseEntry(destination: destination, format: format, tempName: ".djc-part-abcdefgh-000001", disposition: .created,
                                     oldSHA256: nil, newSHA256: "00", appleDoublePreexisted: false, sidecarsPreexisted: [], state: state)
        }
        journal.databases = [entry(UsbLayout.oneLibrary, .oneLibrary, .done), entry(UsbLayout.exportPdb, .deviceLibrary, .done),
                             entry(UsbLayout.exportExtPdb, .deviceLibrary, .pending)]
        // Device Library는 export.pdb·exportExt.pdb 둘 다 바꿔야 마친 것이다
        #expect(journal.committedFormats == [.oneLibrary])
        #expect(journal.committingFormat == .deviceLibrary)
        journal.databases[2].state = .done
        #expect(journal.committedFormats == [.oneLibrary, .deviceLibrary])
        #expect(journal.committingFormat == nil)
    }

    @Test("수정 저널은 계획 때 USB DB 지문을 담는다")
    func baseFingerprintStored() throws {
        let base = UsbFingerprint(files: [UsbLayout.exportPdb: .init(size: 10, mtime: Date(timeIntervalSince1970: 1_600_000_000), sha256: "cc")])
        let journal = sample(base: base)
        let back = try UsbJournal.decoder().decode(UsbJournal.self, from: UsbJournal.encoder().encode(journal))
        #expect(back.base == base)
        #expect(back.changes.purpose == .edit)
    }

    @Test("내구 쓰기: 임시 → fullSync → rename → 폴더 fsync")
    func durableWriteOrder() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let fs = fixture.fileSystem()
        let target = fixture.home.appending(path: "x.json")
        try UsbDurableFile.write(Data("{}".utf8), to: target, fileSystem: fs)
        let ops = fs.calls.map { String($0.split(separator: " ").first!) }
        #expect(ops == ["writeNew", "fullSync", "rename", "syncDirectory"])
        #expect(fs.calls[2].hasSuffix("mac:x.json"))
        #expect(try Data(contentsOf: target) == Data("{}".utf8))
        // 덮어쓰기도 같은 순서, 임시 파일은 남지 않는다.
        try UsbDurableFile.write(Data("[]".utf8), to: target, fileSystem: fs)
        #expect(try Data(contentsOf: target) == Data("[]".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.home.path) == ["x.json"])
    }

    @Test("DB 항목은 임시 파일을 쓰기 전에 pending으로 적고 rename 뒤 done")
    func databaseEntryWrittenBeforeRename() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let changes = fixture.exportChanges()
        let fs = fixture.fileSystem()
        var checked = 0
        fs.onOperation = { op, url in
            guard let relative = fs.relative(url), relative.hasPrefix("PIONEER/rekordbox/") else { return }
            let journal = fixture.journal()
            if op == .writeNew, UsbLayout.isTemp(url.lastPathComponent) {
                // 임시 파일을 쓰기 직전: 이 임시 이름의 DB 항목이 이미 pending으로 디스크에 있다
                let entry = journal?.databases.first { $0.tempName == url.lastPathComponent }
                #expect(entry?.state == .pending)
                #expect(entry?.disposition == .created)
                checked += 1
            }
            if op == .rename, let entry = journal?.databases.first(where: { $0.destination == relative }) {
                #expect(entry.state == .pending)
            }
        }
        try fixture.write(changes, fileSystem: fs)
        #expect(checked == 3)
        let journal = try #require(fixture.journal())
        #expect(journal.state == .verified)
        #expect(journal.databases.map(\.destination) == FixtureOrder.databases)
        #expect(journal.databases.allSatisfy { $0.state == .done })
    }
}

enum FixtureOrder {
    static let databases = [UsbLayout.oneLibrary, UsbLayout.exportPdb, UsbLayout.exportExtPdb]
}
