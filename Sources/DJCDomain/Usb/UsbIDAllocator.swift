import Foundation

/// USB 라이브러리 행 ID 종류
public enum UsbIDKind: String, CaseIterable, Codable, CodingKeyRepresentable, Sendable {
    case content, artist, album, genre, key, label, image, playlist
}

/// USB 행 ID를 나눠 준다. 새 USB는 1부터, 기존 USB는 본 적 있는 가장 큰 값 다음부터.
/// 지운 ID를 다시 쓰지 않는다(기기가 남긴 기록이 옛 ID를 가리킬 수 있다).
public struct UsbIDAllocator: Sendable, Codable {
    /// 종류 → 지금까지 본(또는 나눠 준) 가장 큰 ID
    public private(set) var highWater: [UsbIDKind: Int]

    public init(highWater: [UsbIDKind: Int] = [:]) {
        self.highWater = highWater
    }

    /// 산 행·죽은 행·기기 기록이 가리키는 ID·저널 highWater를 알린다.
    public mutating func observe(_ kind: UsbIDKind, _ id: Int) {
        highWater[kind] = max(highWater[kind] ?? 0, id)
    }

    /// max(관찰값, highWater) + 1
    public mutating func next(_ kind: UsbIDKind) -> Int {
        let id = (highWater[kind] ?? 0) + 1
        highWater[kind] = id
        return id
    }
}
