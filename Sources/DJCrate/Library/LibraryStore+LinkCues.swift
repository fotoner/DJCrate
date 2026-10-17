import DJCApplication
import DJCDomain
import Foundation

extension LibraryStore {
    /// LINK로 CDJ가 저장하거나 지운 큐(#280)를 받은 차례대로 그 곡의 큐 초안에 얹는다
    func enqueueLinkCueEdit(_ edit: LinkCueEdit, drafts: LinkCueDrafts) {
        let previous = linkCueTail
        linkCueTail = Task { [weak self] in
            await previous?.value
            await self?.applyLinkCueEdit(edit, drafts: drafts)
        }
    }

    /// 큐 편집 하나를 그 곡의 큐 초안에 얹고 바로 다시 읽어 화면에 보인다. rekordbox에는 쓰지 않는다. 초안은 rekordbox에 쓰기 때 나간다(LNK-16).
    /// rekordbox에 쓰는 중이거나 다시 읽는 중이면 끝날 때까지 기다린다(쓰기가 끝나며 지우는 초안에 얹지 않고, 쓴 뒤의 rekordbox 큐를 base로 삼게)
    func applyLinkCueEdit(_ edit: LinkCueEdit, drafts: LinkCueDrafts) async {
        while isWritingRekordbox || !isLoaded {
            guard (try? await Task.sleep(for: .milliseconds(250))) != nil else { return }
        }
        guard let row = rows.first(where: { $0.track.id == edit.contentID }) else { return }
        do {
            switch try await drafts.apply(edit, track: row.track, rekordboxCues: row.cues) {
            case .applied: await refreshExternalDrafts()
            case .unchanged, .unsupported: break
            case .memoryLimit:
                toast = .notice(String(ui: "CDJ에서 찍은 메모리 큐를 DJCrate에 옮기지 못했습니다"),
                                String(ui: "메모리 큐는 곡당 \(CueDraft.memoryLimit)개까지입니다. DJCrate에서 쓰지 않는 메모리 큐를 지운 뒤 CDJ에서 다시 찍으세요"),
                                kind: .warning)
            }
        } catch {
            toast = .notice(String(ui: "CDJ에서 고친 큐를 DJCrate에 옮기지 못했습니다"),
                            String(ui: "\(row.track.title): \(error.localizedDescription). 그 곡의 큐를 DJCrate에서 확인한 뒤 CDJ에서 다시 찍으세요"),
                            kind: .warning)
        }
    }

    /// LINK로 내어 줄 큐 초안: 초안이 있는 곡(rekordbox 곡 ID)마다 초안의 큐(아직 저장하지 않은 입력 포함). 초안이 없으면 rekordbox 큐를 내어 준다
    func linkDraftCues() -> [String: [Cue]] {
        var cues: [String: [Cue]] = [:]
        for uuid in cueDraftUUIDs {
            guard let row = rowsByUUID[uuid], let draft = useCases.watch.currentCue(uuid) else { continue }
            cues[row.track.id] = draft.rekordboxShapedCues(contentID: row.track.id, rekordboxCues: row.cues)
        }
        return cues
    }

    /// 그 곡들의 지금 큐(초안이 있으면 초안의 큐, 없으면 rekordbox 큐)를 LINK로 보낸다(#281). LINK가 연결된 동안만 읽는다
    /// - Parameter drafts: 이미 읽은 큐 초안(없는 곡은 저장을 맡은 입력·디스크에서 읽는다)
    /// rekordbox에 쓰는 동안은 보내지 않는다. 쓰기는 초안을 먼저 지우고 나중에 다시 읽으므로, 쓴 곡은 다시 읽은 뒤 보낸다(`deliverWrittenAfterReload`)
    func publishLinkCues(_ uuids: some Sequence<String>, drafts: [String: CueDraft]? = nil) {
        guard let onLinkCuesChanged, !isWritingRekordbox, isLinkServing() else { return }
        for uuid in uuids {
            guard let row = rowsByUUID[uuid] else { continue }
            let draft = drafts.map { $0[uuid] } ?? useCases.watch.currentCue(uuid)
            onLinkCuesChanged(row.track.id, draft?.rekordboxShapedCues(contentID: row.track.id, rekordboxCues: row.cues) ?? row.cues)
        }
    }

    private var isLoaded: Bool { if case .loaded = phase { true } else { false } }
}
