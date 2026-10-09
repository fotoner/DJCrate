import DJCDomain
import Foundation

/// 추가한 곡 목록(`staged.json`)의 읽기·쓰기(포트). 목록을 고치는 곳은 모두 이 포트 하나로, 메인 액터에서 "지금 목록을 읽고 → 고쳐 → 저장"한다.
/// 두 길이 따로 쓰면(디스크 목록에 덧붙이기와 화면이 든 목록으로 덮기) 한쪽이 다른 쪽의 줄을 지운다(adv2 N8).
/// 파일만 읽고 쓰는 실제 구현은 `StagingStore.live(home:)`(DJCAdapters). 앱은 추가 목록 화면이 든 목록과 디스크를 함께 맞추는 구현을 조립 지점이 준다.
public struct StagingStore: Sendable {
    /// 지금 목록
    public var tracks: @MainActor () -> [StagedTrack]
    /// 목록 전체를 저장한다. 저장하지 못하면 던지고 목록은 그대로다
    public var save: @MainActor ([StagedTrack]) throws -> Void

    public init(tracks: @escaping @MainActor () -> [StagedTrack], save: @escaping @MainActor ([StagedTrack]) throws -> Void) {
        self.tracks = tracks
        self.save = save
    }
}

extension StagingStore {
    /// 지금 목록을 고쳐 저장한다(읽기·고치기·저장 사이에 다른 저장이 끼지 않는다)
    @MainActor
    public func update(_ change: (inout [StagedTrack]) throws -> Void) throws {
        var list = tracks()
        try change(&list)
        try save(list)
    }

    /// 이 경로(NFC로 비교)의 곡이 이미 목록에 있는지
    @MainActor
    public func contains(path: String) -> Bool {
        let key = path.precomposedStringWithCanonicalMapping
        return tracks().contains { $0.path.precomposedStringWithCanonicalMapping == key }
    }
}
