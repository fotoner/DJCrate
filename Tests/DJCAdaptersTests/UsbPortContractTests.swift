import DJCAdapters
import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import PortTestKit
import RekordboxKit
import Testing

/// USB 포트의 계약(실제 구현): 가짜(`UsbDraftFiles.memory`)에 DJCApplicationTests가 돌리는 같은 계약 함수(PortTestKit)를 돌린다
@Suite("USB 포트 계약")
struct UsbPortContractTests {
    @Test("초안 파일: 실제 구현(임시 폴더)")
    func draftFilesLive() throws {
        let folder = try TemporaryFolder()
        try usbDraftFilesContract(.live(directory: folder.url.appending(path: "usb-drafts")))
    }
}

/// 가짜 포트(DJCApplicationTests `FakeUsbPorts`)가 기대는 실제 구현의 약속. 실제가 바뀌면 가짜도 함께 바꿔야 한다
@Suite("USB 포트 실제 구현의 약속")
struct UsbPortAssumptionTests {
    @Test("이 Mac의 일: 없는 것 지우기는 넘어가고, 없는 폴더의 이름은 nil, 임시 폴더는 디스크 이미지 자리이며, 실제 master.db는 늘 라이브")
    func deviceAssumptions() throws {
        let folder = try TemporaryFolder()
        let device = UsbDevice.live()
        let missing = folder.url.appending(path: "없음")
        device.remove(missing)
        #expect(!device.exists(missing) && device.names(missing) == nil)
        #expect(device.isScratchMount(folder.url.path))
        #expect(!device.isScratchMount("/Volumes/DJCPHYS"))
        #expect(device.isLiveDatabase(LibrarySnapshot.realRekordboxDirectory.appending(path: "master.db")))
        #expect(device.isLiveDatabase(LibrarySnapshot.rekordboxDirectory.appending(path: "master.db")))
        let copy = folder.url.appending(path: "copy.db")
        try Data("합성".utf8).write(to: copy)
        #expect(!device.isLiveDatabase(copy))
        // 더 거부할 목록은 덧붙이기만 한다
        #expect(UsbDevice.live(extraLiveDatabases: [copy]).isLiveDatabase(copy))
        // 확인한 버전 판정은 쓰기 관문과 같다
        #expect(device.isVerified("7.2.18") && !device.isVerified("7.1.0") && !device.isVerified(nil))
        // Mac 쪽 폴더는 주인만 읽는 폴더로 만든다
        let paths = UsbWritePaths(backups: folder.url.appending(path: "b"), sessions: folder.url.appending(path: "s"), staging: folder.url.appending(path: "t"))
        try device.makeFolders(paths, [folder.url.appending(path: "c")])
        for url in [paths.backups, paths.sessions, paths.staging, folder.url.appending(path: "c")] {
            let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
            #expect(mode == 0o700)
        }
    }

    @Test("쓰기 절차: 저널 없음·읽지 못함·닫힘, 백업 없음, DB 없는 USB의 지문은 비어 있다")
    func writerAssumptions() throws {
        let folder = try TemporaryFolder()
        let writer = UsbLibraryEngine.Writer.live(fileSystem: PosixUsbFileSystem())
        let paths = UsbWritePaths(backups: folder.url.appending(path: "b"), sessions: folder.url.appending(path: "s"), staging: folder.url.appending(path: "t"))
        #expect(writer.journalStatus(paths, "K") == .missing)
        try FileManager.default.createDirectory(at: paths.sessions, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: paths.sessions.appending(path: "K.json"))
        #expect(writer.journalStatus(paths, "K") == .corrupt)
        #expect(writer.backups(paths, "K").isEmpty)
        let usb = folder.url.appending(path: "usb")
        try FileManager.default.createDirectory(at: usb, withIntermediateDirectories: true)
        #expect(try writer.databaseFingerprint(usb).files.isEmpty)
    }

    @Test("동기화 선택 관문: 실제 규칙은 확인한 계약에서 한 형식만 있는 선택 파일만 막는다")
    func syncGateAssumptions() {
        let gate = UsbSyncSelectionGate.live
        #expect(gate.productionBlock() == UsbSyncSelectionStage.productionBlock)
        #expect(gate.gateBlock([:], UsbFormat.defaultSet) == nil)
        #expect(gate.gateBlock([.deviceLibrary: Data("x".utf8)], UsbFormat.defaultSet)?.code == "syncSelectionPartialFiles")
        #expect(gate.draftBlock(.enabledOnly(localDBID: 1, enabled: true, baseFiles: [:])) == nil)
    }
}
