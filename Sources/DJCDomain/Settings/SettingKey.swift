/// 설정 하나의 규칙: 저장 이름(UserDefaults 키), 기본값, 저장된 값을 받아들이는 방법.
public struct SettingKey<Value: Sendable & Equatable>: Sendable {
    public let name: String
    public let defaultValue: Value
    /// 저장된 값을 고친다. nil이면 버리고 기본값을 쓴다.
    private let normalize: @Sendable (Value) -> Value?

    public init(_ name: String, _ defaultValue: Value, normalize: @escaping @Sendable (Value) -> Value? = { $0 }) {
        self.name = name
        self.defaultValue = defaultValue
        self.normalize = normalize
    }

    /// 저장소에서 읽은 값. 없거나 형식이 다르거나 규칙에 맞지 않으면 기본값.
    public func value(from stored: Any?) -> Value {
        guard let value = stored as? Value else { return defaultValue }
        return normalize(value) ?? defaultValue
    }
}

extension SettingKey where Value == Double {
    /// 유한한 수만 받고, 범위가 있으면 끝으로 자른다(손으로 고친 값이 화면·오디오를 깨지 않게).
    public init(_ name: String, _ defaultValue: Double, in range: ClosedRange<Double>? = nil) {
        self.init(name, defaultValue) { value in
            guard value.isFinite else { return nil }
            guard let range else { return value }
            return min(max(value, range.lowerBound), range.upperBound)
        }
    }
}
