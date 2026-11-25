import Foundation

/// 저장 뒤 ⌘Z(R12, #405)의 재생 목록 몫: 편집 한 번 전후에 보이던 목록(rekordbox + 초안을 얹은 모양)을 견줘, 지금 보이는 목록 위에서 그 편집을
/// 거꾸로 하는 단계를 만든다. 역편집은 초안 끝에 쌓아 자동 저장이 쓴다.
/// - 범위: 이름 바꾸기, 같은 폴더 안 목록 순서, 곡 순서, 곡 넣기·빼기(편집 전·뒤 곡 열 중 한쪽이 다른 쪽의 부분 열일 때, #295 E5)
///   - 곡 넣기(가운데 넣기 포함)는 넣은 자리의 항목을 뺀다
///   - 곡 빼기는 뺀 곡을 끝에 넣고, 넣은 꼬리 구간을 꼬리 자리로 집어 원래 자리로 옮긴다(이어진 자리는 한 단계)
/// - 그 밖(만들기·지우기·다른 폴더로 옮기기, 곡 빼기와 순서가 섞인 편집)은 되돌리지 않는다(`unsupported`: ⌘Z를 끈다)
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
    ///   - moved: 그 편집이 순서를 옮긴 목록(`reorder`·`move`의 대상). 순서를 되돌릴 때 이 목록을 원래 자리로 옮긴다(컨실 3라운드 G)
    public static func reversing(before: PlaylistLayout, after: PlaylistLayout, current: PlaylistLayout, ids: [String: String],
                                 moved: Set<String> = []) -> Result {
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
            if new.trackIDs.count > old.trackIDs.count, let kept = subsequence(old.trackIDs, in: new.trackIDs) {
                // 곡 넣기(가운데 포함): 편집 전 곡 열에 맞지 않는 자리의 항목을 뺀다
                let added = new.trackIDs.indices.filter { !kept.contains($0) }.map { now.entries[$0] }
                guard push(.removeTracks(playlist: ref, entries: added)) else { return .changed }
            } else if old.trackIDs.count > new.trackIDs.count, let kept = subsequence(new.trackIDs, in: old.trackIDs) {
                // 곡 빼기: 뺀 곡을 끝에 넣고, 넣은 꼬리 구간을 꼬리 자리로 집어 원래 자리로 옮긴다(이어진 자리는 한 단계)
                let removed = old.trackIDs.indices.filter { !kept.contains($0) }
                guard push(.addTracks(playlist: ref, contentIDs: removed.map { old.trackIDs[$0] })) else { return .changed }
                var tail = new.trackIDs.count
                for run in runs(removed) {
                    guard let entries = working.item(real(id))?.entries else { return .changed }
                    defer { tail += run.count }
                    // 앞 구간을 제자리로 옮겼으니 이 구간 앞은 편집 전 곡 열과 같다: 이미 제자리(끝)면 옮기지 않는다
                    guard run.lowerBound != tail else { continue }
                    let picked = Array(entries[tail..<(tail + run.count)])
                    guard push(.moveTracks(playlist: ref, entries: picked, to: run.lowerBound + 1)) else { return .changed }
                }
            } else if new.trackIDs.sorted() == old.trackIDs.sorted() {
                // 곡 순서: 앞에서부터 편집 전 자리의 곡을 하나씩 옮긴다(같은 곡이 여러 번 들어도 앞의 것부터)
                for index in old.trackIDs.indices {
                    guard let entries = working.item(real(id))?.entries, entries[index].contentID != old.trackIDs[index] else { continue }
                    guard let from = entries.indices.dropFirst(index).first(where: { entries[$0].contentID == old.trackIDs[index] }),
                          push(.moveTracks(playlist: ref, entries: [entries[from]], to: index + 1)) else { return .changed }
                }
            } else {
                // 곡 빼기·넣기와 순서가 섞인 편집은 되돌리지 않는다
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
            // 그 편집이 옮긴 목록부터 본다(두 목록이 자리를 바꾼 모양은 어느 쪽을 옮겨도 되돌아간다: 쓰기 결과·연결 갱신 대상이 옮긴 목록이게)
            let candidates = old.filter { moved.contains($0) } + old.filter { !moved.contains($0) }
            guard let edit = candidates.lazy.compactMap(restoring).first, push(edit) else { return .unsupported }
        }
        // 여러 목록에 걸친 역편집은 자동 저장이 단위를 나눠 일부만 쓸 수 있다: 만들지 않는다
        guard Set(edits.map(\.playlist.layoutID)).count <= 1 else { return .unsupported }
        return edits.isEmpty ? .unsupported : .edits(edits)
    }

    /// `short`가 `long`의 부분 열이면(같은 곡의 개수 포함) `short`의 각 곡에 맞춘 `long`의 자리. 앞에서부터 처음 맞는 자리를 고른다
    /// (같은 곡이 여러 번 들어도 곡 열은 같게 되돌아간다). 아니면 nil
    static func subsequence(_ short: [String], in long: [String]) -> Set<Int>? {
        var matched: Set<Int> = [], next = 0
        for id in short {
            guard let index = long.indices.dropFirst(next).first(where: { long[$0] == id }) else { return nil }
            matched.insert(index)
            next = index + 1
        }
        return matched
    }

    /// 오름차순 자리를 이어진 구간으로 나눈다
    static func runs(_ indices: [Int]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        for index in indices {
            if let last = result.last, last.upperBound == index {
                result[result.count - 1] = last.lowerBound..<(index + 1)
            } else {
                result.append(index..<(index + 1))
            }
        }
        return result
    }
}
