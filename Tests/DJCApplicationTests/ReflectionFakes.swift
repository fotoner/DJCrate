import DJCApplication
import DJCDomain
import Foundation
import Synchronization

/// 반영 세션 시험의 호출 기록. 시험은 줄 전체가 아니라 "무엇이 있었는가"·"무엇이 무엇보다 앞섰는가"만 본다(`first`·`last`).
final class CallLog: Sendable {
    private let lines = Mutex<[String]>([])
    func record(_ line: String) { lines.withLock { $0.append(line) } }
    var all: [String] { lines.withLock { $0 } }
    /// `prefix`로 시작하는 첫·마지막 줄의 차례
    func first(_ prefix: String) -> Int? { all.firstIndex { $0.hasPrefix(prefix) } }
    func last(_ prefix: String) -> Int? { all.lastIndex { $0.hasPrefix(prefix) } }
    func contains(_ prefix: String) -> Bool { first(prefix) != nil }
}

extension RekordboxWriteTarget {
    static let copy = RekordboxWriteTarget.copy(database: URL(filePath: "/copy/master.db"), shareRoot: URL(filePath: "/copy/share"))
}
