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
    /// 원본이 바뀌어 새로 바꾸면 그 원본의 옛 변환본을 지운다(#287).
    /// - Parameter cache: 바꾼 WAV를 둘 폴더(`DJCCachePaths.linkAudio`). 내어 주는 곡과 다른 뿌리 폴더에 있어도 서버가 원본 이름으로 내어 준다
    public static func live(cache: URL) -> LinkAudioConverter {
        LinkAudioConverter(convert: { path throws(LinkProblem) in
            let result = await BlockingWork.run(qos: .userInitiated) { () -> Result<String?, LinkProblem> in
                Result { () throws(LinkProblem) -> String? in try convertIfNeeded(path, cache: cache) }
            }
            return try result.get()
        }, needsConversion: { path in
            // .m4a는 파일을 열어 코덱을 본다
            await BlockingWork.run(qos: .userInitiated) { needsConversion(URL(filePath: path)) }
        })
    }

    /// 바꿔야 하면 바꾼 WAV 경로, 아니면 nil
    static func convertIfNeeded(_ path: String, cache: URL) throws(LinkProblem) -> String? {
        let source = URL(filePath: path)
        guard needsConversion(source) else { return nil }
        let name: CacheName
        do {
            name = try cacheName(source)
        } catch {
            throw .conversionFailed(String(ui: "음원 파일을 읽지 못했습니다"))
        }
        let output = cache.appending(path: name.file)
        if FileManager.default.fileExists(atPath: output.path) { return output.path }
        do {
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            let file = try AVAudioFile(forReading: source)
            let span = EditFrameSpan(sourceFrame: 0, frameCount: file.length, outputFrame: 0, crossfadeFrames: 0)
            _ = try EditRenderer.render([span], source: source, to: output, bitDepth: bitDepth(file, source: source))
            removeOlderVersions(of: name, in: cache)
            return output.path
        } catch {
            // 같은 곡을 거의 같이 두 번 놓아 다른 쪽이 먼저 다 썼으면 그 파일을 쓴다
            if FileManager.default.fileExists(atPath: output.path) { return output.path }
            throw .conversionFailed(error.localizedDescription)
        }
    }

    /// 같은 원본 경로의 다른 판(원본이 바뀌기 전에 바꾼 WAV)을 지운다. 연결마다 원본 하나는 한 번만 바꾸므로 지금 내어 주는 판이 아니다
    static func removeOlderVersions(of name: CacheName, in cache: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []
        for other in names where other != name.file && other.hasPrefix(name.prefix) && other.hasSuffix(".wav") {
            try? FileManager.default.removeItem(at: cache.appending(path: other))
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

    /// 변환본 이름 `<원본 이름 40자>-<경로 열쇠>-<판 열쇠>.wav`. 원본이 바뀌면(크기·수정 시각) 판 열쇠만 달라져 새로 바꾸고,
    /// 같은 앞부분(`prefix`)으로 옛 판을 찾아 지운다
    struct CacheName: Equatable {
        /// 원본 이름과 경로 열쇠까지(`-`로 끝난다)
        var prefix: String
        var version: String
        var file: String { "\(prefix)\(version).wav" }
    }

    /// 원본 경로·크기·수정 시각으로 지은 이름
    static func cacheName(_ source: URL) throws -> CacheName {
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let path = source.standardizedFileURL.path
        let version = "\(values.fileSize ?? 0)\n\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        return CacheName(prefix: "\(source.deletingPathExtension().lastPathComponent.prefix(40))-\(digest(path, bytes: 8))-",
                         version: digest(path + "\n" + version, bytes: 6))
    }

    private static func digest(_ text: String, bytes: Int) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(bytes).map { String(format: "%02x", $0) }.joined()
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
