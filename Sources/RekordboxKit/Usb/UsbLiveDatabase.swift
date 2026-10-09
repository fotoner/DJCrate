import Darwin
import Foundation

/// 로컬 라이브 master.db 판정(USB 내보내기·수정 세션이 원본 사본을 열기 전에 본다). 파일은 열지 않는다(경로·stat만)
public enum UsbLiveDatabase {
    /// realpath가 같거나, 링크를 따라간 device·inode가 같거나, 표준 경로가 같으면 라이브.
    /// 이 Mac의 실제 rekordbox master.db와 이 실행의 rekordbox 폴더(`DJC_REKORDBOX_DIR`, 시험 프로세스는 임시 폴더) master.db는
    /// `others`와 상관없이 늘 본다. `others`는 더 거부할 경로를 덧붙일 때만 쓴다(판정을 좁히지 못한다)
    public static func isLive(_ database: URL, others: [URL]) -> Bool {
        let live = [LibrarySnapshot.realRekordboxDirectory, LibrarySnapshot.rekordboxDirectory].map { $0.appending(path: "master.db") } + others
        let target = UsbScratchRoots.realPath(database.path)
        var mine = Darwin.stat()
        let mineExists = stat(database.path, &mine) == 0
        return live.contains { url in
            var other = Darwin.stat()
            let sameFile = mineExists && stat(url.path, &other) == 0 && mine.st_dev == other.st_dev && mine.st_ino == other.st_ino
            let sameName = target != nil && target == UsbScratchRoots.realPath(url.path)
            return sameFile || sameName || database.standardizedFileURL.path == url.standardizedFileURL.path
        }
    }
}
