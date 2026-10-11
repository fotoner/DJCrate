import Foundation

/// 준비 중인 음원과 실제 읽기 실패를 같은 형식 오류로 취급하지 않는다.
public enum AudioSourceState: Equatable, Sendable {
    case none, preparing, ready, streaming, missing, readFailed, decodeFailed, unsupportedFormat

    public var unavailableReason: String? {
        switch self {
        case .none: String(ui: "재생할 곡을 덱에 불러오세요")
        case .preparing: String(ui: "음원이나 오디오 장치를 준비 중이니 불러오기가 끝난 뒤 다시 재생하세요")
        case .ready: nil
        case .streaming: String(ui: "스트리밍 곡은 재생할 수 없으니 로컬 음원 파일이 있는 곡을 고르세요")
        case .missing: String(ui: "음원 파일이 없으니 외장 드라이브를 연결하거나 rekordbox에서 파일 위치를 확인하세요")
        case .readFailed: String(ui: "음원 파일을 읽지 못했으니 파일 접근 권한과 외장 드라이브 연결을 확인한 뒤 다시 불러오세요")
        case .decodeFailed: String(ui: "음원을 디코딩하지 못했으니 다른 플레이어에서 파일이 정상인지 확인한 뒤 다시 불러오세요")
        case .unsupportedFormat: String(ui: "이 음원 형식은 지원하지 않으니 WAV·AIFF 등 지원하는 형식의 파일을 고르세요")
        }
    }
}
