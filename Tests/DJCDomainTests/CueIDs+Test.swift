import DJCDomain
import Foundation

// 시험 도우미: 핵심부는 큐 ID를 받아서만 만든다(#167). ID 값이 상관없는 시험은 옛 모양 그대로 무작위 ID로 만든다.
// ID를 주입하는 규칙 자체는 `CueIDInjectionTests`가 본다.

extension EditableCue {
    init(sourceID: String? = nil, kind: Kind, time: Double, name: String = "", loop: Loop? = nil) {
        self.init(id: UUID(), sourceID: sourceID, kind: kind, time: time, name: name, loop: loop)
    }

    init?(_ cue: Cue) {
        self.init(cue, id: UUID())
    }
}

extension CueDraft {
    init(trackUUID: String, rekordboxCues: [Cue]) {
        self.init(trackUUID: trackUUID, rekordboxCues: rekordboxCues, newID: { UUID() })
    }

    func includingAutoCues(from rekordboxCues: [Cue]) -> CueDraft {
        includingAutoCues(from: rekordboxCues, newID: { UUID() })
    }

    mutating func addMemory(at time: Double, loop: EditableCue.Loop? = nil) -> MemoryAddResult {
        addMemory(at: time, loop: loop, newID: { UUID() })
    }
}

extension TrackEdit {
    func carry(_ cues: [EditableCue]) -> CueCarry { carry(cues, newID: { UUID() }) }
}

extension FlipEdit {
    func carry(_ cues: [EditableCue]) -> CueCarry { carry(cues, newID: { UUID() }) }
}

extension XMLImportDrafts {
    static func plan(diff: XMLLibraryDiff.Result, selection: Selection, sources: [String: TrackSource],
                     layout: PlaylistLayout, playlistDraft: PlaylistDraft, newKey: () -> String) -> Plan {
        plan(diff: diff, selection: selection, sources: sources, layout: layout, playlistDraft: playlistDraft, newKey: newKey,
             newID: { UUID() })
    }
}
