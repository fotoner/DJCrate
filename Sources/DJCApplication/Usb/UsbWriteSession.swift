import DJCDomain
import Foundation

/// USB 쓰기 세션의 흐름 상태(값): 볼륨별 잠금(쓰기 중)·지금 쓰는 볼륨과 진행, 이 실행의 옮기기 백업·옮기기 막힘.
/// 바뀔 때마다 화면에 내보낸다(`UsbWriteSessionOutput.changed`). 무엇을 어떻게 보일지(덮개·사이드바)는 앱 화면 모델이 정한다.
public struct UsbWriteSessionState: Equatable, Sendable {
    /// 볼륨별 잠금(쓰기 중 표시). 세션의 `begin`·`end`로만 바뀐다
    public internal(set) var busyVolumes: Set<String>
    /// 지금 쓰는 볼륨과 진행(덮개가 읽는다). 앱은 한 번에 한 볼륨에만 쓴다
    public internal(set) var activeWrite: UsbActiveWrite?
    /// 이 실행에서 옮긴 쓰기의 백업. 다른 쓰기가 성공하면 버려 이전 편집을 지우는 복원을 막는다.
    public internal(set) var migrationBackups: [String: URL]
    /// 마지막 옮기기 미리 보기의 막힘(사이드바 도움말). 다시 읽으면 새로 확인한다.
    public internal(set) var migrationBlockReasons: [String: String]

    public init(busyVolumes: Set<String> = [], activeWrite: UsbActiveWrite? = nil, migrationBackups: [String: URL] = [:],
                migrationBlockReasons: [String: String] = [:]) {
        self.busyVolumes = busyVolumes
        self.activeWrite = activeWrite
        self.migrationBackups = migrationBackups
        self.migrationBlockReasons = migrationBlockReasons
    }
}

/// 쓰기 세션이 화면으로 내보내는 것(출력 포트). 앱은 화면 모델(`UsbWriteModel`)이 관찰 상태로 옮긴다
public struct UsbWriteSessionOutput {
    /// 흐름 상태가 바뀔 때마다(같은 값이면 부르지 않는다)
    public var changed: @MainActor (UsbWriteSessionState) -> Void

    public init(changed: @escaping @MainActor (UsbWriteSessionState) -> Void) {
        self.changed = changed
    }
}

/// USB 쓰기 세션: 볼륨별 잠금(쓰기 중)·덮개 진행·취소 표지와, 다시 미리 보기·되돌리기에 쓰는 지난 쓰기.
/// 쓰기 흐름(`UsbWriteFlow`)이 쥐고, 사이드바 저장소(앱 `UsbStore`)와 따로 둔다. 잠금·진행은 쓰기 흐름과 큐·그리드 가져오기가 바꾸고,
/// 지난 쓰기는 그 밖에 볼륨을 다시 읽을 때(옮기기 막힘 지움)와 내보내기 시트(다시 미리 보기 지움)도 바꾼다.
/// 화면 상태는 들지 않는다: 관찰할 흐름 상태(`state`)는 바뀔 때마다 출력 포트로 내보내고, 앱 화면 모델이 관찰 상태로 옮겨 보인다.
@MainActor
public final class UsbWriteSession {
    /// 마지막으로 내보낸 흐름 상태. 바깥에서는 읽기만 한다
    public private(set) var state = UsbWriteSessionState() {
        didSet { if state != oldValue { output?.changed(state) } }
    }
    public var output: UsbWriteSessionOutput?
    /// 볼륨키 → 마지막 내보내기(다시 미리 보기에 쓴다). 화면에 내보내지 않는 흐름 기록
    public var lastExports: [String: UsbExportJob] = [:]
    /// 마지막 옮기기(회복 뒤 재계획할 때 내보내기와 구분한다). 화면에 내보내지 않는 흐름 기록
    public var lastMigrations: Set<String> = []
    private var cancelFlag: UsbCancelFlag?

    public init() {}

    /// 볼륨별 잠금(쓰기 중 표시). `begin`·`end`로만 바꾼다
    public var busyVolumes: Set<String> { state.busyVolumes }
    /// 지금 쓰는 볼륨과 진행. 앱은 한 번에 한 볼륨에만 쓴다
    public var activeWrite: UsbActiveWrite? { state.activeWrite }
    /// 이 실행에서 옮긴 쓰기의 백업(`UsbWriteSessionState.migrationBackups`)
    public var migrationBackups: [String: URL] {
        get { state.migrationBackups }
        set { state.migrationBackups = newValue }
    }
    /// 마지막 옮기기 미리 보기의 막힘(`UsbWriteSessionState.migrationBlockReasons`)
    public var migrationBlockReasons: [String: String] {
        get { state.migrationBlockReasons }
        set { state.migrationBlockReasons = newValue }
    }

    /// 볼륨을 잠그고 쓰기를 시작한다. 그 볼륨이 이미 잠겼거나 다른 볼륨에 쓰는 중이면 nil
    /// - cancellable: 취소를 받는 일인지(회복·되돌리기는 받지 않는다)
    public func begin(_ volume: UsbVolumeInfo, title: String, cancellable: Bool = true) -> UsbCancelFlag? {
        let key = volume.usbKey
        guard !state.busyVolumes.contains(key), state.activeWrite == nil else { return nil }
        let flag = UsbCancelFlag()
        cancelFlag = flag
        var next = state
        next.busyVolumes.insert(key)
        next.activeWrite = UsbActiveWrite(volumeKey: key, volumeName: volume.name, title: title, cancellable: cancellable, progress: nil)
        // 잠금과 덮개를 한 번에 내보낸다(잠갔는데 덮개가 없는 상태를 화면에 보이지 않게)
        state = next
        return flag
    }

    /// 덮개 제목(미리 보기 → 쓰기처럼 단계가 바뀔 때)
    public func setTitle(_ title: String, for key: String) {
        guard var active = state.activeWrite, active.volumeKey == key else { return }
        active.title = title
        active.progress = nil
        state.activeWrite = active
    }

    /// 쓰기 절차의 진행. 지금 쓰는 볼륨의 것만 받는다
    public func report(_ progress: UsbProgress, for key: String) {
        guard var active = state.activeWrite, active.volumeKey == key else { return }
        active.progress = progress
        state.activeWrite = active
    }

    public func end(_ key: String) {
        var next = state
        next.busyVolumes.remove(key)
        if next.activeWrite?.volumeKey == key {
            next.activeWrite = nil
            cancelFlag = nil
        }
        state = next
    }

    /// 취소를 청한다. 취소를 받지 않는 일이거나 DB 교체가 시작된 뒤(`cancellable == false`)에는 받지 않는다
    public func cancel() {
        guard let cancelFlag, let activeWrite = state.activeWrite, activeWrite.cancellable, activeWrite.progress?.cancellable != false else { return }
        cancelFlag.set()
    }
}

/// 지금 쓰는 볼륨과 진행
public struct UsbActiveWrite: Equatable, Sendable {
    public var volumeKey: String
    public var volumeName: String
    /// 덮개 제목(미리 보기·쓰기·회복·되돌리기)
    public var title: String
    /// 취소를 받는 일인지(내보내기만)
    public var cancellable: Bool
    public var progress: UsbProgress?

    public init(volumeKey: String, volumeName: String, title: String, cancellable: Bool, progress: UsbProgress?) {
        self.volumeKey = volumeKey
        self.volumeName = volumeName
        self.title = title
        self.cancellable = cancellable
        self.progress = progress
    }
}

/// 내보내기 시트를 열 때 넘기는 것: 대상 볼륨(연 때의 정보)과, 다시 미리 보기면 그 내보내기·요약
public struct UsbExportSheetRequest: Equatable, Identifiable, Sendable {
    public var volume: UsbVolumeInfo
    public var job: UsbExportJob?
    public var summary: UsbExportSummary?

    public init(volume: UsbVolumeInfo, job: UsbExportJob? = nil, summary: UsbExportSummary? = nil) {
        self.volume = volume
        self.job = job
        self.summary = summary
    }

    public var volumeKey: String { volume.usbKey }
    public var id: String { volumeKey }
}
