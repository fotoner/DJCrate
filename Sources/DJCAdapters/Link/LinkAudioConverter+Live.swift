import AVFoundation
import CryptoKit
import DJCAnalysis
import DJCApplication
import DJCDomain
import Foundation
import RekordboxKit

extension LinkAudioConverter {
    /// FLAC·ALAC를 같은 샘플의 WAV로 바꿔 `cache` 폴더에 둔다(#277). 원본은 읽기만 한다.
    /// 무손실 형식은 인코더 지연이 0이라(`RekordboxTimeline.predictedOffset`) 처음부터 끝까지 그대로 옮기면 큐·그리드 시각이 같다.
    /// 같은 원본(경로·크기·수정 시각)은 한 번만 바꾸고 다시 쓴다. 다 쓴 뒤에 이름을 바꿔 반쯤 쓴 파일을 내어 주지 않는다(`EditRenderer`).
    /// - Parameter cache: 바꾼 WAV를 둘 폴더. CDJ가 NFS로 읽으므로 내어 주는 곡과 같은 뿌리 폴더(경로 앞 세 단계) 안이어야 한다
    public static func live(cache: URL) -> LinkAudioConverter {
        LinkAudioConverter { path throws(LinkProblem) in
            let result = await BlockingWork.run(qos: .userInitiated) { () -> Result<String?, LinkProblem> in
                Result { () throws(LinkProblem) -> String? in try convertIfNeeded(path, cache: cache) }
            }
            return try result.get()
        }
    }

    /// 바꿔야 하면 바꾼 WAV 경로, 아니면 nil
    static func convertIfNeeded(_ path: String, cache: URL) throws(LinkProblem) -> String? {
        let source = URL(filePath: path)
        guard needsConversion(source) else { return nil }
        let output: URL
        do {
            output = cache.appending(path: try cacheName(source) + ".wav")
        } catch {
            throw .conversionFailed(String(ui: "음원 파일을 읽지 못했습니다"))
        }
        if FileManager.default.fileExists(atPath: output.path) { return output.path }
        do {
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            let file = try AVAudioFile(forReading: source)
            let span = EditFrameSpan(sourceFrame: 0, frameCount: file.length, outputFrame: 0, crossfadeFrames: 0)
            _ = try EditRenderer.render([span], source: source, to: output, bitDepth: bitDepth(file, source: source))
            return output.path
        } catch {
            // 같은 곡을 거의 같이 두 번 놓아 다른 쪽이 먼저 다 썼으면 그 파일을 쓴다
            if FileManager.default.fileExists(atPath: output.path) { return output.path }
            throw .conversionFailed(error.localizedDescription)
        }
    }

    /// FLAC과 ALAC(.m4a·.mp4 안의 Apple Lossless). AAC .m4a는 CDJ가 읽으므로 바꾸지 않는다(코덱으로 가른다)
    static func needsConversion(_ url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "flac": true
        case "m4a", "mp4": RekordboxTimeline.packetInfo(url: url)?.formatID == "alac"
        default: false
        }
    }

    /// 원본 경로·크기·수정 시각으로 지은 이름(원본이 바뀌면 새로 바꾼다)
    static func cacheName(_ source: URL) throws -> String {
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let key = "\(source.standardizedFileURL.path)\n\(values.fileSize ?? 0)\n\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return "\(source.deletingPathExtension().lastPathComponent.prefix(40))-\(digest)"
    }

    /// 원본 비트 수를 지킨다: 16비트 이하면 16, 아니면 24(CDJ WAV는 16·24비트)
    /// 원본 비트 깊이가 16 이하면 16, 아니면 24. FLAC·ALAC은 PCM 비트 수가 0으로 읽혀 파일이 적어 둔 원본 비트 깊이를 본다.
    /// 16비트를 24비트로 키우면 같은 소리에 파일만 1.5배가 되고 CDJ가 NFS로 그만큼 더 읽는다
    static func bitDepth(_ file: AVAudioFile, source: URL) -> Int {
        let pcm = Int(file.fileFormat.streamDescription.pointee.mBitsPerChannel)
        let bits = pcm > 0 ? pcm : sourceBitDepth(source) ?? 0
        return bits > 0 && bits <= 16 ? 16 : 24
    }

    /// 파일이 적어 둔 원본 비트 깊이. 정수는 양수, 부동소수는 음수다. 모르면 nil
    static func sourceBitDepth(_ url: URL) -> Int? {
        var id: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &id) == noErr, let id else { return nil }
        defer { AudioFileClose(id) }
        var depth: Int32 = 0
        var size = UInt32(MemoryLayout<Int32>.size)
        guard AudioFileGetProperty(id, kAudioFilePropertySourceBitDepth, &size, &depth) == noErr, depth != 0 else { return nil }
        return Int(depth)
    }
}
