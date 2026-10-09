import DJCDomain
import DJCStorage
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing
@testable import djc

/// `usb-restore`·`usb-recover`와 USB lab 명령의 인자·거부(실제 USB·라이브 라이브러리·DJCrate 데이터 폴더에 닿지 않는다)
@Suite("USB 명령")
struct UsbCommandTests {
    func paths() -> (UsbWritePaths, URL) {
        let base = FileManager.default.temporaryDirectory.appending(path: "djc-usbcmd-\(UUID().uuidString)")
        return (UsbWritePaths(backups: base.appending(path: "b"), sessions: base.appending(path: "s"), staging: base.appending(path: "t")), base)
    }

    func refusedCodes(_ body: () async throws -> Void) async -> [String] {
        do {
            try await body()
            return []
        } catch let UsbError.writeRefused(blocks) {
            return blocks.map(\.code)
        } catch {
            return ["other: \(error)"]
        }
    }

    @Test("--volume 없이는 사용법")
    func volumeRequired() async {
        let (paths, base) = paths()
        defer { try? FileManager.default.removeItem(at: base) }
        await #expect(throws: UsageError.self) { try await UsbCommands.restore(["usb-restore"], paths: paths) }
        await #expect(throws: UsageError.self) { try await UsbCommands.recover(["usb-recover", "--discard-temp"], paths: paths) }
    }

    @Test("rekordbox 라이브러리 폴더는 USB로 받지 않는다(recover·restore 모두)")
    func liveLibraryRefused() async {
        let (paths, base) = paths()
        defer { try? FileManager.default.removeItem(at: base) }
        let live = NSHomeDirectory() + "/Library/Pioneer/rekordbox"
        #expect(await refusedCodes { try await UsbCommands.recover(["usb-recover", "--volume", live], paths: paths) } == ["liveLibrary"])
        #expect(await refusedCodes { try await UsbCommands.restore(["usb-restore", "--volume", live + "/share"], paths: paths) } == ["liveLibrary"])
        #expect(!FileManager.default.fileExists(atPath: base.path))
    }

    @Test("실물 볼륨은 쓰기가 열리기 전 거부(recover·restore 모두)", arguments: ["/Volumes/DJCNOTEXIST", NSHomeDirectory()])
    func physicalRefused(volume: String) async {
        let (paths, base) = paths()
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(await refusedCodes { try await UsbCommands.recover(["usb-recover", "--volume", volume, "--discard-temp"], paths: paths) } == ["physicalDisabled"])
        #expect(await refusedCodes { try await UsbCommands.restore(["usb-restore", "--volume", volume], paths: paths) } == ["physicalDisabled"])
        #expect(!FileManager.default.fileExists(atPath: base.path))
        // 문구는 이유와 할 일
        for run in [{ try await UsbCommands.recover(["usb-recover", "--volume", volume], paths: paths) },
                    { try await UsbCommands.restore(["usb-restore", "--volume", volume], paths: paths) }] {
            do {
                try await run()
                Issue.record("실물 볼륨을 받았다")
            } catch {
                #expect((error as? UsbError)?.errorDescription?.contains("--allow-physical") == true)
            }
        }
    }

    @Test("--allow-physical을 줘도 시험 프로세스는 임시 폴더 밖 볼륨에 쓰지 않는다(recover·restore 모두)", arguments: ["/Volumes/DJCNOTEXIST", NSHomeDirectory()])
    func allowPhysicalStillRefusedInTests(volume: String) async {
        let (paths, base) = paths()
        defer { try? FileManager.default.removeItem(at: base) }
        for run in [{ try await UsbCommands.recover(["usb-recover", "--volume", volume, "--discard-temp", "--allow-physical", "--confirm", "X"], paths: paths) },
                    { try await UsbCommands.restore(["usb-restore", "--volume", volume, "--allow-physical", "--confirm", "X"], paths: paths) }] {
            do {
                try await run()
                Issue.record("실물 볼륨을 받았다")
            } catch let UsbError.writeRefused(blocks) {
                #expect(blocks.map(\.code) == ["physicalDisabled"])
                #expect(blocks.first?.message == "시험 실행은 임시 폴더 아래 디스크 이미지에만 씁니다")
            } catch {
                Issue.record("다른 오류: \(error)")
            }
        }
        #expect(!FileManager.default.fileExists(atPath: base.path))
    }

    @Test("--allow-physical 인자는 모든 USB 쓰기 명령이 받는다")
    func allowPhysicalArgument() throws {
        #expect(try UsbCommands.restoreRequest(["usb-restore", "--volume", "/private/tmp/m", "--allow-physical"]).allowPhysical)
        #expect(try UsbCommands.recoverRequest(["usb-recover", "--volume", "/private/tmp/m", "--allow-physical"]).allowPhysical)
        #expect(!(try UsbCommands.recoverRequest(["usb-recover", "--volume", "/private/tmp/m"]).allowPhysical))
        #expect(try UsbCommands.exportRequest(["usb-export", "--volume", "/private/tmp/m", "--tracks", "1", "--allow-physical"]).allowPhysical)
        #expect(!(try UsbCommands.exportRequest(["usb-export", "--volume", "/private/tmp/m", "--tracks", "1"]).allowPhysical))
        #expect(try UsbCommands.editRequest(["usb-edit", "--volume", "/private/tmp/m", "--draft", "--allow-physical"]).allowPhysical)
        #expect(try UsbCommands.migrateRequest(["usb-migrate", "--volume", "/private/tmp/m", "--allow-physical"]).allowPhysical)
    }

    @Test("쓰기 허용·금지 목록 명령과 --allow-provisional은 없다(실물은 --allow-physical --confirm만)")
    func noListCommandsOrProvisionalFlag() {
        let names = UsbCommands.all.map(\.name)
        #expect(!names.contains("usb-allow"))
        #expect(!names.contains("usb-deny"))
        #expect(throws: UsageError.self) {
            _ = try UsbCommands.exportRequest(["usb-export", "--volume", "/private/tmp/m", "--tracks", "1", "--allow-provisional", "cueVariant"])
        }
        #expect(throws: UsageError.self) {
            _ = try UsbCommands.migrateRequest(["usb-migrate", "--volume", "/private/tmp/m", "--allow-provisional", "cueVariant"])
        }
    }

    @Test("라이브 라이브러리 거부 문구는 무엇을 줘야 하는지까지")
    func liveLibraryMessage() {
        #expect {
            _ = try UsbCommands.recoverRequest(["usb-recover", "--volume", NSHomeDirectory() + "/Library/Pioneer"])
        } throws: { error in
            (error as? UsbError)?.errorDescription == "rekordbox 라이브러리나 DJCrate 데이터 폴더는 USB가 아닙니다. USB 볼륨의 맨 위 폴더를 주세요"
        }
    }

    @Test("usb-restore·usb-recover 인자")
    func arguments() throws {
        let restore = try UsbCommands.restoreRequest(["usb-restore", "--volume", "/private/tmp/m", "--backup", "/private/tmp/b",
                                                      "--discard-device-changes", "--confirm", "DJCTEST", "--dry-run"])
        #expect(restore == .init(volume: "/private/tmp/m", backup: "/private/tmp/b", discardDeviceChanges: true, confirmName: "DJCTEST", dryRun: true))
        #expect(try UsbCommands.restoreRequest(["usb-restore", "--volume", "/private/tmp/m"])
            == .init(volume: "/private/tmp/m", backup: nil, discardDeviceChanges: false, confirmName: nil, dryRun: false))
        let recover = try UsbCommands.recoverRequest(["usb-recover", "--volume", "/private/tmp/m", "--discard-temp", "--confirm", "DJCTEST"])
        #expect(recover == .init(volume: "/private/tmp/m", discardTemp: true, confirmName: "DJCTEST"))
        #expect(try UsbCommands.recoverRequest(["usb-recover", "--volume", "/private/tmp/m"])
            == .init(volume: "/private/tmp/m", discardTemp: false, confirmName: nil))
        // 값이 없는 --confirm·--backup은 사용법
        #expect(throws: UsageError.self) { try UsbCommands.recoverRequest(["usb-recover", "--volume", "/private/tmp/m", "--confirm"]) }
        #expect(throws: UsageError.self) {
            try UsbCommands.recoverRequest(["usb-recover", "--volume", "/private/tmp/m", "--confirm", "--discard-temp"])
        }
        #expect(throws: UsageError.self) { try UsbCommands.restoreRequest(["usb-restore", "--volume", "/private/tmp/m", "--backup"]) }
        #expect(throws: UsageError.self) { try UsbCommands.restoreRequest(["usb-restore", "--volume", "--dry-run"]) }
    }

    @Test("마운트 지점이 아닌 임시 폴더는 파일 연산 없이 막는다(recover·restore 모두)")
    func scratchFolderNotMountPoint() async throws {
        let (paths, base) = paths()
        let folder = FileManager.default.temporaryDirectory.appending(path: "djc-usbcmd-root-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: base)
            try? FileManager.default.removeItem(at: folder)
        }
        #expect(await refusedCodes { try await UsbCommands.recover(["usb-recover", "--volume", folder.path, "--discard-temp"], paths: paths) }
            == ["notMountPoint"])
        #expect(await refusedCodes { try await UsbCommands.restore(["usb-restore", "--volume", folder.path], paths: paths) } == ["notMountPoint"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: base.path))
    }

    @Test("보고: USB 경로가 붙은 알림은 수로만, 그 밖 알림은 그대로")
    func reportLinesHidePaths() {
        var report = UsbWriteReport(outcome: .written, session: "abcdefgh")
        report.filesRemoved = 1
        report.notes = ["분석 파일이 다른 곡 것이라 지우지 않았습니다: PIONEER/USBANLZ/P001/0000ABCD/ANLZ0000.DAT",
                        "분석 파일이 다른 곡 것이라 지우지 않았습니다: PIONEER/USBANLZ/P002/0000ABCE/ANLZ0000.DAT",
                        "쓰기 전과 다른 파일이 남았습니다: Contents/Some Artist/Some Album/Some Song.mp3",
                        "마저 쓰지 못해 되돌렸습니다: staged file changed"]
        let lines = UsbCommands.reportLines(report)
        #expect(lines.contains("분석 파일이 다른 곡 것이라 지우지 않았습니다 (2개)"))
        #expect(lines.contains("쓰기 전과 다른 파일이 남았습니다 (1개)"))
        #expect(lines.contains("마저 쓰지 못해 되돌렸습니다: staged file changed"))
        #expect(!lines.contains { $0.contains("PIONEER/") || $0.contains("Contents/") })
        #expect(lines.first == "결과: 썼습니다")
    }

    @Test("보고: 저널이 없던 회복은 마저 썼다고 하지 않는다")
    func reportLinesNothingToRecover() {
        var report = UsbWriteReport(outcome: .recovered, session: "")
        report.notes = ["끝나지 않은 쓰기가 없습니다"]
        #expect(UsbCommands.reportLines(report) == ["결과: 회복할 쓰기가 없습니다", "끝나지 않은 쓰기가 없습니다"])
        #expect(UsbCommands.reportLines(UsbWriteReport(outcome: .recovered, session: "abcdefgh")).first == "결과: 끊긴 쓰기를 마저 썼습니다")
    }

    @Test("강제 분리 반복: 반복 번호의 복제본이 이미 있으면 건드리지 않고 멈춘다")
    func crashRunKeepsExistingClone() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "djc-crashrun-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let template = folder.appending(path: "k.img").path
        FileManager.default.createFile(atPath: template, contents: Data(count: 512))
        let clone = template + ".run-3.img"
        let leftover = Data("leftover".utf8)
        FileManager.default.createFile(atPath: clone, contents: leftover)
        let (paths, base) = paths()
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(throws: UsbError.self) {
            _ = try UsbImageLab.crashRun(index: 3, template: template, djc: "/nonexistent/djc", paths: paths, detachAfter: nil)
        }
        #expect(FileManager.default.contents(atPath: clone) == leftover)
    }

    @Test("usb-image seed는 마운트 지점을 위치 인자로 받지 않는다(--image·--from만)")
    func seedTakesNoMountPoint() async {
        await #expect(throws: UsageError.self) {
            try await UsbImageLab.image(["usb-image", "seed", "/private/tmp/x.img", "/private/tmp/mnt"])
        }
        await #expect(throws: UsageError.self) {
            try await UsbImageLab.image(["usb-image", "seed", "--image", "/private/tmp/x.img", "--from", "/private/tmp/from", "/private/tmp/mnt"])
        }
        await #expect(throws: UsageError.self) { try await UsbImageLab.image(["usb-image", "seed", "--image", "/private/tmp/x.img"]) }
    }

    @Test("lab 경로 인자는 임시 폴더 아래만", arguments: ["/Volumes/X", NSHomeDirectory() + "/Library/Pioneer/x.img", NSHomeDirectory()])
    func labPathsGoThroughScratchCheck(path: String) async {
        func refused(_ body: () async throws -> Void) async -> Bool {
            do { try await body(); return false } catch UsbError.pathRefused { return true } catch { return false }
        }
        #expect(await refused { try await UsbImageLab.tree(["usb-tree", path]) })
        #expect(await refused { try await UsbImageLab.writeCheck(["usb-write-check", "--volume", path]) })
        #expect(await refused { try await UsbImageLab.commitCrash(["usb-commit-crash", "--image", path, "--repeat", "1"]) })
        #expect(await refused { try await UsbImageLab.image(["usb-image", "create", path + "/new.img", "--size", "64m"]) })
        #expect(await refused { try await UsbImageLab.image(["usb-image", "attach", path, "--mount", "/private/tmp"]) })
        #expect(await refused { try await UsbImageLab.image(["usb-image", "seed", "--image", path, "--from", "/private/tmp"]) })
    }

    @Test("--slow는 시간만 늘리고 결과는 같다")
    func slowOnlyDelays() throws {
        let fast = UsbChangeSetFixture(), slow = UsbChangeSetFixture()
        defer { fast.remove(); slow.remove() }
        let fastReport = try fast.write(fast.exportChanges(audioSize: 1_500_000))
        let started = Date()
        let changes = slow.exportChanges(audioSize: 1_500_000)
        let slowReport = try UsbWriter.write(changes, root: slow.root, paths: slow.paths, guard: slow.writeGuard(),
                                             fileSystem: SlowUsbFileSystem(inner: slow.fileSystem(), delayMilliseconds: 5),
                                             ppthReader: UsbChangeSetFixture.ppthReader)
        let elapsed = Date().timeIntervalSince(started)
        #expect(slowReport.outcome == fastReport.outcome)
        #expect(slowReport.filesCreated == fastReport.filesCreated)
        #expect(slow.tree() == changes.target.mustExist.mapValues { $0.sha256 ?? "" })
        // rename·fsync·저널 쓰기마다 5ms: 적어도 수십 번은 잔다
        #expect(elapsed > 0.2)
    }

    @Test("합성 묶음: 이름이 _로 시작하는 파일·NFD 원본·중첩 새 폴더, 음원 합 64MiB 이상")
    func syntheticChangeSetShape() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "djc-synth-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let changes = try UsbSyntheticChanges.make(session: "abcdefgh", staging: folder)
        #expect(changes.copies.reduce(Int64(0)) { $0 + $1.size } >= 64 << 20)
        #expect(changes.copies.contains { ($0.destination as NSString).lastPathComponent.hasPrefix("_") })
        // Swift 문자열 ==는 NFC·NFD를 같게 보므로 바이트로 비교한다
        #expect(changes.copies.contains { Array($0.source.utf8) != Array($0.source.precomposedStringWithCanonicalMapping.utf8) })
        #expect(changes.copies.allSatisfy { Array($0.destination.utf8) == Array($0.destination.precomposedStringWithCanonicalMapping.utf8) })
        #expect(changes.databases.map(\.destination) == [UsbLayout.oneLibrary, UsbLayout.exportPdb, UsbLayout.exportExtPdb])
        #expect(changes.target.mustExist.count == changes.copies.count + changes.writes.count + changes.databases.count)
        #expect(changes.base == nil)
    }
}
