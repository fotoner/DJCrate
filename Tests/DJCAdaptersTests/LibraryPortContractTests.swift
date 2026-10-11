import DJCAdapters
import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import PortTestKit
import RekordboxFixtures
import RekordboxKit
import Testing

/// 라이브러리 읽기 포트의 계약(실제 구현: 암호화 DB 사본·스냅샷 폴더·목록 사본 파일): 가짜(`LibrarySource.memory`·`MemoryMusicLibrary`)에
/// DJCApplicationTests가 돌리는 같은 계약 함수를 돌린다.
@Suite("라이브러리 읽기 포트 계약(실제)")
struct LibraryPortContractTests {
    @Test func 라이브러리_실제_구현() throws {
        let fixture = try RekordboxFixture()
        let tracks = [TrackSpec(), TrackSpec()]
        try fixture.add(tracks: tracks)
        let folder = try TemporaryFolder(prefix: "djc-library-source")
        let older = folder.url.appending(path: "master-2026-01-01T000000.db"), newest = folder.url.appending(path: "master-2026-01-02T000000.db")
        try FileManager.default.copyItem(at: fixture.database, to: older)
        try FileManager.default.copyItem(at: fixture.database, to: newest)
        try librarySourceContract(.live, directory: folder.url, newest: newest, ids: Set(tracks.map(\.id)))
        // 스냅샷 이름에 시각이 없으면 바뀌었는지 모른다(거짓)
        #expect(!LibrarySource.live.changed(fixture.database, fixture.database))
    }

    @Test func Music_실제_구현() throws {
        let folder = try TemporaryFolder(prefix: "djc-music-source")
        let directory = folder.url.appending(path: "rekordbox")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try musicLibrarySourceContract(.live(rekordboxDirectory: directory), database: folder.url.appending(path: "master-1.db"), directory: directory)
    }
}
