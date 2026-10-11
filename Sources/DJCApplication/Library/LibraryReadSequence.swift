/// 라이브러리 읽기 순번(한 곳에서 센다). 늦게 끝난 읽기·Music 최신화·파일 확인·USB 사본 출처는 세대가 달라지면 버린다.
public struct LibraryReadSequence: Sendable, Equatable {
    /// 읽기 세대: 새 읽기·사본 뜨기를 시작하거나 기다리던 읽기를 버릴 때 오른다. 결과를 채택하기 전에 이것과 비교한다
    public private(set) var generation = 0
    /// 읽기 요청 순번: 뜬 사본이 아직 마지막 요청의 것인지 본다(세대만 올리는 버리기와 구분한다)
    public private(set) var request = 0

    public init() {}

    /// 기다리던 읽기 결과를 버린다
    public mutating func invalidate() { generation += 1 }

    /// 사본을 다 뜬 뒤(또는 사본을 바로 열 때) DB 읽기를 시작한다
    @discardableResult
    public mutating func beginLoad() -> Int {
        request += 1
        generation += 1
        return generation
    }

    /// 사본 뜨기를 시작한다: 기다리던 읽기를 버리고 요청 순번을 받는다
    public mutating func beginSnapshot() -> (generation: Int, request: Int) {
        generation += 1
        request += 1
        return (generation, request)
    }

    public func isCurrent(_ generation: Int) -> Bool { self.generation == generation }
    public func isCurrentRequest(_ request: Int) -> Bool { self.request == request }
}
