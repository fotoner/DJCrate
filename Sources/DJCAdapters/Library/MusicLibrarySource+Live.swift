import DJCApplication
import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit

extension MusicLibrarySource {
    /// 이 Mac의 Music 보관함과 rekordbox 폴더(`rekordboxDirectory`, 위치 값의 라이브 rekordbox 폴더)의 동기화 선택을 읽고,
    /// DB 사본 옆 목록 사본(`.itunes.json`)을 읽고 쓴다.
    public static func live(rekordboxDirectory: URL) -> MusicLibrarySource {
        MusicLibrarySource(
            capture: { RekordboxITunesReader.capture(directory: rekordboxDirectory) },
            cached: { ITunesLibrarySnapshot.load(for: $0) },
            save: { try $0.save(for: $1) },
            syncFile: { directory in
                let url = directory.appending(path: "playlists3.sync")
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                return Result { try Data(contentsOf: url) }
            },
            applySelection: { try $0.applyingRekordboxSelection($1) },
            rootSelected: { ITunesLibrarySnapshot.rootSelected($0) },
            selectionChanged: { RekordboxITunesReader.selectionChanged(since: $0, directory: $1) })
    }
}

extension ITunesRefreshCoordinator {
    /// 이 프로세스의 Music 결과 채택 순서(앱·시험의 저장소가 함께 쓴다)
    public static let shared = ITunesRefreshCoordinator()
}
