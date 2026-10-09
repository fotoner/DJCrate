import DJCDomain
import Foundation
import Observation

/// USB 쓰기 세션 상태: 볼륨별 잠금(쓰기 중)·덮개 진행·취소 표지와, 다시 미리 보기·되돌리기에 쓰는 지난 쓰기.
/// 쓰기 흐름(`UsbWriteFlow`)이 쥐고, 사이드바 화면 모델(`UsbStore`)과 따로 둔다. 잠금·진행은 쓰기 흐름(`UsbWriteCoordinator`)과 큐·그리드 가져오기가 `UsbStore`를 거쳐 바꾸고,
/// 지난 쓰기는 그 밖에 볼륨을 다시 읽을 때(`UsbStore`, 옮기기 막힘 지움)와 내보내기 시트(다시 미리 보기 지움)도 바꾼다.
/// 사이드바·덮개는 `UsbStore`를 거쳐 읽는다(관찰은 이 객체에 걸린다).
@MainActor @Observable public final class UsbWriteSession {
    /// 볼륨별 잠금(쓰기 중 표시). `begin`·`end`로만 바꾼다
    public private(set) var busyVolumes: Set<String> = []
    /// 지금 쓰는 볼륨과 진행(덮개가 읽는다). 앱은 한 번에 한 볼륨에만 쓴다
    public private(set) var activeWrite: UsbActiveWrite?
    /// 볼륨키 → 마지막 내보내기(다시 미리 보기에 쓴다)
    @ObservationIgnored public var lastExports: [String: UsbExportJob] = [:]
    /// 마지막 옮기기(회복 뒤 재계획할 때 내보내기와 구분한다)
    @ObservationIgnored public var lastMigrations: Set<String> = []
    /// 이 실행에서 옮긴 쓰기의 백업. 다른 쓰기가 성공하면 버려 이전 편집을 지우는 복원을 막는다.
    public var migrationBackups: [String: URL] = [:]
    /// 마지막 옮기기 미리 보기의 막힘(사이드바 도움말). 다시 읽으면 새로 확인한다.
    public var migrationBlockReasons: [String: String] = [:]
    @ObservationIgnored private var cancelFlag: UsbCancelFlag?

    public init() {}

    /// 볼륨을 잠그고 쓰기를 시작한다. 그 볼륨이 이미 잠겼거나 다른 볼륨에 쓰는 중이면 nil
    /// - cancellable: 취소를 받는 일인지(회복·되돌리기는 받지 않는다)
    public func begin(_ volume: UsbVolumeInfo, title: String, cancellable: Bool = true) -> UsbCancelFlag? {
        let key = volume.usbKey
        guard !busyVolumes.contains(key), activeWrite == nil else { return nil }
        busyVolumes.insert(key)
        let flag = UsbCancelFlag()
        cancelFlag = flag
        activeWrite = UsbActiveWrite(volumeKey: key, volumeName: volume.name, title: title, cancellable: cancellable, progress: nil)
        return flag
    }

    /// 덮개 제목(미리 보기 → 쓰기처럼 단계가 바뀔 때)
    public func setTitle(_ title: String, for key: String) {
        guard activeWrite?.volumeKey == key else { return }
        activeWrite?.title = title
        activeWrite?.progress = nil
    }

    /// 쓰기 절차의 진행. 지금 쓰는 볼륨의 것만 받는다
    public func report(_ progress: UsbProgress, for key: String) {
        guard activeWrite?.volumeKey == key else { return }
        activeWrite?.progress = progress
    }

    public func end(_ key: String) {
        busyVolumes.remove(key)
        guard activeWrite?.volumeKey == key else { return }
        activeWrite = nil
        cancelFlag = nil
    }

    /// 취소를 청한다. 취소를 받지 않는 일이거나 DB 교체가 시작된 뒤(`cancellable == false`)에는 받지 않는다
    public func cancel() {
        guard let cancelFlag, let activeWrite, activeWrite.cancellable, activeWrite.progress?.cancellable != false else { return }
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
