import AVFoundation
import CoreGraphics
import DJCApplication
import DJCDomain
import Foundation
import ImageIO
import RekordboxKit

extension TrackAssetReader {
    /// 실제 파일: 음원·rekordbox share(분석 파일·그림). 초안은 초안 저장소에서 읽는다(저장하지 못한 입력이 디스크보다 최신이다).
    public static func live(drafts: DraftStore) -> TrackAssetReader {
        TrackAssetReader(
            audioFileExists: { FileManager.default.fileExists(atPath: $0.path) },
            timelineOffset: { RekordboxTimeline.predictedOffset(url: $0) },
            gainDraft: { drafts.currentGain($0) },
            cueDraft: { drafts.currentCue($0) },
            newCueID: drafts.newCueID,
            gridDraft: { drafts.currentGrid($0) },
            rekordboxGrid: { readGrid($0, shareRoot: $1) },
            analysisState: { analysisState($0, shareRoot: $1) },
            colorWaveform: { colorWaveform($0, shareRoot: $1, mode: $2) },
            artwork: { path, root, pixels in RekordboxShare.artworkThumbnail(path, root: root, maxPixels: pixels).map { DeckArtwork(image: $0) } },
            embeddedArtwork: { await embeddedArtwork($0) })
    }

    /// 분석 파일의 비트 그리드(PQTZ). 없음·읽기 실패·박 없음을 나눠 덱 안내 문구를 고른다.
    public static func readGrid(_ analysisPath: String?, shareRoot: URL?) -> AnalysisGridRead {
        guard let url = RekordboxShare.analysisURL(analysisPath, root: shareRoot),
              FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let grid = try? BeatGrid.load(anlz: url) else { return .unreadable }
        return grid.beats.isEmpty ? .noBeats : .grid(grid)
    }

    /// 그리드 쓰기 조건: 분석 경로가 빈 곡은 분석 파일을 붙이고(`RekordboxWriter.needsAnalysis`), 파형 파일(.EXT)이 빠진 곡은 막는다.
    public static func analysisState(_ analysisPath: String?, shareRoot: URL?) -> RekordboxAnalysisState {
        if RekordboxWriter.needsAnalysis(analysisPath) { return .notAnalyzed(attachesAnalysis: RekordboxWriter.attachesAnalysis) }
        return RekordboxShare.hasWaveformAnalysis(analysisPath, root: shareRoot) ? .ready : .waveformMissing
    }

    /// 분석 파일(.EXT)의 색 파형(PWV3 파랑·PWV5 RGB). 3밴드 모드거나 없으면 nil
    static func colorWaveform(_ analysisPath: String?, shareRoot: URL?, mode: WaveformColorMode) -> ColorWaveformColumns? {
        guard mode != .threeBand, let dat = RekordboxShare.analysisURL(analysisPath, root: shareRoot),
              let file = try? AnlzFile(url: dat.deletingPathExtension().appendingPathExtension("EXT")),
              let source = try? AnlzColorWaveform(file: file, mode: mode) else { return nil }
        return ColorWaveformColumns(columns: source.columns, rate: source.rate)
    }

    /// 음원 파일에 든 그림(ID3 APIC·MP4 covr 등)
    static func embeddedArtwork(_ url: URL) async -> DeckArtwork? {
        let asset = AVURLAsset(url: url)
        guard let metadata = try? await asset.load(.commonMetadata),
              let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtwork).first,
              let data = try? await item.load(.dataValue),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return DeckArtwork(image: image)
    }
}
