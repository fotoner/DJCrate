import DJCDomain
import Foundation

/// 같은 음원 곡 합치기(유스케이스): 남길 곡과 컬렉션에서 뺄 곡을 비교해 합치기 초안을 만든다(쓸 때 잃는 정보는 쓰기 확인이 묻는다, #212).
public struct MergeDuplicates: Sendable {
    /// 사본에서 합칠 곡들을 읽어 초안을 만든다(합칠 수 없으면 이유를 던진다)
    let prepare: @Sendable (_ keeping: String, _ removing: [String], _ snapshot: URL) throws -> DuplicateMergeDraft
    /// 합치기 초안 파일(`merge-drafts.json`)
    let drafts: DraftStore

    public init(prepare: @escaping @Sendable (_ keeping: String, _ removing: [String], _ snapshot: URL) throws -> DuplicateMergeDraft,
                drafts: DraftStore) {
        self.prepare = prepare
        self.drafts = drafts
    }

    /// 합치기 초안 전체를 저장한다(실패하면 던진다).
    /// - Parameter takingMovedFiles: 저장이 손상된 옛 파일을 옮겼는지 가져온다(데이터 폴더를 정한 저장소만)
    /// - Returns: 저장이 옮긴 손상 파일
    @MainActor
    public func save(_ merges: [DuplicateMergeDraft], takingMovedFiles: Bool) throws -> [DamagedDraftFile] {
        try drafts.saveMergeDrafts(merges)
        return takingMovedFiles ? drafts.takeMovedFiles() : []
    }

    /// 사본에서 초안을 만든다(메인 밖에서)
    public func draft(keeping: String, removing: [String], snapshot: URL) async throws -> DuplicateMergeDraft {
        try await LoadLibrary.background { [prepare] in try prepare(keeping, removing, snapshot) }
    }

    /// 같은 음원인지 묻는 확인(초안 단계는 비교만 한다. 잃는 정보는 rekordbox에 쓸 때 한 번 묻는다)
    /// - Parameter paths: 곡 ContentID → 음원 경로
    public static func confirmation(_ draft: DuplicateMergeDraft, paths: [String: String]) -> ReflectionPrompt {
        let details = [String(ui: "남길 곡: \(draft.keeping.title)") + "\n" + (paths[draft.keeping.contentID] ?? "")]
            + draft.removing.map { String(ui: "컬렉션에서 뺄 곡: \($0.title)") + "\n" + (paths[$0.contentID] ?? "") }
        return ReflectionPrompt(title: String(ui: "같은 음원인지 확인하고 합치기 초안을 만들까요?"),
                                text: String(ui: "직접 미리 들어 같은 음원인지 확인하세요. 인코더 지연만 보정하며, 곡 앞뒤의 편집 차이는 보정하지 않습니다. 초안은 ⇧⌘E로 쓰고, 쓸 때 옮기지 않는 정보를 알립니다."),
                                confirm: String(ui: "같은 음원 확인 · 초안 만들기"), details: details)
    }

    /// 초안을 더한다. 같은 곡의 다른 초안이나 재생 목록 초안이 있으면 막는다
    public static func staging(_ draft: DuplicateMergeDraft, onto current: [DuplicateMergeDraft], pending: Set<String>,
                               playlistDraftEmpty: Bool) throws -> [DuplicateMergeDraft] {
        guard Set(draft.members.map(\.trackUUID)).isDisjoint(with: pending), playlistDraftEmpty else {
            throw DuplicateMerge.Blocked(String(ui: "같은 곡의 다른 초안이나 재생 목록 초안이 있습니다. 먼저 쓰거나 버린 뒤 합치세요"))
        }
        return current + [draft]
    }
}
