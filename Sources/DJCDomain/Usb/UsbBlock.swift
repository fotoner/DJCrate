import Foundation

/// USB 쓰기 전 막힘 하나. 막힘이 하나라도 있으면 USB에 아무것도 쓰지 않는다.
public struct UsbBlock: Codable, Hashable, Sendable {
    public enum Scope: Codable, Hashable, Sendable {
        case volume
        /// 로컬 ContentID 또는 "usb:<content_id>"
        case track(String)
        case playlist(String)
        case format(UsbFormat)
        /// USB 루트 기준 상대 경로
        case file(String)
    }

    /// 영어 고정 식별자(번역하지 않음), 예: "rekordboxRunning", "notFAT32"
    public var code: String
    public var scope: Scope
    /// 이유와 할 일을 적은 한 문장(`String(ui:)`)
    public var message: String
    /// 이 막힘을 낸 확인 안 된 규칙
    public var rule: UsbProvisionalRule?

    public init(code: String, scope: Scope, message: String, rule: UsbProvisionalRule? = nil) {
        self.code = code
        self.scope = scope
        self.message = message
        self.rule = rule
    }
}

extension UsbBlock {
    /// 동기화가 그 곡만 빼고 나머지를 쓰는 곡 단위 막힘인지. rekordbox도 동기화할 수 없는 곡(분석 파일 없음 등)은
    /// 내보내기 기록에 남기고 나머지를 동기화했다(2026-10-08 실제 동기화). 로컬 스냅샷에 없는 곡은 원본과 사본이
    /// 어긋났다는 뜻이라 빼고 쓰지 않는다(선택을 동기화했다고 잘못 적게 된다)
    public var isSkippableInSync: Bool {
        guard case .track = scope else { return false }
        return code != "localTrackMissing"
    }
}
