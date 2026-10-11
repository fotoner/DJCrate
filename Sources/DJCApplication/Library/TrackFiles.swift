import DJCDomain
import Foundation

/// 이 Mac의 음원·그림 파일(포트): 있는지 보기, 폴더에서 음원 고르기, 태그 읽기. 실제 구현은 DJCAdapters(`TrackFiles.live`).
public struct TrackFiles: Sendable {
    /// 그 경로에 파일이 있는지(메인 밖에서 부른다)
    public var exists: @Sendable (_ path: String) -> Bool
    /// 고른 파일·폴더에서 넣을 수 있는 음원(MP3·M4A·WAV·AIFF·FLAC)을 고른다(폴더는 안까지)
    public var audioFiles: @Sendable ([URL]) -> [URL]
    /// 음원의 태그를 읽어 추가할 곡으로 만든다(`addedOn`: 추가한 날짜)
    public var stagedTrack: @Sendable (_ file: URL, _ addedOn: String) async throws -> StagedTrack
    /// 음원 태그의 키(없으면 nil)
    public var tagKey: @Sendable (URL) async -> String?
    /// 파일 내용(고른 그림)
    public var read: @Sendable (URL) throws -> Data

    public init(exists: @escaping @Sendable (_ path: String) -> Bool,
                audioFiles: @escaping @Sendable ([URL]) -> [URL],
                stagedTrack: @escaping @Sendable (_ file: URL, _ addedOn: String) async throws -> StagedTrack,
                tagKey: @escaping @Sendable (URL) async -> String?,
                read: @escaping @Sendable (URL) throws -> Data) {
        self.exists = exists
        self.audioFiles = audioFiles
        self.stagedTrack = stagedTrack
        self.tagKey = tagKey
        self.read = read
    }
}

/// 추가한 곡의 소리 분석(포트): 그리드 추정·인코더 지연·주 조성. 실제 구현은 DJCAdapters(`StagingAnalysis.live`, DJCAnalysis·RekordboxKit).
/// 무거운 일이라 메인 밖에서 돈다. 크로마는 덱과 같은 캐시를 쓴다.
public struct StagingAnalysis: Sendable {
    /// 그리드 추정(음원 시간축, 캐시 열쇠 = 곡 UUID). 추정하지 못하면 nil
    public var estimateGrid: @Sendable (_ file: URL, _ cacheKey: String) async throws -> GridEstimate?
    /// rekordbox 시간축 − 음원 시간축(인코더 지연)
    public var timelineOffset: @Sendable (URL) -> Double
    /// 곡 전체의 주 조성(Camelot). 창은 rekordbox 시간축 그리드의 마디(`offset`만큼 당겨 크로마에 맞춘다).
    /// 파일을 읽지 못하면 nil(다음에 다시 본다), 소리가 없어 조성을 못 찾으면 `.some(nil)`
    public var mainKey: @Sendable (_ file: URL, _ grid: BeatGrid?, _ offset: Double, _ duration: Double, _ cacheKey: String?) async -> String??

    public init(estimateGrid: @escaping @Sendable (_ file: URL, _ cacheKey: String) async throws -> GridEstimate?,
                timelineOffset: @escaping @Sendable (URL) -> Double,
                mainKey: @escaping @Sendable (_ file: URL, _ grid: BeatGrid?, _ offset: Double, _ duration: Double, _ cacheKey: String?) async -> String??) {
        self.estimateGrid = estimateGrid
        self.timelineOffset = timelineOffset
        self.mainKey = mainKey
    }
}
