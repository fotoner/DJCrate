import DJCAdapters
import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import PortTestKit
import Testing

/// 보존 기록 파일 포트(`UsbHistoryFiles.live`, #43)의 계약: 임시 폴더의 `usb-histories/`에 가짜(`MemoryUsbHistoryFiles`)와 같은 계약 함수를 돌리고,
/// 손상·읽기 실패 알림이 포트 값으로 그대로 오는지 본다. 파일 모양·내구 쓰기는 DJCStorageTests의 `UsbHistoryStoreTests`가 본다.
@Suite("USB 재생 기록 보존 파일 포트 계약(실제)")
struct UsbHistoryFilesContractTests {
    @Test func 실제_구현() throws {
        let folder = try TemporaryFolder(prefix: "djc-usb-history-files")
        try usbHistoryFilesContract(.live(directory: folder.url.appending(path: "usb-histories"), home: folder.url.appending(path: "home")))
    }

    @Test func 손상_파일은_옮겼다고_읽지_못한_파일은_그대로_두었다고_알린다() throws {
        let folder = try TemporaryFolder(prefix: "djc-usb-history-damaged")
        let directory = folder.url.appending(path: "usb-histories"), home = folder.url.appending(path: "home")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let broken = ArchivedHistory.idPrefix + "broken.json", blocked = ArchivedHistory.idPrefix + "blocked.json"
        try Data("{".utf8).write(to: directory.appending(path: broken))
        // 권한 시험은 실행 계정에 따라 달라서 JSON 이름의 폴더로 읽기 실패를 만든다
        try FileManager.default.createDirectory(at: directory.appending(path: blocked), withIntermediateDirectories: true)
        let loaded = UsbHistoryFiles.live(directory: directory, home: home).load()
        #expect(loaded.histories.isEmpty)
        #expect(loaded.damaged == [broken])
        #expect(loaded.unreadable == [blocked])
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: broken).path))
    }
}
