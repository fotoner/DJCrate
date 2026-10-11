import AVFoundation
import DJCDomain
@testable import DJCAnalysis
import Foundation
import Testing

@Suite("곡 편집 렌더")
struct EditRendererTests {
    let rate = 44_100.0
    /// 120 BPM, 첫 다운비트 0.5초, 20.5초 = 10마디
    let grid = [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)]

    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "djc-edit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 프레임마다 값이 다른 램프(32비트 float WAV). 값으로 어느 원본 프레임인지 안다.
    func ramp(seconds: Double, in directory: URL) throws -> (url: URL, value: (Int64) -> Float) {
        let url = directory.appending(path: "ramp.wav")
        let frames = AVAudioFrameCount(seconds * rate)
        let value: (Int64) -> Float = { i in i < 0 || i >= Int64(frames) ? 0 : Float(-0.9 + 1.8 * Double(i) / Double(frames)) }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            buffer.floatChannelData![0][i] = value(Int64(i))
            buffer.floatChannelData![1][i] = -value(Int64(i))
        }
        try file.write(from: buffer)
        return (url, value)
    }

    func samples(_ url: URL) throws -> (left: [Float], right: [Float], rate: Double) {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let n = Int(buffer.frameLength)
        return (Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: n)),
                Array(UnsafeBufferPointer(start: buffer.floatChannelData![1], count: n)), file.processingFormat.sampleRate)
    }

    @Test func 조각을_샘플_단위로_잇고_이음새만_섞는다() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try ramp(seconds: 20.5, in: dir)
        let edit = try TrackEdit(grid: grid, sourceDuration: 20.5, bars: BarRange.list("1-2,1-2,3-10"))
        let output = dir.appending(path: "edit.wav")
        let result = try EditRenderer.render(edit, source: source.url, sourceOffset: 0, to: output, bitDepth: 24)
        #expect(result == EditRenderer.Result(frames: 24 * 44_100, sampleRate: rate, channels: 2, seams: 1))

        let out = try samples(output)
        #expect(out.left.count == 24 * 44_100 && out.rate == rate)
        let seam = 4 * 44_100, fade = 176
        // 첫 조각(원본 1~2마디 = 22050프레임부터), 이음새 앞 섞는 구간 전까지는 원본 그대로
        for j in stride(from: 0, to: seam - fade, by: 97) {
            #expect(abs(out.left[j] - source.value(Int64(22_050 + j))) < 5e-7, "프레임 \(j)")
        }
        // 두 번째 조각(원본 1~10마디)은 이음새부터 원본 그대로(다운비트 어택을 건드리지 않는다)
        for j in stride(from: seam, to: out.left.count, by: 101) {
            #expect(abs(out.left[j] - source.value(Int64(22_050 + j - seam))) < 5e-7, "프레임 \(j)")
            #expect(abs(out.right[j] + source.value(Int64(22_050 + j - seam))) < 5e-7)
        }
        // 이음새 앞 4ms: 앞 조각은 줄고 두 번째 조각 바로 앞 원본은 커진다
        for k in [0, 50, 175] {
            let g = (Float(k) + 0.5) / Float(fade)
            let expected = source.value(Int64(22_050 + seam - fade + k)) * (1 - g) + source.value(Int64(22_050 - fade + k)) * g
            #expect(abs(out.left[seam - fade + k] - expected) < 1e-6, "섞는 구간 \(k)")
        }
    }

    @Test func 재생_예약표로_메모리에서_낸_소리는_렌더와_같다() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try ramp(seconds: 20.5, in: dir)
        let file = try AVAudioFile(forReading: source.url)
        let whole = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: whole)
        // 곡 머리 + 이음새 둘, MP3처럼 0.05초 늦은 시간축(곡 머리 앞은 무음)
        let edit = try TrackEdit(grid: grid, sourceDuration: 20.5, bars: BarRange.list("0-2,1-2,9-10"))
        let output = dir.appending(path: "edit.wav")
        _ = try EditRenderer.render(edit, source: source.url, sourceOffset: 0.05, to: output, bitDepth: 24)
        let rendered = try samples(output)
        let items = TrackEdit.playbackItems(edit.frames(sampleRate: rate, sourceOffset: 0.05))
        // 처음부터, 그리고 이음새 섞는 구간 가운데부터 이어 붙인 소리가 렌더 파일과 같다
        let seam = Int64((edit.pieces[1].outputStart * rate).rounded())
        for start in [Int64(0), seam - 100] {
            var left: [Float] = [], right: [Float] = []
            for item in items.starting(at: start) {
                #expect(item.outputFrame == start + Int64(left.count))
                let buffer = try #require(EditRenderer.playbackBuffer(item, source: whole))
                #expect(Int64(buffer.frameLength) == item.frameCount)
                left += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
                right += UnsafeBufferPointer(start: buffer.floatChannelData![1], count: Int(buffer.frameLength))
            }
            let expected = rendered.left[Int(start)...]
            #expect(left.count == expected.count)
            #expect(zip(left, expected).allSatisfy { abs($0 - $1) < 1e-6 }, "\(start)부터")
            #expect(zip(right, rendered.right[Int(start)...]).allSatisfy { abs($0 - $1) < 1e-6 })
        }
    }

    @Test func 인코더_지연만큼_곡_머리에_무음을_채운다() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try ramp(seconds: 20.5, in: dir)
        // MP3처럼 rekordbox 시각 = 음원 시각 + 0.05초라 가정: 곡 머리(0초)는 음원 −2205프레임
        let edit = try TrackEdit(grid: grid, sourceDuration: 20.5, bars: BarRange.list("0-1"))
        let output = dir.appending(path: "lead.aiff")
        let result = try EditRenderer.render(edit, source: source.url, sourceOffset: 0.05, to: output, bitDepth: 24)
        #expect(result.frames == Int64((2.5 * rate).rounded()) && result.seams == 0)
        let out = try samples(output)
        #expect(out.left[0..<2_205].allSatisfy { $0 == 0 })
        #expect(abs(out.left[2_205] - source.value(0)) < 5e-7 && abs(out.left[50_000] - source.value(50_000 - 2_205)) < 5e-7)
    }

    @Test func 진행을_알리고_취소하면_파일을_남기지_않는다() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try ramp(seconds: 20.5, in: dir)
        let edit = try TrackEdit(grid: grid, sourceDuration: 20.5, bars: BarRange.list("1-10,1-10"))
        final class Seen: @unchecked Sendable {
            let lock = NSLock()
            var values: [Double] = []
            func add(_ value: Double) { lock.withLock { values.append(value) } }
        }
        // 쓴 만큼 늘어 1에서 끝난다(편집 창의 진행 막대)
        let seen = Seen()
        _ = try EditRenderer.render(edit, source: source.url, sourceOffset: 0, to: dir.appending(path: "full.wav"), progress: seen.add)
        #expect(seen.values.count > 10 && seen.values == seen.values.sorted() && seen.values.last == 1)

        // 렌더하는 작업을 취소하면 멈추고 출력·임시 파일을 지운다
        let cancelled = dir.appending(path: "cancelled.wav")
        let job = Task.detached {
            try EditRenderer.render(edit, source: source.url, sourceOffset: 0, to: cancelled, progress: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            })
        }
        await #expect(throws: CancellationError.self) { _ = try await job.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["full.wav", "ramp.wav"])
    }

    @Test func 원본과_이미_있는_파일에는_쓰지_않는다() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try ramp(seconds: 20.5, in: dir)
        let edit = try TrackEdit(grid: grid, sourceDuration: 20.5, bars: BarRange.list("1-4"))
        let before = try Data(contentsOf: source.url)
        func reason(_ output: URL) -> String? {
            do { _ = try EditRenderer.render(edit, source: source.url, sourceOffset: 0, to: output); return nil }
            catch let DJCError.editRefused(reason) { return reason } catch { return "다른 오류: \(error)" }
        }
        #expect(reason(source.url) != nil)
        #expect(reason(dir.appending(path: "out.mp3"))?.contains("WAV") == true)
        let taken = dir.appending(path: "taken.wav")
        try Data("x".utf8).write(to: taken)
        #expect(reason(taken)?.contains("이미") == true)
        #expect(try Data(contentsOf: source.url) == before && Data(contentsOf: taken) == Data("x".utf8))
        // 반쯤 쓴 임시 파일을 남기지 않는다
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(left == ["ramp.wav", "taken.wav"])
    }
}
