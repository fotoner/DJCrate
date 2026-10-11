import CryptoKit
import DJCDomain
import Foundation

/// 곡 그림 초안(#66). 곡마다 `<UUID>.json`(초안)과 `<UUID>.<SHA-256>.image`(고른 그림의 사본)를 둔다. 원본 그림 파일을 옮기거나 지워도 초안은 남는다.
/// rekordbox에 쓰면 지운다(쓴 초안과 사본은 그 쓰기의 백업 `artwork-drafts/`에 남아 되돌리면 다시 살린다).
/// 읽지 못한 초안, 사본이 없거나 SHA-256이 다른 초안은 지우지 않고 사본과 함께 `damaged-drafts`로 옮긴다(#174).
///
/// 사본 이름에 내용 해시를 넣는 까닭(#66 리뷰): 저장은 사본 → 초안 순서라, 같은 이름의 사본을 덮어쓰면 그 사이 뒤에서 도는 손상 검사가
/// "옛 초안 + 새 사본"을 보고 해시가 다르다며 옮길 수 있었다. 새 사본을 다른 이름으로 쓰고 초안을 바꾼 뒤 옛 사본을 지우면 어느 순간에
/// 보아도 초안이 가리키는 사본이 있다. 초안이 가리키지 않는 사본(끝나지 않은 저장)은 손상이 아니며 그 곡을 저장하거나 버릴 때 지운다.
public enum ArtworkDraftStore {
    public static let folderName = DraftFileNames.artwork

    public static var directory: URL { DJCPaths.userData.appending(path: folderName) }

    /// 그림 파일 바이트로 넣기·바꾸기 초안을 만든다(사본의 SHA-256을 함께 둔다).
    public static func edit(trackUUID: String, base: ArtworkBase, image: Data, imageName: String?) -> ArtworkEdit {
        ArtworkEdit(draft: ArtworkDraft(trackUUID: trackUUID, change: .set, base: base, imageName: imageName, imageSHA256: sha256(image)),
                    image: image)
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// 초안이 가리키는 사본 자리(`<UUID>.<SHA-256>.image`)
    public static func imageURL(for draft: ArtworkDraft, directory: URL) -> URL {
        directory.appending(path: "\(draft.trackUUID).\(draft.imageSHA256 ?? "none").image")
    }

    /// 그 곡의 사본들(끝나지 않은 저장이 남긴 것까지)
    static func imageURLs(trackUUID: String, directory: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix("\(trackUUID).") && $0.hasSuffix(".image") && $0.dropFirst(trackUUID.count + 1).dropLast(6).allSatisfy(\.isHexDigit) }
            .sorted().map { directory.appending(path: $0) }
    }

    /// 없으면 nil. 초안을 해석하지 못하거나 사본이 맞지 않으면 `DraftFileDamaged`, 읽지 못하면 그 오류를 던진다.
    public static func load(trackUUID: String, directory: URL = directory) throws -> ArtworkEdit? {
        let url = directory.appending(path: "\(trackUUID).json")
        guard let draft = try DamagedDrafts.read(ArtworkDraft.self, at: url) else { return nil }
        guard draft.trackUUID == trackUUID else { throw DraftFileDamaged(file: url) }
        guard draft.change == .set else { return ArtworkEdit(draft: draft, image: nil) }
        guard let sha = draft.imageSHA256, let image = try? Data(contentsOf: imageURL(for: draft, directory: directory)),
              sha256(image) == sha else { throw DraftFileDamaged(file: url) }
        return ArtworkEdit(draft: draft, image: image)
    }

    /// 읽을 수 있는 초안(그림 바이트 없이). 목록 표시용이라 읽지 못한 초안은 뺀다.
    public static func all(directory: URL = directory) -> [String: ArtworkDraft] {
        var drafts: [String: ArtworkDraft] = [:]
        for uuid in uuids(directory: directory) {
            if let edit = try? load(trackUUID: uuid, directory: directory) { drafts[uuid] = edit.draft }
        }
        return drafts
    }

    public static func uuids(directory: URL = directory) -> Set<String> { DraftFiles.uuids(in: directory) }

    /// 새 사본 → 초안 → 옛 사본 지우기 순서(어느 순간에 보아도 초안이 가리키는 사본이 있다). 지우기 초안이면 사본을 모두 지운다.
    public static func save(_ edit: ArtworkEdit, directory: URL = directory) throws {
        let uuid = edit.trackUUID
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try preserveIfDamaged(trackUUID: uuid, directory: directory)
        var keep: URL?
        if edit.draft.change == .set {
            guard let image = edit.image, edit.draft.imageSHA256 == sha256(image) else { throw CocoaError(.fileWriteUnknown) }
            let copy = imageURL(for: edit.draft, directory: directory)
            if (try? Data(contentsOf: copy)) != image { try image.write(to: copy, options: .atomic) }
            keep = copy
        }
        try JSONEncoder().encode(edit.draft).write(to: directory.appending(path: "\(uuid).json"), options: .atomic)
        for stale in imageURLs(trackUUID: uuid, directory: directory) where stale.lastPathComponent != keep?.lastPathComponent {
            try removeIfPresent(stale)
        }
    }

    /// 초안과 사본을 지운다(없으면 그대로). 손상된 초안은 지우지 않고 옮겨 보관한다.
    public static func remove(trackUUID: String, directory: URL = directory) throws {
        try preserveIfDamaged(trackUUID: trackUUID, directory: directory)
        try removeIfPresent(directory.appending(path: "\(trackUUID).json"))
        for copy in imageURLs(trackUUID: trackUUID, directory: directory) { try removeIfPresent(copy) }
    }

    private static func removeIfPresent(_ url: URL) throws {
        do { try FileManager.default.removeItem(at: url) }
        catch CocoaError.fileNoSuchFile { }
    }

    /// 읽지 못한 초안이면 그 곡의 사본과 함께 `damaged-drafts/artwork-drafts/`로 옮긴다.
    static func preserveIfDamaged(trackUUID: String, directory: URL) throws {
        do { _ = try load(trackUUID: trackUUID, directory: directory) }
        catch is DraftFileDamaged {
            let home = directory.deletingLastPathComponent()
            try DamagedDrafts.preserve(directory.appending(path: "\(trackUUID).json"), home: home, trackUUID: trackUUID)
            for copy in imageURLs(trackUUID: trackUUID, directory: directory) {
                try DamagedDrafts.preserve(copy, home: home, trackUUID: trackUUID, logged: false)
            }
        }
    }
}
