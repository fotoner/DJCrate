import DJCApplication
import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit

extension CompatibilityPorts {
    /// 설치된 rekordbox와 라이브러리 사본을 읽기만 한다. 사본은 `LibraryRead.resolve`(명시한 사본 또는 마지막 스냅샷, 라이브 DB 거부)로 고르고,
    /// 판정은 쓰기 관문과 같은 `RekordboxCompatibility`가 한다
    public static var live: Self {
        Self(installedAppVersion: { RekordboxCompatibility.installedAppVersion() },
             verifiedAppVersions: RekordboxCompatibility.verifiedAppVersions.sorted(),
             checkApp: { try RekordboxCompatibility.checkApp(version: $0) },
             databaseVersion: RekordboxCompatibility.databaseVersion,
             openSnapshot: { database in
                 let snapshot = try LibraryRead.resolve(database: database)
                 let db = try CipherDatabase(path: snapshot.path, key: RekordboxKey.derive())
                 return CompatibilitySnapshot(fileName: snapshot.lastPathComponent,
                                              checkSchema: { try RekordboxCompatibility.checkSchema(db) },
                                              updateCounters: { try RekordboxCompatibility.updateCounters(db) },
                                              close: { db.close() })
             },
             checkCounters: { try RekordboxCompatibility.checkCounters(local: $0, cloud: $1) })
    }
}
