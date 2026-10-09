import DJCApplication
import DJCDomain
import Foundation
import RekordboxKit

extension RecoveryReader {
    /// 원본 DB·분석 파일을 임시 사본(`WritePreviewSnapshot`)으로 떠서 읽는다. 원본은 읽기만 하고 사본은 끝나면 지운다.
    public static let live = RecoveryReader { source, share, grids in
        try await WritePreviewSnapshot.withCopy(from: source, shareRoot: share, grids: grids) { database, copiedShare in
            let library = try RekordboxLibrary.load(snapshot: database)
            var loaded: [String: Result<BeatGrid?, any Error>] = [:]
            for draft in grids {
                let tracks = library.tracks.filter { $0.uuid == draft.trackUUID }
                guard tracks.count == 1, let track = tracks.first, !track.isStreaming,
                      let path = track.analysisDataPath, !path.isEmpty else {
                    loaded[draft.trackUUID] = .success(nil)
                    continue
                }
                loaded[draft.trackUUID] = Result { try BeatGrid.load(anlz: copiedShare.appending(path: String(path.drop(while: { $0 == "/" })))) }
            }
            return (library, loaded)
        }
    }
}
