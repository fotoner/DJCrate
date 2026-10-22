import DJCAdapters
import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import Testing

/// 실제 파일 시스템에서 사본을 뜨다 나는 오류가 원인별 실패로 갈리는지(#299).
/// 오류의 모양(Cocoa 코드·밑에 깔린 POSIX 오류)은 OS가 정하므로 가짜 오류가 아니라 임시 폴더의 실제 파일로 낸다.
/// rekordbox 폴더는 임시 폴더라 실제 라이브러리를 읽지 않는다. `force`를 켜서 이 Mac의 rekordbox 실행 여부와 상관없게 한다.
@Suite("읽기 실패 원인(실제 파일)")
struct LibraryReadFailureLiveTests {
    /// 임시 rekordbox 폴더와 스냅샷 폴더를 가리키는 위치 값
    static func location(in folder: TemporaryFolder) -> (LibraryLocation, rekordbox: URL) {
        let rekordbox = folder.url.appending(path: "rekordbox"), home = folder.url.appending(path: "home")
        try? FileManager.default.createDirectory(at: rekordbox, withIntermediateDirectories: true)
        let location = LibraryLocation.resolve(arguments: ["DJCrate"],
                                               environment: ["DJC_REKORDBOX_DIR": rekordbox.path, "DJC_HOME": home.path])
        return (location, rekordbox)
    }

    func failure(of location: LibraryLocation) -> LibraryReadFailure? {
        do {
            _ = try SnapshotTaker.live(location).take(true)
            return nil
        } catch {
            return LibraryReadFailure(stage: .snapshotCreation, keepsPreviousLibrary: false, error: error, home: NSHomeDirectory())
        }
    }

    @Test func master_db가_없으면_라이브러리를_찾지_못했다고_알린다() throws {
        let folder = try TemporaryFolder()
        let (location, _) = Self.location(in: folder)

        let failure = try #require(failure(of: location))

        #expect(failure.cause == .libraryMissing)
        #expect(failure.message == "rekordbox 라이브러리를 찾지 못했습니다. rekordbox 7을 설치하고 한 번 실행한 뒤 다시 찾아 주세요")
    }

    @Test func rekordbox_폴더가_없어도_라이브러리를_찾지_못했다고_알린다() throws {
        let folder = try TemporaryFolder()
        let (location, rekordbox) = Self.location(in: folder)
        try FileManager.default.removeItem(at: rekordbox)

        #expect(failure(of: location)?.cause == .libraryMissing)
    }

    @Test(.enabled(if: geteuid() != 0, "root는 파일 권한을 무시한다"))
    func master_db를_읽을_권한이_없으면_권한_문제라고_알린다() throws {
        let folder = try TemporaryFolder()
        let (location, rekordbox) = Self.location(in: folder)
        let database = rekordbox.appending(path: "master.db")
        try Data("not a real database".utf8).write(to: database)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: database.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: database.path) }

        let failure = try #require(failure(of: location))

        #expect(failure.cause == .permissionDenied)
        #expect(failure.message.contains("읽을 권한이 없습니다"))
    }

    @Test func 사본을_둘_폴더에_쓰지_못한_것은_읽기_권한으로_보지_않는다() throws {
        let folder = try TemporaryFolder()
        let (location, rekordbox) = Self.location(in: folder)
        try Data("not a real database".utf8).write(to: rekordbox.appending(path: "master.db"))
        // 스냅샷 폴더 자리에 파일을 둬서 폴더를 만들 수 없게 한다
        try FileManager.default.createDirectory(at: location.snapshotDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: location.snapshotDirectory)

        #expect(failure(of: location)?.cause == .other)
    }

    @Test(arguments: [("7.2.18", String?.none), ("7.2", nil), ("7.3.0", "7.3.0"), ("7.1.9", "7.1.9"), ("6.8.5", "6.8.5"), ("8", "8")])
    func 지원하지_않는_버전은_쓰기_관문과_같은_판정으로_가른다(_ installed: String, _ expected: String?) {
        #expect(LibrarySource.unsupportedVersion(installed: installed) == expected)
    }

    @Test func 설치된_rekordbox를_못_찾으면_지원하지_않는_버전으로_보지_않는다() {
        #expect(LibrarySource.unsupportedVersion(installed: nil) == nil)
    }
}
