import DiskArbitration
import Foundation
import Testing
@testable import djc

@Suite("USB 마운트 막기 실험")
struct UsbHoldTests {
    func disk(_ bsd: String? = "disk10s1", isInternal: Bool = false, name: String? = "OPUS") -> UsbHoldPolicy.Disk {
        .init(bsdName: bsd, isInternal: isInternal, volumeName: name)
    }

    @Test func 켠_뒤_꽂힌_외장_디스크는_막는다() {
        #expect(UsbHoldPolicy(existing: ["disk0", "disk0s1"]).holds(disk()))
    }

    @Test func 켜기_전부터_붙어_있던_디스크는_두다() {
        // 이미 쓰고 있던 USB를 사용자가 다시 마운트하는 것까지 막지 않는다.
        #expect(!UsbHoldPolicy(existing: ["disk10", "disk10s1"]).holds(disk()))
    }

    @Test func 뺐다가_같은_이름으로_다시_나타나면_막는다() {
        // 켤 때 꽂혀 있던 USB를 빼고 시험 USB를 꽂으면 macOS가 같은 disk 번호를 다시 줄 수 있다.
        var policy = UsbHoldPolicy(existing: ["disk10", "disk10s1"])
        policy.forget("disk10s1")
        #expect(policy.holds(disk()))
    }

    @Test func 내장_디스크는_두다() {
        #expect(!UsbHoldPolicy(existing: []).holds(disk(isInternal: true)))
    }

    @Test func 이름을_모르면_막는다() {
        // 증거를 지키는 쪽으로 기운다. 잘못 막아도 이 명령을 끝내면 다시 마운트할 수 있다.
        #expect(UsbHoldPolicy(existing: []).holds(disk(nil)))
    }

    @Test func 이름_접두어를_주면_맞는_볼륨만_막는다() {
        let policy = UsbHoldPolicy(existing: [], namePrefix: "DJCHOLD")
        #expect(policy.holds(disk(name: "DJCHOLDM")))
        #expect(!policy.holds(disk(name: "OPUS")))
        #expect(!policy.holds(disk(name: nil)))
    }

    @Test func DA_설명에서_장치_이름과_내장_여부를_읽는다() {
        let description: [String: Any] = [
            kDADiskDescriptionMediaBSDNameKey as String: "disk10s1",
            kDADiskDescriptionDeviceInternalKey as String: false,
            kDADiskDescriptionVolumeNameKey as String: "OPUS",
        ]
        let read = UsbHoldPolicy.Disk(description: description)
        #expect(read.bsdName == "disk10s1" && read.isInternal == false && read.volumeName == "OPUS")
        // 내장 여부가 없으면 외장으로 본다(막는 쪽).
        #expect(UsbHoldPolicy.Disk(description: [:]).isInternal == false)
    }

    @Test func 원본_뜨기_안내는_원시_장치에서_읽는다() {
        // 실물 USB 원시 장치는 root만 읽는다. authopen은 터미널 sudo 없이 인증 창으로 연다(2026-09-27 실물 확인).
        let lines = UsbHoldPolicy.imagingHint(wholeDisk: "disk10", readable: false)
        #expect(lines.contains { $0.contains("/usr/libexec/authopen /dev/rdisk10 > ") })
        #expect(!lines.contains { $0.contains("sudo") })
        #expect(lines.contains { $0.contains("diskutil eject disk10") })
        let readable = UsbHoldPolicy.imagingHint(wholeDisk: "disk10", readable: true)
        #expect(readable.contains { $0.contains("dd if=/dev/rdisk10 of=") })
        #expect(!readable.contains { $0.contains("authopen") })
    }
}
