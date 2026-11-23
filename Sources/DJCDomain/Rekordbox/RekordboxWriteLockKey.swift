import Foundation

/// 쓰기 잠금 키(R9): master.db의 링크를 푼 뒤 그 부모 폴더의 (장치, inode). 링크·대소문자·`/System/Volumes/Data` 같은
/// 별칭으로 가리켜도 같고, 복원으로 master.db 파일이 바뀌어도 같다. `DJC_HOME`과 상관없다.
/// 키를 재는 일(stat)과 잠금(`flock`, 풀 때 파일을 지우지 않는다)은 입출력이라 쓰기 입구와 쓰기 잠금 포트가 한다.
/// 같은 키는 준비 폴더(`RekordboxStaging`)와 미정리 목록의 대상 이름으로도 쓴다.
public struct RekordboxWriteLockKey: Hashable, Codable, Sendable, CustomStringConvertible {
    /// 잠금 폴더 이름. 자리는 `confstr(_CS_DARWIN_USER_TEMP_DIR)` 아래다(`$TMPDIR`에 흔들리지 않는 사용자 전용 임시 영역).
    /// 시험 프로세스는 `TestProcess.sandbox` 아래이고 주입할 수 있다. `DJC_HOME`·DJCrate 사용자 폴더 밖이다
    public static let folderName = "djc-locks"
    /// 잠금 폴더 권한. 폴더는 `O_NOFOLLOW`로 연다
    public static let folderMode: UInt16 = 0o700

    public var device: UInt64
    public var inode: UInt64

    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }

    /// 파일·폴더 이름에 쓰는 글자: `<장치 16진>-<inode 16진>`
    public var name: String { String(device, radix: 16) + "-" + String(inode, radix: 16) }

    /// `name`을 다시 읽는다. 모양이 다르면 nil
    public init?(name: String) {
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let device = UInt64(parts[0], radix: 16), let inode = UInt64(parts[1], radix: 16) else { return nil }
        self.init(device: device, inode: inode)
    }

    /// 잠금 폴더 안 잠금 파일 이름
    public var lockFileName: String { name + ".lock" }

    public var description: String { name }
}

/// 준비 폴더(R10): 초안 쓰기가 커밋 전에 분석·그림·XML의 새 내용을 만들어 두는 곳. 바꿀 파일의 루트(DB 폴더·분석 루트)마다
/// 그 볼륨에 `.djc-staging/<대상 키>/`로 둔다. 곡 분석 폴더와 백업의 `anlz/` 안에는 두지 않는다. 쓰기가 끝나면 지우고,
/// 남은 준비 폴더는 그 대상의 잠금 아래에서 다음 쓰기 전에 지운다. 만들고 지우는 일은 쓰기 입구가 한다.
public enum RekordboxStaging {
    /// 루트 바로 아래 폴더 이름
    public static let folderName = ".djc-staging"

    /// 루트 하나의 이 대상 준비 폴더
    public static func folder(root: URL, key: RekordboxWriteLockKey) -> URL {
        root.appending(path: folderName, directoryHint: .isDirectory).appending(path: key.name, directoryHint: .isDirectory)
    }
}
