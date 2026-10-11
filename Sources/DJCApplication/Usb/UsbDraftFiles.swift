import DJCDomain
import Foundation

/// USB 초안 파일을 읽고 쓰는 창구(피동 포트). USB 수정 세션·초안 고치기가 부르고, 실제 파일은 DJCStorage `UsbDraftStore`가 맡는다.
/// 실제 구현(`.live(directory:)`)은 DJCAdapters에 있고 조립 지점(앱·CLI)이 고른다
public struct UsbDraftFiles: Sendable {
    /// 그 볼륨의 초안(없으면 nil)
    public var load: @Sendable (_ volumeKey: String) throws -> UsbDraft?
    public var save: @Sendable (UsbDraft) throws -> Void
    /// 편집 하나를 끝에 더한다. 초안이 없으면 이 base로 새로 만든다(있으면 처음 base를 그대로 둔다)
    public var append: @Sendable (_ edit: UsbLibraryEdit, _ volumeKey: String, _ base: UsbFingerprint) throws -> Void
    /// 초안을 지운다(없으면 아무것도 하지 않는다)
    public var discard: @Sendable (_ volumeKey: String) throws -> Void

    public init(load: @escaping @Sendable (String) throws -> UsbDraft?, save: @escaping @Sendable (UsbDraft) throws -> Void,
                append: @escaping @Sendable (UsbLibraryEdit, String, UsbFingerprint) throws -> Void,
                discard: @escaping @Sendable (String) throws -> Void) {
        self.load = load
        self.save = save
        self.append = append
        self.discard = discard
    }

    /// 메모리 구현(시험). 실제와 같은 규칙: 없는 초안은 nil, 더하기는 처음 base를 지키고, 새 초안의 만든 때는 `now`
    public static func memory(now: @escaping @Sendable () -> Date) -> UsbDraftFiles {
        let box = MemoryUsbDrafts()
        return UsbDraftFiles(load: { box.get($0) }, save: { box.set($0) },
                             append: { edit, key, base in
                                 box.update(key) { draft in
                                     var draft = draft ?? UsbDraft(volumeKey: key, base: base, edits: [], createdAt: now())
                                     draft.edits.append(edit)
                                     return draft
                                 }
                             },
                             discard: { box.remove($0) })
    }
}

/// `UsbDraftFiles.memory`의 저장소(잠금 안에서만 바꾼다)
private final class MemoryUsbDrafts: @unchecked Sendable {
    private let lock = NSLock()
    private var drafts: [String: UsbDraft] = [:]

    func get(_ key: String) -> UsbDraft? { lock.withLock { drafts[key] } }
    func set(_ draft: UsbDraft) { lock.withLock { drafts[draft.volumeKey] = draft } }
    func remove(_ key: String) { lock.withLock { drafts[key] = nil } }
    func update(_ key: String, _ body: (UsbDraft?) -> UsbDraft) { lock.withLock { drafts[key] = body(drafts[key]) } }
}
