import Foundation

/// 저널에 남겨 두는 선택 파일의 의미 검증 기대값. 원문은 로그·보고서로 내보내지 않는다.
public struct UsbSyncSelectionVerification: Codable, Equatable, Sendable {
    public var draft: UsbSyncSelectionDraft
    public var formats: Set<UsbFormat>
    /// 형식마다 원본 ID → 그 형식 DB의 USB 목록 번호(Dev_ID)
    public var playlistIDs: [UsbFormat: [String: Int]]
    public var contract: UsbSyncXMLWriteContract

    public init(draft: UsbSyncSelectionDraft, formats: Set<UsbFormat>, playlistIDs: [UsbFormat: [String: Int]],
                contract: UsbSyncXMLWriteContract) {
        self.draft = draft
        self.formats = formats
        self.playlistIDs = playlistIDs
        self.contract = contract
    }
}

/// 확인한 동기화 선택 파일 칸 규칙의 판. 저널의 기대값에 함께 남긴다.
/// 확인한 판(`confirmed`)과 비상 스위치(`production`)는 RekordboxKit `UsbSyncSelectionXML.swift`에 있다.
public struct UsbSyncXMLWriteContract: Codable, Hashable, Sendable {
    public let revision: Int

    public init(revision: Int) { self.revision = revision }
}
