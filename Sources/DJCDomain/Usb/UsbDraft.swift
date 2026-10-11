import Foundation

/// 한 USB에 쌓은 편집 초안. 반영(`djc usb-edit --draft`) 때 한 번에 쓴다
public struct UsbDraft: Codable, Sendable, Equatable {
    /// 볼륨 UUID(대문자)
    public var volumeKey: String
    /// 초안을 만든 때의 USB DB 지문. 쓸 때 지금 지문과 다르면 지금 USB 상태로 다시 계획한다
    public var base: UsbFingerprint
    /// 적힌 순서대로 쓴다
    public var edits: [UsbLibraryEdit]
    public var createdAt: Date

    public init(volumeKey: String, base: UsbFingerprint, edits: [UsbLibraryEdit], createdAt: Date) {
        self.volumeKey = volumeKey
        self.base = base
        self.edits = edits
        self.createdAt = createdAt
    }
}
