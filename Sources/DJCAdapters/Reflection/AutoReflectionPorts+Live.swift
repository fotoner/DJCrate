import DJCApplication
import DJCDomain
import Foundation
import RekordboxKit

// 자동 저장 엔진(`AutoReflection`)의 실제 포트. 조립 지점(`AppComposition`)이 고른다.

extension ReflectionClock {
    /// 이 Mac의 시계
    public static var live: Self { Self(now: { Date() }, sleep: { try await Task.sleep(for: $0) }) }
}

extension AutoReflectionRecords {
    /// `home`(이 실행의 `DJC_HOME` 데이터 폴더) 아래 `auto-reflection.json`. 없으면 빈 기록, 읽지 못하면 던진다(엔진은 멈춤으로 본다)
    public static func live(home: URL) -> Self {
        let url = home.appending(path: AutoReflectionRecord.fileName, directoryHint: .notDirectory)
        return Self(load: {
            guard FileManager.default.fileExists(atPath: url.path) else { return AutoReflectionRecord() }
            return try JSONDecoder().decode(AutoReflectionRecord.self, from: Data(contentsOf: url))
        }, save: { record in
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            try encoder.encode(record).write(to: url, options: .atomic)
        })
    }
}

extension LibraryQuietStamps {
    /// 대상 폴더의 조용함 조건 파일 상태(R2): 링크를 푼 master.db 옆 `-wal` 크기, `-shm`이 있는지, master.db·masterPlaylists6.xml 크기·시각.
    /// 파일을 열지 않고 `stat`만 한다(읽기 전용). 링크를 풀지 못하면 적힌 경로를 본다
    public static func live(_ target: RekordboxWriteTarget) -> Self {
        let database = (try? RekordboxWriteLocks.resolve(target.database)) ?? target.database
        func stamp(_ url: URL) -> RekordboxFileStamp? {
            var info = stat()
            guard stat(url.path, &info) == 0 else { return nil }
            return RekordboxFileStamp(size: Int64(info.st_size),
                                      modifiedNanoseconds: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec))
        }
        let wal = URL(filePath: database.path + "-wal"), shm = URL(filePath: database.path + "-shm")
        let playlists = database.deletingLastPathComponent().appending(path: "masterPlaylists6.xml")
        return Self(walSize: stamp(wal)?.size, shmExists: stamp(shm) != nil, database: stamp(database), playlistsXML: stamp(playlists))
    }
}

extension RekordboxRunState {
    /// 이 Mac의 커널 프로세스 목록으로 본 rekordbox·Agent 실행 여부(프로세스를 띄우지 않는다. 읽지 못하면 모름 = 켜짐)
    public static func live() -> Self { RekordboxProcessList.state() }
}
