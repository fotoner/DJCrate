import DJCDomain
import Foundation

/// 시점 스냅샷 되돌리기 미리 보기(계획까지, USB에 쓰지 않는다)
public struct UsbPointRestoreSummary: Sendable {
    public var result: UsbPointRestoreResult
    /// 계획 전에 막힌 것과 계획의 막힘
    public var blocks: [UsbBlock]
    /// 스냅샷 뒤 DJCrate가 모르는 변경(기기가 쓴 재생 기록 등)이 지금 USB에 있다. 되돌리면 그 내용을 잃는다
    public var deviceChanged: Bool

    public init(result: UsbPointRestoreResult, blocks: [UsbBlock], deviceChanged: Bool) {
        self.result = result
        self.blocks = blocks
        self.deviceChanged = deviceChanged
    }
}

/// 시점 스냅샷 되돌리기 결과. 바꿀 것이 없으면 report가 nil이다
public struct UsbPointRestoreWritten: Sendable {
    public var summary: UsbPointRestoreSummary
    public var report: UsbWriteReport?

    public init(summary: UsbPointRestoreSummary, report: UsbWriteReport?) {
        self.summary = summary
        self.report = report
    }
}

/// USB 시점 스냅샷(#226) 유스케이스: 만들기·목록·고정·지우기·되돌리기. CLI `djc usb-snapshot`과 앱이 함께 쓴다.
/// 만들기는 USB를 읽기만 한다(실물 USB도 동의 없이 읽는다). 되돌리기는 쓰기다:
/// 볼륨(정책·보호 경로·실물 관문, 막히면 USB를 읽지 않는다) → 이 볼륨의 스냅샷인지 → 저널 → 기기 변경(`usb-restore`의 D13과 같은 기준)
/// → 계획(스냅샷 → 변경 묶음, 준비 폴더) → `writer.write`(목표 지문 검증). 쓰기 절차가 쓰기 전 백업을 남기므로 `usb-restore`로 다시 되돌린다.
/// 가드·Mac 쪽 폴더·포트는 기본값 없이 조립 지점(앱·CLI)이 넘긴다.
public struct UsbPointSnapshots: Sendable {
    /// 스냅샷 폴더(DJC_HOME의 `usb-point-snapshots`, 볼륨마다 하위 폴더)
    public var directory: URL
    public var paths: UsbWritePaths
    /// 부를 때마다 새로 만든다(CLI: `--allow-physical`, 앱: 쓰기 확인 창을 거친 쓰기)
    public var writeGuard: @Sendable () -> UsbWriteGuard
    public var engine: UsbLibraryEngine
    public var device: UsbDevice
    public var now: @Sendable () -> Date

    public init(directory: URL, paths: UsbWritePaths, writeGuard: @escaping @Sendable () -> UsbWriteGuard, engine: UsbLibraryEngine,
                device: UsbDevice, now: @escaping @Sendable () -> Date) {
        self.directory = directory
        self.paths = paths
        self.writeGuard = writeGuard
        self.engine = engine
        self.device = device
        self.now = now
    }

    // MARK: - 만들기·목록

    /// 그 자리 볼륨의 키(대문자 UUID). 볼륨 번호가 없으면 막는다
    public func volumeKey(root: URL) throws -> String {
        try UsbEditSession.volumeKey(writeGuard().volume(root))
    }

    /// 지금 USB를 스냅샷으로 남긴다(USB에는 쓰지 않는다). Mac 쪽 폴더는 엔진이 볼륨·보호 경로를 본 뒤에 만든다
    public func create(root: URL, name: String) throws -> UsbPointSnapshotEntry {
        try engine.pointSnapshot.create(UsbPointSnapshotCreateRequest(name: name, root: root, directory: directory, paths: paths,
                                                                             guard: writeGuard(), now: now()))
    }

    /// 그 볼륨의 스냅샷(최근 것부터)
    public func entries(volumeKey: String) -> [UsbPointSnapshotEntry] {
        engine.pointSnapshot.list(directory, volumeKey)
    }

    /// 폴더 이름(ID) 또는 겹치지 않는 이름으로 찾는다
    public func find(_ key: String, volumeKey: String) throws -> UsbPointSnapshotEntry {
        let entries = entries(volumeKey: volumeKey)
        if let entry = entries.first(where: { $0.id == key }) { return entry }
        let named = entries.filter { !$0.metadata.name.isEmpty && $0.metadata.name == key }
        guard named.count == 1 else {
            throw UsbError.writeRefused([UsbBlock(code: "pointSnapshotNotFound", scope: .volume,
                                                  message: String(ui: "그 USB 스냅샷을 찾지 못했습니다. 목록에서 ID를 확인한 뒤 다시 주세요"))])
        }
        return named[0]
    }

    @discardableResult
    public func setPinned(_ pinned: Bool, _ entry: UsbPointSnapshotEntry) throws -> UsbPointSnapshotEntry {
        try engine.pointSnapshot.setPinned(pinned, entry, directory)
    }

    public func delete(_ entry: UsbPointSnapshotEntry) throws {
        try engine.pointSnapshot.delete(entry, directory)
    }

    // MARK: - 되돌리기

    /// 계획까지(USB에 쓰지 않는다). 준비 폴더는 지운다
    public func previewRestore(root: URL, entry: UsbPointSnapshotEntry, options: UsbWriteOptions) throws -> UsbPointRestoreSummary {
        let (summary, staging) = try prepare(root: root, entry: entry, options: options)
        if let staging { device.remove(staging) }
        return summary
    }

    /// 계획하고 쓴다(`options.dryRun`이면 준비·저널까지). 막히면 `writeRefused`. 기기가 바꾼 USB는 `discardDeviceChanges`를 줘야 쓴다
    public func restore(root: URL, entry: UsbPointSnapshotEntry, discardDeviceChanges: Bool, options: UsbWriteOptions,
                        progress: @escaping @Sendable (UsbProgress) -> Void, isCancelled: @escaping @Sendable () -> Bool) throws -> UsbPointRestoreWritten {
        progress(UsbProgress(phase: .planning, cancellable: true))
        let (summary, staging) = try prepare(root: root, entry: entry, options: options)
        // 끝나지 않은 쓰기(볼륨이 사라짐·되돌리기 실패)는 회복이 준비 폴더를 쓸 수 있어 남긴다
        var keepStaging = false
        defer { if !keepStaging, let staging { device.remove(staging) } }
        guard summary.blocks.isEmpty else { throw UsbError.writeRefused(summary.blocks) }
        if summary.deviceChanged, !discardDeviceChanges { throw UsbError.writeRefused([Self.deviceChangedBlock]) }
        guard let changes = summary.result.changes else { return UsbPointRestoreWritten(summary: summary, report: nil) }
        // 쓰기 직전 USB의 `._*`(사용자·macOS가 둔 것)는 검증이 이 쓰기가 남긴 것으로 세지 않게
        let preexisting = try engine.writer.preexistingAppleDoubles(root)
        do {
            let report = try engine.writer.write(UsbWriteRequest(changes: changes, verification: .pointRestore(summary.result), root: root,
                                                                 paths: paths, guard: writeGuard(), options: options,
                                                                 preexistingAppleDoubles: preexisting, progress: progress, isCancelled: isCancelled))
            return UsbPointRestoreWritten(summary: summary, report: report)
        } catch let error as UsbError {
            switch error {
            case .volumeLost, .volumeChanged, .restoreFailed, .restorePending: keepStaging = true
            default: break
            }
            throw error
        }
    }

    /// 기기가 바꾼 USB를 되돌리려 할 때(앱은 이 막힘을 보고 버릴지 묻는다)
    public static var deviceChangedBlock: UsbBlock {
        UsbBlock(code: "deviceChanged", scope: .volume,
                 message: String(ui: "스냅샷 뒤 USB에 DJCrate가 모르는 변경이 있습니다(기기가 쓴 기록 등). 되돌리면 그 내용을 잃습니다. 그래도 되돌리려면 --discard-device-changes를 주세요"))
    }

    // MARK: - 순서

    func prepare(root: URL, entry: UsbPointSnapshotEntry, options: UsbWriteOptions) throws -> (UsbPointRestoreSummary, URL?) {
        func blocked(_ blocks: [UsbBlock]) -> (UsbPointRestoreSummary, URL?) {
            (UsbPointRestoreSummary(result: UsbPointRestoreResult(), blocks: blocks, deviceChanged: false), nil)
        }
        // 1. 볼륨(정책·보호 경로·관문). 막히면 USB를 읽지도 계획하지도 않는다
        let guardNow = writeGuard()
        let volume = try guardNow.volume(root)
        let environment = UsbExportSession.environmentBlocks(volume, root: root, required: [], confirmName: options.confirmName, purpose: .edit,
                                                             guard: guardNow, device: device)
        guard environment.isEmpty else { return blocked(environment) }
        let volumeKey = try UsbEditSession.volumeKey(volume)
        // 2. 이 볼륨의 스냅샷만 되돌린다(다른 USB의 파일로 덮지 않게)
        guard entry.metadata.volumeUUID.uppercased() == volumeKey else {
            return blocked([UsbBlock(code: "pointSnapshotOtherVolume", scope: .volume,
                                     message: String(ui: "다른 USB의 스냅샷입니다. 이 USB에서 뜬 스냅샷을 고르세요"))])
        }
        // 3. 저널: 끝나지 않은 쓰기는 막는다. 닫힌 저널의 ID 상한은 잇는다
        var highWater: [String: Int] = [:]
        switch engine.writer.journalStatus(paths, volumeKey) {
        case .open:
            return blocked([UsbBlock(code: "recoveryNeeded", scope: .volume,
                                     message: String(ui: "지난 USB 쓰기가 끝나지 않았습니다. `djc usb-recover`로 먼저 회복하세요"))])
        case .corrupt:
            return blocked([UsbBlock(code: "journalUnreadable", scope: .volume,
                                     message: String(ui: "회복 기록 파일을 읽지 못했습니다. DJCrate 데이터 폴더의 usb-sessions를 확인하세요"))])
        case let .closed(_, idHighWater): highWater = idHighWater
        case .missing: break
        }
        // 4. 기기 변경: 스냅샷 뒤 사건을 따라가 DJCrate가 모르는 변경이 지금 USB에 있으면 되돌릴 때 그 내용을 잃는다.
        //    판정한 지문을 계획의 base로 넘긴다(그 사이 USB가 바뀌면 계획·쓰기 전 확인이 막는다)
        let current = try engine.writer.databaseFingerprint(root)
        let deviceChanged = UsbPointSnapshotRules.deviceChanged(since: entry,
                                                                events: engine.pointSnapshot.volumeEvents(directory, paths, volumeKey),
                                                                current: current)
        // 5. 계획(준비 폴더)
        try device.makeFolders(paths, [directory])
        let session = UsbLayout.newSessionID()
        let staging = paths.staging.appending(path: session)
        let result = try engine.pointSnapshot.planRestore(UsbPointRestoreInput(entry: entry, root: root, base: current, staging: staging,
                                                                              session: session, highWater: highWater))
        return (UsbPointRestoreSummary(result: result, blocks: result.blocks, deviceChanged: deviceChanged), result.changes == nil ? nil : staging)
    }
}
