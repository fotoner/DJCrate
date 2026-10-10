import DJCAdapters
import DJCApplication
import DJCDomain
import DJCEnvironment
import DJCStorage
import Foundation
import RekordboxKit
import Testing

/// 조립 지점이 실행 인자·환경을 한 번 풀어 만드는 라이브러리 위치(adv3 R1). 화면 모델이 환경을 다시 읽던 계산과 같은 값이어야 하고,
/// 시험 프로세스에서는 실제 rekordbox·DJCrate 폴더 대신 임시 폴더여야 한다(#182).
@Suite("라이브러리 위치")
struct LibraryLocationTests {
    @Test func 시험_프로세스는_환경이_없으면_임시_폴더를_가리킨다() {
        let location = LibraryLocation.resolve(arguments: ["DJCrate"], environment: [:])
        #expect(location.rekordboxDirectory == TestProcess.sandbox.appending(path: "rekordbox"))
        #expect(location.rekordboxDirectory != LibrarySnapshot.realRekordboxDirectory)
        #expect(location.database == location.liveDatabase && location.shareRoot == nil)
        #expect(!location.draftHome.path.hasPrefix(DJCIdentity.userSupportDirectory.path))
        #expect(location.backupDirectory == location.draftHome.appending(path: "rekordbox-backups"))
        #expect(!location.opensExplicitCopy && location.explicitCopy == nil && location.allowsSnapshot && location.mayCaptureMusic)
        #expect(location.movesDamagedDrafts)
    }

    @Test func 이_프로세스의_위치는_옛_전역_기본값과_같다() {
        let info = ProcessInfo.processInfo
        let location = LibraryLocation.resolve(arguments: info.arguments, environment: info.environment)
        #expect(location.database == RekordboxWriter.liveDatabase)
        #expect(location.backupDirectory == DJCPaths.rekordboxBackups)
        #expect(location.draftHome == DJCPaths.userData)
        #expect(location.snapshotDirectory == LibrarySnapshot.defaultDirectory)
        #expect(location.rekordboxDirectory == LibrarySnapshot.rekordboxDirectory)
    }

    @Test func 명시한_사본과_사본_rekordbox_폴더() {
        let location = LibraryLocation.resolve(arguments: ["DJCrate", "--db", "/tmp/djc-copy/master.db"],
                                               environment: ["DJC_REKORDBOX_DIR": "/tmp/djc-rb"])
        #expect(location.opensExplicitCopy && location.explicitCopy == URL(filePath: "/tmp/djc-copy/master.db"))
        #expect(location.rekordboxDirectoryOverridden && !location.mayCaptureMusic)
        #expect(location.rekordboxDirectory == URL(filePath: "/tmp/djc-rb") && location.database == URL(filePath: "/tmp/djc-rb/master.db"))
        #expect(location.snapshotDirectory == URL(filePath: "/tmp/djc-rb/djc-snapshots"))
        // 사본 rekordbox 폴더가 있으면 명시한 사본으로 열어도 스냅샷을 뜰 수 있다.
        #expect(location.allowsSnapshot)
    }

    @Test func 사본_폴더_없이_DJC_DB만_주면_스냅샷을_뜨지_않는다() {
        let location = LibraryLocation.resolve(arguments: ["DJCrate"], environment: ["DJC_DB": "/tmp/djc-copy.db"])
        #expect(location.opensExplicitCopy && location.explicitCopy == URL(filePath: "/tmp/djc-copy.db"))
        #expect(!location.allowsSnapshot)
        // --db만 있고 경로가 없어도 명시 사본 실행이다(옛 판정 그대로).
        let bare = LibraryLocation.resolve(arguments: ["DJCrate", "--db"], environment: [:])
        #expect(bare.opensExplicitCopy && bare.explicitCopy == nil && !bare.allowsSnapshot)
    }

    /// iTunes 새로고침·동기화·스냅샷의 출처 선택은 명시한 사본(`--db`, 빈 값이라도 `DJC_DB`)만 그 사본으로 제한한다
    /// (옛 ITunesPlaylistIntegrationTests의 `explicitDatabaseRequested` 판정)
    @Test func 명시한_사본_판정은_인자와_DJC_DB만_본다() {
        func explicit(_ arguments: [String], _ environment: [String: String]) -> Bool {
            LibraryLocation.resolve(arguments: arguments, environment: environment).opensExplicitCopy
        }
        #expect(explicit(["DJCrate", "--db", "/copy.db"], [:]))
        #expect(explicit(["DJCrate"], ["DJC_DB": "/copy.db"]))
        #expect(explicit(["DJCrate"], ["DJC_DB": ""]))
        #expect(!explicit(["DJCrate"], [:]))
        #expect(!explicit(["DJCrate"], ["DJC_REKORDBOX_DIR": "/copy"]))
    }

    /// `--db`는 읽기 출처만 바꾼다(2026-10-10 결정): 쓰기 대상(반영·복원·iTunes 동기화)은 늘 rekordbox 폴더의 master.db다.
    @Test func 명시한_사본은_읽기_출처만_바꾸고_쓰기_대상은_rekordbox_폴더다() {
        let copy = LibraryLocation.resolve(arguments: ["DJCrate", "--db", "/tmp/djc-copy/master.db"], environment: [:])
        #expect(copy.explicitCopy == URL(filePath: "/tmp/djc-copy/master.db") && copy.database == copy.liveDatabase)
        let overridden = LibraryLocation.resolve(arguments: ["DJCrate"], environment: ["DJC_REKORDBOX_DIR": "/tmp/djc-rb"])
        #expect(overridden.database == URL(filePath: "/tmp/djc-rb/master.db") && overridden.database == overridden.liveDatabase)
    }

    @Test func DJC_HOME은_초안과_백업_폴더를_옮기고_스냅샷은_옮기지_않는다() {
        let location = LibraryLocation.resolve(arguments: [], environment: ["DJC_HOME": "/tmp/djc-home"])
        #expect(location.draftHome == URL(filePath: "/tmp/djc-home"))
        #expect(location.backupDirectory == URL(filePath: "/tmp/djc-home/rekordbox-backups"))
        #expect(!location.snapshotDirectory.path.hasPrefix("/tmp/djc-home"))
    }
}
