import DJCDomain
import Foundation

/// 쓰기 전 백업 폴더의 목록(`manifest.json`). 백업한 파일은 폴더 안 `files/<상대 경로>`에 있다
public struct UsbManifest: Codable, Sendable, Equatable {
    /// 지운 음원의 로컬 원본(되돌릴 때 SHA-1이 같으면 다시 복사한다)
    public struct RemovedAudio: Codable, Sendable, Equatable {
        public var path: String
        public var localOriginal: String?
        public var localOriginalSHA1: String?
        public var size: Int64
        public var sha256: String
        /// USB에 있던 파일의 mtime(다시 복사할 때 되살린다)
        public var modificationDate: Date?

        public init(path: String, localOriginal: String?, localOriginalSHA1: String?, size: Int64, sha256: String, modificationDate: Date?) {
            self.path = path
            self.localOriginal = localOriginal
            self.localOriginalSHA1 = localOriginalSHA1
            self.size = size
            self.sha256 = sha256
            self.modificationDate = modificationDate
        }
    }

    public var formatVersion = 1
    public var volumeUUID: String
    public var volumeName: String
    public var appVersion: String
    public var session: String
    /// 정리·"가장 최근" 판정에 쓰는 실제 만든 시각
    public var createdAt: Date
    /// 백업한 파일: 상대 경로 → 크기·mtime·SHA-256
    public var files: [String: UsbFingerprint.Stamp] = [:]
    /// 원래 있던 `._<이름>`(백업에 있음)
    public var appleDoublesPreexisting: [String] = []
    public var removedAudio: [RemovedAudio] = []
    /// 이번 쓰기가 건드릴 경로 중 쓰기 전에 있던 파일(되돌린 뒤 같아야 한다)
    public var before: [String: UsbTreeStamp] = [:]
    /// 이번 쓰기가 건드릴 경로 중 쓰기 전에 없던 파일
    public var absentBefore: [String] = []

    public init(volumeUUID: String, volumeName: String, appVersion: String, session: String, createdAt: Date) {
        self.volumeUUID = volumeUUID
        self.volumeName = volumeName
        self.appVersion = appVersion
        self.session = session
        self.createdAt = createdAt
    }

    static var currentAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}
