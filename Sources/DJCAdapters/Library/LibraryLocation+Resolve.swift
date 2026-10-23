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
                               movesDamagedDrafts: true,
                               userHome: NSHomeDirectory())
    }
}

extension SnapshotTaker {
    /// 위치 값의 라이브 master.db에서 그 스냅샷 폴더로 사본을 뜬다(원본은 읽기만 한다)
    public static func live(_ location: LibraryLocation) -> SnapshotTaker {
        let source = location.liveDatabase, directory = location.snapshotDirectory
        return SnapshotTaker { force in
            do {
                return try LibrarySnapshot.take(from: source, into: directory, force: force)
            } catch {
                // `FileManager.copyItem`·`FileHandle`은 원본을 읽을 수 없을 때도 "쓰기 권한"(513) 오류를 낸다. 그대로 두면 사본을 둘 폴더의
                // 쓰기 문제와 가를 수 없다. 원본이 있는데 열 때 커널이 접근 거부(EACCES·EPERM)를 내면 읽기 권한 오류로 바로잡는다(#299).
                // 직접 열어 보므로 ACL·개인정보 보호(TCC)로 막힌 경우도 잡는다.
                let descriptor = open(source.path, O_RDONLY), code = errno
                if descriptor >= 0 {
                    close(descriptor)
                } else if code == EACCES || code == EPERM {
                    throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: source.path,
                                                                      NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(code))])
                }
                throw error
            }
        }
    }
}
