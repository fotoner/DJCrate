import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

/// 곡 목록 화면·스크롤 성능 확인용 합성 라이브러리(#121). 위쪽에 스트리밍 곡·큐 없는 곡·자동 큐만 있는 곡·큐 많은 곡을 두고,
/// 아래는 스크롤을 잴 만큼 채운다. 로컬 곡은 모두 합성 음원 하나와 PWAV·PWV4 미리 보기를 쓴다. 실데이터는 쓰지 않는다.
/// `DJC_TRACK_LIST_FIXTURE=<폴더> swift test --filter TrackListFixtureCapture`
struct TrackListFixtureCapture {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DJC_TRACK_LIST_FIXTURE"] != nil))
    func fixture() throws {
        guard let path = ProcessInfo.processInfo.environment["DJC_TRACK_LIST_FIXTURE"] else { return }
        let fixture = try RekordboxFixture()
        let root = URL(filePath: path)
        let seconds = 180
        let audio = try EditLayoutFixtureCapture.song(bpm: 128, first: 0.35, seconds: Double(seconds),
                                                      to: fixture.audio.appending(path: "track-list.wav"))
        try fixture.insert("djmdArtist", ["ID": .text("a1"), "Name": .text("합성 아티스트")])
        try fixture.insert("djmdArtist", ["ID": .text("a2"), "Name": .text("스트리밍 아티스트")])

        func hot(_ slot: Int, _ second: Double) -> CueSpec {
            // rekordbox 핫큐 종류: 1·2·3 = A·B·C, 5…9 = D…H
            CueSpec(kind: slot < 3 ? slot + 1 : slot + 2, inMsec: Int(second * 1000))
        }
        func memory(_ second: Double, loop: Double? = nil) -> CueSpec {
            var cue = CueSpec(kind: 0, inMsec: Int(second * 1000))
            if let loop { cue.outMsec = Int((second + loop) * 1000) }
            return cue
        }
        let autoCue = CueSpec.autoCue(at: 350)
        var loopHot = hot(1, 30)
        loopHot.outMsec = 37_500

        // 제목, 스트리밍 경로(nil이면 로컬 음원), 큐
        let showcase: [(String, String?, [CueSpec])] = [
            ("큐 많은 곡", nil, (0..<8).map { hot($0, 8 + Double($0) * 20) }.enumerated().map { $0.offset == 1 ? loopHot : $0.element }
                + [0.35, 30, 60, 75, 90, 120, 150, 165].map { memory($0) } + [memory(105, loop: 15)]),
            ("스트리밍 곡", "apple-music:1234567", []),
            ("큐 없는 곡", nil, []),
            ("자동 큐만 있는 곡", nil, [autoCue]),
            ("핫큐만 있는 곡", nil, [hot(0, 15), hot(1, 45), hot(2, 90)]),
            ("큐 있는 스트리밍 곡", "spotify:track:synthetic", [hot(0, 20), memory(60)]),
            ("메모리 큐만 있는 곡", nil, [memory(0.35), memory(45), memory(90), memory(135)]),
            ("긴 루프가 있는 곡", nil, [hot(0, 10), memory(40, loop: 60)]),
        ]
        let filler: [(String, String?, [CueSpec])] = (1...192).map { n in
            let cues: [CueSpec] = switch n % 4 {
            case 0: []
            case 1: [hot(0, 15), hot(1, 60), memory(0.35), memory(90)]
            case 2: (0..<8).map { hot($0, 5 + Double($0) * 21) } + [memory(30), memory(120)]
            default: [autoCue]
            }
            return ("목록 채우기 곡 \(n)", n % 10 == 5 ? "apple-music:\(9_000_000 + n)" : nil, cues)
        }
        for (index, entry) in (showcase + filler).enumerated() {
            var track = TrackSpec(id: String(index + 1))
            track.title = entry.0
            // 같은 큐 모양을 여러 곡에 쓰므로 ID를 곡마다 새로 준다.
            track.cues = entry.2.enumerated().map { offset, cue in
                var cue = cue
                cue.id = String((index + 1) * 100 + offset)
                cue.uuid = UUID().uuidString.lowercased()
                return cue
            }
            track.bpm100 = 12000 + (index % 9) * 100
            if let streaming = entry.1 {
                track.folderPath = streaming
                track.length = 240
                track.artistID = "a2"
            } else {
                track.folderPath = root.appending(path: "audio/\(audio.lastPathComponent)").path
                track.fileType = 11
                track.length = seconds
                track.artistID = "a1"
                track.analysisDataPath = "/PIONEER/USBANLZ/list\(index + 1)/ANLZ0000.DAT"
            }
            try fixture.add(track)
            guard entry.1 == nil else { continue }
            let (pwav, pwv4) = Self.preview(seed: index)
            let beats = AnlzBuilder.beats(bpm: 128, first: 350, count: 380)
            try fixture.putAnalysis(for: track, dat: AnlzBuilder.file([BeatGridTags.pqtz(beats), AnlzBuilder.pwav(pwav)]),
                                    ext: AnlzBuilder.file([AnlzBuilder.waveform("PWV4", entryBytes: 6, samples: pwv4)]))
        }
        // 기본 정렬(임포트 최신순)에서 보여 줄 곡이 맨 위에 오게 ID 순서대로 날짜를 하루씩 앞당긴다.
        try fixture.execute("""
            UPDATE djmdContent SET created_at = date('2026-09-20', '-' || (CAST(ID AS INTEGER) - 1) || ' days') || ' 00:00:00.000 +00:00'
            """)
        try FileManager.default.copyItem(at: fixture.root, to: root)
    }

    /// 인트로 → 빌드업 → 드롭 → 브레이크 → 드롭 → 아웃트로 모양의 400칸 미리 보기(곡마다 조금씩 다르게)
    static func preview(seed: Int) -> (pwav: [UInt8], pwv4: [UInt8]) {
        var pwav: [UInt8] = [], pwv4: [UInt8] = []
        var noise = UInt32(truncatingIfNeeded: seed &* 2_654_435_761 &+ 12345)
        for column in 0..<400 {
            let t = Double(column) / 400
            let base: Double = switch t {
            case ..<0.1: 0.35
            case ..<0.25: 0.35 + (t - 0.1) * 3
            case ..<0.5: 0.9
            case ..<0.6: 0.4
            case ..<0.85: 0.95
            default: max(0.15, 0.95 - (t - 0.85) * 5)
            }
            noise = noise &* 1_664_525 &+ 1_013_904_223
            let wobble = Double(noise >> 8) / Double(1 << 24) * 0.25
            let height = min(1, base * (0.75 + wobble) + Double(seed % 5) * 0.02)
            pwav.append(UInt8(4 << 5) | UInt8((height * 31).rounded()))
            let low = UInt8(min(127, height * 127)), mid = UInt8(min(127, height * (t > 0.5 && t < 0.6 ? 110 : 60)))
            let high = UInt8(min(127, height * (40 + wobble * 120)))
            pwv4 += [0, 220, UInt8(height * 127), low, mid, high]
        }
        return (pwav, pwv4)
    }
}
