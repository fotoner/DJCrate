import Foundation

// 개발용 자가 시험은 디버그 빌드에만 들어간다(설치하는 릴리스 앱에는 없다).
#if DEBUG
/// 덱을 불러온 뒤 적용하는 개발용 실행 인자
extension DeckModel {
    /// 개발용: `--grid-edit`, `--autoplay [--muted|--quiet] [--metronome]`
    func applyLaunchFlags() {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--grid-edit") { gridEditing = true }
        if args.contains("--autoplay"), !isPlaying {
            if args.contains("--muted") { volume = 0 }
            if args.contains("--quiet") { volume = 0.0003 }   // 진단용 −70dB
            if args.contains("--metronome") { metronome = true }
            togglePlay()
        }
    }
}
#endif
