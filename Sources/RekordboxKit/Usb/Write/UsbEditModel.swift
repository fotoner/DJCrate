import DJCDomain
import Foundation

/// ID·값까지 정한 편집 하나. OneLibrary 단계(`OneLibraryEditStep.target`)와 Device Library 모델이 같은 적용 함수를 쓴다.
/// 계획한 모델과 다른 모델(앞 편집이 건너뛰어진 모델)에 적용하면 전제를 다시 보고, 맞지 않으면 던져 그 편집만 건너뛴다
enum UsbResolvedEdit: Sendable, Hashable {
    case removeTracks([Int])
    case playlist(UsbResolvedPlaylistEdit)
    case upsert(UsbTrackUpsert)
}

enum UsbResolvedPlaylistEdit: Sendable, Hashable {
    case create(UsbPlaylist)
    case rename(id: Int, name: String)
    case move(id: Int, parentID: Int, sortOrder: [UsbFormat: Int])
    /// 목록 id → 형식별 새 순번
    case reorder([Int: [UsbFormat: Int]])
    /// 목록과 그 안 목록 전부
    case delete([Int])
    case entries(UsbEntriesChange)
}

/// 목록 항목 바꾸기: 형식마다 지금 항목이 `before`와 같을 때만 `after`로
struct UsbEntriesChange: Sendable, Hashable {
    var playlistID: Int
    var before: [UsbFormat: [Int]]
    var after: [UsbFormat: [Int]]
}

/// 곡 갱신·더하기: 바꿀 곡(있어야 함)·새 곡(없어야 함)과 새 이름 행·그림 행, 목록 끝에 넣기
struct UsbTrackUpsert: Sendable, Hashable {
    var replaced: [UsbTrack] = []
    var added: [UsbTrack] = []
    var artists: [UsbNamedRow] = []
    var albums: [UsbAlbum] = []
    var genres: [UsbNamedRow] = []
    var keys: [UsbNamedRow] = []
    var labels: [UsbNamedRow] = []
    var images: [UsbImage] = []
    var entries: UsbEntriesChange?
}

/// 적용 전제가 맞지 않음(그 편집만 건너뛴다). 기술 정보(번역하지 않음)
struct UsbEditConflict: Error, CustomStringConvertible {
    let description: String
}

enum UsbEditModel {
    /// 편집을 모델에 적용한다. `writable` 밖 형식의 곡·항목은 건드리지 않는다
    static func apply(_ edit: UsbResolvedEdit, to model: UsbLibrary, writable: Set<UsbFormat>) throws -> UsbLibrary {
        var model = model
        switch edit {
        case let .removeTracks(ids): try removeTracks(ids, from: &model, writable: writable)
        case let .playlist(edit): try apply(edit, to: &model, writable: writable)
        case let .upsert(upsert): try apply(upsert, to: &model, writable: writable)
        }
        return model.canonicalized()
    }

    // MARK: 곡 빼기

    static func removeTracks(_ ids: [Int], from model: inout UsbLibrary, writable: Set<UsbFormat>) throws {
        let removing = Set(ids)
        for id in ids {
            guard let index = model.tracks.firstIndex(where: { $0.id == id }), !model.tracks[index].presentIn.isDisjoint(with: writable) else {
                throw UsbEditConflict(description: "content \(id) missing")
            }
            model.tracks[index].presentIn.subtract(writable)
            for format in writable { model.tracks[index].deviceFields[format] = nil }
            model.deadIDs[UsbIDKind.content.rawValue, default: []].insert(id)
        }
        model.tracks.removeAll { removing.contains($0.id) && $0.presentIn.isEmpty }
        for id in removing where !model.tracks.contains(where: { $0.id == id }) { model.trackRowExtras[id] = nil }
        for index in model.playlists.indices {
            for format in writable {
                guard let entries = model.playlists[index].entries[format] else { continue }
                model.playlists[index].entries[format] = entries.filter { !removing.contains($0) }
            }
        }
        model.myTagLinks = model.myTagLinks.compactMap { link in
            guard removing.contains(link.contentID) else { return link }
            var link = link
            link.presentIn.subtract(writable)
            return link.presentIn.isEmpty ? nil : link
        }
    }

    // MARK: 재생 목록

    static func apply(_ edit: UsbResolvedPlaylistEdit, to model: inout UsbLibrary, writable: Set<UsbFormat>) throws {
        func index(_ id: Int) throws -> Int {
            guard let found = model.playlists.firstIndex(where: { $0.id == id }) else { throw UsbEditConflict(description: "playlist \(id) missing") }
            return found
        }
        func requireParent(_ id: Int) throws {
            guard id == 0 || model.playlists.contains(where: { $0.id == id && $0.attribute == 1 }) else {
                throw UsbEditConflict(description: "parent \(id) missing")
            }
        }
        switch edit {
        case let .create(playlist):
            guard !model.playlists.contains(where: { $0.id == playlist.id || $0.formatIDs.values.contains(playlist.id) }) else {
                throw UsbEditConflict(description: "playlist \(playlist.id) exists")
            }
            try requireParent(playlist.parentID)
            model.playlists.append(playlist)
        case let .rename(id, name):
            model.playlists[try index(id)].name = name
        case let .move(id, parentID, sortOrder):
            try requireParent(parentID)
            let at = try index(id)
            model.playlists[at].parentID = parentID
            model.playlists[at].sortOrder.merge(sortOrder) { _, new in new }
        case let .reorder(orders):
            for (id, order) in orders { model.playlists[try index(id)].sortOrder.merge(order) { _, new in new } }
        case let .delete(ids):
            for id in ids { _ = try index(id) }
            let removing = Set(ids)
            model.playlists.removeAll { removing.contains($0.id) }
        case let .entries(change):
            try apply(change, to: &model)
        }
    }

    /// 같은 번호의 목록 이름이 철자(유니코드 스칼라)만 달라졌는지. 모델 비교(Swift 문자열 ==)는 NFC·NFD를 같다고 본다(#233)
    static func playlistNamesRespelled(_ before: UsbLibrary, _ after: UsbLibrary) -> Bool {
        let names = Dictionary(before.playlists.map { ($0.id, $0.name) }) { first, _ in first }
        return after.playlists.contains { playlist in
            names[playlist.id].map { !UsbNameSpelling.sameScalars($0, playlist.name) } ?? false
        }
    }

    static func apply(_ change: UsbEntriesChange, to model: inout UsbLibrary) throws {
        guard let at = model.playlists.firstIndex(where: { $0.id == change.playlistID }) else {
            throw UsbEditConflict(description: "playlist \(change.playlistID) missing")
        }
        for (format, before) in change.before where (model.playlists[at].entries[format] ?? []) != before {
            throw UsbEditConflict(description: "playlist \(change.playlistID) entries changed")
        }
        for (format, after) in change.after {
            guard model.playlists[at].presentIn.contains(format) else {
                throw UsbEditConflict(description: "playlist \(change.playlistID) format \(format.rawValue) missing")
            }
            let tracks = Set(model.tracks.filter { $0.presentIn.contains(format) }.map(\.id))
            if let missing = after.first(where: { !tracks.contains($0) }) {
                throw UsbEditConflict(description: "playlist \(change.playlistID) entry \(missing) missing")
            }
            model.playlists[at].entries[format] = after
        }
    }

    // MARK: 곡 갱신·더하기

    static func apply(_ upsert: UsbTrackUpsert, to model: inout UsbLibrary, writable: Set<UsbFormat>) throws {
        func insert<Row: Equatable>(_ rows: [Row], into table: inout [Row], id: KeyPath<Row, Int>, name: String) throws {
            for row in rows {
                if let existing = table.first(where: { $0[keyPath: id] == row[keyPath: id] }) {
                    guard existing == row else { throw UsbEditConflict(description: "\(name) \(row[keyPath: id]) differs") }
                } else {
                    table.append(row)
                }
            }
        }
        try insert(upsert.artists, into: &model.artists, id: \.id, name: "artist")
        try insert(upsert.albums, into: &model.albums, id: \.id, name: "album")
        try insert(upsert.genres, into: &model.genres, id: \.id, name: "genre")
        try insert(upsert.keys, into: &model.keys, id: \.id, name: "key")
        try insert(upsert.labels, into: &model.labels, id: \.id, name: "label")
        try insert(upsert.images, into: &model.images, id: \.id, name: "image")
        for track in upsert.replaced {
            guard let at = model.tracks.firstIndex(where: { $0.id == track.id }) else {
                throw UsbEditConflict(description: "content \(track.id) missing")
            }
            var track = track
            // 형식 소속은 지금 모델 것(앞 편집이 한 형식에서 뺐을 수 있다)
            track.presentIn = model.tracks[at].presentIn
            model.tracks[at] = track
        }
        for track in upsert.added {
            guard !model.tracks.contains(where: { $0.id == track.id }) else { throw UsbEditConflict(description: "content \(track.id) exists") }
            model.tracks.append(track)
        }
        // 새·바꾼 곡이 가리키는 행이 모두 있어야 한다(앞 편집이 건너뛰어져 행이 없으면 이 편집도 건너뛴다)
        let artists = Set(model.artists.map(\.id)), albums = Set(model.albums.map(\.id)), genres = Set(model.genres.map(\.id))
        let keys = Set(model.keys.map(\.id)), labels = Set(model.labels.map(\.id)), images = Set(model.images.map(\.id))
        for track in upsert.replaced + upsert.added {
            let refs: [(Int?, Set<Int>, String)] = [
                (track.artistID, artists, "artist"), (track.remixerID, artists, "artist"), (track.originalArtistID, artists, "artist"),
                (track.composerID, artists, "artist"), (track.albumID, albums, "album"), (track.genreID, genres, "genre"),
                (track.keyID, keys, "key"), (track.labelID, labels, "label"), (track.imageID, images, "image"),
            ]
            for (id, table, name) in refs {
                if let id, id != 0, !table.contains(id) { throw UsbEditConflict(description: "content \(track.id) \(name) \(id) missing") }
            }
        }
        if let change = upsert.entries { try apply(change, to: &model) }
    }
}
