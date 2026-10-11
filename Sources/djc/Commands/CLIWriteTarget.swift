import DJCApplication
import DJCStorage
import Foundation
import RekordboxKit

extension RekordboxWriteTarget {
    /// 쓰기 명령의 대상(`--live` 또는 `--db <사본.db>`, `--share <분석 뿌리>`)을 한 곳에서 푼다.
    /// 라이브는 DJCrate 데이터 폴더의 백업 폴더, 사본은 그 옆 `backups/`에 백업한다. 둘 다 없으면 nil(명령마다 사용법 오류), 둘 다 있으면 `--live`.
    static func cli(_ args: [String]) -> Self? {
        let share = value(after: "--share", in: args).map { URL(filePath: $0) }
        // 라이브는 rekordbox 폴더(`DJC_REKORDBOX_DIR`이면 그 사본 폴더)의 master.db(조립 지점이 환경에서 한 번 푼 위치)
        let location = CLIComposition.live.location
        if args.contains("--live") { return Self(database: location.database, shareRoot: share, backups: location.backupDirectory) }
        guard let path = value(after: "--db", in: args) else { return nil }
        return .copy(database: URL(filePath: path), shareRoot: share)
    }
}
