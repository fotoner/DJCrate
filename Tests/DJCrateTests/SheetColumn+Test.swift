@testable import DJCrate

extension SheetColumn {
    /// 열 정의(`all`) 순서의 자리. 저장된 배치 없이 `all` 순서로 열을 만든 시험 표에서 열 번호로 쓴다.
    /// 열을 더해도 시험이 번호를 옮겨 적지 않게, 칸을 열 이름으로 가리킨다.
    static func index(of id: String) -> Int {
        guard let index = all.firstIndex(where: { $0.id == id }) else { fatalError("시트에 없는 열: \(id)") }
        return index
    }

    /// 제목 열 번호(시작 커서 자리와 같다)
    static var titleIndex: Int { index(of: "title") }
}
