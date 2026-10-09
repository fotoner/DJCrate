@testable import DJCStorage
import DJCDomain
import Foundation
import RekordboxFixtures
import Testing

/// #187: 화면이 잠긴 동안에도 iTunes 목록 사본을 읽고 덮어쓸 수 있어야 한다.
/// 시험에서 화면 잠금을 만들 수는 없으니, 잠금 중 닫힌 파일을 열 수 없게 하는 보호 등급을 쓰지 않는지로 확인한다.
@Suite("iTunes 목록 사본 파일 보호")
struct ITunesSnapshotFileProtectionTests {
    typealias Playlist = ITunesLibrarySnapshot.Playlist

    /// 화면이 잠기면 닫힌 파일을 다시 열 수 없는 등급.
    private static let lockBlocked: [FileProtectionType] = [.complete, .completeUnlessOpen]

    private func protection(of url: URL) throws -> FileProtectionType? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.protectionKey] as? FileProtectionType
    }

    @Test func 저장_옵션은_첫_잠금_해제_뒤_접근_등급이고_원자적이다() {
        let options = ITunesLibrarySnapshot.writeOptions
        // 보호 등급은 한 덩어리 값이라 contains가 아니라 마스크로 비교한다(UnlessOpen은 Complete의 비트를 포함한다).
        // OptionSet.intersection은 이 SDK에서 등급 비트를 지워 버려 rawValue로 직접 가른다.
        let level = options.rawValue & Data.WritingOptions.fileProtectionMask.rawValue
        #expect(level == Data.WritingOptions.completeFileProtectionUntilFirstUserAuthentication.rawValue)
        #expect(options.contains(.atomic))
    }

    @Test func 저장한_사본은_화면_잠금_중_읽을_수_없는_등급이_아니다() throws {
        let fixture = try RekordboxFixture()
        try ITunesLibrarySnapshot(playlists: [.init(id: "A", name: "목록")]).save(for: fixture.database)
        let level = try protection(of: ITunesLibrarySnapshot.url(for: fixture.database))
        #expect(level.map { !Self.lockBlocked.contains($0) } ?? true, "보호 등급: \(String(describing: level?.rawValue))")
    }

    @Test func 잠금_중_읽기_불가_등급으로_남은_옛_사본도_덮어쓰면_풀린다() throws {
        let fixture = try RekordboxFixture()
        let file = ITunesLibrarySnapshot.url(for: fixture.database)
        // #187 이전 버전이 쓴 파일: 사용자 디스크에는 이 등급의 사본이 이미 남아 있다.
        try Data("{}".utf8).write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
        try ITunesLibrarySnapshot(playlists: [.init(id: "A", name: "새 목록")]).save(for: fixture.database)
        let level = try protection(of: file)
        #expect(level.map { !Self.lockBlocked.contains($0) } ?? true, "보호 등급: \(String(describing: level?.rawValue))")
    }

    /// 화면이 잠겨 있을 때 돌리면 실제 잠금 중 읽기·덮어쓰기까지 확인한다(등급이 잘못이면 EPERM으로 `.unavailable`이 된다).
    @Test func 저장한_사본을_읽고_다시_덮어쓰고_다시_읽는다() throws {
        let fixture = try RekordboxFixture()
        try ITunesLibrarySnapshot(playlists: [.init(id: "A", name: "처음")]).save(for: fixture.database)
        let first = ITunesLibrarySnapshot.load(for: fixture.database)
        #expect(first.status == .ready)
        #expect(first.playlists.map(\.name) == ["처음"])
        try ITunesLibrarySnapshot(playlists: [.init(id: "A", name: "다음")]).save(for: fixture.database)
        let second = ITunesLibrarySnapshot.load(for: fixture.database)
        #expect(second.status == .ready)
        #expect(second.playlists.map(\.name) == ["다음"])
    }
}
