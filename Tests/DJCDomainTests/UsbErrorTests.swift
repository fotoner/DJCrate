import DJCDomain
import Foundation
import Testing

@Suite("USB 오류 문구")
struct UsbErrorTests {
    static let all: [UsbError] = [
        .writeRefused([UsbBlock(code: "readOnly", scope: .volume, message: "USB가 읽기 전용으로 연결됐습니다. 잠금 스위치를 풀고 다시 연결하세요")]),
        .writeRefused([]),
        .writeRolledBack(reason: "SQLITE_CORRUPT"),
        .planCheckFailed(detail: "SQLITE onelibrary reread"),
        .restoreFailed(reason: "SQLITE_CORRUPT", restoreError: "EIO", backup: "/fixture/backup"),
        .restorePending(reason: "rekordbox"),
        .recoveryNeeded(volumeName: "DJCVOL"),
        .readFailed(detail: "opendir PIONEER: EIO"),
        .formatUnsupported(detail: "DBVersion 7000"),
        .diskImageToolFailed(detail: "hdiutil exit 1"),
        .pathRefused(path: "/fixture/outside.img", reason: "outsideScratch"),
        .volumeLost(volumeName: "DJCVOL"),
        .cancelled,
    ]

    @Test("앱 문구에는 경로·볼륨 이름·기술 정보가 없다", arguments: all)
    func appMessageHidesDetail(error: UsbError) {
        let message = error.localizedDescription
        #expect(!message.isEmpty)
        for detail in ["/fixture", "DJCVOL", "SQLITE", "EIO", "hdiutil", "DBVersion"] {
            #expect(!message.contains(detail), "\(detail)")
        }
    }

    @Test("CLI 상세에는 경로·볼륨 이름·기술 정보가 있다")
    func cliDescriptionKeepsDetail() {
        #expect(UsbError.pathRefused(path: "/fixture/outside.img", reason: "outsideScratch").description.contains("/fixture/outside.img"))
        #expect(UsbError.pathRefused(path: "/fixture/outside.img", reason: "outsideScratch").localizedDescription
            == "임시 폴더 아래의 경로만 쓸 수 있습니다(outsideScratch)")
        #expect(UsbError.volumeLost(volumeName: "DJCVOL").description.contains("DJCVOL"))
        #expect(UsbError.volumeLost(volumeName: "DJCVOL").localizedDescription.contains("djc usb-recover"))
        #expect(UsbError.restoreFailed(reason: "SQLITE_CORRUPT", restoreError: "EIO", backup: "/fixture/backup").description.contains("/fixture/backup"))
        #expect(UsbError.readFailed(detail: "opendir PIONEER: EIO").description.contains("opendir PIONEER: EIO"))
        #expect(UsbError.planCheckFailed(detail: "onelibrary reread: key.onlyRight×1").description.contains("key.onlyRight×1"))
        let refused = UsbError.writeRefused([UsbBlock(code: "notFAT32", scope: .volume, message: "막힘")])
        #expect(refused.description.contains("[notFAT32] 막힘"))
        #expect(refused.localizedDescription == "막힘")
    }

    @Test("CLI 상세는 확인 안 된 규칙의 이름을 함께 적는다")
    func cliDescriptionNamesProvisionalRule() {
        // 규칙 이름을 CLI에서 볼 수 있어야 한다. 앱 문구에는 넣지 않는다.
        let block = UsbBlock(code: "provisional", scope: .volume, message: "막힘", rule: .cueVariant)
        let refused = UsbError.writeRefused([block])
        #expect(refused.description.contains("[provisional:cueVariant] 막힘"))
        #expect(refused.localizedDescription == "막힘")
    }
}
