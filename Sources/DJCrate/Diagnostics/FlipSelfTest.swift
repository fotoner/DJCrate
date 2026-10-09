import AVFoundation
import DJCAdapters
import DJCAnalysis
import DJCDomain
import Foundation

#if DEBUG
extension DevSelfTests {
    /// 개발용: Flip 기록이 실제로 들린 소리와 샘플 단위로 같은지 실제 재생 경로로 확인한다(`--flip-selftest`, 스피커 음소거).
    ///
    /// 값이 곧 프레임 번호인 램프 WAV(120BPM 그리드)를 틀고 Flip 기록을 켠 채 퀀타이즈 끈 핫큐(다시 재생)·퀀타이즈 켠 핫큐(샘플 단위 예약)·
    /// 루프 핫큐 되풀이·루프 나가기를 쓴다. 기록을 `FlipEdit`으로 만들어 섞지 않고(crossfade 0) 렌더한 파일과 곡 믹서 출력을 프레임마다 비교하고,
    /// 이음새(출발 → 착지 프레임)마다 차이를 샘플 수로 적는다. 끝으로 출력 장치 변경(엔진 멈춤 → 같은 자리에서 이어 재생)이
    /// 이어진 재생(점프)으로 남지 않는지 본다.
    static func runFlipSelfTestIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--flip-selftest") else { return }
        func log(_ text: String) { FileHandle.standardError.write(Data("[Flip 시험] \(text)\n".utf8)) }
        Task { @MainActor in
            func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
            // 24비트 WAV에 그대로 들어가게 값 = 프레임 / 2^23(곡 길이 190초 안쪽은 정확하다)
            let rate = 44_100.0, seconds = 40, scale = 8_388_608.0
            let directory = FileManager.default.temporaryDirectory.appending(path: "djc-flip-selftest-\(UUID().uuidString)")
            let url = directory.appending(path: "ramp.wav"), rendered = directory.appending(path: "flip.wav")
            defer { try? FileManager.default.removeItem(at: directory) }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
                let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                let count = Int(rate) * seconds
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
                buffer.frameLength = AVAudioFrameCount(count)
                for i in 0..<count { buffer.floatChannelData![0][i] = Float(Double(i) / scale) }
                try file.write(from: buffer)
            } catch { log("램프 파일을 만들지 못함: \(error)"); exit(1) }
            let grid = BeatGrid(beats: (0..<Int(Double(seconds) * 2)).map {
                BeatGrid.Beat(number: $0 % 4 + 1, bpm: 120, time: 0.5 + Double($0) * 0.5)
            })

            let audio = DeckAudio()
            audio.volume = 1   // 값이 곧 프레임 번호여야 한다(볼륨을 곱하지 않게)
            try? audio.load(url: url)
            for _ in 0..<100 where !audio.canLoopSampleAccurately || !audio.isOutputReady { await wait(0.05) }
            guard audio.canLoopSampleAccurately else { log("메모리 디코딩 안 됨"); exit(1) }
            guard audio.isOutputReady else { log("오디오 출력을 준비하지 못함(장치 응답 없음)"); exit(1) }
            let captured = Captured()
            audio.debugCaptureTrack { buffer in
                guard case let .float(data) = buffer.channelData(0) else { return }
                captured.append((0..<Int(buffer.frameLength)).map { Int((Double(data[$0]) * scale).rounded()) })
            }
            var recording = FlipRecording()
            var runs: [PlayedRun] = []
            audio.onPlayedRun = { run in
                runs.append(run)
                recording.record(run)
            }
            var failures: [String] = []

            // 앱 첫 화면을 그리는 동안은 메인 스레드가 밀려 실제 덱과 다르다(렌더 시각을 읽고 멈추기 사이가 벌어진다).
            await wait(1.0)
            // 1) 1초부터 재생 → 2) 퀀타이즈 끈 핫큐(10초, 다시 재생) → 3) 퀀타이즈 켠 핫큐(20초, 1박)
            // → 4) 루프 핫큐(5~5.5초, ½박 퀀타이즈)를 몇 바퀴 → 5) 루프 나가기 → 6) 퀀타이즈 끈 핫큐 열일곱 번
            // → 7) 루프 핫큐 → 나가기 → 퀀타이즈 끈 핫큐를 여섯 번
            audio.play(from: 1.0)
            await wait(0.6)
            audio.play(from: 10.0)
            await wait(0.7)
            if audio.scheduleJump(to: 20, loop: nil, quantize: PlayQuantize(grid: grid, beats: 1)!) == nil { failures.append("20초 핫큐 예약 못 함") }
            await wait(1.2)
            if audio.scheduleJump(to: 5, loop: 5...5.5, quantize: PlayQuantize(grid: grid, beats: 0.5)!) == nil { failures.append("루프 핫큐 예약 못 함") }
            await wait(1.8)
            audio.setLoop(nil)
            await wait(0.8)
            audio.play(from: 30.0)
            await wait(0.5)
            for (i, cue) in [12.0, 16.0, 26.0, 8.0, 34.0, 14.0, 22.0, 3.0, 18.0, 28.0, 6.0, 32.0, 11.0, 24.0, 2.0, 36.0].enumerated() {
                audio.play(from: cue)
                await wait(0.2 + Double(i % 5) * 0.013)
            }
            for (i, cue) in [7.0, 9.0, 15.0, 19.0, 27.0, 31.0].enumerated() {
                _ = audio.scheduleJump(to: 5, loop: 5...5.5, quantize: PlayQuantize(grid: grid, beats: 0.5)!)
                await wait(1.2 + Double(i) * 0.037)
                audio.setLoop(nil)
                await wait(0.7 + Double(i) * 0.011)
                audio.play(from: cue)
                await wait(0.3)
            }
            audio.pause()
            await wait(0.2)
            audio.onPlayedRun = nil

            // 곡 믹서 출력: 재생 전·다시 재생 사이·멈춘 뒤의 0(무음)은 뺀다(램프는 1초부터라 0이 나오지 않는다).
            let heard = captured.values.filter { $0 != 0 }
            var heardSeams: [(Int, Int)] = []
            for (a, b) in zip(heard, heard.dropFirst()) where b != a + 1 { heardSeams.append((a, b)) }

            let flip: FlipEdit
            do { flip = try FlipEdit(recording, sourceDuration: audio.duration) } catch { log("실패: Flip을 만들지 못함 \(error)"); exit(1) }
            let spans = flip.frames(sampleRate: rate, sourceOffset: 0, crossfade: 0)
            var recordedSeams: [(Int, Int)] = []
            for (a, b) in zip(spans, spans.dropFirst()) { recordedSeams.append((Int(a.sourceFrame + a.frameCount) - 1, Int(b.sourceFrame))) }
            log("들린 프레임 \(heard.count) · 들린 이음새 \(heardSeams.count)곳 · 기록 이음새 \(recordedSeams.count)곳")
            log("들린: " + heardSeams.map { "\($0.0)→\($0.1)" }.joined(separator: " "))
            log("기록: " + recordedSeams.map { "\($0.0)→\($0.1)" }.joined(separator: " "))
            if heardSeams.count != recordedSeams.count { failures.append("이음새 수가 다름(들린 \(heardSeams.count) · 기록 \(recordedSeams.count))") }
            // 기록 − 들린 소리(샘플). 음수면 기록이 실제로 들린 것보다 일찍 끊었다.
            var worst = 0
            for (index, (heardSeam, recordedSeam)) in zip(heardSeams, recordedSeams).enumerated() {
                let departure = recordedSeam.0 - heardSeam.0, landing = recordedSeam.1 - heardSeam.1
                worst = max(worst, abs(departure), abs(landing))
                if departure != 0 || landing != 0 {
                    log("이음새 \(index + 1): 출발 차이 \(departure)샘플(\(String(format: "%.2f", Double(departure) / rate * 1000))ms) · 착지 차이 \(landing)샘플")
                }
            }
            log("이음새 \(min(heardSeams.count, recordedSeams.count))곳 출발·착지 차이 최대 \(worst)샘플")
            if worst != 0 { failures.append("이음새가 들린 소리와 최대 \(worst)샘플 어긋남") }

            // 섞지 않고 렌더한 파일 = 들린 소리(처음 재생한 1초 앞은 곡 처음부터 이어진다)
            do {
                _ = try EditRenderer.render(spans, source: url, to: rendered, bitDepth: 24)
                let file = try AVAudioFile(forReading: rendered)
                let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
                try file.read(into: buffer)
                let data = buffer.floatChannelData![0]
                let output = (0..<Int(buffer.frameLength)).map { Int((Double(data[$0]) * scale).rounded()) }
                let lead = heard.first ?? 0
                let compared = min(heard.count, output.count - lead)
                let mismatches = (0..<max(0, compared)).filter { output[lead + $0] != heard[$0] }
                log("렌더 \(output.count)프레임 · 들린 소리와 비교 \(compared)프레임 · 다른 프레임 \(mismatches.count)개"
                    + (mismatches.first.map { " · 첫 차이 렌더 \(output[lead + $0]) / 들림 \(heard[$0])" } ?? ""))
                if compared < heard.count - 1 || !mismatches.isEmpty { failures.append("렌더가 들린 소리와 다름(\(mismatches.count)프레임)") }
            } catch { failures.append("렌더 실패: \(error)") }

            // 출력 장치 변경: 같은 자리에서 이어 재생해도 기록에는 이어진 재생(점프)이 아니다.
            runs = []
            audio.onPlayedRun = { runs.append($0) }
            audio.play(from: 3.0)
            await wait(0.5)
            audio.debugConfigurationChange()
            for _ in 0..<40 where !audio.isPlaying || runs.isEmpty { await wait(0.05) }
            await wait(0.3)
            audio.stop()
            audio.onPlayedRun = nil
            let interrupted = runs.first
            log("출력 장치 변경: 끝난 재생 \(runs.count)번 · 첫 재생 이어짐=\(interrupted.map { "\($0.continuing)" } ?? "없음")")
            if interrupted?.continuing != false { failures.append("출력 장치 변경으로 끊긴 재생이 이어진 재생으로 남음") }

            log(failures.isEmpty ? "Flip 시험 통과: 이음새 \(recordedSeams.count)곳이 들린 소리와 샘플 단위로 같음" : "실패: \(failures)")
            exit(failures.isEmpty ? 0 : 1)
        }
    }
}
#endif
