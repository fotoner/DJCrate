import DJCApplication
import DJCDomain
import Foundation

// 시험 도우미: 핵심부는 큐 ID를 받아서만 만든다(#167). ID 값이 상관없는 시험은 옛 모양 그대로 무작위 ID로 만든다.

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

extension UsbCueGridDraftImport {
    static func cueDraft(uuid: String, local: [Cue], imported: [EditableCue], legacy: Bool) throws -> CueDraft {
        try cueDraft(uuid: uuid, local: local, imported: imported, legacy: legacy, newID: { UUID() })
    }
}

extension WatchDrafts {
    static func visibleCueDrafts(_ drafts: [String: CueDraft], autoCues: (String) -> [Cue]) -> [String: CueDraft] {
        visibleCueDrafts(drafts, newID: { UUID() }, autoCues: autoCues)
    }
}
