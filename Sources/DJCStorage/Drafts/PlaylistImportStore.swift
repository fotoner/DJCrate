import DJCDomain
import Foundation

/// 컬렉션 등록 뒤 만들 목록 연결과 완료한 출처를 저장한다(라이브러리 DB에는 쓰지 않는다).
public enum PlaylistImportStore {
    public static let fileName = "playlist-imports.json"
    public static var url: URL { DJCPaths.userData.appending(path: fileName) }

    public static func load(url: URL = url) throws -> PlaylistImports {
        do { return try JSONDecoder().decode(PlaylistImports.self, from: Data(contentsOf: url)) }
        catch CocoaError.fileReadNoSuchFile { return PlaylistImports() }
    }

    public static func save(_ imports: PlaylistImports, url: URL = url) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(imports).write(to: url, options: .atomic)
    }
}
