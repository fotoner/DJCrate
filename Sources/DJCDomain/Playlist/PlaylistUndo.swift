import Foundation

/// 저장 뒤 ⌘Z(R12, #405)의 재생 목록 몫: 편집 한 번 전후에 보이던 목록(rekordbox + 초안을 얹은 모양)을 견줘, 지금 보이는 목록 위에서 그 편집을
/// 거꾸로 하는 단계를 만든다. 역편집은 초안 끝에 쌓아 자동 저장이 쓴다.
/// - 범위: 이름 바꾸기, 같은 폴더 안 목록 순서, 곡 순서, 곡 넣기(넣은 곡을 뺀다)
/// - 그 밖(만들기·지우기·다른 폴더로 옮기기·곡 빼기)은 되돌리지 않는다(`unsupported`: ⌘Z를 끈다)
/// - 새로 만든 목록(`new:키`)은 쓰기 결과의 연결 ID(`ids`)로 지금 목록에서 찾는다. 아직 쓰지 않았으면 새 목록 참조 그대로 둔다
/// - 목록 순서는 옮긴 목록 하나를 원래 자리로 옮기는 단계 하나로만 되돌린다. 역편집은 한 목록에 닿는 단계로만 만든다
///   (자동 저장이 한 단위로 쓰게, 컨실 2라운드 G). 그렇게 나타낼 수 없으면 되돌리지 않는다
/// - 대상이 지금 그 편집 뒤 모양이 아니면(쓴 뒤 바깥에서 바뀜) 정할 수 없다(`changed`: ⌘Z를 끈다)
public enum PlaylistUndo {
    public enum Result: Equatable, Sendable {
        /// 지금 보이는 목록에 차례로 얹으면 그 편집 전 모양이 되는 단계
        case edits([PlaylistEdit])
        /// 되돌리지 않는 종류다(또는 바뀐 것이 없다)
        case unsupported
        /// 대상이 지금 그 편집 뒤 모양이 아니다
        case changed
    }

    /// - Parameters:
    ///   - before, after: 편집 전·뒤에 보이던 목록
    ///   - current: 지금 보이는 목록(rekordbox + 지금 초안)
    ///   - ids: 새 목록 키(`new:키`) → 쓴 뒤 실제 목록 ID
    public static func reversing(before: PlaylistLayout, after: PlaylistLayout, current: PlaylistLayout, ids: [String: String]) -> Result {
        func real(_ id: String) -> String { ids[id] ?? id }
        let beforeIDs = Set(before.outline.map(\.id)), afterIDs = Set(after.outline.map(\.id))
        // 만들기·지우기는 되돌리지 않는다(만들기를 되돌리면 지우기다)
        guard beforeIDs == afterIDs else { return .unsupported }
        var edits: [PlaylistEdit] = []
        var working = current
        func push(_ edit: PlaylistEdit) -> Bool {
            guard (try? working.apply(edit)) != nil else { return false }
            edits.append(edit)
            return true
        }
        // 목록마다: 이름·곡(넣기·순서)
        for id in after.outline.map(\.id) {
            guard let old = before.item(id), let new = after.item(id) else { continue }
            // 다른 폴더로 옮긴 편집은 되돌리지 않는다
            guard old.parentID == new.parentID else { return .unsupported }
            let nameChanged = old.name != new.name, tracksChanged = old.trackIDs != new.trackIDs
            guard nameChanged || tracksChanged else { continue }
            guard let now = working.item(real(id)) else { return .changed }
            let ref = PlaylistRef(real(id))
            if nameChanged {
                guard now.name == new.name else { return .changed }
                guard push(.rename(playlist: ref, name: old.name)) else { return .changed }
            }
            guard tracksChanged else { continue }
            guard now.trackIDs == new.trackIDs else { return .changed }
            if new.trackIDs.count > old.trackIDs.count, Array(new.trackIDs.prefix(old.trackIDs.count)) == old.trackIDs {
                // 곡 넣기: 끝에 붙은 곡을 뺀다
                guard push(.removeTracks(playlist: ref, entries: Array(now.entries.suffix(new.trackIDs.count - old.trackIDs.count)))) else {
                    return .changed
                }
            } else if new.trackIDs.sorted() == old.trackIDs.sorted() {
                // 곡 순서: 앞에서부터 편집 전 자리의 곡을 하나씩 옮긴다(같은 곡이 여러 번 들어도 앞의 것부터)
                for index in old.trackIDs.indices {
                    guard let entries = working.item(real(id))?.entries, entries[index].contentID != old.trackIDs[index] else { continue }
                    guard let from = entries.indices.dropFirst(index).first(where: { entries[$0].contentID == old.trackIDs[index] }),
                          push(.moveTracks(playlist: ref, entries: [entries[from]], to: index + 1)) else { return .changed }
                }
            } else {
                // 곡 빼기(와 섞인 편집)는 되돌리지 않는다
                return .unsupported
            }
        }
        // 폴더마다: 목록 순서(같은 폴더 안). 옮긴 목록 하나를 원래 자리로 옮긴다: 형제(옮길 수 없는 인텔리전트 목록 포함)를 건드리지 않는다
        for parent in Set(after.outline.map(\.parentID)).union([PlaylistLayout.root]).sorted() {
            let old = before.childIDs(of: parent), new = after.childIDs(of: parent)
            guard old != new else { continue }
            let realParent = real(parent)
            guard working.childIDs(of: realParent) == new.map(real) else { return .changed }
            func restoring(_ id: String) -> PlaylistEdit? {
                guard let index = old.firstIndex(of: id), old.filter({ $0 != id }) == new.filter({ $0 != id }) else { return nil }
                let edit = PlaylistEdit.reorder(playlist: PlaylistRef(real(id)), index: index)
                var trial = working
                guard (try? trial.apply(edit)) != nil, trial.childIDs(of: realParent) == old.map(real) else { return nil }
                return edit
            }
            guard let edit = old.lazy.compactMap(restoring).first, push(edit) else { return .unsupported }
        }
        // 여러 목록에 걸친 역편집은 자동 저장이 단위를 나눠 일부만 쓸 수 있다: 만들지 않는다
        guard Set(edits.map(\.playlist.layoutID)).count <= 1 else { return .unsupported }
        return edits.isEmpty ? .unsupported : .edits(edits)
    }
}
