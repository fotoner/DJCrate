import DJCDomain
import Foundation
import Synchronization

/// 곡마다 한 번 재면 되는 분석 값의 캐시(포트): 조성 크로마·음량·그리드 추정. 파일이 바뀌면(크기·수정 시각) 없는 것으로 본다.
/// 실제 구현(`.live`)은 DJCAdapters가 주고 조립 지점이 고른다. 메모리 구현은 `MemoryAnalysisStore`.
public struct AnalysisStore: Sendable {
    /// 조성 크로마(곡 UUID, 음원)
    public var chroma: @Sendable (String, URL) -> KeyChroma?
    public var storeChroma: @Sendable (KeyChroma, String, URL) -> Void
    /// 전에 잰 음량(음원)
    public var loudness: @Sendable (URL) -> Loudness?
    /// 음량 저장(모아서 쓰는 저장 예약은 메인 액터에서)
    public var storeLoudness: @MainActor (Loudness, URL) -> Void
    /// 그리드 추정(곡 UUID, 음원, 음원 시간축)
    public var gridEstimate: @Sendable (String, URL) -> GridEstimate?
    public var storeGridEstimate: @Sendable (GridEstimate, String, URL) -> Void
    /// 재분석: 이 곡의 섹션 분석·그리드 추정·크로마 캐시를 지운다
    public var removeAll: @Sendable (String) -> Void

    public init(chroma: @escaping @Sendable (String, URL) -> KeyChroma?,
                storeChroma: @escaping @Sendable (KeyChroma, String, URL) -> Void,
                loudness: @escaping @Sendable (URL) -> Loudness?,
                storeLoudness: @escaping @MainActor (Loudness, URL) -> Void,
                gridEstimate: @escaping @Sendable (String, URL) -> GridEstimate?,
                storeGridEstimate: @escaping @Sendable (GridEstimate, String, URL) -> Void,
                removeAll: @escaping @Sendable (String) -> Void) {
        self.chroma = chroma
        self.storeChroma = storeChroma
        self.loudness = loudness
        self.storeLoudness = storeLoudness
        self.gridEstimate = gridEstimate
        self.storeGridEstimate = storeGridEstimate
        self.removeAll = removeAll
    }
}

/// 파일 없이 메모리에만 두는 분석 캐시(`AnalysisStore`의 메모리 구현). 덱 시험·하네스가 캐시 폴더를 건드리지 않게 쓴다.
/// 열쇠는 실제 구현과 같다: 크로마·그리드 추정은 곡 UUID와 음원, 음량은 음원(파일이 바뀌었는지는 보지 않는다).
/// 같은 규칙인지는 DJCAdaptersTests의 계약 시험이 본다.
public final class MemoryAnalysisStore: Sendable {
    private struct State {
        var chroma: [String: KeyChroma] = [:]
        var loudness: [String: Loudness] = [:]
        var grids: [String: GridEstimate] = [:]
    }
    private let state = Mutex(State())

    public init() {}

    private static func key(_ uuid: String, _ file: URL) -> String { "\(uuid)|\(file.path)" }

    /// 이 메모리 캐시를 읽고 쓰는 포트
    public var store: AnalysisStore {
        AnalysisStore(
            chroma: { uuid, file in self.state.withLock { $0.chroma[Self.key(uuid, file)] } },
            storeChroma: { chroma, uuid, file in self.state.withLock { $0.chroma[Self.key(uuid, file)] = chroma } },
            loudness: { file in self.state.withLock { $0.loudness[file.path] } },
            storeLoudness: { loudness, file in self.state.withLock { $0.loudness[file.path] = loudness } },
            gridEstimate: { uuid, file in self.state.withLock { $0.grids[Self.key(uuid, file)] } },
            storeGridEstimate: { estimate, uuid, file in self.state.withLock { $0.grids[Self.key(uuid, file)] = estimate } },
            removeAll: { uuid in
                self.state.withLock { state in
                    state.chroma = state.chroma.filter { !$0.key.hasPrefix(uuid + "|") }
                    state.grids = state.grids.filter { !$0.key.hasPrefix(uuid + "|") }
                }
            })
    }
}
