import DJCApplication
import DJCDomain
import Foundation
import RekordboxKit

extension RekordboxWriteLock {
    /// 쓰기 입구와 같은 잠금 파일(`flock`)과 같은 링크 풀기(realpath)를 쓰는 실제 쓰기 잠금(R9). 시험은 잠금 폴더·경합 알림을 바꿔 준다
    public static func live(_ locks: RekordboxWriteLocks = .system) -> Self {
        Self(
            resolve: { try RekordboxWriteLocks.resolve($0) },
            key: { try RekordboxWriteLocks.key($0) },
            lock: { key in
                let hold = try locks.lock(key)
                return Hold(key: key) { hold.release() }
            },
            tryLock: { key in
                try locks.tryLock(key).map { hold in Hold(key: key) { hold.release() } }
            })
    }
}
