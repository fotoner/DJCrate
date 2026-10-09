import DJCTestKit
import Foundation
import RekordboxKit
import Testing

/// USB 세션이 원본 사본을 열기 전에 보는 라이브 master.db 판정(경로·realpath·device/inode). 파일은 열지 않는다
@Suite("USB 라이브 master.db 판정")
struct UsbLiveDatabaseTests {
    @Test("같은 경로·표준 경로·심볼릭 링크·하드 링크·링크를 거친 하드 링크는 라이브, 복사본은 아니다")
    func sameFileForms() throws {
        let folder = try DJCTestKit.TemporaryFolder(prefix: "djc-live")
        let fm = FileManager.default
        let live = folder.url.appending(path: "rekordbox/master.db")
        try fm.createDirectory(at: live.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("합성".utf8).write(to: live)
        let link = folder.url.appending(path: "link.db")
        try fm.createSymbolicLink(at: link, withDestinationURL: live)
        let hard = folder.url.appending(path: "hard.db")
        try fm.linkItem(at: live, to: hard)
        let linkToHard = folder.url.appending(path: "link-hard.db")
        try fm.createSymbolicLink(at: linkToHard, withDestinationURL: hard)
        let copy = folder.url.appending(path: "copy.db")
        try fm.copyItem(at: live, to: copy)

        #expect(UsbLiveDatabase.isLive(live, others: [live]))
        #expect(UsbLiveDatabase.isLive(URL(filePath: folder.url.path + "/rekordbox/./master.db"), others: [live]))
        #expect(UsbLiveDatabase.isLive(link, others: [live]))
        #expect(UsbLiveDatabase.isLive(hard, others: [live]))
        #expect(UsbLiveDatabase.isLive(linkToHard, others: [live]))
        #expect(!UsbLiveDatabase.isLive(copy, others: [live]))
        #expect(!UsbLiveDatabase.isLive(live, others: []))
    }

    @Test("아직 없는 파일도 경로가 같으면 라이브")
    func missingFileSamePath() throws {
        let folder = try DJCTestKit.TemporaryFolder(prefix: "djc-live")
        let live = folder.url.appending(path: "master.db")
        #expect(UsbLiveDatabase.isLive(live, others: [live]))
        #expect(!UsbLiveDatabase.isLive(folder.url.appending(path: "other.db"), others: [live]))
    }

    @Test("이 실행의 rekordbox 폴더(DJC_REKORDBOX_DIR, 시험 프로세스는 임시 폴더) master.db도 빈 목록으로 늘 라이브")
    func runRekordboxFolderAlwaysLive() throws {
        let folder = LibrarySnapshot.rekordboxDirectory
        #expect(UsbLiveDatabase.isLive(folder.appending(path: "master.db"), others: []))
        #expect(UsbLiveDatabase.isLive(URL(filePath: folder.path + "/./master.db"), others: []))
        #expect(!UsbLiveDatabase.isLive(folder.appending(path: "other.db"), others: []))
    }

    @Test("이 Mac의 실제 rekordbox master.db는 넘긴 목록과 상관없이 늘 라이브(열지 않고 경로만 본다)")
    func realLibraryAlwaysLive() {
        // 실제 라이브러리는 열지도 쓰지도 않는다. 경로 메타데이터(stat·realpath)만 보고, 파일이 없어도 표준 경로 비교로 통과한다
        let real = LibrarySnapshot.realRekordboxDirectory.appending(path: "master.db")
        #expect(UsbLiveDatabase.isLive(real, others: []))
    }
}
