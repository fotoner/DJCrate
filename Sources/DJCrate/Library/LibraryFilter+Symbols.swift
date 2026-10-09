import DJCDomain
import Foundation

extension LibraryFilter {
    var systemImage: String {
        switch self {
        case .emptyComment: "text.badge.xmark"
        case .offConvention: "exclamationmark.bubble"
        case .noCues: "flag.slash"
        case .played: "play.circle"
        case .streaming: "antenna.radiowaves.left.and.right"
        case .noBPM: "metronome"
        case .missingFile: "questionmark.folder"
        case .tempoChange: "speedometer"
        case .all: "music.note.list"
        }
    }
}

extension Double {
    /// `m:ss.ss`
    var clockText: String {
        String(format: "%d:%05.2f", Int(self) / 60, truncatingRemainder(dividingBy: 60))
    }
}
