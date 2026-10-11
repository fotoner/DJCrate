import AudioToolbox
import AVFoundation
import DJCDomain
import Foundation

enum AudioSourceFailure {
    /// 확정된 형식 오류만 지원 밖으로 분류한다. 확장자나 알 수 없는 오류로 단정하지 않는다.
    static func state(for error: any Error) -> AudioSourceState {
        let error = error as NSError
        if error.domain == NSOSStatusErrorDomain {
            switch error.code {
            case Int(kAudioFileUnsupportedFileTypeError), Int(kAudioFileUnsupportedDataFormatError): return .unsupportedFormat
            case Int(kAudioFileInvalidFileError): return .decodeFailed
            default: break
            }
        }
        if error.domain == AVFoundationErrorDomain, error.code == AVError.Code.decodeFailed.rawValue { return .decodeFailed }
        return .readFailed
    }
}
