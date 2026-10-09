import DJCDomain
import Foundation

/// 로컬 파일 하나의 모양(따라간 stat: 크기·수정 시각·일반 파일인지)
public struct UsbLocalFileStamp: Sendable, Hashable {
    public var size: Int64
    public var modificationDate: Date
    public var isRegularFile: Bool

    public init(size: Int64, modificationDate: Date, isRegularFile: Bool) {
        self.size = size
        self.modificationDate = modificationDate
        self.isRegularFile = isRegularFile
    }
}

/// USB 유스케이스가 이 Mac에서 하는 일(피동 포트): rekordbox 버전, 라이브 master.db 판정, 세션 사본 뜨기·지우기, 경로·볼륨 확인.
/// 실제 구현(`.live`)은 DJCAdapters가 RekordboxKit·DJCStorage로 채우고 조립 지점(앱·CLI)이 고른다. 시험은 가짜를 넣는다.
/// USB에 쓰는 일은 여기 없다(쓰기는 `UsbLibraryEngine.Writer` → `UsbWriter.write` 한 곳).
public struct UsbDevice: Sendable {
    /// 이 Mac의 rekordbox 버전(찾지 못하면 nil)
    public var appVersion: @Sendable () -> String?
    /// USB 쓰기를 확인한 rekordbox 버전인지(`RekordboxCompatibility.checkApp`)
    public var isVerifiedVersion: @Sendable (String) -> Bool
    /// 라이브 master.db인지(파일은 열지 않는다). 이 Mac의 실제 rekordbox master.db와 이 실행의 rekordbox 폴더 master.db는 늘 참이다
    /// (`UsbLiveDatabase.isLive`). 판정은 더 엄격한 쪽으로만 바꾼다
    public var isLiveDatabase: @Sendable (URL) -> Bool
    /// 세션 사본 뜨기: 넘겨받은 사본 → 세션 전용 폴더(원본은 읽기만, 곁의 WAL을 사본 안에서 합친다). 뜬 사본 경로
    public var copyLocalDatabase: @Sendable (_ database: URL, _ into: URL) throws -> URL
    /// 로컬 스냅샷 사본을 뜬 시각(명시 → 파일 이름 → mtime). 모르면 `writeRefused`
    public var snapshotTime: @Sendable (_ explicit: String?, _ database: URL) throws -> (date: Date, source: UsbSnapshotTimeSource)
    /// realpath(3). 없는 경로·오류면 nil
    public var realPath: @Sendable (String) -> String?
    /// realpath 결과가 임시 폴더 뿌리 아래인지(디스크 이미지·시험 쓰기를 받는 곳)
    public var isUnderScratch: @Sendable (String) -> Bool
    /// statfs(2) 마운트 지점(realpath 모양). 실패하면 nil
    public var mountedOn: @Sendable (String) -> String?
    /// 그 경로의 볼륨 정보(DiskArbitration·statfs·hdiutil)
    public var volumeInfo: @Sendable (URL) throws -> UsbVolumeInfo
    /// 있는지(링크는 따라간다)
    public var exists: @Sendable (URL) -> Bool
    /// 폴더 안 이름. 없거나 읽지 못하면 nil
    public var names: @Sendable (URL) -> [String]?
    /// 폴더·파일을 통째로 지운다. 없거나 지우지 못해도 넘어간다(정리)
    public var remove: @Sendable (URL) -> Void
    /// 로컬 파일 모양(링크를 따라간다). 없으면 nil
    public var stat: @Sendable (URL) throws -> UsbLocalFileStamp?
    /// Mac 쪽 USB 폴더(백업·저널·준비)와 더 만들 폴더를 만든다
    public var makeFolders: @Sendable (_ paths: UsbWritePaths, _ extra: [URL]) throws -> Void

    public init(appVersion: @escaping @Sendable () -> String?, isVerifiedVersion: @escaping @Sendable (String) -> Bool,
                isLiveDatabase: @escaping @Sendable (URL) -> Bool,
                copyLocalDatabase: @escaping @Sendable (URL, URL) throws -> URL,
                snapshotTime: @escaping @Sendable (String?, URL) throws -> (date: Date, source: UsbSnapshotTimeSource),
                realPath: @escaping @Sendable (String) -> String?, isUnderScratch: @escaping @Sendable (String) -> Bool,
                mountedOn: @escaping @Sendable (String) -> String?, volumeInfo: @escaping @Sendable (URL) throws -> UsbVolumeInfo,
                exists: @escaping @Sendable (URL) -> Bool, names: @escaping @Sendable (URL) -> [String]?,
                remove: @escaping @Sendable (URL) -> Void, stat: @escaping @Sendable (URL) throws -> UsbLocalFileStamp?,
                makeFolders: @escaping @Sendable (UsbWritePaths, [URL]) throws -> Void) {
        self.appVersion = appVersion
        self.isVerifiedVersion = isVerifiedVersion
        self.isLiveDatabase = isLiveDatabase
        self.copyLocalDatabase = copyLocalDatabase
        self.snapshotTime = snapshotTime
        self.realPath = realPath
        self.isUnderScratch = isUnderScratch
        self.mountedOn = mountedOn
        self.volumeInfo = volumeInfo
        self.exists = exists
        self.names = names
        self.remove = remove
        self.stat = stat
        self.makeFolders = makeFolders
    }

    /// 마운트 지점(realpath)이 임시 폴더 뿌리 아래인지. 쓰기 세션의 실물 관문과 같은 판정이다(그 밖의 디스크 이미지는 실물로 본다)
    public func isScratchMount(_ mountPoint: String) -> Bool {
        realPath(mountPoint).map(isUnderScratch) ?? false
    }

    /// 확인한 rekordbox 버전인지(없으면 거짓)
    public func isVerified(_ version: String?) -> Bool {
        guard let version else { return false }
        return isVerifiedVersion(version)
    }
}
