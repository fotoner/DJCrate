import CoreGraphics
import DJCDomain
import Foundation

/// 앨범아트 그림(포트): rekordbox가 받는 그림인지 보고(JPEG·PNG·회전 없음 등), 초안 사본 이름(해시)을 매기고,
/// 목록·인스펙터가 보일 rekordbox 그림(share의 `PIONEER/Artwork`)을 작게 읽는다. 실제 구현은 DJCAdapters.
public struct ArtworkFiles: Sendable {
    /// 쓸 수 없는 그림이면 이유(무엇을 하면 되는지까지)
    public var unsupportedReason: @Sendable (Data) -> String?
    /// 넣기·바꾸기 초안(그림 사본과 그 해시)
    public var edit: @Sendable (_ trackUUID: String, _ base: ArtworkBase, _ image: Data, _ imageName: String?) -> ArtworkEdit
    /// rekordbox 그림을 긴 변이 `maxPixels` 이하가 되게 작게 읽는다(큰 그림 → 중간 그림 순). share 뿌리가 nil이면 기본 rekordbox 폴더. 메인 밖에서 부른다
    public var thumbnail: @Sendable (_ imagePath: String?, _ shareRoot: URL?, _ maxPixels: Int) -> CGImage?
    /// 곡 목록 칸의 작은 그림(rekordbox가 만든 작은 그림을 64픽셀로). share 뿌리가 nil이면 기본 rekordbox 폴더. 메인 밖에서 부른다
    public var listThumbnail: @Sendable (_ imagePath: String?, _ shareRoot: URL?) -> CGImage?

    public init(unsupportedReason: @escaping @Sendable (Data) -> String?,
                edit: @escaping @Sendable (_ trackUUID: String, _ base: ArtworkBase, _ image: Data, _ imageName: String?) -> ArtworkEdit,
                thumbnail: @escaping @Sendable (_ imagePath: String?, _ shareRoot: URL?, _ maxPixels: Int) -> CGImage?,
                listThumbnail: @escaping @Sendable (_ imagePath: String?, _ shareRoot: URL?) -> CGImage?) {
        self.unsupportedReason = unsupportedReason
        self.edit = edit
        self.thumbnail = thumbnail
        self.listThumbnail = listThumbnail
    }
}

/// 곡 그림 초안(유스케이스, #66): 그림 넣기·바꾸기·지우기를 초안으로 쌓는다(반영 때 rekordbox 라이브러리에 쓴다, 음원 파일의 그림은 그대로).
/// 그림을 고르면 그 사본을 초안 폴더에 바로 둔다(원본 파일을 옮겨도 초안이 남게). 저장은 그 자리에서 끝나 실패하면 바로 알린다.
public struct EditArtwork: Sendable {
    let artwork: ArtworkFiles
    let files: TrackFiles
    let drafts: DraftStore

    public init(artwork: ArtworkFiles, files: TrackFiles, drafts: DraftStore) {
        self.artwork = artwork
        self.files = files
        self.drafts = drafts
    }

    /// 그림을 고칠 수 있는 곡(이 라이브러리의 로컬 곡). 추가한 곡·USB 곡·스트리밍 곡은 뺀다
    public static func canEdit(_ row: TrackRow) -> Bool { !row.isStaged && !row.isUsb && !row.track.isStreaming }

    /// 고른 그림 파일을 읽는다(읽지 못하면 던진다)
    public func image(at url: URL) throws -> Data { try files.read(url) }

    /// 넣기·바꾸기 초안. 확인하지 않은 그림이면 만들지 않고 이유를 던진다(`Refused`)
    public func setEdits(image: Data, name: String?, targets: [(uuid: String, base: ArtworkBase)]) throws -> [ArtworkEdit] {
        if let reason = artwork.unsupportedReason(image) { throw Refused(message: reason) }
        return targets.map { artwork.edit($0.uuid, $0.base, image, name) }
    }

    /// 그림을 쓰지 않은 이유(화면에 그대로 보인다)
    public struct Refused: Error, Sendable {
        public var message: String
    }

    /// 초안을 저장한다. 저장한 초안과 저장하지 못한 곡 수
    public func save(_ edits: [ArtworkEdit]) -> (saved: [ArtworkEdit], failed: Int) {
        var saved: [ArtworkEdit] = [], failed = 0
        for edit in edits {
            do {
                try drafts.saveArtwork(edit)
                saved.append(edit)
            } catch { failed += 1 }
        }
        return (saved, failed)
    }

    /// 초안과 사본을 지운다(메모리·파일 어디에든 있는 곡만). 지운 곡과 지우지 못한 곡 수
    public func remove(_ uuids: [String], inMemory: Set<String>) -> (removed: [String], failed: Int) {
        let stored = drafts.artworkDraftUUIDs()
        var removed: [String] = [], failed = 0
        for uuid in uuids where inMemory.contains(uuid) || stored.contains(uuid) {
            do {
                try drafts.removeArtwork(uuid)
                removed.append(uuid)
            } catch { failed += 1 }
        }
        return (removed, failed)
    }

    /// 한 동작에서 저장·지우기에 실패한 곡이 있으면 알릴 문장
    public static func failureText(_ failed: Int) -> String? {
        failed == 0 ? nil : String(ui: "\(failed)곡의 앨범아트 초안을 저장하지 못했으니 DJCrate 데이터 폴더의 쓰기 권한을 확인한 뒤 다시 하세요")
    }

    /// 초안의 그림 사본(넣기·바꾸기 초안만)
    public func draftImage(_ uuid: String) -> Data? { (try? drafts.artworkEdit(uuid))?.image }

    /// share의 rekordbox 그림을 `maxPixels` 안으로 줄인 것(인스펙터). 없거나 읽지 못하면 nil
    public func thumbnail(imagePath: String?, shareRoot: URL?, maxPixels: Int) -> CGImage? {
        artwork.thumbnail(imagePath, shareRoot, maxPixels)
    }

    /// 목록 칸의 작은 그림(rekordbox가 만든 작은 그림 파일). 없거나 읽지 못하면 nil
    public func listThumbnail(imagePath: String?, shareRoot: URL?) -> CGImage? { artwork.listThumbnail(imagePath, shareRoot) }
}
