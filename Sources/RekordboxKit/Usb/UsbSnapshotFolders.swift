import Foundation

/// USB 읽기가 이 Mac에 만드는 사본 폴더의 파일 일(있는지·안의 이름·만들기·지우기).
/// 읽기 유스케이스(`UsbRead`, DJCApplication)가 파일 시스템을 직접 부르지 않고 이것을 부른다(#167: 포트로 옮기는 것은 USB 단계).
public enum UsbSnapshotFolders {
    public static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// 폴더 안의 이름. 없거나 읽지 못하면 nil
    public static func names(in url: URL) -> [String]? { try? FileManager.default.contentsOfDirectory(atPath: url.path) }

    /// 나만 읽고 쓰는 폴더(0700)를 만든다(중간 폴더까지)
    public static func createPrivate(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// 통째로 지운다. 없거나 지우지 못해도 넘어간다(정리)
    public static func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }
}
