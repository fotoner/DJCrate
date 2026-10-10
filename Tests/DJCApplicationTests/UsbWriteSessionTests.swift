import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import Testing

/// 쓰기 세션이 출력 포트로 내보낸 흐름 상태를 차례로 적는 가짜 화면
@MainActor
final class UsbWriteSessionScreen {
    let session = UsbWriteSession()
    private(set) var states: [UsbWriteSessionState] = []

    init() {
        session.output = UsbWriteSessionOutput(changed: { [weak self] in self?.states.append($0) })
    }
}

@MainActor
@Suite("USB 쓰기 세션(잠금·진행·지난 쓰기)")
struct UsbWriteSessionTests {
    let first = FakeUsbVolume.diskImageFAT32(name: "B1", uuid: "00000000-0000-0000-0000-0000000000B1")
    let second = FakeUsbVolume.diskImageFAT32(name: "B2", uuid: "00000000-0000-0000-0000-0000000000B2")

    @Test("같은 볼륨은 두 번 잠그지 않고, 거절한 잠금은 상태를 내보내지 않는다")
    func sameVolumeTwice() {
        let screen = UsbWriteSessionScreen()
        let session = screen.session
        let flag = session.begin(first, title: "합성 미리 보기")
        #expect(flag != nil)
        let locked = UsbWriteSessionState(busyVolumes: [first.usbKey],
                                          activeWrite: UsbActiveWrite(volumeKey: first.usbKey, volumeName: "B1", title: "합성 미리 보기",
                                                                      cancellable: true, progress: nil))
        #expect(session.state == locked)
        #expect(screen.states == [locked])

        #expect(session.begin(first, title: "두 번째") == nil)
        #expect(session.state == locked && screen.states.count == 1)

        session.end(first.usbKey)
        #expect(session.state == UsbWriteSessionState())
        #expect(screen.states.last == UsbWriteSessionState())
        // 풀린 뒤에는 다시 잠근다
        #expect(session.begin(first, title: "다시") != nil)
    }

    @Test("한 볼륨에 쓰는 동안 다른 볼륨도 잠그지 않는다(앱은 한 번에 한 볼륨에만 쓴다)")
    func otherVolumeWhileWriting() {
        let screen = UsbWriteSessionScreen()
        let session = screen.session
        #expect(session.begin(first, title: "첫 볼륨") != nil)
        #expect(session.begin(second, title: "둘째 볼륨") == nil)
        #expect(session.state.busyVolumes == [first.usbKey] && session.state.activeWrite?.volumeKey == first.usbKey)
        #expect(screen.states.count == 1)
        // 다른 볼륨의 끝은 지금 쓰기를 풀지 않는다
        session.end(second.usbKey)
        #expect(session.state.activeWrite?.volumeKey == first.usbKey && screen.states.count == 1)
        session.end(first.usbKey)
        #expect(session.begin(second, title: "둘째 볼륨") != nil)
        #expect(session.state.busyVolumes == [second.usbKey])
    }

    @Test("제목·진행은 지금 쓰는 볼륨의 것만 받고, 바뀔 때마다 상태를 내보낸다")
    func progressForActiveVolumeOnly() {
        let screen = UsbWriteSessionScreen()
        let session = screen.session
        _ = session.begin(first, title: "합성 미리 보기")
        let files = UsbProgress(phase: .files, completedItems: 1, totalItems: 4, cancellable: true)
        session.report(files, for: first.usbKey)
        #expect(session.state.activeWrite?.progress == files)
        session.report(UsbProgress(phase: .commit, cancellable: false), for: second.usbKey)
        session.setTitle("다른 볼륨", for: second.usbKey)
        #expect(session.state.activeWrite?.progress == files && session.state.activeWrite?.title == "합성 미리 보기")
        // 단계가 바뀌면 진행을 지운다
        session.setTitle("합성 쓰기", for: first.usbKey)
        #expect(session.state.activeWrite?.title == "합성 쓰기" && session.state.activeWrite?.progress == nil)
        #expect(screen.states.map { $0.activeWrite?.progress } == [nil, files, nil])
        #expect(screen.states.map { $0.activeWrite?.title } == ["합성 미리 보기", "합성 미리 보기", "합성 쓰기"])
    }

    @Test("취소는 취소를 받는 일에서 DB 교체 전까지만 받는다")
    func cancelBeforeCommitOnly() throws {
        let session = UsbWriteSession()
        let flag = try #require(session.begin(first, title: "합성 쓰기"))
        session.report(UsbProgress(phase: .commit, cancellable: false), for: first.usbKey)
        session.cancel()
        #expect(!flag.isSet)
        session.report(UsbProgress(phase: .files, cancellable: true), for: first.usbKey)
        session.cancel()
        #expect(flag.isSet)
        session.end(first.usbKey)

        let recovery = try #require(session.begin(first, title: "합성 회복", cancellable: false))
        session.cancel()
        #expect(!recovery.isSet)
    }

    @Test("옮기기 백업·막힘은 상태로 내보내고, 다시 미리 보기용 지난 쓰기 기록은 내보내지 않는다")
    func migrationStateAndRecords() {
        let screen = UsbWriteSessionScreen()
        let session = screen.session
        let key = first.usbKey, backup = URL(filePath: "/private/tmp/djc-fixture/usb-backups/B1/m1")
        session.migrationBackups[key] = backup
        session.migrationBlockReasons[key] = "합성 막힘"
        #expect(screen.states.map(\.migrationBackups) == [[key: backup], [key: backup]])
        #expect(screen.states.last?.migrationBlockReasons == [key: "합성 막힘"])
        // 같은 값을 다시 넣으면 내보내지 않는다
        session.migrationBlockReasons[key] = "합성 막힘"
        #expect(screen.states.count == 2)

        session.lastMigrations.insert(key)
        session.lastExports[key] = UsbExportJob(database: URL(filePath: "/private/tmp/djc-fixture/m.db"),
                                                share: URL(filePath: "/private/tmp/djc-fixture/share"), volume: first,
                                                selection: .playlists(["10"]), formats: UsbFormat.defaultSet, snapshotTime: nil)
        #expect(screen.states.count == 2)
        #expect(session.lastMigrations == [key] && session.lastExports[key] != nil)

        session.migrationBackups[key] = nil
        #expect(screen.states.last?.migrationBackups == [:] && session.state.migrationBlockReasons == [key: "합성 막힘"])
    }
}
