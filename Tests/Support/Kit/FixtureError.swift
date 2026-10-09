/// 시험 재료를 만들지 못했을 때(파일 없음·덱이 곡을 다 읽지 못함 등). DB 재료에 기대지 않는 시험도 쓰게 Kit에 둔다.
public struct FixtureError: Error, CustomStringConvertible {
    public var description: String
    public init(_ description: String) { self.description = description }
}
