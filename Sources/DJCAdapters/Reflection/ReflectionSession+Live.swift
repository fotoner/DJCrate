import DJCAnalysis
import DJCApplication
import DJCDomain
import Foundation
import RekordboxKit

extension TrackAudioReader {
    /// 음원 읽기(AVFoundation 태그·길이, 넣기 계획, 분석 지원 형식). 음량은 캐시를 든 쪽이 준다(앱은 음량 캐시, CLI는 매번 잰다).
    public static func live(loudness: @escaping @Sendable (URL) async -> Loudness?) -> Self {
        Self(needsAnalysis: { RekordboxWriter.needsAnalysis($0) },
             tags: { try await AudioTags.read(url: $0) },
             loudness: loudness,
             unsupported: { AudioFacts.read(url: $0).unsupported },
             addPlan: { try TrackAddPlan.make(url: $0, tags: $1) })
    }

    /// 캐시 없이 매번 잰다(CLI)
    public static var measuring: Self { live { url in try? Loudness.measure(fileAt: url) } }
}

extension RunningApps {
    /// 이 Mac에서 rekordbox·rekordboxAgent가 켜져 있는지
    public static var live: Self { Self { LibrarySnapshot.isRekordboxRunning() } }
}

extension ReflectionSession.Options {
    /// 앱: 쓴 뒤 처리·되살리기를 하고, 분석 붙이기·앨범아트 쓰기는 쓰기 관문이 지금 연 것을 따른다
    public static var liveApp: Self { .app(attachesAnalysis: RekordboxWriter.attachesAnalysis, writesArtwork: RekordboxTrackWriter.writesArtwork) }
    /// CLI: 쓴 뒤 처리·되살리기를 하지 않는다(사용자 결정 2026-10-10, `Options.cli`)
    public static var liveCLI: Self { .cli(attachesAnalysis: RekordboxWriter.attachesAnalysis, writesArtwork: RekordboxTrackWriter.writesArtwork) }
}
