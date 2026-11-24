import DJCAdapters
import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import PortTestKit
import Testing

/// 자동 저장 엔진의 실제 포트(#403): `DJC_HOME`의 기록 파일, 대상 폴더의 조용함 파일 상태(R2). 임시 폴더에서만 본다
@Suite("자동 저장 실제 포트")
struct AutoReflectionPortsLiveTests {
    @Test func 기록_파일은_가짜와_같은_계약을_지키고_깨진_파일은_던진다() throws {
        let folder = try TemporaryFolder(prefix: "djc-auto-records")
        let home = folder.url.appending(path: "home", directoryHint: .isDirectory)
        try autoReflectionRecordsContract(.live(home: home))
        try Data("{깨짐".utf8).write(to: home.appending(path: AutoReflectionRecord.fileName))
        #expect(throws: (any Error).self) { try AutoReflectionRecords.live(home: home).load() }
    }

    @Test func 조용함은_링크를_푼_master_db_옆_파일을_stat으로만_본다() throws {
        let folder = try TemporaryFolder(prefix: "djc-auto-quiet")
        let library = folder.url.appending(path: "rekordbox", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let database = library.appending(path: "master.db")
        try Data(count: 4096).write(to: database)
        try Data().write(to: URL(filePath: database.path + "-wal"))
        try Data("<xml/>".utf8).write(to: library.appending(path: "masterPlaylists6.xml"))
        // 폴더 링크로 가리켜도 같은 파일을 본다
        let link = folder.url.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: library)
        for target in [database, link.appending(path: "master.db")] {
            let stamps = LibraryQuietStamps.live(.copy(database: target, shareRoot: nil))
            #expect(stamps.walSize == 0 && !stamps.shmExists && stamps.database?.size == 4096 && stamps.playlistsXML?.size == 6)
        }
        try Data(count: 8).write(to: URL(filePath: database.path + "-shm"))
        let shm = LibraryQuietStamps.live(.copy(database: database, shareRoot: nil))
        #expect(shm.shmExists)
        let missing = LibraryQuietStamps.live(.copy(database: folder.url.appending(path: "none/master.db"), shareRoot: nil))
        #expect(missing == LibraryQuietStamps(walSize: nil, shmExists: false, database: nil, playlistsXML: nil))
    }
}
