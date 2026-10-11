import Foundation

/// 읽기 명령(CLI 읽기·XML·초안)의 실패: 기계가 읽는 코드와 사람이 읽는 이유(무엇을 하면 되는지까지). JSON 오류 계약에 그대로 담긴다.
public struct ReadFailure: Error, Codable, CustomStringConvertible {
    public let code: String
    public let message: String
    public var description: String { message }
    public init(_ code: String, _ message: String) { self.code = code; self.message = message }
}

/// 읽기 API의 JSON 계약. 선택 값이 없으면 해당 키를 생략한다.
public enum ReadJSON {
    private struct Envelope<Value: Encodable>: Encodable {
        let schemaVersion = 1
        let command: String
        let data: Value
    }

    private struct ErrorEnvelope: Encodable {
        let schemaVersion = 1
        let command: String
        let error: ReadFailure
    }

    public static func encode<T: Encodable>(command: String, data: T) throws -> Data {
        try encoder().encode(Envelope(command: command, data: data))
    }

    public static func error(command: String, error: any Error) throws -> Data {
        let failure = error as? ReadFailure ?? ReadFailure("read_failed", String(ui: "읽지 못했습니다: \(String(describing: error)). 사본과 접근 권한을 확인하세요"))
        return try encoder().encode(ErrorEnvelope(command: command, error: failure))
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
