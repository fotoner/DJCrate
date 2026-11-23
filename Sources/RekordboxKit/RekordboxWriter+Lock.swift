import DJCDomain
import DJCEnvironment
import Darwin
import Foundation
import Synchronization

/// 프로세스 사이 쓰기 잠금(R9). 같은 라이브러리에 쓰는 모든 입구(초안 쓰기·복원·시점 복원·곡 넣기·빼기·iTunes 동기화·기록으로 복원·
/// "이대로 둔다")가 사전 확인부터 파일 단계·복구가 끝날 때까지 같은 잠금을 쥔다.
/// - 키는 master.db의 링크를 푼 경로의 부모 폴더 (장치, inode)다(`RekordboxWriteLockKey`). 링크·대소문자·`/System/Volumes/Data` 별칭에
///   흔들리지 않고, 복원으로 master.db 파일이 바뀌어도 같다. `DJC_HOME`과 상관없다.
/// - 잠금 파일은 master.db를 열지 않는 별도 파일(`<키>.lock`)이고 `flock`으로 잡는다. 풀 때 파일을 지우지 않는다(지우면 다른 프로세스가
///   지운 파일을 잡고 새 파일을 또 다른 프로세스가 잡는 틈이 생긴다).
/// - 잠금 폴더는 `confstr(_CS_DARWIN_USER_TEMP_DIR)` 아래 `djc-locks/`다(`$TMPDIR`에 흔들리지 않는 사용자 전용 임시 영역,
///   `DJC_HOME`·DJCrate 사용자 폴더 밖). 시험 프로세스는 `TestProcess.sandbox` 아래이고 주입할 수 있다.
/// - 다시 들어갈 수 없다: 같은 프로세스라도 쥔 키를 또 잡으면 기다리고 시도는 nil이다(`flock`은 열린 파일마다 따로다).
public struct RekordboxWriteLocks: Sendable {
    /// 잠금 폴더
    public var folder: URL
    /// 다른 쪽이 쥐고 있어 기다리기 시작할 때 부른다(시험이 잠금 경합을 본다)
    public var contended: @Sendable (RekordboxWriteLockKey) -> Void

    public init(folder: URL? = nil, contended: @escaping @Sendable (RekordboxWriteLockKey) -> Void = { _ in }) {
        self.folder = folder ?? Self.defaultFolder
        self.contended = contended
    }

    /// 앱·CLI의 잠금(기본 폴더)
    public static var system: Self { Self() }

    /// 기본 잠금 폴더. 시험 프로세스는 샌드박스 안이다(시험의 잠금 파일이 사용자 임시 영역에 생기지 않게)
    public static var defaultFolder: URL {
        if TestProcess.isRunning { return TestProcess.sandbox.appending(path: RekordboxWriteLockKey.folderName, directoryHint: .isDirectory) }
        let size = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        if size > 0 {
            var buffer = [CChar](repeating: 0, count: size)
            if confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, size) > 0 {
                let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                return URL(filePath: path, directoryHint: .isDirectory).appending(path: RekordboxWriteLockKey.folderName, directoryHint: .isDirectory)
            }
        }
        // 사용자 임시 영역을 모르면 사용자마다 다른 이름으로 /tmp 아래에 둔다(폴더 권한·주인을 열 때 다시 본다)
        return URL(filePath: "/private/tmp/djc-locks-\(getuid())", directoryHint: .isDirectory)
    }

    // MARK: - 키

    /// master.db의 링크를 푼 경로(파일·폴더 링크를 모두 푼다). master.db가 없으면(망가진 라이브러리의 비상 복원) 부모 폴더만 푼다
    public static func resolve(_ database: URL) throws -> URL {
        let path = database.standardizedFileURL.path
        if let real = realpath(path, nil) {
            defer { free(real) }
            return URL(filePath: String(cString: real), directoryHint: .notDirectory)
        }
        // 실패 원인은 곧바로 읽는다(다른 호출이 errno를 바꾸기 전에)
        let code = errno
        let parent = database.standardizedFileURL.deletingLastPathComponent().path
        guard code == ENOENT, let real = realpath(parent, nil) else {
            throw DJCError.writeRefused(String(ui: "라이브러리 폴더를 찾지 못했습니다. 폴더가 있는지 확인한 뒤 다시 시도하세요"))
        }
        defer { free(real) }
        return URL(filePath: String(cString: real), directoryHint: .isDirectory).appending(path: database.lastPathComponent, directoryHint: .notDirectory)
    }

    /// 대상 master.db의 잠금 키: 링크를 푼 경로의 부모 폴더 (장치, inode)
    public static func key(_ database: URL) throws -> RekordboxWriteLockKey {
        let folder = try resolve(database).deletingLastPathComponent()
        var info = stat()
        guard stat(folder.path, &info) == 0 else {
            throw DJCError.writeRefused(String(ui: "라이브러리 폴더를 읽지 못했습니다. 폴더가 있는지 확인한 뒤 다시 시도하세요"))
        }
        return RekordboxWriteLockKey(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino))
    }

    /// master.db의 하드 링크 수가 1이 아니면 거부한다(R9: 같은 파일을 다른 폴더에서 가리키면 잠금 키가 갈라진다)
    static func refuseHardLinks(_ resolved: URL) throws {
        var info = stat()
        guard lstat(resolved.path, &info) == 0 else { return }
        guard info.st_nlink == 1 else {
            throw DJCError.writeRefused(String(ui: "master.db가 다른 곳과 하드 링크로 이어져 있어 저장하지 않습니다. 하드 링크를 끊은 실제 사본을 고른 뒤 다시 시도하세요"))
        }
    }

    // MARK: - 잡기

    /// 잡을 때까지 기다린다(메인 액터 밖에서 부른다)
    public func lock(_ key: RekordboxWriteLockKey) throws -> RekordboxWriteLockHold {
        let fd = try open(key)
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { return RekordboxWriteLockHold(key: key, fd: fd) }
        guard errno == EWOULDBLOCK else { try fail(fd) }
        contended(key)
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { try fail(fd) }
        }
        return RekordboxWriteLockHold(key: key, fd: fd)
    }

    /// 비차단 시도. 누가 쥐고 있으면 nil
    public func tryLock(_ key: RekordboxWriteLockKey) throws -> RekordboxWriteLockHold? {
        let fd = try open(key)
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { return RekordboxWriteLockHold(key: key, fd: fd) }
        guard errno == EWOULDBLOCK else { try fail(fd) }
        close(fd)
        return nil
    }

    private func fail(_ fd: Int32) throws -> Never {
        let code = errno
        close(fd)
        throw DJCError.writeRefused(String(ui: "쓰기 잠금을 잡지 못했습니다(\(String(cString: strerror(code)))). 잠시 뒤 다시 시도하세요"))
    }

    // MARK: - 저장소 잠금

    /// 백업·시점 스냅샷 폴더(저장소) 잠금(R11·R13): 솎기·삭제와 기록 핀 게시(근거 확인·핀·기록 저장)를 같은 저장소에 대해 하나씩 한다.
    /// 그래야 다른 대상의 솎기가 핀을 두기 직전의 근거를 지우거나, 핀을 둔 근거를 지우지 않는다. 키는 그 폴더의 (장치, inode)이고 잠금 파일은
    /// 기본 잠금 폴더의 `<키>.store.lock`이다(저장소 폴더에 파일을 더하지 않는다). 폴더가 없으면 nil(지킬 것이 없다)
    public static func lockStore(_ folder: URL) throws -> RekordboxWriteLockHold? {
        var info = stat()
        guard stat(folder.path, &info) == 0 else { return nil }
        let key = RekordboxWriteLockKey(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino))
        let locks = Self()
        let fd = try locks.open(fileName: key.name + ".store.lock")
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { try locks.fail(fd) }
        }
        return RekordboxWriteLockHold(key: key, fd: fd)
    }

    /// 잠금 폴더(`0700`, 내 것)를 링크를 따라가지 않고 열고 그 안의 잠금 파일을 연다
    private func open(_ key: RekordboxWriteLockKey) throws -> Int32 { try open(fileName: key.lockFileName) }

    private func open(fileName: String) throws -> Int32 {
        func refuse(_ detail: String) -> DJCError {
            .writeRefused(String(ui: "쓰기 잠금 폴더를 쓸 수 없습니다(\(detail)). \(folder.path) 폴더를 확인한 뒤 다시 시도하세요"))
        }
        try? FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        if mkdir(folder.path, mode_t(RekordboxWriteLockKey.folderMode)) != 0, errno != EEXIST {
            throw refuse(String(cString: strerror(errno)))
        }
        let directory = Darwin.open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw refuse(String(cString: strerror(errno))) }
        defer { close(directory) }
        var info = stat()
        guard fstat(directory, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw refuse(String(ui: "주인이나 권한이 다름"))
        }
        let fd = openat(directory, fileName, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw refuse(String(cString: strerror(errno))) }
        return fd
    }
}

/// 쥔 쓰기 잠금. `release`로 푼다(여러 번 불러도 한 번만 푼다). 잊고 버려도 풀린다
public final class RekordboxWriteLockHold: Sendable {
    public let key: RekordboxWriteLockKey
    private let fd: Mutex<Int32>

    init(key: RekordboxWriteLockKey, fd: Int32) {
        self.key = key
        self.fd = Mutex(fd)
    }

    public func release() {
        let descriptor = fd.withLock { value in defer { value = -1 }; return value }
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    deinit { release() }
}
