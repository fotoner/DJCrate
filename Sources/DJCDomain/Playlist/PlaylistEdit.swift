import Foundation

/// 재생 목록·폴더를 가리킨다: 맨 위(`root`), rekordbox에 있는 목록(ID), 같은 묶음에서 새로 만든 목록(만들 때 준 key).
/// JSON·명령줄에서는 글자 하나로 쓴다: `root`, `123456`, `new:이름`.
public enum PlaylistRef: Hashable, Sendable, Codable, CustomStringConvertible {
    case root
    case id(String)
    case new(String)

    public init(_ text: String) {
        if text == "root" { self = .root } else if text.hasPrefix("new:") { self = .new(String(text.dropFirst(4))) } else { self = .id(text) }
    }

    public var description: String {
        switch self {
        case .root: "root"
        case let .id(id): id
        case let .new(key): "new:\(key)"
        }
    }

    public init(from decoder: any Decoder) throws { self.init(try decoder.singleValueContainer().decode(String.self)) }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// 곡 항목 자리(TrackNo, 1부터)와 그 자리에 있어야 할 곡. 편집을 만든 뒤 rekordbox에서 목록이 바뀌었으면 쓰지 않는다.
public struct PlaylistEntry: Hashable, Sendable, Codable {
    public var trackNo: Int
    public var contentID: String

    public init(trackNo: Int, contentID: String) {
        self.trackNo = trackNo
        self.contentID = contentID
    }
}

/// 재생 목록 편집 한 건. 앱은 초안(`PlaylistDraft`)으로 쌓고, `RekordboxWriter.write(playlists:)`가 적힌 순서대로 한 트랜잭션에서 쓴다.
/// 각 편집은 rekordbox 7.2.18 화면에서 같은 조작을 했을 때와 같은 행을 남긴다(docs/rekordbox-internals.md "재생 목록").
public enum PlaylistEdit: Hashable, Sendable, Codable {
    /// 새 재생 목록·폴더를 부모(맨 위 또는 폴더)의 맨 위에 만든다. 뒤 편집에서는 `.new(key)`로 가리킨다.
    case create(key: String, name: String, isFolder: Bool, parent: PlaylistRef)
    case rename(playlist: PlaylistRef, name: String)
    /// 다른 폴더(또는 맨 위)의 맨 끝으로 옮긴다.
    case move(playlist: PlaylistRef, into: PlaylistRef)
    /// 같은 부모 안에서 자리를 바꾼다(0부터).
    case reorder(playlist: PlaylistRef, index: Int)
    /// 지운다. 폴더면 안에 든 목록·폴더까지.
    case delete(playlist: PlaylistRef)
    /// 곡을 목록 끝에 넣는다(이미 든 곡도 한 번 더 넣는다). 가운데 자리는 넣은 뒤 `moveTracks`로 옮긴다.
    case addTracks(playlist: PlaylistRef, contentIDs: [String])
    case removeTracks(playlist: PlaylistRef, entries: [PlaylistEntry])
    /// 곡들을 옮긴다. `to`는 옮긴 뒤 첫 곡의 자리(1부터, 옮기는 곡을 뺀 목록 기준으로 끼워 넣는 자리).
    case moveTracks(playlist: PlaylistRef, entries: [PlaylistEntry], to: Int)

    /// 편집하는 목록(만들기면 새 목록)
    public var playlist: PlaylistRef {
        switch self {
        case let .create(key, _, _, _): .new(key)
        case let .rename(playlist, _), let .move(playlist, _), let .reorder(playlist, _), let .delete(playlist),
             let .addTracks(playlist, _), let .removeTracks(playlist, _), let .moveTracks(playlist, _, _): playlist
        }
    }
}
