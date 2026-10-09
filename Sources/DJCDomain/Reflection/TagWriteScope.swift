import Foundation

/// 태그 칸마다 rekordbox 쓰기 규칙을 확인한 범위(#65). 확인하지 않은 곡에서 그 칸을 고친 초안은 막는다: 앱은 초안을 만들 때, 쓰기 모듈은
/// 백업 전 확인과 트랜잭션 안에서(반영 미리 보기에 이유가 보인다). 실험으로 범위를 넓힐 때는 `byKey` 한 곳만 고친다.
/// 표에 없는 칸은 태그 쓰기 공통 범위(`common`: 곡 상태 0·256·257, 재생 목록 XML Timestamp, #171·#173·S5)다.
public struct TagWriteScope: Sendable, Equatable {
    /// 쓰기를 확인한 곡 상태(`rb_data_status`)
    public var states: Set<Int>
    /// 그 곡이 든 재생 목록의 `masterPlaylists6.xml` Timestamp를 rekordbox가 어떻게 고치는지 확인했는지. 아니면 살아 있는 목록에 든 곡을 막는다.
    public var playlistXML: Bool

    public init(states: Set<Int>, playlistXML: Bool) {
        self.states = states
        self.playlistXML = playlistXML
    }

    /// 정보 패널 아홉 칸과 키(#171·#173 S1~S4·S5 K1)
    public static let common = TagWriteScope(states: [0, 256, 257], playlistXML: true)

    /// 칸마다 따로 확인한 범위. 앱 목록·인스펙터·`djc draft`·XML 가져오기도 이 표에 든 칸만 초안을 만들 때 곡 상태·재생 목록을 미리 본다.
    /// - 평점·곡 색(rekordbox 7.2.18): 상태 0 곡의 넣기·바꾸기·지우기(2026-10-04 묶음 2 S1~S3)와 동기화 곡의 평점·색(#173 S1 T11·T12: 256 → 257,
    ///   2026-10-07 사본 재현 차이 0)을 칸 단위로 확인했다. 재생 목록에 든 곡은 R65(2026-10-09)에서 정보 패널 칸과 같이 그 곡이 든 목록의 XML
    ///   Timestamp만 바뀌는 것을 확인하고 사본 재현으로 맞췄다.
    ///   평점·곡 색 조건의 인텔리전트 목록 Timestamp·결과는 [미확인]이지만 사용자 결정(2026-10-07)으로 막지 않는다(rekordbox에서 목록을 다시 정렬한다).
    public static let byKey: [TagFields.Key: TagWriteScope] = [
        .rating: TagWriteScope(states: [0, 256, 257], playlistXML: true),
        .color: TagWriteScope(states: [0, 256, 257], playlistXML: true),
    ]

    public static func scope(for key: TagFields.Key, in scopes: [TagFields.Key: TagWriteScope] = byKey) -> TagWriteScope {
        scopes[key] ?? common
    }

    /// 고친 칸 가운데 이 곡(상태 `state`, 살아 있는 재생 목록에 들었는지 `inPlaylist`)에서 확인하지 않은 칸이 있으면 막을 이유.
    /// 공통 범위 밖의 곡 상태는 태그 쓰기가 따로 막는다(여기서는 칸별로 좁힌 것만 본다).
    /// - Parameter hasDraft: 그 칸의 초안이 이미 있는지(쓰기 확인). 초안을 만들기 전(목록·인스펙터·`djc draft`·XML 가져오기)에는 버리라고 하지 않는다.
    public static func blockReason(keys: [TagFields.Key], state: Int?, inPlaylist: Bool,
                                   scopes: [TagFields.Key: TagWriteScope] = byKey, hasDraft: Bool = false) -> String? {
        let narrowed = TagFields.Key.allCases.filter { keys.contains($0) && scopes[$0] != nil }
        let unsynced = narrowed.filter { key in !(state.map { scope(for: key, in: scopes).states.contains($0) } ?? false) }
        if !unsynced.isEmpty {
            let labels = unsynced.map(\.label).joined(separator: "·")
            return hasDraft
                ? String(ui: "동기화된 곡의 \(labels)은 rekordbox에 쓰는 규칙을 아직 확인하지 않았으니 rekordbox에서 직접 고치거나 이 칸 초안을 버리세요")
                : String(ui: "동기화된 곡의 \(labels)은 rekordbox에 쓰는 규칙을 아직 확인하지 않았으니 rekordbox에서 직접 고치세요")
        }
        let listed = inPlaylist ? narrowed.filter { !scope(for: $0, in: scopes).playlistXML } : []
        if !listed.isEmpty {
            let labels = listed.map(\.label).joined(separator: "·")
            return hasDraft
                ? String(ui: "재생 목록에 든 곡의 \(labels)은 rekordbox에 쓰는 규칙을 아직 확인하지 않았으니 rekordbox에서 직접 고치거나 이 칸 초안을 버리세요")
                : String(ui: "재생 목록에 든 곡의 \(labels)은 rekordbox에 쓰는 규칙을 아직 확인하지 않았으니 rekordbox에서 직접 고치세요")
        }
        return nil
    }
}
