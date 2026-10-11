import DJCDomain
import Foundation

/// 로컬 스냅샷 사본에서 USB 짝짓기 키를 읽는 창구(피동 포트). 실제 구현은 DJCAdapters가 RekordboxKit `LocalLibraryKeysReader`로 채운다.
/// 백그라운드 작업에서 부른다(사본을 읽기 전용으로 연다)
public struct LocalLibraryKeysSource: Sendable {
    public var load: @Sendable (_ snapshot: URL) throws -> LocalLibraryKeys

    public init(load: @escaping @Sendable (URL) throws -> LocalLibraryKeys) {
        self.load = load
    }
}

/// 앱이 연 스냅샷에서 읽은 짝짓기 키(백그라운드에서 채우고 어디서나 읽는다)
public final class LocalLibraryKeysCache: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: LocalLibraryKeys?

    public init() {}

    public var current: LocalLibraryKeys? { lock.withLock { keys } }

    public func set(_ keys: LocalLibraryKeys?) {
        lock.withLock { self.keys = keys }
    }
}
