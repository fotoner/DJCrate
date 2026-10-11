import DJCApplication
import DJCDomain
import Foundation
import RekordboxKit

extension PointSnapshotFiles {
    /// 이 Mac의 가드(`RekordboxWriteGuard.system`)로 보는 실제 구현(앱·CLI 조립 지점이 고른다)
    public static func live() -> Self { live(guard: .system) }

    /// 시점 스냅샷의 실제 모양(RekordboxKit `RekordboxPointSnapshot`·`RekordboxPointSnapshotDiff`). 뜨기·비교는 같은 쓰기 관문의 가드로
    /// 라이브 DB·rekordbox 실행을 본다(시험은 사본만 보는 가드를 준다).
    public static func live(guard writeGuard: RekordboxWriteGuard) -> Self {
        Self(
            create: { name, database, shareRoot, directory, autoDays, now in
                try RekordboxPointSnapshot.create(name: name, database: database, shareRoot: shareRoot, in: directory, autoDays: autoDays, now: now,
                                                  guard: writeGuard)
            },
            list: { RekordboxPointSnapshot.list(in: $0) },
            find: { RekordboxPointSnapshot.find($0, in: $1) },
            setPinned: { pinned, entry, directory in _ = try RekordboxPointSnapshot.setPinned(pinned, entry, in: directory) },
            delete: { try RekordboxPointSnapshot.delete($0, in: $1) },
            compare: { entry, database, shareRoot in
                try RekordboxPointSnapshotDiff.compare(entry, database: database, shareRoot: shareRoot, guard: writeGuard)
            },
            size: { RekordboxPointSnapshot.size(of: $0) },
            canClone: { RekordboxPointSnapshot.canClone(from: $0, to: $1) },
            isLiveAndRunning: { writeGuard.isLive($0) && writeGuard.isRekordboxRunning() },
            isRekordboxRunning: { writeGuard.isRekordboxRunning() },
            takeAutoIfDue: { database, shareRoot, directory, autoDays, now, calendar, canClone in
                try RekordboxPointSnapshot.takeAutoIfDue(database: database, shareRoot: shareRoot, in: directory, autoDays: autoDays, now: now,
                                                         calendar: calendar, canClone: canClone, guard: writeGuard)
            },
            discard: { try FileManager.default.removeItem(at: $0) })
    }
}
