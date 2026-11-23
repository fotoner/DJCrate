import Foundation

/// 제안 판정(자동 저장 R5): 자동으로 쓰지 않고 ⌘S·저장 단추로 함께 쓰는 초안을 가린다.
/// 자동 저장 대상은 사람 편집만 든 도장이고, 지금 내용의 해시가 도장에 적힌 해시와 같은 초안뿐이다. 그 밖은 모두 제안이다.
/// 곡 초안(`DraftKey`)과 재생 목록 단계가 같은 규칙을 쓴다. 순수 규칙이라 앱·CLI·시험이 같은 함수를 부른다.
public enum DraftSuggestion: String, Codable, CaseIterable, Sendable {
    /// 사람 편집이 아닌 출처만 든다(CLI·AI·LINK·복원이 되살림)
    case notHuman = "not_human"
    /// 사람 편집과 다른 출처가 섞였다
    case mixedOrigins = "mixed_origins"
    /// 출처를 모른다: 도장이 없는 초안(업데이트 전부터 있던 초안 포함)이나 출처에 모름이 든 초안
    case unknownOrigin = "unknown_origin"
    /// 내용 해시가 기록과 맞지 않는다(바깥에서 고친 초안). 지금 내용을 읽지 못해 해시를 못 구한 때도 같다
    case contentChanged = "content_changed"

    /// 제안 사유. nil이면 자동 저장 대상이다(사람 편집만 들고 해시가 맞는다).
    /// 사유는 하나만 보인다: 출처(모름 → 섞임 → 사람 아님)를 해시보다 먼저 본다.
    /// - Parameters:
    ///   - stamp: 초안의 도장. nil이면 출처를 모른다
    ///   - currentHash: 지금 내용의 해시. nil이면 읽지 못했다
    public static func judge(stamp: DraftStamp?, currentHash: DraftContentHash?) -> DraftSuggestion? {
        guard let stamp, !stamp.origins.isEmpty, !stamp.origins.contains(.unknown) else { return .unknownOrigin }
        guard stamp.origins.contains(.human) else { return .notHuman }
        guard stamp.origins == [.human] else { return .mixedOrigins }
        return currentHash == stamp.contentHash ? nil : .contentChanged
    }
}

extension DraftContentHash {
    /// 그림 초안의 해시. 그림 바이트는 넣지 않는다: 초안이 사본의 SHA-256(`imageSHA256`)을 이미 들고 있어 그림이 바뀌면 해시도 바뀐다.
    /// 그림 사본이 크므로(몇 MB) 쓸 때마다 다시 잴 수 없다. 메모리 구현과 실제 저장소가 이 함수 하나를 쓴다
    public init(artwork edit: ArtworkEdit) throws {
        try self.init(of: edit.draft)
    }
}
