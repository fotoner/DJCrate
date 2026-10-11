import DJCDomain
import Foundation

/// USB에서 읽은 큐·그리드를 이 라이브러리의 초안으로 넣는 쪽(유스케이스). USB 읽기·짝짓기 계획은 USB 쪽(`UsbWriteService.planCueGridImport`)이 하고,
/// 여기서는 걸린 초안 저장을 끝낸 뒤 곡별 초안 파일로 바로 쓴다(XML 가져오기와 같은 파일 포트). 저장 대기 입력·초안 파일·화면의 메모리 입력이
/// 있는 칸은 덮지 않는다(`UsbCueGridImport.saveDrafts`). rekordbox와 USB에는 쓰지 않는다.
public struct ImportUsbCueGridDrafts: Sendable {
    let drafts: DraftStore
    let files: DraftFiles
    let newKey: @Sendable () -> String

    public init(drafts: DraftStore, files: DraftFiles, newKey: @escaping @Sendable () -> String) {
        self.drafts = drafts
        self.files = files
        self.newKey = newKey
    }

    /// USB 사본을 읽을 작업 폴더(초안 폴더 `home` 아래 새 이름)
    public func scratchFolder(in home: URL) -> URL {
        home.appending(path: "usb-snapshots").appending(path: "import-\(newKey())")
    }

    /// 계획의 큐·그리드를 초안 파일로 쓴다. 메인 액터에서 라이브러리 상태를 확인한 같은 차례에 부른다.
    /// - Parameter hasInput: 화면이 든 초안·복구 입력이 있는 칸(덮지 않는다)
    @MainActor
    public func save(_ plan: UsbCueGridImportPlan, hasInput: (String, UsbCueGridDraftImport.Part) -> Bool) -> UsbCueGridImport.Saved {
        let store = drafts, files = files
        store.flush()
        let target = UsbCueGridDraftFiles(
            cueExists: { uuid in store.pendingCue(uuid) != nil || files.exists(.cue, uuid) },
            saveCue: { try files.saveCue($0) },
            gridExists: { uuid in store.pendingGrid(uuid) != nil || files.exists(.grid, uuid) },
            saveGrid: { try files.saveGrid($0) })
        return UsbCueGridImport.saveDrafts(plan, files: target, hasDraft: hasInput)
    }

    /// 덱에 넘길 큐 초안: 저장 대기 입력이 있으면 그것, 없으면 초안 파일(둘 다 없는 곡은 뺀다)
    public func cueDrafts(_ uuids: some Sequence<String>) -> [String: CueDraft] {
        var cues: [String: CueDraft] = [:]
        for uuid in uuids { cues[uuid] = drafts.pendingCue(uuid) ?? drafts.cueDraft(uuid) }
        return cues
    }
}
