import Foundation

/// 폴더 훑기 진행(#62, 훑기는 DJCStorage `RelocateScanner`)
public struct RelocateProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable { case listing, reading, matching }
    public var phase: Phase
    /// 지금까지 찾은 음원 파일 수
    public var audioFiles: Int
    /// 태그를 읽을 파일 수와 읽은 수(`reading` 단계)
    public var filesToRead: Int
    public var filesRead: Int

    public init(phase: Phase, audioFiles: Int, filesToRead: Int, filesRead: Int) {
        self.phase = phase; self.audioFiles = audioFiles; self.filesToRead = filesToRead; self.filesRead = filesRead
    }
}

public struct RelocateSummary: Sendable, Equatable {
    /// 폴더에서 찾은 음원 파일 수
    public var audioFiles: Int
    /// 이름이나 크기가 맞아 태그·길이까지 읽은 파일 수
    public var comparedFiles: Int

    public init(audioFiles: Int, comparedFiles: Int) {
        self.audioFiles = audioFiles; self.comparedFiles = comparedFiles
    }
}

public struct RelocateOutput: Sendable, Equatable {
    public var report: RelocateReport
    public var summary: RelocateSummary

    public init(report: RelocateReport, summary: RelocateSummary) {
        self.report = report; self.summary = summary
    }
}

/// 후보 폴더로 쓸 수 없는 이유
public enum RelocateScanError: Error, LocalizedError, Equatable {
    case notAFolder
    case protectedFolder
    case usbLibraryFolder

    public var errorDescription: String? {
        switch self {
        case .notAFolder: String(ui: "폴더를 열지 못했습니다. 다른 폴더를 고르세요")
        case .protectedFolder: String(ui: "rekordbox·DJCrate의 데이터 폴더는 후보 폴더로 쓸 수 없습니다. 음악이 있는 폴더를 고르세요")
        case .usbLibraryFolder: String(ui: "USB의 PIONEER 폴더와 그 안은 후보 폴더로 쓸 수 없습니다. PIONEER 바깥의 음악 폴더를 고르세요")
        }
    }
}
