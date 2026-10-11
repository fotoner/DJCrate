import Foundation

/// 곡 그림(아트워크) 초안(#66). 반영하면 rekordbox 라이브러리의 그림 파일 셋·`ImagePath`·`artwork.jpg` 파일 행만 고친다
/// (음원 파일에 든 그림은 그대로 둔다).
///
/// 그림 바이트는 초안에 넣지 않는다. 고른 그림의 사본은 초안 저장소가 따로 두고(`ArtworkEdit.image`), 초안에는 그 SHA-256만 둔다.
public struct ArtworkDraft: Codable, Hashable, Sendable {
    public enum Change: String, Codable, Sendable {
        /// 그림 넣기(그림 없던 곡)·바꾸기(그림 있던 곡)
        case set
        /// 그림 지우기
        case delete
    }

    public var trackUUID: String
    public var change: Change
    /// 초안을 만들 때의 rekordbox 상태. rekordbox의 그림 바꾸기는 곡 행을 건드리지 않으므로 파일 행까지 본다.
    public var base: ArtworkBase
    /// 고른 그림 파일 이름(표시용, 경로 없이)
    public var imageName: String?
    /// 저장소에 둔 그림 사본의 SHA-256(소문자 16진수). 사본이 바뀌거나 사라졌는지 본다.
    public var imageSHA256: String?

    public init(trackUUID: String, change: Change, base: ArtworkBase, imageName: String? = nil, imageSHA256: String? = nil) {
        self.trackUUID = trackUUID
        self.change = change
        self.base = base
        self.imageName = imageName
        self.imageSHA256 = imageSHA256
    }

    /// 이 초안을 쓰면 무엇이 되는지(초안을 만들 때의 base 기준)
    public var kind: ArtworkWriteKind {
        switch change {
        case .delete: .delete
        case .set: base.imagePath.isEmpty ? .add : .replace
        }
    }
}

/// 그림 초안의 기준: 곡 행 `ImagePath`와 살아 있는(`rb_local_deleted` 0) 그림 파일 행.
public struct ArtworkBase: Codable, Hashable, Sendable {
    /// `djmdContent.ImagePath`(그림이 없으면 '')
    public var imagePath: String
    /// 살아 있는 그림 파일 행(`/PIONEER/Artwork/…`). 없으면 비어 있다.
    public var files: [ArtworkFileRow]

    public init(imagePath: String, files: [ArtworkFileRow] = []) {
        self.imagePath = imagePath
        self.files = files.sorted { $0.path < $1.path }
    }

    public var hasArtwork: Bool { !imagePath.isEmpty }
}

/// 그림 파일 행(`contentFile`)에서 base로 보는 칸
public struct ArtworkFileRow: Codable, Hashable, Sendable {
    public var path: String
    public var hash: String?
    public var size: Int?
    /// `rb_data_status`
    public var status: Int?

    public init(path: String, hash: String?, size: Int?, status: Int?) {
        self.path = path
        self.hash = hash
        self.size = size
        self.status = status
    }
}

/// 그림 초안을 쓰면 일어나는 일(쓰기 결과·확인 창 문구)
public enum ArtworkWriteKind: String, Codable, Hashable, Sendable {
    case add, replace, delete

    /// "그림 넣기" 등(확인 창·결과 줄)
    public var label: String {
        switch self {
        case .add: String(ui: "앨범아트 넣기")
        case .replace: String(ui: "앨범아트 바꾸기")
        case .delete: String(ui: "앨범아트 지우기")
        }
    }
}

/// 쓰기에 넘기는 그림 초안과 그 그림 바이트(지우기는 nil)
public struct ArtworkEdit: Hashable, Sendable {
    public var draft: ArtworkDraft
    public var image: Data?

    public init(draft: ArtworkDraft, image: Data?) {
        self.draft = draft
        self.image = image
    }

    public var trackUUID: String { draft.trackUUID }
}
