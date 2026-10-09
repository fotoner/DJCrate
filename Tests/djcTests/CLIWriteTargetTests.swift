@testable import djc
import DJCApplication
import DJCStorage
import Foundation
import RekordboxKit
import Testing

/// 쓰기 명령(`track-add`·`track-delete`·`cue-write` …)의 대상 인자를 한 곳(`RekordboxWriteTarget.cli`)에서 푸는 규칙.
/// 결과 값(DB·백업 폴더·share)만 본다. DB를 열거나 쓰지 않는다.
@Suite("CLI 쓰기 대상 인자")
struct CLIWriteTargetTests {
    @Test func 라이브는_rekordbox_DB와_DJCrate_백업_폴더() throws {
        let target = try #require(RekordboxWriteTarget.cli(["track-add", "--live", "--share", "/tmp/djc-share"]))
        #expect(target.database == RekordboxWriter.liveDatabase)
        #expect(target.backups == DJCPaths.rekordboxBackups)
        #expect(target.shareRoot == URL(filePath: "/tmp/djc-share"))
    }

    @Test func 사본은_그_DB와_옆_backups_폴더() throws {
        let target = try #require(RekordboxWriteTarget.cli(["track-add", "--db", "/tmp/djc-copy/master.db"]))
        #expect(target.database == URL(filePath: "/tmp/djc-copy/master.db"))
        #expect(target.backups == URL(filePath: "/tmp/djc-copy/backups"))
        #expect(target.shareRoot == nil)
    }

    /// 둘 다 주면 `--live`가 이긴다(명령마다 따로 정하지 않는다). 둘 다 없으면 nil이라 명령이 사용법 오류를 낸다.
    @Test func 둘_다_주면_라이브이고_둘_다_없으면_대상이_없다() throws {
        let both = try #require(RekordboxWriteTarget.cli(["track-delete", "--db", "/tmp/djc-copy/master.db", "--live"]))
        #expect(both.database == RekordboxWriter.liveDatabase && both.backups == DJCPaths.rekordboxBackups)
        #expect(RekordboxWriteTarget.cli(["track-delete", "--share", "/tmp/djc-share"]) == nil)
        #expect(RekordboxWriteTarget.cli(["track-delete", "--db"]) == nil)
    }
}
