import CryptoKit
import DJCDomain
import Foundation
import RekordboxKit

/// 임시 폴더에 USB 모양 트리를 만드는 시험 도우미. 내용은 합성 자료만 쓴다.
public struct UsbTreeFixture {
    public let base: URL

    public init() {
        self.init(base: FileManager.default.temporaryDirectory.appending(path: "djc-usbtree-\(UUID().uuidString)"))
    }

    /// 이미 정한 폴더(예: 쓰기 시험의 USB 루트 흉내)에 트리를 만든다
    public init(base: URL) {
        self.base = base
        try! FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    public var root: UsbRoot { UsbRoot(base) }

    public func url(_ relative: String) -> URL { base.appending(path: relative) }

    /// 중간 폴더를 만들고 파일을 쓴다.
    public func write(_ relative: String, _ data: Data) {
        let target = url(relative)
        try! FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! data.write(to: target)
    }

    public func write(_ relative: String, _ text: String) {
        write(relative, Data(text.utf8))
    }

    public func mkdir(_ relative: String) {
        try! FileManager.default.createDirectory(at: url(relative), withIntermediateDirectories: true)
    }

    /// `relative`에 `destination`을 가리키는 심볼릭 링크를 만든다(대상 경로는 그대로 적는다).
    public func symlink(_ relative: String, to destination: String) {
        let link = url(relative)
        try! FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: destination)
    }

    /// 상대 경로(NFC) → SHA-256(소문자 16진). 일반 파일만, 순회 코드와 따로 센다.
    /// 받은 상대 경로를 그대로 쓴다(Foundation 경로 정규화는 /private를 떼어 어긋난다). 링크는 따라가지 않는다.
    /// `enumerator(atPath:)`는 짝 파일이 있는 AppleDouble("._*")을 숨기므로 `subpathsOfDirectory`를 쓴다.
    public func tree() -> [String: String] {
        var result: [String: String] = [:]
        guard let paths = try? FileManager.default.subpathsOfDirectory(atPath: base.path) else {
            preconditionFailure("시험 트리를 열거하지 못함")
        }
        for relative in paths {
            let full = base.path + "/" + relative
            // attributesOfItem은 링크를 따라가지 않는다(링크는 .typeSymbolicLink).
            guard (try? FileManager.default.attributesOfItem(atPath: full)[.type] as? FileAttributeType) == .typeRegular else { continue }
            guard let data = FileManager.default.contents(atPath: full) else { preconditionFailure("시험 파일을 읽지 못함: \(relative)") }
            result[relative.precomposedStringWithCanonicalMapping] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return result
    }

    public func remove() {
        try? FileManager.default.removeItem(at: base)
    }
}
