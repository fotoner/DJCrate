import DiskArbitration
import Foundation
import IOKit

/// 강제로 뽑은 USB를 다시 꽂을 때, macOS가 마운트하며 FAT를 고치기 전에 원본을 뜨려고 쓰는 실험(#44).
/// 마운트는 DiskArbitration 승인 단계에서 거부한다. 자동 검사·수리는 승인 뒤에 돌아서 함께 막힌다.
enum UsbLab {
    static let all: [Command] = [
        Command("usb-hold", "[--name <볼륨 이름 접두어>] [--minutes N]",
                "켠 뒤 꽂은 외장 디스크의 마운트를 막는다. macOS가 FAT를 고치기 전에 원시 이미지를 뜨려고 쓴다(끝내면 막기도 끝남)",
                UsbLab.hold),
    ]

    static func hold(_ args: [String]) async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let minutes = Double(value(after: "--minutes", in: args) ?? "") ?? 60
        let holder = UsbHolder(policy: UsbHoldPolicy(existing: currentMediaNames(), namePrefix: value(after: "--name", in: args)))
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            FileHandle.standardError.write(Data("DiskArbitration에 연결하지 못해 막지 않았다. 다시 실행하세요\n".utf8))
            exit(1)
        }
        let context = Unmanaged.passUnretained(holder).toOpaque()
        DARegisterDiskDisappearedCallback(session, nil, { disk, context in
            guard let context, let name = UsbHoldPolicy.Disk(disk).bsdName else { return }
            Unmanaged<UsbHolder>.fromOpaque(context).takeUnretainedValue().policy.forget(name)
        }, context)
        DARegisterDiskMountApprovalCallback(session, nil, { disk, context in
            guard let context else { return nil }
            return Unmanaged<UsbHolder>.fromOpaque(context).takeUnretainedValue().approve(disk)
        }, context)
        DASessionSetDispatchQueue(session, holder.queue)
        print("\(UsbHolder.stamp()) 막는 중(\(Int(minutes))분): 지금부터 꽂는 외장 디스크는 마운트하지 않는다. 끝내려면 Ctrl-C")
        try await Task.sleep(for: .seconds(minutes * 60))
        DASessionSetDispatchQueue(session, nil)
        print("\(UsbHolder.stamp()) 시간이 다 돼 막기를 끝낸다")
        withExtendedLifetime(holder) {}
    }

    /// 켤 때 이미 있는 저장 장치 이름(disk0, disk0s1 …). 읽지 못하면 비워 새 장치처럼 막는다.
    static func currentMediaNames() -> Set<String> {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMedia"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var names: Set<String> = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            if let name = IORegistryEntryCreateCFProperty(service, kIOBSDNameKey as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String {
                names.insert(name)
            }
            IOObjectRelease(service)
        }
        return names
    }
}

/// 어떤 디스크의 마운트를 막을지. 켤 때 이미 있던 장치와 내장 디스크는 두고, 새로 나타난 외장 디스크를 막는다.
struct UsbHoldPolicy: Sendable {
    struct Disk: Equatable {
        var bsdName: String?
        var isInternal: Bool
        var volumeName: String?
        var detail = ""

        init(bsdName: String?, isInternal: Bool, volumeName: String?) {
            self.bsdName = bsdName
            self.isInternal = isInternal
            self.volumeName = volumeName
        }

        init(description: [String: Any]) {
            bsdName = description[kDADiskDescriptionMediaBSDNameKey as String] as? String
            // 내장 여부를 모르면 외장으로 본다(막는 쪽).
            isInternal = description[kDADiskDescriptionDeviceInternalKey as String] as? Bool ?? false
            volumeName = description[kDADiskDescriptionVolumeNameKey as String] as? String
            detail = [kDADiskDescriptionVolumeKindKey, kDADiskDescriptionDeviceProtocolKey]
                .compactMap { description[$0 as String] as? String }.joined(separator: " · ")
        }

        init(_ disk: DADisk) {
            self.init(description: DADiskCopyDescription(disk) as? [String: Any] ?? [:])
        }
    }

    private(set) var existing: Set<String>
    let namePrefix: String?

    init(existing: Set<String>, namePrefix: String? = nil) {
        self.existing = existing
        self.namePrefix = namePrefix
    }

    /// 켤 때 있던 장치가 빠지면 잊는다. 새 USB가 같은 disk 번호를 받아도 막히게.
    mutating func forget(_ bsdName: String) {
        existing.remove(bsdName)
    }

    func holds(_ disk: Disk) -> Bool {
        guard !disk.isInternal else { return false }
        if let name = disk.bsdName, existing.contains(name) { return false }
        guard let namePrefix else { return true }
        return disk.volumeName?.hasPrefix(namePrefix) ?? false
    }

    /// 실물 USB 원시 장치는 root만 읽는다. authopen은 터미널 sudo 없이 관리자 인증 창으로 연다.
    static func imagingHint(wholeDisk: String, readable: Bool) -> [String] {
        [
            readable
                ? "  원본 뜨기: dd if=/dev/r\(wholeDisk) of=<파일>.img bs=1m"
                : "  원본 뜨기: /usr/libexec/authopen /dev/r\(wholeDisk) > <파일>.img   (관리자 인증 창이 뜬다. 앞부분만: | head -c 536870912)",
            "  다 떴으면: diskutil eject \(wholeDisk) 한 뒤 이 명령을 끝낸다",
        ]
    }
}

/// DA 콜백은 모두 `queue` 한 줄에서 불려 상태를 따로 잠그지 않는다.
final class UsbHolder: @unchecked Sendable {
    let queue = DispatchQueue(label: "djc.usb-hold")
    var policy: UsbHoldPolicy
    private var hinted: Set<String> = []

    init(policy: UsbHoldPolicy) {
        self.policy = policy
    }

    /// 막을 디스크면 거부를 돌려준다. 이 프로세스가 승인 도중 죽으면 DA가 마운트를 진행하므로 멈출 수 있는 연산을 쓰지 않는다.
    func approve(_ disk: DADisk) -> Unmanaged<DADissenter>? {
        let info = UsbHoldPolicy.Disk(disk)
        guard policy.holds(info) else { return nil }
        let whole = DADiskCopyWholeDisk(disk).flatMap { UsbHoldPolicy.Disk($0).bsdName } ?? info.bsdName ?? "?"
        print("\(Self.stamp()) 막음: \(info.bsdName ?? "?") \"\(info.volumeName ?? "")\" \(info.detail)")
        if hinted.insert(whole).inserted {
            UsbHoldPolicy.imagingHint(wholeDisk: whole, readable: access("/dev/r\(whole)", R_OK) == 0).forEach { print($0) }
        }
        let dissenter = DADissenterCreate(kCFAllocatorDefault, DAReturn(truncatingIfNeeded: kDAReturnNotPermitted),
                                          "djc lab usb-hold" as CFString)
        return Unmanaged.passRetained(dissenter)
    }

    static func stamp() -> String {
        Date.now.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
    }
}
