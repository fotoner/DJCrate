import DJCDomain
import Foundation

/// USB 초안 고치기(유스케이스): 곡 목록·사이드바의 편집을 USB 초안 파일에 쌓는다. USB에는 쓰지 않는다.
/// 볼륨마다 한 줄로 세우는 일(읽고-고치고-쓰기가 겹쳐 편집을 잃지 않게)은 부르는 쪽(앱 `UsbStore.draftQueue`)이 한다. 메인 액터 밖에서 부른다
public struct UsbDraftEditing: Sendable {
    /// 초안 한 번 고치기: 고치기 전·뒤 편집
    public struct Change: Sendable, Equatable {
        public var before: [UsbLibraryEdit]
        public var after: [UsbLibraryEdit]

        public init(before: [UsbLibraryEdit], after: [UsbLibraryEdit]) {
            self.before = before
            self.after = after
        }
    }

    public var files: UsbDraftFiles
    /// 초안을 처음 만들 때의 base: 지금 그 자리 USB DB 지문(앱은 `UsbWriting.draftBase`)
    public var base: @Sendable (UsbVolumeInfo) throws -> UsbFingerprint
    /// 새 초안의 만든 때
    public var now: @Sendable () -> Date

    public init(files: UsbDraftFiles, base: @escaping @Sendable (UsbVolumeInfo) throws -> UsbFingerprint, now: @escaping @Sendable () -> Date) {
        self.files = files
        self.base = base
        self.now = now
    }

    /// 지금 초안 편집을 읽어 `change`로 새 편집을 받고(nil이면 그대로), 비면 초안을 지우고 아니면 저장한다.
    /// 초안 파일이 없을 때만 지금 USB DB 지문을 base로 뜬다 — 빠진 볼륨(`volume` nil)이거나 지문을 뜨지 못하면
    /// (그 자리의 볼륨이 바뀜·읽지 않는 볼륨) 빈 지문으로 둔다(쓸 때 지금 상태로 다시 계획한다).
    /// 지금 편집과, 고쳤으면 그 전·뒤 편집
    public func mutate(_ volumeKey: String, volume: UsbVolumeInfo?, _ change: ([UsbLibraryEdit]) -> [UsbLibraryEdit]?) throws
        -> (edits: [UsbLibraryEdit], changed: Change?) {
        let draft = try files.load(volumeKey)
        let before = draft?.edits ?? []
        guard let after = change(before) else { return (before, nil) }
        if after.isEmpty {
            try files.discard(volumeKey)
        } else {
            let base = draft?.base ?? volume.flatMap { try? self.base($0) } ?? UsbFingerprint(files: [:])
            try files.save(UsbDraft(volumeKey: volumeKey, base: base, edits: after, createdAt: draft?.createdAt ?? now()))
        }
        return (after, Change(before: before, after: after))
    }

    /// 초안 파일을 통째로 바꾼다(nil·빈 편집이면 지운다). 바꾸기 전·뒤 초안
    public func replace(_ volumeKey: String, _ transform: (UsbDraft?) -> UsbDraft?) throws -> (old: UsbDraft?, new: UsbDraft?) {
        let old = try files.load(volumeKey)
        let new = transform(old).flatMap { $0.edits.isEmpty ? nil : $0 }
        if let new { try files.save(new) } else if old != nil { try files.discard(volumeKey) }
        return (old, new)
    }

    /// 그 볼륨의 초안 편집. 읽지 못하면 빈 목록(초안 줄이 다시 미리 보며 오류를 알린다)
    public func edits(_ volumeKey: String) -> [UsbLibraryEdit] {
        ((try? files.load(volumeKey)) ?? nil)?.edits ?? []
    }
}
