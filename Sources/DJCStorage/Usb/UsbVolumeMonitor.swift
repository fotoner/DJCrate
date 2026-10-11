import DJCDomain
import DiskArbitration
import Foundation
import RekordboxKit

/// 연결된 USB 볼륨 목록을 DiskArbitration 알림(나타남·마운트 경로 바뀜·사라짐)으로 지켜본다(앱 사이드바).
/// 볼륨 안의 파일은 열지 않고 볼륨 정보(`UsbVolumes.info`)만 읽는다. 알림 해석은 순수 함수(`apply`·`mountPoints`)다.
public final class UsbVolumeMonitor: @unchecked Sendable {
    /// DA 설명 사전 중 목록 판정에 쓰는 칸
    struct Disk: Sendable, Hashable {
        /// DAVolumePath(마운트 지점). 마운트 전·해제 뒤에는 nil
        var volumePath: String?
        /// DADeviceInternal. 키가 없으면 nil(디스크 이미지가 아니면 내장으로 본다)
        var isInternal: Bool?
        var isNetwork: Bool
        /// DADeviceModel "Disk Image"
        var isDiskImage: Bool

        init(description: [String: Any]) {
            let path: String? = switch description["DAVolumePath"] {
            case let url as URL: url.path(percentEncoded: false)
            case let text as String: text
            default: nil
            }
            // "/Volumes/X/"처럼 끝 "/"가 붙어 온다
            volumePath = path.map { $0.count > 1 && $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
            isInternal = description["DADeviceInternal"] as? Bool
            isNetwork = description["DAVolumeNetwork"] as? Bool ?? false
            isDiskImage = description["DADeviceModel"] as? String == UsbVolumes.diskImageModel
        }
    }

    /// DA 알림 하나
    enum Event {
        case appeared(bsd: String, description: [String: Any])
        case changed(bsd: String, description: [String: Any])
        case disappeared(bsd: String)
    }

    /// 순수: 알림으로 BSD 이름 → 칸 표를 고친다
    static func apply(_ event: Event, to disks: inout [String: Disk]) {
        switch event {
        case let .appeared(bsd, description), let .changed(bsd, description): disks[bsd] = Disk(description: description)
        case let .disappeared(bsd): disks[bsd] = nil
        }
    }

    /// 순수: 사이드바에 올릴 마운트 지점(정렬). 네트워크·시동 볼륨·내장 디스크는 빼고(내장 여부를 모르면 뺀다),
    /// 디스크 이미지는 /Volumes 아래이거나 임시 폴더 아래(`lab usb-image attach`)일 때만 올린다 — 시스템이 붙인 이미지(시뮬레이터 등)를 빼려고.
    /// `diskImagesOnly`(시험 실행)면 실물 볼륨은 볼륨 정보조차 읽지 않게 여기서 뺀다.
    static func mountPoints(_ disks: [String: Disk], diskImagesOnly: Bool = false,
                            isScratch: (String) -> Bool = defaultIsScratch) -> [String] {
        Set(disks.values.compactMap { disk -> String? in
            guard let path = disk.volumePath, path != "/", !disk.isNetwork else { return nil }
            if disk.isDiskImage { return path.hasPrefix("/Volumes/") || isScratch(path) ? path : nil }
            guard !diskImagesOnly else { return nil }
            return disk.isInternal == false && path.hasPrefix("/Volumes/") ? path : nil
        }).sorted()
    }

    static func defaultIsScratch(_ path: String) -> Bool {
        UsbScratchRoots.isUnderAllowedRoot(UsbScratchRoots.realPath(path) ?? path)
    }

    // MARK: - 실행

    private let queue: DispatchQueue
    private let debounce: DispatchTimeInterval
    private let diskImagesOnly: Bool
    private let info: @Sendable (String) -> UsbVolumeInfo?
    private let lock = NSLock()
    private var disks: [String: Disk] = [:]
    private var current: [UsbVolumeInfo] = []
    private var scanScheduled = false
    private var session: DASession?
    private var continuation: AsyncStream<[UsbVolumeInfo]>.Continuation?

    /// - diskImagesOnly: 디스크 이미지 볼륨만 본다(시험 실행)
    /// - info: 마운트 지점 → 볼륨 정보(시험은 가짜). 알림 대기열에서 부른다
    public init(diskImagesOnly: Bool = false, queue: DispatchQueue = DispatchQueue(label: "djc.usb.volume-monitor"),
                debounce: DispatchTimeInterval = .milliseconds(300),
                info: @escaping @Sendable (String) -> UsbVolumeInfo? = { try? UsbVolumes.info(root: URL(filePath: $0)) }) {
        self.diskImagesOnly = diskImagesOnly
        self.queue = queue
        self.debounce = debounce
        self.info = info
    }

    deinit { stop() }

    /// 지금 연결된(사이드바 후보) 볼륨
    public var volumes: [UsbVolumeInfo] { lock.withLock { current } }

    /// 지켜보기를 시작한다. 목록이 바뀔 때마다(처음 한 번 포함) 새 목록을 보낸다. 두 번 부르면 앞 흐름은 끝난다
    public func start() -> AsyncStream<[UsbVolumeInfo]> {
        stop()
        let (stream, continuation) = AsyncStream.makeStream(of: [UsbVolumeInfo].self, bufferingPolicy: .bufferingNewest(1))
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            continuation.finish()
            return stream
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, { disk, context in
            guard let context else { return }
            Unmanaged<UsbVolumeMonitor>.fromOpaque(context).takeUnretainedValue().handle(disk: disk, kind: 0)
        }, context)
        DARegisterDiskDescriptionChangedCallback(session, nil, nil, { disk, _, context in
            guard let context else { return }
            Unmanaged<UsbVolumeMonitor>.fromOpaque(context).takeUnretainedValue().handle(disk: disk, kind: 1)
        }, context)
        DARegisterDiskDisappearedCallback(session, nil, { disk, context in
            guard let context else { return }
            Unmanaged<UsbVolumeMonitor>.fromOpaque(context).takeUnretainedValue().handle(disk: disk, kind: 2)
        }, context)
        lock.withLock {
            self.session = session
            self.continuation = continuation
        }
        DASessionSetDispatchQueue(session, queue)
        // 알림이 없어도(연결된 USB가 없을 때) 빈 목록을 한 번 보낸다
        schedule()
        return stream
    }

    public func stop() {
        let (session, continuation) = lock.withLock {
            defer { self.session = nil; self.continuation = nil }
            return (self.session, self.continuation)
        }
        if let session { DASessionSetDispatchQueue(session, nil) }
        continuation?.finish()
    }

    /// 알림 대기열에서 불린다
    private func handle(disk: DADisk, kind: Int) {
        guard let name = DADiskGetBSDName(disk).map({ String(cString: $0) }) else { return }
        let description = DADiskCopyDescription(disk) as? [String: Any] ?? [:]
        let event: Event = switch kind {
        case 0: .appeared(bsd: name, description: description)
        case 1: .changed(bsd: name, description: description)
        default: .disappeared(bsd: name)
        }
        lock.withLock { Self.apply(event, to: &disks) }
        schedule()
    }

    /// 알림이 몰려도(파티션·전체 디스크·마운트) 잠깐 기다렸다 한 번만 다시 본다
    private func schedule() {
        let first = lock.withLock {
            defer { scanScheduled = true }
            return !scanScheduled
        }
        guard first else { return }
        queue.asyncAfter(deadline: .now() + debounce) { [weak self] in self?.scan() }
    }

    private func scan() {
        let points = lock.withLock {
            scanScheduled = false
            return Self.mountPoints(disks, diskImagesOnly: diskImagesOnly)
        }
        let volumes = points.compactMap(info)
        let continuation = lock.withLock { () -> AsyncStream<[UsbVolumeInfo]>.Continuation? in
            current = volumes
            return self.continuation
        }
        continuation?.yield(volumes)
    }

    // MARK: - 꺼내기

    /// 볼륨이 든 디스크 전체를 마운트 해제한 뒤 꺼낸다(DADiskUnmount → DADiskEject). 볼륨 파일은 열지 않는다
    public static func eject(mountPoint: String) async throws {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { throw UsbError.readFailed(detail: "DASessionCreate") }
        let queue = DispatchQueue(label: "djc.usb.eject")
        DASessionSetDispatchQueue(session, queue)
        defer { DASessionSetDispatchQueue(session, nil) }
        guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, URL(filePath: mountPoint) as CFURL),
              let whole = DADiskCopyWholeDisk(disk) else {
            throw UsbError.readFailed(detail: "eject: no disk")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let box = Unmanaged.passRetained(DissenterBox(continuation)).toOpaque()
            DADiskUnmount(whole, DADiskUnmountOptions(kDADiskUnmountOptionWhole), { _, dissenter, context in
                guard let context else { return }
                Unmanaged<DissenterBox>.fromOpaque(context).takeRetainedValue().finish(dissenter, step: "unmount")
            }, box)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let box = Unmanaged.passRetained(DissenterBox(continuation)).toOpaque()
            DADiskEject(whole, DADiskEjectOptions(kDADiskEjectOptionDefault), { _, dissenter, context in
                guard let context else { return }
                Unmanaged<DissenterBox>.fromOpaque(context).takeRetainedValue().finish(dissenter, step: "eject")
            }, box)
        }
    }

    /// DA 완료 콜백을 async로 잇는다(콜백은 한 번만 온다)
    private final class DissenterBox: @unchecked Sendable {
        let continuation: CheckedContinuation<Void, any Error>

        init(_ continuation: CheckedContinuation<Void, any Error>) {
            self.continuation = continuation
        }

        func finish(_ dissenter: DADissenter?, step: String) {
            if let dissenter {
                continuation.resume(throwing: UsbError.readFailed(detail: "\(step) status \(DADissenterGetStatus(dissenter))"))
            } else {
                continuation.resume()
            }
        }
    }
}
