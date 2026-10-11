import DJCDomain
import Foundation

/// 쓴 뒤 검증(G 단계). 문제 목록을 돌려준다(빈 배열 = 통과). 하나라도 있으면 백업으로 되돌린다.
public protocol UsbWriteVerifier: Sendable {
    func verify(root: UsbRoot, changes: UsbChangeSet, fileSystem: any UsbFileSystem, scratch: URL) throws -> [String]
}

/// 기본 검증: 목표 지문(있어야 할 파일의 크기·SHA-256을 매체에서 다시 읽어, 없어야 할 파일), 우리 폴더에 임시 파일 0개,
/// 이번에 만들거나 바꾼 파일 옆 `._<이름>` 0개
public struct UsbFingerprintVerifier: UsbWriteVerifier {
    public init() {}

    public func verify(root: UsbRoot, changes: UsbChangeSet, fileSystem: any UsbFileSystem, scratch: URL) throws -> [String] {
        var problems: [String] = []
        for (path, stamp) in changes.target.mustExist.sorted(by: { $0.key < $1.key }) {
            let url = root.url.appending(path: path)
            guard let info = try fileSystem.stat(url), info.kind == .file else {
                problems.append("missing: \(path)")
                continue
            }
            if info.size != stamp.size {
                problems.append("size: \(path)")
                continue
            }
            if let expected = stamp.sha256, try fileSystem.sha256(url, uncached: true) != expected {
                problems.append("sha256: \(path)")
            }
        }
        for path in changes.target.mustNotExist.sorted() where try fileSystem.stat(root.url.appending(path: path)) != nil {
            problems.append("exists: \(path)")
        }
        for temp in try UsbWriter.tempFiles(root: root, fileSystem: fileSystem) {
            problems.append("temp: \(temp)")
        }
        let changed = changes.copies.filter { $0.disposition != .reuse }.map(\.destination)
            + changes.writes.filter { $0.disposition != .reuse }.map(\.destination) + changes.databases.map(\.destination)
        for path in changed {
            guard let companion = UsbRemovalPolicy.appleDoubleCompanion(of: path) else { continue }
            if try fileSystem.stat(root.url.appending(path: companion)) != nil { problems.append("appledouble: \(companion)") }
        }
        return problems
    }
}
