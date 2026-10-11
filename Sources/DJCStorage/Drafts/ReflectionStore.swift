import DJCDomain
import Foundation

/// 반영 계획 묶음(내보낸 XML마다 하나) 파일. 가져온 뒤 검증에 쓴다. 자리는 부르는 쪽(조립 지점)이 정한다(`DraftLocations.reflection`).
public enum ReflectionStore {
    public typealias Batch = ReflectionXMLBatch

    /// 데이터 폴더 안 파일 이름
    public static let fileName = "reflection.json"

    public static func load(url: URL) -> Batch? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Batch.self, from: data)
    }

    public static func save(_ batch: Batch?, url: URL) throws {
        guard let batch else { try? FileManager.default.removeItem(at: url); return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(batch).write(to: url, options: .atomic)
    }
}
