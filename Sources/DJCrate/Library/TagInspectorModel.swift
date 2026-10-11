import DJCApplication
import DJCDomain
import Foundation
import Observation

/// 태그 인스펙터 화면 모델(#250): 고른 곡의 칸 값·초안 표시·충돌·잠금 이유를 화면 값으로 바꾸고, 고친 값은 태그 편집 조각(`TagEditStore`)에 넘긴다.
/// 상태는 공유 핵심(`LibraryStore`: 선택·태그 초안)과 조각에 있다. 본문이 읽는 관찰 속성은 옛 인스펙터와 같다(다시 계산 횟수가 같다).
/// 조립 지점(`AppComposition`)이 한 번 만든다. 그래서 인스펙터를 닫았다 열어도 그림 칸 안내가 남는다.
@MainActor
@Observable
final class TagInspectorModel {
    /// 칸 하나의 표시 값
    struct Field: Equatable {
        var value: String
        /// 고른 곡의 값이 서로 다르다
        var mixed: Bool
        /// 고른 곡 가운데 이 칸을 초안에서 고친 곡이 있다
        var edited: Bool
    }

    /// 지금 rekordbox 값과 내 초안이 부딪친 칸(곡 하나를 골랐을 때)
    struct Conflict: Equatable {
        var current: String
        var draft: String
    }

    /// 인스펙터 그림 칸
    let artwork: ArtworkInspectorModel
    @ObservationIgnored private let library: LibraryStore
    private var tags: TagEditStore { library.tags }

    init(store: LibraryStore) {
        library = store
        artwork = ArtworkInspectorModel(store: store)
    }

    // MARK: - 보이기

    /// 고른 곡(목록 순서, 반복 행은 한 번)
    var rows: [TrackRow] { library.selectedRows }

    /// 글자 칸의 정체. 고른 곡이 바뀌면 칸을 새로 만들어 입력 중이던 글자가 다른 곡에 들어가지 않게 한다.
    func fieldID(_ key: TagFields.Key) -> String { "\(key.rawValue)-\(library.selection.hashValue)" }

    var trackColors: [TrackColor] { library.trackColors }

    func field(_ key: TagFields.Key, rows: [TrackRow]) -> Field {
        let current = tags.tagValue(key, rows: rows)
        return Field(value: current.value, mixed: current.mixed, edited: rows.contains { tags.isTagEdited($0, key) })
    }

    /// 태그 초안이 있는 곡 수(여러 곡을 골랐을 때 머리에 보인다)
    func draftCount(_ rows: [TrackRow]) -> Int { rows.filter { library.tagDrafts[$0.track.uuid] != nil }.count }

    /// 곡 정보 칸 위 잠금 안내: 고칠 수 없는 곡(USB·스트리밍)이 섞였으면 그 이유
    func lockReason(_ rows: [TrackRow]) -> String? {
        rows.first(where: { $0.isUsb || $0.track.isStreaming }).flatMap { TrackListTagEditing.unavailableReason($0, key: .title) }
    }

    /// 글자 칸을 막을지(고른 곡이 모두 USB·스트리밍 곡)
    func isTextLocked(_ rows: [TrackRow]) -> Bool { rows.allSatisfy { $0.isUsb || $0.track.isStreaming } }

    /// 글자 칸 도움말(첫 곡을 고칠 수 없으면 그 이유)
    func textHelp(_ key: TagFields.Key, rows: [TrackRow]) -> String {
        rows.first.flatMap { TrackListTagEditing.unavailableReason($0, key: key) } ?? key.label
    }

    func conflict(_ key: TagFields.Key, rows: [TrackRow]) -> Conflict? {
        guard rows.count == 1, let row = rows.first, let draft = library.tagDrafts[row.track.uuid],
              draft.conflictingKeys(with: row.tagFields).contains(key) else { return nil }
        return Conflict(current: row.tagFields[key], draft: draft.fields[key])
    }

    /// 쓰기 전 확인할 문제(고른 곡 초안의 문제를 겹치지 않게 한 줄로)
    func issues(_ rows: [TrackRow]) -> String? {
        let issues = rows.compactMap { library.tagDrafts[$0.track.uuid] }.flatMap(\.issues)
        return issues.isEmpty ? nil : Set(issues).sorted().joined(separator: " · ")
    }

    /// '태그 현재값 가져오기…'를 보일 곡(태그 초안이 있는 곡 하나를 골랐을 때)
    func recoverableRow(_ rows: [TrackRow]) -> TrackRow? {
        guard rows.count == 1, let row = rows.first, library.tagDrafts[row.track.uuid] != nil else { return nil }
        return row
    }

    var isRecoveringDraft: Bool { library.isRecoveringDraft }

    /// 코멘트 칸 아래 프리셋 분류. 프리셋이 없거나 값이 여럿이면 nil이다.
    func commentEvaluation(_ rows: [TrackRow]) -> CommentEvaluation? {
        let comment = tags.tagValue(.comment, rows: rows)
        guard !comment.mixed, let rule = library.commentPreset.rule else { return nil }
        return rule.evaluate(comment.value)
    }

    // MARK: - 바꾸기

    /// 글자 칸을 확정했을 때(Enter·칸 벗어나기)
    func setText(_ key: TagFields.Key, _ text: String, rows: [TrackRow]) { tags.setTag(key, text, rows: rows) }

    /// 키 고르기. 고칠 수 없는 곡(USB·스트리밍)은 뺀다.
    func pickKey(_ value: String, rows: [TrackRow]) { tags.setTag(.musicalKey, value, rows: KeyPicker.targets(rows)) }

    /// 평점·곡 색 고르기. 고칠 수 없는 곡(추가한 곡·쓰기를 확인하지 않은 곡)은 뺀다.
    func pick(_ key: TagFields.Key, _ value: String, rows: [TrackRow]) { tags.setTag(key, value, rows: TagChoice.targets(key, rows)) }

    func resolveConflict(_ key: TagFields.Key, keepingDraft: Bool, rows: [TrackRow]) {
        tags.resolveTagConflict(key, keepingDraft: keepingDraft, rows: rows)
    }

    func revert(rows: [TrackRow]) { tags.revertTags(rows: rows) }
}
