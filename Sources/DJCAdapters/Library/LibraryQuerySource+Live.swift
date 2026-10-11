import DJCApplication
import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit

extension LibraryQuerySource {
    /// 사본 DB(`LibraryRead`)와 초안 폴더 `home`을 읽는다
    public static func live(home: URL) -> LibraryQuerySource {
        LibraryQuerySource(
            open: { snapshot, share, preset in
                let read = Box(try LibraryRead(snapshot: snapshot, home: home, shareRoot: share, commentPreset: preset))
                return LibraryQuery(
                    search: { try read.value.search(query: $0, bpm: $1, key: $2, playlistID: $3, filter: $4) },
                    track: { try read.value.track(id: $0) },
                    playlists: { read.value.playlists(tree: $0) },
                    playlist: { try read.value.playlist(id: $0) },
                    histories: { read.value.histories() },
                    history: { try read.value.history(id: $0) },
                    drafts: { read.value.drafts() },
                    duplicates: { read.value.duplicates() },
                    report: { read.value.libraryReport(checkFiles: $0) },
                    paths: { read.value.paths(query: $0) },
                    titlePaths: { read.value.titlePaths(query: $0) },
                    draftSource: { try read.value.draftSource(id: $0) },
                    isInPlaylist: { read.value.isInPlaylist(id: $0) },
                    colors: read.value.colors)
            },
            parse: { LibraryRead.parse(comment: $0) },
            compatibility: { try LibraryRead.compatibility(snapshot: $0, version: RekordboxCompatibility.installedAppVersion()) })
    }

    /// 한 번 연 사본(읽기만 하고 바꾸지 않는다)
    private final class Box: @unchecked Sendable {
        let value: LibraryRead
        init(_ value: LibraryRead) { self.value = value }
    }
}
