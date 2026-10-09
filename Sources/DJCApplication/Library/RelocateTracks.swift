import DJCDomain
import Foundation

/// 파일 없는 곡의 새 위치 찾기(포트): 사본 DB의 파일 크기, 폴더 훑기, 연결된 볼륨. 실제 구현은 DJCAdapters(`RelocateSource.live`).
/// 폴더·음원·라이브러리는 읽기만 한다.
public struct RelocateSource: Sendable {
    /// 후보를 맞출 곡(스트리밍 곡 빼고, 곡 행의 파일 크기는 사본 DB에서 읽는다)
    public var targets: @Sendable (_ tracks: [Track], _ snapshot: URL) throws -> [RelocateTarget]
    /// 폴더를 훑어 후보를 맞춘다(취소하면 `CancellationError`)
    public var scan: @Sendable (_ targets: [RelocateTarget], _ folder: URL, _ progress: @escaping @Sendable (RelocateProgress) -> Void) async throws -> RelocateOutput
    /// 지금 연결된 볼륨 경로("/", "/Volumes/X" …)
    public var mountedVolumes: @Sendable () -> [String]

    public init(targets: @escaping @Sendable (_ tracks: [Track], _ snapshot: URL) throws -> [RelocateTarget],
                scan: @escaping @Sendable (_ targets: [RelocateTarget], _ folder: URL, _ progress: @escaping @Sendable (RelocateProgress) -> Void) async throws -> RelocateOutput,
                mountedVolumes: @escaping @Sendable () -> [String]) {
        self.targets = targets
        self.scan = scan
        self.mountedVolumes = mountedVolumes
    }
}

/// 파일 없는 곡의 새 위치 찾기(유스케이스, #62): 곡 행의 파일 크기를 사본에서 읽고, 고른 폴더를 훑어 후보를 맞추고, 왜 없는지(외장 디스크가 빠졌는지) 가른다.
/// 경로 바꾸기 쓰기는 아직 막혀 있다(미리 보기만).
public struct RelocateTracks: Sendable {
    let source: RelocateSource

    public init(source: RelocateSource) {
        self.source = source
    }

    /// 훑기 결과: 후보 보고서·센 것과 곡마다 왜 없는지
    public struct Found: Sendable, Equatable {
        public var output: RelocateOutput
        public var absences: [String: RelocateAbsence]
    }

    /// 곡들의 새 위치 후보를 폴더에서 찾는다. 라이브러리 사본이 없으면 DB도 폴더도 열기 전에 멈춘다. 무거운 일은 메인 밖에서 한다
    public func find(_ tracks: [Track], snapshot: URL?, folder: URL,
                     progress: @escaping @Sendable (RelocateProgress) -> Void) async throws -> Found {
        guard let snapshot else { throw DJCError.snapshotNotFound }
        // 곡 행의 파일 크기를 사본 DB에서 읽는다(메인 스레드 밖).
        let targets = try await LoadLibrary.background { [source] in try source.targets(tracks, snapshot) }
        let output = try await source.scan(targets, folder, progress)
        // 볼륨 목록은 멈춘 네트워크 디스크에서 오래 걸릴 수 있어 메인 스레드 밖에서 읽는다.
        let mounted = try await LoadLibrary.background { [source] in source.mountedVolumes() }
        return Found(output: output, absences: RelocateAbsence.classify(targets, mountedVolumes: mounted))
    }
}
