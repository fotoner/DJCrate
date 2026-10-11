import DJCApplication
import DJCDomain
import DJCEnvironment
import Foundation
import RekordboxKit

extension LibraryLocation {
    /// 실행 인자·환경을 한 번 풀어 위치 값을 만든다(조립 지점만 부른다).
    /// rekordbox 폴더·스냅샷 폴더·데이터 폴더는 `DJC_REKORDBOX_DIR`·`DJC_HOME`을 따르고, 시험 프로세스는 실제 폴더 대신 임시 폴더를 받는다(#182).
    /// 쓰기·복원 대상은 rekordbox 폴더의 master.db와 그 옆 share, 초안·백업은 데이터 폴더다.
    public static func resolve(arguments: [String], environment: [String: String]) -> LibraryLocation {
        let directory = LibrarySnapshot.rekordboxDirectory(in: environment)
        let data = DJCIdentity.dataDirectory(environment: environment, support: DJCIdentity.supportDirectory)
        let explicitPath = arguments.firstIndex(of: "--db").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
            ?? environment["DJC_DB"]
        return LibraryLocation(rekordboxDirectory: directory,
                               rekordboxDirectoryOverridden: LibrarySnapshot.hasRekordboxDirectoryOverride(in: environment),
                               snapshotDirectory: LibrarySnapshot.defaultDirectory(in: environment),
                               opensExplicitCopy: arguments.contains("--db") || environment["DJC_DB"] != nil,
                               explicitCopy: explicitPath.map { URL(filePath: $0) },
                               database: directory.appending(path: "master.db"),
                               shareRoot: nil,
                               backupDirectory: data.appending(path: "rekordbox-backups"),
                               draftHome: data,
                               movesDamagedDrafts: true)
    }
}

extension SnapshotTaker {
    /// 위치 값의 라이브 master.db에서 그 스냅샷 폴더로 사본을 뜬다(원본은 읽기만 한다)
    public static func live(_ location: LibraryLocation) -> SnapshotTaker {
        let source = location.liveDatabase, directory = location.snapshotDirectory
        return SnapshotTaker { force in try LibrarySnapshot.take(from: source, into: directory, force: force) }
    }
}
