import DJCDomain
import AVFoundation
import CryptoKit
import Foundation

/// DJCrate 그리드 초안을 rekordbox 분석 파일(ANLZ)에 쓴다.
///
/// rekordbox 7.2.18이 직접 그리드를 옮겼을 때 바뀐 모양을 그대로 따른다(2026-09-26 확인):
/// - `.DAT`의 PQTZ만 새 박 목록으로 바꾸고 나머지 태그는 바이트 그대로 둔다(PMAI 전체 길이만 다시 적는다).
/// - `.EXT`의 PQT2는 빈 형태(머리 0, 본문 없음)로 바꾼다. 다른 태그는 그대로.
/// - DB(`contentFile` 해시·크기, `djmdContent`)는 건드리지 않는다. rekordbox도 이동만 했을 때는 DB를 고치지 않았다.
/// 박 시각은 정밀 시각(ms)을 내림해 적고, 곡 앞쪽 −1ms 안의 박은 0으로 적는다(rekordbox가 만든 그리드와 전 박 일치 확인).
/// 단일 템포 BPM 변경은 분석 기록도 갱신한다. 다구간 편집은 분석 기록을 보존하고,
/// 첫 구간의 BPM이 바뀔 때만 곡 BPM·TrackInfoUpdated를 갱신한다(2026-09-28 별도 BPM 입력창 실험).
public enum RekordboxGridWriter {
    /// 그리드 구간 → rekordbox PQTZ 박
    public static func beats(segments: [GridSegment], duration: Double) -> [BeatGridTags.Beat] {
        generate(segments: segments, duration: duration, preserving: [:]).beats
    }

    static func generate(segments: [GridSegment], duration: Double,
                         preserving originals: [Int: [BeatGridTags.Beat]],
                         unchangedBoundaries: Set<Int> = [],
                         fillsLeadIn: Bool = false) -> (beats: [BeatGridTags.Beat], counts: [Int]) {
        var beats: [BeatGridTags.Beat] = []
        var counts = [Int](repeating: 0, count: segments.count)
        for (index, segment) in segments.enumerated() where segment.bpm > 0 {
            let before = beats.count
            let interval = 60 / segment.bpm
            // 새로 만든 박만 가까운 다음 구간 박으로 대체한다. 원본 박은 실제 경계까지 보존한다.
            let end = index + 1 < segments.count
                ? segments[index + 1].start - (unchangedBoundaries.contains(index) ? 0 : interval / 2)
                : duration
            var k = index == 0 ? -Int(((segment.start + 0.001) / interval).rounded(.up)) : 0
            let bpm100 = Int((segment.bpm * 100).rounded())
            func append(until stop: Int?) {
                while stop.map({ k < $0 }) ?? true {
                    let t = segment.start + Double(k) * interval
                    if t >= end - 0.0005 { break }
                    if t > -0.001 {
                        let number = ((segment.firstBeatNumber - 1 + k) % 4 + 4) % 4 + 1
                        beats.append(BeatGridTags.Beat(number: number, bpm100: bpm100, time: max(0, t * 1000)))
                    }
                    k += 1
                }
            }
            if let original = originals[index] {
                // 첫 구간을 뒤로 옮기면 원본 첫 박 앞이 빈다. 옮겼을 때만 원본 없이 만들 때처럼 곡 시작까지 채운다.
                if fillsLeadIn { append(until: 0) }
                beats.append(contentsOf: original.filter { $0.time > -1 && $0.time < (end - 0.0005) * 1000 })
                // 다음 경계를 뒤로 옮겼다면 기존 박 뒤에 필요한 박만 이어 붙인다.
                k = original.count
            }
            append(until: nil)
            counts[index] = beats.count - before
        }
        return (beats, counts)
    }

    /// 곡 하나를 쓰기 위한 계획(파일 바이트까지 미리 만든다).
    public struct Plan: Sendable {
        public var trackUUID: String
        public var title: String
        public var datURL: URL
        public var extURL: URL?
        public var originalDat: Data
        public var originalExt: Data?
        public var newDat: Data
        public var newExt: Data?
        public var beats: [BeatGridTags.Beat]
        /// BPM이 바뀌면 새 `djmdContent.BPM`(BPM×100). 그대로면 nil(DB를 건드리지 않는다).
        public var newBPM100: Int?
        /// 전체를 단일 템포로 고칠 때만 분석 카운터와 파일 행도 갱신한다.
        public var updatesAnalysis: Bool
        /// `.DAT`의 DB 경로(`contentFile.Path`와 같다)
        public var analysisDataPath: String
    }

    public struct Blocked: Error, Sendable {
        public var title: String
        public var reason: String
    }

    /// 음원 안의 구간에 박이 하나도 없으면 대표 BPM과 실제 그리드가 어긋난다.
    static func hasEmptyVisibleSegment(segments: [GridSegment], counts: [Int], duration: Double) -> Bool {
        segments.enumerated().contains { index, segment in
            segment.start >= 0 && segment.start < duration && counts[index] == 0
        }
    }

    /// 계획을 만든다. 막히면 `Blocked`를 던진다.
    /// - Parameters:
    ///   - rekordboxBPM100: `djmdContent.BPM`(BPM×100). 구간 BPM과 달라도 이동만 할 때는 보존한다.
    public static func plan(draft: GridDraft, title: String, analysisDataPath: String?, rekordboxBPM100: Int,
                            audioPath: String, shareRoot: URL = RekordboxShare.directory) throws -> Plan {
        func block(_ reason: String) -> Blocked { Blocked(title: title, reason: reason) }
        guard draft.hasChanges else { throw block(String(ui: "그리드 변경이 없습니다")) }
        // PQTZ의 BPM은 u16, 시각은 u32다. 잘못된 초안을 정수로 바꾸다 앱이 종료되지 않게 먼저 거른다.
        guard !draft.segments.isEmpty, draft.segments.allSatisfy({
            $0.start.isFinite && abs($0.start) < Double(UInt32.max) / 1000
                && (20...655.35).contains($0.bpm) && (1...4).contains($0.firstBeatNumber)
        }), zip(draft.segments, draft.segments.dropFirst()).allSatisfy({ $0.start < $1.start }) else {
            throw block(String(ui: "그리드를 쓸 수 없습니다. BPM을 20~655.35로 맞추고 변속 지점의 위치와 순서를 확인하세요"))
        }
        let datURL = analysisDataPath.flatMap { $0.isEmpty ? nil : shareRoot.appending(path: String($0.drop(while: { $0 == "/" }))) }
        guard let datURL, FileManager.default.fileExists(atPath: datURL.path) else {
            throw block(String(ui: "rekordbox 분석 파일이 없습니다. rekordbox에서 트랙 분석을 먼저 하세요"))
        }
        // 구간 편집의 대표 BPM은 첫 구간을 바꿀 때만 갱신한다. 분석 기록은 전체 BPM 편집만 바꾼다.
        let bpmChanged = draft.segments.count != draft.base.count
            || zip(draft.segments, draft.base).contains { abs($0.bpm - $1.bpm) >= 0.005 }
            || rekordboxBPM100 == 0
        let updatesAnalysis = draft.segments.count == 1
        let firstBPMChanged = draft.segments.first.map { first in
            draft.base.first.map { abs(first.bpm - $0.bpm) >= 0.005 } ?? true
        } ?? false
        let newBPM100 = (updatesAnalysis ? bpmChanged : firstBPMChanged)
            ? draft.segments.first.map { Int(($0.bpm * 100).rounded()) } : nil
        let datFile: AnlzFile
        let originalDat: Data
        do {
            originalDat = try Data(contentsOf: datURL)
            datFile = try AnlzFile(data: originalDat)
        } catch {
            throw block(String(ui: "분석 파일을 읽지 못했습니다"))
        }
        guard let pqtz = datFile.tag("PQTZ") else { throw block(String(ui: "분석 파일에 그리드 칸(PQTZ)이 없습니다")) }
        let extURL = datURL.deletingPathExtension().appendingPathExtension("EXT")
        // .DAT만 있고 파형(.EXT)이 없는 곡은 rekordbox 분석이 끝나지 않은 반쪽 곡이다(분석 실패: 0박·파형 0인 .DAT와 .3EX만).
        // 그리드만 쓰면 rekordbox는 분석된 곡으로 보고 파형이 없는 채로 남는다(2026-09-26 サラマンダー). 기존 .DAT·파일 행을
        // rekordbox가 다시 분석할 때 어떻게 바꾸는지 몰라 분석 붙이기(`RekordboxWriter+Analysis`)도 하지 않는다.
        guard FileManager.default.fileExists(atPath: extURL.path) else {
            throw block(String(ui: "rekordbox 분석이 끝나지 않은 곡입니다(파형 파일 없음). rekordbox에서 트랙 분석을 다시 한 뒤 쓰세요"))
        }
        let originalExt = try? Data(contentsOf: extURL)
        let extFile = originalExt.flatMap { try? AnlzFile(data: $0) }
        guard originalExt != nil, extFile != nil else { throw block(String(ui: "확장 분석 파일(.EXT)을 읽지 못했습니다")) }

        // 초안을 시작한 뒤 rekordbox에서 그리드가 바뀌었으면 쓰지 않는다.
        let current = BeatGridTags.decode(pqtz: pqtz.bytes, pqt2: extFile?.tag("PQT2")?.bytes).beats
        // 편집기와 같은 PQTZ 정수 ms로 비교한다. PQT2 소수로 BPM을 역산하면 짧고 빠른 구간이 거짓 충돌한다(#159).
        let baseBeats = BeatGridTags.decode(pqtz: pqtz.bytes, pqt2: nil).beats
        let currentGrid = BeatGrid(beats: baseBeats.map { .init(number: $0.number, bpm: Double($0.bpm100) / 100, time: $0.time / 1000) })
        let currentSegments = GridDraft.segments(from: currentGrid)
        guard currentSegments.count == draft.base.count,
              zip(currentSegments, draft.base).allSatisfy({ abs($0.start - $1.start) < 0.002 && abs($0.bpm - $1.bpm) < 0.01 && $0.firstBeatNumber == $1.firstBeatNumber })
        else { throw block(String(ui: "초안을 만든 뒤 rekordbox에서 그리드가 바뀌었습니다. DJCrate에서 다시 불러와 확인하세요")) }

        // 초안은 PQTZ의 ms(내림)로 만든 것이다. 실제 박은 그 ms 안 어딘가에 있어서, rekordbox는 소수(PQT2)를 알면 그 값을,
        // 모르면 ms 한가운데(+0.5ms)를 기준으로 다시 계산한다(BPM 244→245 실험에서 바이트까지 확인).
        let anchors = Dictionary(current.map { (Int($0.time.rounded(.down)), $0.time) }, uniquingKeysWith: { first, _ in first })
        var segments = draft.segments
        for index in segments.indices {
            let originalStart = draft.base.count == segments.count ? draft.base[index].start : segments[index].start
            let precise = anchors[Int((originalStart * 1000).rounded())]
            let fraction = precise.map { $0 - $0.rounded(.down) } ?? 0
            segments[index].start += (fraction > 0 ? fraction : 0.5) / 1000
        }

        // 곡 길이(rekordbox 시간축): 음원 길이 + 인코더 지연
        let url = URL(filePath: audioPath)
        guard let audio = try? AVAudioFile(forReading: url) else { throw block(String(ui: "음원 파일을 열지 못했습니다")) }
        let duration = Double(audio.length) / audio.processingFormat.sampleRate + RekordboxTimeline.predictedOffset(url: url)
        // 대체 승인은 구간화에서 사라지는 내부 박의 변경도 쓰기 직전에 확인한다.
        if draft.replacementSource != nil, !draft.isVerifiedReplacement(of: currentGrid, duration: duration) {
            throw block(String(ui: "초안을 만든 뒤 rekordbox에서 그리드가 바뀌었습니다. DJCrate에서 다시 불러와 확인하세요"))
        }
        // 그대로인 구간은 실측 BPM으로 다시 만들면 1ms씩 흔들릴 수 있다. 원래 PQTZ 칸을 보존한다.
        var preserved: [Int: [BeatGridTags.Beat]] = [:]
        let matched = draft.matchingBaseIndices()
        let unchangedBoundaries = Set(draft.segments.indices.filter { draft.preservesBoundary(after: $0, matched: matched) })
        if segments.count > 1 {
            for (index, segment) in draft.segments.enumerated() {
                guard let oldIndex = matched[index], abs(segment.bpm - draft.base[oldIndex].bpm) < 0.005 else { continue }
                let base = draft.base[oldIndex]
                let lower = currentGrid.firstIndex(atOrAfter: currentSegments[oldIndex].start)
                let upper = oldIndex + 1 < currentSegments.count
                    ? currentGrid.firstIndex(atOrAfter: currentSegments[oldIndex + 1].start) : current.count
                let delta = segment.start - base.start
                let numberDelta = segment.firstBeatNumber - base.firstBeatNumber
                preserved[index] = current[lower..<upper].map { beat in
                    let number = (beat.number - 1 + numberDelta + 4) % 4 + 1
                    return BeatGridTags.Beat(number: number, bpm100: beat.bpm100,
                                             time: beat.time + delta * 1000)
                }
            }
        }
        // 첫 구간을 옮겼을 때만 곡 시작 쪽을 채운다. 그대로인 구간은 원본 박만 둔다.
        let movesFirst = matched.first.flatMap { $0 }.map { abs(draft.segments[0].start - draft.base[$0].start) >= 0.0005 } ?? false
        let generated = generate(segments: segments, duration: duration, preserving: preserved,
                                 unchangedBoundaries: unchangedBoundaries, fillsLeadIn: movesFirst)
        let beats = generated.beats
        guard beats.count >= 8 else { throw block(String(ui: "만든 박이 너무 적습니다")) }
        guard !hasEmptyVisibleSegment(segments: segments, counts: generated.counts, duration: duration) else {
            throw block(String(ui: "그리드 구간의 첫 박이 사라집니다. 변속 지점이나 BPM을 조정하세요"))
        }

        var newDatFile = datFile
        newDatFile.replace("PQTZ", with: BeatGridTags.pqtz(beats))
        var newExt: Data?
        if var extFile {
            if extFile.tag("PQT2") != nil { extFile.replace("PQT2", with: BeatGridTags.pqt2([], unknown: 0)) }
            newExt = extFile.serialized()
        }
        return Plan(trackUUID: draft.trackUUID, title: title, datURL: datURL, extURL: originalExt == nil ? nil : extURL,
                    originalDat: originalDat, originalExt: originalExt, newDat: newDatFile.serialized(), newExt: newExt, beats: beats,
                    newBPM100: newBPM100, updatesAnalysis: updatesAnalysis,
                    analysisDataPath: analysisDataPath ?? "")
    }

    /// 새 파일이 의도대로인지: 그리드 칸만 바뀌고 나머지 태그는 원본과 바이트까지 같아야 한다.
    public static func verify(_ plan: Plan, written dat: Data, ext: Data?) throws {
        func fail(_ reason: String) -> DJCError { .writeVerificationFailed("\(reason) (\(plan.title))") }
        let original = try AnlzFile(data: plan.originalDat), now = try AnlzFile(data: dat)
        guard original.header.prefix(8) == now.header.prefix(8), original.header.dropFirst(12) == now.header.dropFirst(12),
              original.tags.map(\.fourcc) == now.tags.map(\.fourcc) else {
            throw fail(String(ui: "분석 파일 태그 구성이 달라졌습니다"))
        }
        for (a, b) in zip(original.tags, now.tags) where a.fourcc != "PQTZ" && a.bytes != b.bytes { throw fail(String(ui: "그리드 밖 태그(\(a.fourcc))가 바뀌었습니다")) }
        let decoded = BeatGridTags.decode(pqtz: now.tag("PQTZ")!.bytes, pqt2: nil).beats
        guard decoded.count == plan.beats.count,
              zip(decoded, plan.beats).allSatisfy({ $0.number == $1.number && $0.bpm100 == $1.bpm100 && Int($0.time) == Int((max(0, $1.time) + 1e-6).rounded(.down)) })
        else { throw fail(String(ui: "쓴 그리드가 의도와 다릅니다")) }
        if let originalExt = plan.originalExt {
            guard let ext else { throw fail(String(ui: ".EXT가 사라졌습니다")) }
            let a = try AnlzFile(data: originalExt), b = try AnlzFile(data: ext)
            guard a.tags.map(\.fourcc) == b.tags.map(\.fourcc) else { throw fail(String(ui: ".EXT 태그 구성이 달라졌습니다")) }
            for (x, y) in zip(a.tags, b.tags) where x.fourcc != "PQT2" && x.bytes != y.bytes { throw fail(String(ui: ".EXT의 \(x.fourcc)가 바뀌었습니다")) }
        }
    }
}

extension RekordboxGridWriter {
    /// 계획대로 파일을 바꾼다(같은 폴더의 임시 파일에 쓰고 바꿔 끼운다). 다시 읽어 검증하고, 실패하면 원본으로 되돌리고 던진다.
    static func apply(_ plan: Plan) throws {
        let fm = FileManager.default
        func replace(_ url: URL, with data: Data) throws {
            let partial = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).djc-part")
            try? fm.removeItem(at: partial)
            try data.write(to: partial)
            if let attributes = try? fm.attributesOfItem(atPath: url.path), let mode = attributes[.posixPermissions] {
                try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: partial.path)
            }
            _ = try fm.replaceItemAt(url, withItemAt: partial)
        }
        do {
            try replace(plan.datURL, with: plan.newDat)
            if let extURL = plan.extURL, let newExt = plan.newExt { try replace(extURL, with: newExt) }
            let dat = try Data(contentsOf: plan.datURL)
            let ext = try plan.extURL.map { try Data(contentsOf: $0) }
            guard dat == plan.newDat, ext == plan.newExt else { throw DJCError.writeVerificationFailed(String(ui: "분석 파일이 쓴 내용과 다릅니다(\(plan.title))")) }
            try verify(plan, written: dat, ext: ext)
        } catch {
            try? restore(plan)
            throw error
        }
    }

    /// 원본 바이트로 되돌린다.
    static func restore(_ plan: Plan) throws {
        try plan.originalDat.write(to: plan.datURL, options: .atomic)
        if let extURL = plan.extURL, let originalExt = plan.originalExt { try originalExt.write(to: extURL, options: .atomic) }
    }
}

extension RekordboxGridWriter.Plan {
    /// 새 `.DAT`의 MD5(`contentFile.Hash`와 같은 형식)
    public var newDatMD5: String { Insecure.MD5.hash(data: newDat).map { String(format: "%02x", $0) }.joined() }
}
