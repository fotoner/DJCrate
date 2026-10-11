import DJCDomain
import Foundation

func clock(_ seconds: Double) -> String {
    String(format: "%d:%05.2f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
}

func nearestBeat(_ grid: BeatGrid, to time: Double) -> BeatGrid.Beat? {
    let i = grid.firstIndex(atOrAfter: time)
    let candidates = [i - 1, i].filter { grid.beats.indices.contains($0) }.map { grid.beats[$0] }
    return candidates.min { abs($0.time - time) < abs($1.time - time) }
}

func value(after flag: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}
