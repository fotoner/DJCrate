import DJCApplication
import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit

extension LibrarySource {
    /// 스냅샷 사본(암호화 DB)과 분석 파일을 읽고, 스냅샷 폴더·라이브 DB 시각을 본다. 읽기 단계 기록은 표준 오류로 낸다.
    public static var live: LibrarySource {
        LibrarySource(
            library: { try RekordboxLibrary.load(snapshot: $0) },
            tempoChanges: { tracks, shareRoot in
                let tempo = TempoScan(count: tracks.count)
                DispatchQueue.concurrentPerform(iterations: tracks.count) { i in
                    let track = tracks[i]
                    guard !track.isStreaming, let url = RekordboxShare.analysisURL(track.analysisDataPath, root: shareRoot),
                          let grid = try? BeatGrid.load(anlz: url) else { return }
                    tempo.set(i, grid.tempoChanges)
                }
                return tempo.values
            },
            grid: { path, shareRoot in RekordboxShare.analysisURL(path, root: shareRoot).flatMap { try? BeatGrid.load(anlz: $0) } },
            latestSnapshot: { try LibrarySnapshot.latest(in: $0) },
            snapshots: { directory in
                ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
                    .filter { $0.pathExtension == "db" }
            },
            changed: { LibrarySnapshot.changed(since: $0, source: $1) },
            isRekordboxRunning: { LibrarySnapshot.isRekordboxRunning() },
            log: { FileHandle.standardError.write(Data("\($0)\n".utf8)) },
            resolveCopy: { try LibraryRead.resolve(database: $0) })
    }
}

/// 병렬로 채우는 변속 결과(칸마다 한 스레드만 쓴다).
final class TempoScan: @unchecked Sendable {
    private(set) var values: [[Double]]
    private let lock = NSLock()
    init(count: Int) { values = Array(repeating: [], count: count) }
    func set(_ index: Int, _ value: [Double]) {
        guard !value.isEmpty else { return }
        lock.lock(); values[index] = value; lock.unlock()
    }
}
