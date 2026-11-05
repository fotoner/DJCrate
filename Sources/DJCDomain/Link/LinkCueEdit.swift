import Foundation

/// LINK로 CDJ가 보낸 큐 저장·삭제 하나(#280). CDJ에서 MEMORY·핫큐를 찍거나 DELETE를 누르면 온다.
/// 시각은 rekordbox 시간축 ms다(CDJ가 읽는 분석 파일과 같은 시간축).
public struct LinkCueEdit: Equatable, Sendable {
    /// rekordbox 곡 ID
    public var contentID: String
    /// 지우기인지(아니면 저장)
    public var deleted: Bool
    /// rekordbox `djmdCue.Kind` 부호: 0 메모리, 1~3 핫큐 A~C, 5~9 핫큐 D~H, 4 활성 메모리 루프
    public var kind: Int
    public var inMs: UInt32
    /// 루프 끝. 시작보다 뒤일 때만 루프다
    public var outMs: UInt32?
    /// 큐 이름(CDJ 코멘트). 옛 CDJ는 비워 보낸다
    public var comment: String

    public init(contentID: String, deleted: Bool, kind: Int, inMs: UInt32, outMs: UInt32?, comment: String) {
        self.contentID = contentID
        self.deleted = deleted
        self.kind = kind
        self.inMs = inMs
        self.outMs = outMs
        self.comment = comment
    }

    public var time: Double { Double(inMs) / 1000 }

    /// 루프 끝(초). 루프가 아니면 nil
    public var loopEnd: Double? { outMs.flatMap { $0 > inMs ? Double($0) / 1000 : nil } }

    /// 편집용 종류. 4(활성 메모리 루프)는 메모리 큐다. 모르는 종류는 nil
    public var cueKind: EditableCue.Kind? { kind == 4 ? .memory : EditableCue.Kind(rekordbox: kind) }
}

/// LINK 큐 편집을 초안에 옮긴 결과
public enum LinkCueEditResult: Equatable, Sendable {
    case applied
    /// 이미 같은 큐가 있거나 지울 큐가 없다
    case unchanged
    /// 메모리 큐 한도(`CueDraft.memoryLimit`)라 더하지 않았다
    case memoryLimit
    /// 모르는 큐 종류
    case unsupported
}

public extension CueDraft {
    /// CDJ가 보낸 큐 저장·삭제를 이 초안에 옮긴다. 덱의 MEMORY·핫큐·DELETE와 같은 규칙을 쓴다(메모리 큐는 ±30ms 안이면 같은 큐).
    /// 핫큐는 그 칸의 큐를 바꾸고, 있던 큐의 ID·rekordbox 큐 ID를 이어받는다(rekordbox에는 고친 큐로 쓴다).
    /// - Parameter newID: 새 큐의 ID(부르는 쪽이 준다)
    mutating func apply(_ edit: LinkCueEdit, newID: () -> UUID) -> LinkCueEditResult {
        guard let kind = edit.cueKind else { return .unsupported }
        // 활성 루프는 곡에 하나만이라, 더한 뒤 덱처럼 켠다(`toggleActiveLoop`가 다른 활성 루프를 끈다)
        let loop = edit.loopEnd.map { EditableCue.Loop(end: $0) }
        switch (kind, edit.deleted) {
        case (.memory, true):
            guard let cue = memoryCue(near: [edit.time], closestTo: edit.time) else { return .unchanged }
            remove(cue.id)
            return .applied
        case let (.hot(slot), true):
            guard let cue = hotCue(slot: slot) else { return .unchanged }
            remove(cue.id)
            return .applied
        case let (.hot(slot), false):
            let old = hotCue(slot: slot)
            let cue = EditableCue(id: old?.id ?? newID(), sourceID: old?.sourceID, kind: kind, time: edit.time,
                                  name: edit.comment.isEmpty ? old?.name ?? "" : edit.comment,
                                  loop: loop.map { EditableCue.Loop(end: $0.end, active: old?.loop?.active ?? false) })
            if let old, old.time == cue.time, old.loop == cue.loop, old.name == cue.name { return .unchanged }
            place(cue)
            return .applied
        case (.memory, false):
            switch addMemory(at: edit.time, loop: loop, newID: newID) {
            case .limitReached: return .memoryLimit
            case .existing: return .unchanged
            case let .added(id):
                if !edit.comment.isEmpty, var cue = cue(id) {
                    cue.name = edit.comment
                    place(cue)
                }
                if edit.kind == 4, cue(id)?.loop?.active == false { toggleActiveLoop(id) }
                return .applied
            }
        }
    }
}

public extension CueDraft {
    /// 초안의 큐를 rekordbox 큐 모양으로 바꾼다(LINK로 CDJ에 내어 줄 때, #280). 시각 차례로 돌려준다.
    /// 초안은 색을 들지 않으므로, 자리·종류를 고치지 않은 rekordbox 큐만 그 색을 이어받는다. 활성 루프는 메모리 루프(Kind 0, ActiveLoop 1)다
    func rekordboxShapedCues(contentID: String, rekordboxCues: [Cue]) -> [Cue] {
        let originals = Dictionary(rekordboxCues.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return cues.sorted { $0.time < $1.time }.map { cue in
            let kind = switch cue.kind {
            case .memory: 0
            case let .hot(slot): slot < 3 ? slot + 1 : slot + 2
            }
            let inMsec = Int((cue.time * 1000).rounded())
            let original = cue.sourceID.flatMap { originals[$0] }.flatMap { $0.kind == kind && $0.inMsec == inMsec ? $0 : nil }
            return Cue(id: cue.sourceID ?? cue.id.uuidString, contentID: contentID, kind: kind, inMsec: inMsec, name: cue.name,
                       colorTableIndex: original?.colorTableIndex, outMsec: cue.loop.map { Int(($0.end * 1000).rounded()) } ?? 0,
                       color: original?.color, activeLoop: cue.loop?.active == true ? 1 : 0,
                       beatLoopSize: EditableCue.Loop.beatLoopSize(beats: cue.loop?.beats))
        }
    }
}
