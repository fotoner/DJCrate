import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit

/// sync 선택의 전후 사본을 칸으로 비교한다. 원본 ID·DBID·시각 값은 출력하지 않는다.
enum UsbSyncSelectionLab {
    static let all: [Command] = [
        Command("usb-sync-diff", "<전 폴더> <후 폴더>",
                "임시 폴더의 USB sync 파일 사본 둘을 원본 ID·체크·USB 번호·시각 칸으로 비교(값은 출력하지 않음)", diff),
    ]

    static func diff(_ args: [String]) async throws {
        guard args.count == 3 else { throw UsageError() }
        let folders = try args.dropFirst().map { URL(filePath: try UsbScratchPath.check($0, as: .existingDirectory)) }
        for format in UsbFormat.allCases {
            let files = try folders.map { try read(format: format, from: $0) }
            for line in differences(before: files[0], after: files[1], format: format) { print(line) }
        }
    }

    static func read(format: UsbFormat, from folder: URL,
                     fileSystem fs: any UsbFileSystem = PosixUsbFileSystem()) throws -> UsbSyncSelectionFile? {
        let root = UsbRoot(folder)
        // 단독 파일 사본과 USB 트리 사본 모두 두 허용 이름만 루트 fd 아래에서 연다.
        let name = URL(filePath: UsbSyncSelectionFile.relativePath(for: format)).lastPathComponent
        let maximum = 16 * 1024 * 1024
        let data: Data?
        if let direct = try fs.readFile(root: root, relativePath: name, maxBytes: maximum) {
            guard direct.stat.kind == .file, direct.stat.size > 0, direct.stat.size <= Int64(maximum),
                  direct.data.count == Int(direct.stat.size) else { throw UsbSyncSelectionFile.ParseError.unsafePath }
            data = direct.data
        } else {
            data = try UsbSyncSelectionBundle.readFile(root: root, format: format, fileSystem: fs)
        }
        return try data.map { try UsbSyncSelectionFile.parse($0) }
    }

    static func differences(before: UsbSyncSelectionFile?, after: UsbSyncSelectionFile?, format: UsbFormat) -> [String] {
        let name = format == .deviceLibrary ? "playlists3.sync" : "playlists3Plus.sync"
        guard let before, let after else {
            return ["\(name): \(before == nil && after == nil ? "전후 모두 없음" : before == nil ? "파일 생성" : "파일 제거")"]
        }
        func changed(_ a: [String: String], _ b: [String: String]) -> [String] {
            Set(a.keys).union(b.keys).filter { a[$0] != b[$0] }.sorted()
        }
        func key(_ node: UsbSyncSelectionFile.Node) -> String {
            "\(node.libraryType):\(String(UInt64(node.id, radix: 16)!, radix: 16))"
        }
        let a = Dictionary(uniqueKeysWithValues: before.nodes.map { (key($0), $0.attributes) })
        let b = Dictionary(uniqueKeysWithValues: after.nodes.map { (key($0), $0.attributes) })
        var counts: [String: Int] = [:]
        for id in Set(a.keys).intersection(b.keys) {
            for field in changed(a[id]!, b[id]!) { counts[field, default: 0] += 1 }
        }
        let rootFields = changed(before.rootAttributes, after.rootAttributes)
        let playlistFields = changed(before.playlistAttributes, after.playlistAttributes)
        return [
            "\(name): 루트 칸 \(rootFields.isEmpty ? "같음" : rootFields.joined(separator: ", "))",
            "목록 머리 칸 \(playlistFields.isEmpty ? "같음" : playlistFields.joined(separator: ", "))",
            "NODE 추가 \(Set(b.keys).subtracting(a.keys).count) · 제거 \(Set(a.keys).subtracting(b.keys).count)",
            "기존 NODE 칸 \(counts.isEmpty ? "같음" : counts.keys.sorted().map { "\($0) \(counts[$0]!)" }.joined(separator: " · "))",
            "NODE 순서 \(before.nodes.map(key) == after.nodes.map(key) ? "같음" : "다름")",
        ]
    }
}
