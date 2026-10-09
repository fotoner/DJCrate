import Foundation

/// 한 묶음은 큐·목록 이동과 삭제가 모두 성공해야 반영된다. base는 준비할 때의 DB·음원 지문이다.
public struct DuplicateMergeDraft: Codable, Equatable, Sendable, Identifiable {
    public struct Member: Codable, Equatable, Sendable {
        public var contentID: String
        public var trackUUID: String
        public var title: String
        public var duration: Double
        public var offset: Double
        public var cues: [EditableCue]

        public init(contentID: String, trackUUID: String, title: String, duration: Double, offset: Double, cues: [EditableCue]) {
            self.contentID = contentID; self.trackUUID = trackUUID; self.title = title
            self.duration = duration; self.offset = offset; self.cues = cues
        }
    }

    public var keeping: Member
    public var removing: [Member]
    public var base: String
    public var id: String { keeping.trackUUID }
    public var members: [Member] { [keeping] + removing }

    public init(keeping: Member, removing: [Member], base: String) {
        self.keeping = keeping; self.removing = removing; self.base = base
    }
}

public enum DuplicateMerge {
    public struct Blocked: Error, LocalizedError, Sendable {
        public var reason: String
        public init(_ reason: String) { self.reason = reason }
        public var errorDescription: String? { reason }
    }

    public static var lossNotice: String {
        String(ui: "뺄 곡의 재생 기록·재생 횟수·평점·색·마이 태그·그리드·게인·자동 큐·큐 색은 옮기지 않습니다. 음원 파일은 남습니다.")
    }

    /// - Parameter newID: 옮긴 큐의 새 ID(부르는 쪽이 준다)
    public static func cues(keeping: DuplicateMergeDraft.Member, removing: [DuplicateMergeDraft.Member],
                            newID: () -> UUID) throws -> CueDraft {
        let members = [keeping] + removing
        guard !removing.isEmpty, Set(members.map(\.contentID)).count == members.count,
              Set(members.map(\.trackUUID)).count == members.count else {
            throw Blocked(String(ui: "서로 다른 곡을 골라 합치기 초안을 다시 만드세요"))
        }
        guard members.allSatisfy({ $0.duration.isFinite && $0.duration > 0 && $0.offset.isFinite && $0.offset >= 0
            && abs($0.duration - keeping.duration) <= 0.020000001 }) else {
            throw Blocked(String(ui: "음원 길이 차이가 20ms를 넘거나 시간축을 확인할 수 없습니다. 같은 음원인지 확인하세요"))
        }
        var draft = CueDraft(trackUUID: keeping.trackUUID)
        draft.base = keeping.cues; draft.cues = keeping.cues
        for member in removing {
            for original in member.cues {
                var cue = original
                let shift = keeping.offset - member.offset
                cue.time += shift
                if cue.loop != nil { cue.loop?.end += shift }
                guard cue.time.isFinite, cue.time >= 0, cue.time <= keeping.duration + keeping.offset,
                      cue.loop.map({ $0.end.isFinite && $0.end > cue.time && $0.end <= keeping.duration + keeping.offset }) ?? true else {
                    throw Blocked(String(ui: "옮길 큐나 루프가 곡 길이를 벗어납니다. 큐를 확인한 뒤 다시 합치세요"))
                }
                if draft.cues.contains(where: { same($0, cue) }) { continue }
                if case let .hot(slot) = cue.kind {
                    guard (0..<8).contains(slot), !draft.cues.contains(where: { $0.kind == cue.kind }) else {
                        throw Blocked(String(ui: "같은 핫큐 슬롯에 다른 큐가 있습니다. 슬롯을 정리한 뒤 다시 합치세요"))
                    }
                }
                if cue.loop?.active == true, draft.cues.contains(where: { $0.loop?.active == true }) {
                    throw Blocked(String(ui: "서로 다른 활성 루프가 있습니다. 활성 루프를 하나로 정한 뒤 다시 합치세요"))
                }
                cue.id = newID(); cue.sourceID = nil
                draft.cues.append(cue)
            }
        }
        guard draft.cues.filter({ $0.kind == .memory }).count <= 10 else {
            throw Blocked(String(ui: "합친 메모리 큐가 10개를 넘습니다. 큐를 정리한 뒤 다시 합치세요"))
        }
        draft.cues.sort { $0.time < $1.time }
        return draft
    }

    private static func same(_ a: EditableCue, _ b: EditableCue) -> Bool {
        a.kind == b.kind && (a.time * 1000).rounded() == (b.time * 1000).rounded() && a.name == b.name
            && a.loop?.active == b.loop?.active && a.loop?.beats == b.loop?.beats
            && a.loop.map { ($0.end * 1000).rounded() } == b.loop.map { ($0.end * 1000).rounded() }
    }

    /// 가운데에 직접 넣지 않는다. 검증된 삭제 → 끝에 넣기 → 순서 바꾸기를 조합한다.
    public static func playlists(keeping: String, removing: Set<String>, in original: PlaylistLayout) throws -> [PlaylistEdit] {
        var layout = original, edits: [PlaylistEdit] = []
        for item in original.items.values.sorted(by: { $0.id < $1.id }) {
            let entries = item.entries(of: removing)
            guard let first = entries.first, let index = item.entries.firstIndex(of: first) else { continue }
            let ref = PlaylistRef.id(item.id)
            let remove = PlaylistEdit.removeTracks(playlist: ref, entries: entries)
            try layout.apply(remove); edits.append(remove)
            if !item.trackIDs.contains(keeping) {
                let add = PlaylistEdit.addTracks(playlist: ref, contentIDs: [keeping])
                try layout.apply(add); edits.append(add)
                let last = layout.item(item.id)!.entries.last!
                let move = PlaylistEdit.moveTracks(playlist: ref, entries: [last], to: index + 1)
                try layout.apply(move); edits.append(move)
            }
        }
        return edits
    }
}
