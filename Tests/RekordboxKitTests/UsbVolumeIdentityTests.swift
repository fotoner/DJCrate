import DJCDomain
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// 쓰는 도중 USB A가 빠지고 같은 이름의 USB B가 같은 마운트 지점에 붙는 경우.
/// 마운트 지점 문자열만 보면 B에 이어 쓰거나, A의 백업으로 B를 되돌리게 된다. 정체가 바뀌면 그 자리에서 멈추고 B에는 아무것도 쓰지 않는다.
/// 시험은 같은 임시 폴더를 "B"로 보고, 바뀐 순간의 트리와 그 뒤의 USB 연산을 본다.
@Suite("USB 쓰기 중 볼륨 바뀜")
struct UsbVolumeIdentityTests {
    /// 바꿔치기 흉내: 열어 둔 루트가 다른 볼륨이 됨(fd) 또는 DiskArbitration이 다른 UUID를 돌려줌(da)
    enum Swap: String, CaseIterable, CustomTestStringConvertible {
        case rootHandle, diskArbitration
        var testDescription: String { rawValue }
    }

    static let otherUUID = "00000000-0000-0000-0000-0000000000B2"
    static let mutating: Set<String> = ["makeDirectory", "writeNew", "copyDataNew", "rename", "remove", "removeDirectoryIfEmpty",
                                        "setModificationDate"]

    /// 바꿔치기를 한 번만 하고, 그때의 연산 기록 위치와 트리를 남긴다
    final class Swapper: @unchecked Sendable {
        let fixture: UsbChangeSetFixture
        let fs: FaultyUsbFileSystem
        let mode: Swap
        private(set) var index: Int?
        private(set) var tree: [String: String] = [:]

        init(_ fixture: UsbChangeSetFixture, _ fs: FaultyUsbFileSystem, _ mode: Swap) {
            self.fixture = fixture
            self.fs = fs
            self.mode = mode
        }

        var swapped: Bool { index != nil }

        /// skipCurrent: 지금 막 시작한 연산(실패를 주입한 연산)은 바꾸기 전 것으로 센다
        func swap(skipCurrent: Bool = false) {
            guard index == nil else { return }
            index = fs.calls.count + (skipCurrent ? 1 : 0)
            tree = fixture.tree()
            switch mode {
            case .rootHandle: fs.swapVolume()
            case .diskArbitration: fixture.volume.volumeUUID = UsbVolumeIdentityTests.otherUUID
            }
        }

        /// 바꿔치기 뒤 USB 쪽에서 무엇을 바꾼 연산
        func mutationsAfter() -> [String] {
            guard let index else { return [] }
            return fs.calls[index...].filter { call in
                !call.contains("mac:") && UsbVolumeIdentityTests.mutating.contains(String(call.split(separator: " ")[0]))
            }
        }
    }

    func isVolumeChanged(_ error: any Error) -> Bool {
        if case UsbError.volumeChanged = error { true } else { false }
    }

    func journal(_ fixture: UsbChangeSetFixture, key: String) -> UsbJournal? {
        if case let .open(journal) = UsbWriter.journalStatus(paths: fixture.paths, volumeKey: key) { return journal }
        if case let .closed(journal) = UsbWriter.journalStatus(paths: fixture.paths, volumeKey: key) { return journal }
        return nil
    }

    /// 파일마다는 붙잡은 루트로(빠진 볼륨의 fd는 죽는다), 묶음(음원 → 분석 → 아트워크 → 그 밖)마다는 볼륨 정보로 본다
    @Test("파일을 쓰는 도중 바뀌면 그 자리에서 멈추고 다른 볼륨에 쓰지도 되돌리지도 않는다", arguments: Swap.allCases)
    func changedDuringFiles(mode: Swap) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let key = fixture.volumeKey
        let fs = fixture.fileSystem()
        let swapper = Swapper(fixture, fs, mode)
        var written = 0, copied = 0
        fs.onOperation = { op, url in
            guard fs.relative(url) != nil else { return }
            if op == .writeNew { written += 1 }
            if op == .copyDataNew { copied += 1 }
            switch mode {
            // 분석 파일 묶음 한가운데: 쓰기 연산 자체가 아니라 그 다음 확인 사이에 바뀐다(마운트 지점 이름은 그대로)
            case .rootHandle: if op == .mountedOn, written >= 2 { swapper.swap() }
            // 음원 묶음을 다 쓴 뒤(마지막 폴더 fsync), 분석 파일 묶음 전
            case .diskArbitration: if op == .syncDirectory, copied == UsbChangeSetFixture.exportAudio.count { swapper.swap() }
            }
        }
        var thrown: (any Error)?
        do { try fixture.write(fixture.exportChanges(), fileSystem: fs) } catch { thrown = error }
        #expect(swapper.swapped)
        #expect(thrown.map(isVolumeChanged) == true)
        #expect(swapper.mutationsAfter().isEmpty)
        #expect(fixture.tree() == swapper.tree)
        // 되돌리지 않았다: 저널은 열린 채로 처음 USB를 기다린다
        let open = try #require(journal(fixture, key: key))
        #expect(!open.isClosed)
        #expect(open.state != .restorePending)
    }

    @Test("단계 사이(파일 뒤 DB 교체 전)에 바뀌면 DB를 교체하지 않는다", arguments: Swap.allCases)
    func changedBetweenStages(mode: Swap) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let key = fixture.volumeKey
        let fs = fixture.fileSystem()
        let swapper = Swapper(fixture, fs, mode)
        let options = UsbWriteOptions(pauseAfter: .files, pauseHandler: { _ in swapper.swap() })
        var thrown: (any Error)?
        do { try fixture.write(fixture.exportChanges(), fileSystem: fs, options: options) } catch { thrown = error }
        #expect(thrown.map(isVolumeChanged) == true)
        #expect(swapper.mutationsAfter().isEmpty)
        #expect(fixture.tree() == swapper.tree)
        for database in UsbChangeSetFixture.databasePaths { #expect(!fixture.exists(database)) }
        #expect(journal(fixture, key: key)?.isClosed == false)
    }

    @Test("실패 뒤 되돌리기 직전에 바뀌면 처음 USB의 백업으로 다른 볼륨을 덮지 않는다", arguments: Swap.allCases)
    func changedBeforeRollback(mode: Swap) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.seedEdit()
        let key = fixture.volumeKey
        let changes = try fixture.editChanges()
        let fs = fixture.fileSystem()
        let swapper = Swapper(fixture, fs, mode)
        // DB 교체 중 실패 → H. 실패한 그 연산 직전에 바뀐다
        fs.failAt = (operation: .rename, occurrence: 4, mode: .error)
        var renames = 0
        fs.onOperation = { op, url in
            guard fs.relative(url) != nil, op == .rename else { return }
            renames += 1
            if renames == 4 { swapper.swap(skipCurrent: true) }
        }
        var thrown: (any Error)?
        do { try fixture.write(changes, fileSystem: fs) } catch { thrown = error }
        #expect(swapper.swapped)
        #expect(thrown.map(isVolumeChanged) == true)
        #expect(swapper.mutationsAfter().isEmpty)
        #expect(fixture.tree() == swapper.tree)
        let open = try #require(journal(fixture, key: key))
        #expect(!open.isClosed)
        #expect(open.state != .restorePending)
    }

    /// 쓰기 도중 크래시로 열린 저널을 남긴다
    func crashedWrite(_ fixture: UsbChangeSetFixture) throws {
        let fs = fixture.fileSystem()
        fs.failAt = (operation: .rename, occurrence: 3, mode: .crash)
        #expect(throws: (any Error).self) { try fixture.write(fixture.exportChanges(), fileSystem: fs) }
        #expect(fixture.journal()?.isClosed == false)
    }

    @Test("회복을 시작한 뒤 바뀌면 USB 파일을 건드리지 않는다", arguments: Swap.allCases)
    func changedDuringRecover(mode: Swap) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        try crashedWrite(fixture)
        let key = fixture.volumeKey
        let before = try #require(journal(fixture, key: key))
        let fs = fixture.fileSystem()
        let swapper = Swapper(fixture, fs, mode)
        var mounts = 0
        fs.onOperation = { op, url in
            guard fs.relative(url) != nil, op == .mountedOn else { return }
            mounts += 1
            // 첫 번째는 열 때(가드와 무관한 확인), 그 뒤는 회복의 확인
            if mounts == 2 { swapper.swap() }
        }
        var thrown: (any Error)?
        do { _ = try fixture.recover(fileSystem: fs, discardTemp: true) } catch { thrown = error }
        #expect(swapper.swapped)
        #expect(thrown.map(isVolumeChanged) == true)
        #expect(swapper.mutationsAfter().isEmpty)
        #expect(fixture.tree() == swapper.tree)
        #expect(journal(fixture, key: key)?.state == before.state)
    }

    @Test("되돌리기(usb-restore)를 시작한 뒤 바뀌면 처음 USB의 백업을 다른 볼륨에 쓰지 않는다", arguments: Swap.allCases)
    func changedDuringRestore(mode: Swap) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        try fixture.write(fixture.exportChanges())
        let fs = fixture.fileSystem()
        let swapper = Swapper(fixture, fs, mode)
        var mounts = 0
        fs.onOperation = { op, url in
            guard fs.relative(url) != nil, op == .mountedOn else { return }
            mounts += 1
            if mounts == 2 { swapper.swap() }
        }
        var thrown: (any Error)?
        do { _ = try fixture.restore(fileSystem: fs) } catch { thrown = error }
        #expect(swapper.swapped)
        #expect(thrown.map(isVolumeChanged) == true)
        #expect(swapper.mutationsAfter().isEmpty)
        #expect(fixture.tree() == swapper.tree)
    }

    @Test("앱이 확인한 볼륨 UUID와 지금 볼륨이 다르면 쓰기·회복·되돌리기 모두 USB 파일 연산 없이 막는다")
    func expectedUUIDMismatchRefusesAtStart() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let changes = fixture.exportChanges()
        let actions: [(FaultyUsbFileSystem) throws -> Void] = [
            { _ = try fixture.write(changes, fileSystem: $0, options: UsbWriteOptions(expectedVolumeUUID: Self.otherUUID)) },
            { _ = try fixture.recover(fileSystem: $0, discardTemp: true, expectedVolumeUUID: Self.otherUUID) },
            { _ = try fixture.restore(fileSystem: $0, expectedVolumeUUID: Self.otherUUID) },
        ]
        for action in actions {
            let fs = fixture.fileSystem()
            var codes: [String] = []
            do { try action(fs) } catch let UsbError.writeRefused(blocks) { codes = blocks.map(\.code) } catch {
                Issue.record("다른 오류: \(error)")
            }
            #expect(codes == ["volumeChanged"])
            #expect(fs.calls == ["mountedOn ."])
        }
        #expect(fixture.tree().isEmpty)
        #expect(fixture.journal() == nil)
        // 같은 UUID(대소문자 무관)면 쓴다
        let report = try fixture.write(changes, options: UsbWriteOptions(expectedVolumeUUID: fixture.volumeKey.lowercased()))
        #expect(report.outcome == .written)
    }

    @Test("바뀌지 않으면 열어 둔 루트 확인은 쓰기를 막지 않는다(실제 POSIX 파일 시스템)")
    func posixHoldSeesSameVolume() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "djc-hold-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let hold = try PosixUsbFileSystem().holdVolume(folder)
        #expect(hold.isSameVolume())
        hold.release()
        #expect(!hold.isSameVolume())
    }

    @Test("볼륨이 바뀌었다는 오류는 처음 USB를 다시 꽂고 회복하라고 안내한다")
    func volumeChangedMessage() {
        let error = UsbError.volumeChanged(volumeName: "DJCVOL")
        #expect(error.description.contains("DJCVOL"))
        #expect(error.localizedDescription.contains("처음"))
        #expect(error.localizedDescription.contains("djc usb-recover"))
    }
}
