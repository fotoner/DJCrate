import Foundation

/// 파일 이름을 비교용으로 미리 갈라 둔 것: 정규화(NFC)한 이름, 대소문자를 접은 이름·줄기·확장자.
struct RelocateName: Sendable {
    let nfc: String
    let folded: String
    let stem: String
    let ext: String

    init(_ fileName: String) {
        nfc = fileName.precomposedStringWithCanonicalMapping
        folded = nfc.folding(options: .caseInsensitive, locale: nil)
        let ns = folded as NSString
        ext = ns.pathExtension
        stem = ext.isEmpty ? folded : ns.deletingPathExtension
    }

    /// 태그 문자열 비교용: 정규화·대소문자·앞뒤 공백을 무시한다. 빈 값은 nil(모름).
    static func tagKey(_ text: String?) -> String? {
        guard let text else { return nil }
        let key = text.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }
}

/// 곡 쪽에서 파일 이름·크기를 미리 모아 두고, 폴더 아래 파일 중 후보가 될 수 있는 것만 가려낸다.
/// 파일마다 태그를 읽는 일은 비싸서, 이름(줄기)이나 크기가 어느 곡과도 안 맞는 파일은 읽지 않는다.
/// (이름도 크기도 다른 파일은 태그·길이가 맞아도 후보 기준 점수에 못 미친다.)
public struct RelocateTargetIndex: Sendable {
    private let foldedNames: Set<String>
    private let stems: Set<String>
    private let sizes: Set<Int64>

    public init(targets: [RelocateTarget]) {
        var names = Set<String>(), stems = Set<String>(), sizes = Set<Int64>()
        for target in targets {
            let name = RelocateName(target.fileName)
            names.insert(name.folded)
            stems.insert(name.stem)
            if let size = target.fileSize, size > 0 { sizes.insert(size) }
        }
        foldedNames = names
        self.stems = stems
        self.sizes = sizes
    }

    public func mayMatch(fileName: String, size: Int64) -> Bool {
        let name = RelocateName(fileName)
        return foldedNames.contains(name.folded) || stems.contains(name.stem) || (size > 0 && sizes.contains(size))
    }
}

/// 파일 없는 곡마다 폴더 아래 음원 목록에서 후보를 찾아 확실·애매·없음으로 나눈다(#62). 입출력 없는 순수 규칙.
public enum RelocateMatcher {
    /// 곡과 파일 한 쌍이 어디까지 맞는지(길이가 어긋난 쌍도 그대로 돌려준다. 후보에서 빼는 것은 `match`).
    public static func evidence(for target: RelocateTarget, file: RelocateFile) -> RelocateEvidence {
        evidence(PreparedTarget(target), PreparedFile(file))
    }

    public static func match(targets: [RelocateTarget], files: [RelocateFile]) -> RelocateReport {
        let prepared = files.map(PreparedFile.init)
        let index = FileIndex(prepared)

        // 곡마다 후보(후보 기준 점수 이상, 길이가 어긋나지 않은 것)를 점수 높은 순으로.
        var scoredByTarget: [[Scored]] = []
        scoredByTarget.reserveCapacity(targets.count)
        for target in targets {
            let want = PreparedTarget(target)
            var scored: [Scored] = []
            for fileIndex in index.possible(for: want) {
                let evidence = evidence(want, prepared[fileIndex])
                guard !evidence.isDisqualified, evidence.score >= RelocateRules.candidateScore else { continue }
                scored.append(Scored(file: fileIndex, score: evidence.score, evidence: evidence))
            }
            scored.sort { ($0.score, prepared[$1.file].file.path) > ($1.score, prepared[$0.file].file.path) }
            scoredByTarget.append(scored)
        }

        // 파일마다 "자기 1위와 같은 급으로 이 파일을 주 후보로 삼는 곡"과 그 점수.
        var claims: [Int: [(target: Int, score: Int)]] = [:]
        for (targetIndex, scored) in scoredByTarget.enumerated() {
            guard let best = scored.first else { continue }
            for entry in scored where entry.score >= best.score - RelocateRules.ambiguityGap {
                claims[entry.file, default: []].append((targetIndex, entry.score))
            }
        }

        var results: [RelocateResult] = []
        results.reserveCapacity(targets.count)
        for (targetIndex, target) in targets.enumerated() {
            let scored = scoredByTarget[targetIndex]
            guard let best = scored.first else {
                results.append(RelocateResult(target: target, outcome: .none))
                continue
            }
            let options = scored.prefix(RelocateRules.maxOptionsPerTrack).map { entry in
                RelocateCandidate(file: prepared[entry.file].file, score: entry.score, evidence: entry.evidence)
            }
            let leadingCount = scored.prefix { $0.score >= best.score - RelocateRules.ambiguityGap }.count
            // 다른 곡이 이 파일을 비슷하거나 더 잘 맞는 주 후보로 삼으면 내 것이라고 못 박지 않는다.
            let shared = claims[best.file, default: []].contains {
                $0.target != targetIndex && $0.score >= best.score - RelocateRules.ambiguityGap
            }
            let outcome: RelocateOutcome
            if leadingCount > 1 {
                outcome = .ambiguous(.severalCandidates, options)
            } else if shared {
                outcome = .ambiguous(.sharedFile, options)
            } else if !best.evidence.sameExtension {
                outcome = .ambiguous(.differentExtension, options)
            } else if best.score < RelocateRules.confidentScore {
                outcome = .ambiguous(.weakEvidence, options)
            } else {
                outcome = .confident(options[0])
            }
            results.append(RelocateResult(target: target, outcome: outcome))
        }
        return RelocateReport(results: results)
    }

    // MARK: 내부

    private struct Scored {
        let file: Int
        let score: Int
        let evidence: RelocateEvidence
    }

    private struct PreparedTarget {
        let name: RelocateName
        let size: Int64?
        let length: Double?
        let title: String?
        let artist: String?

        init(_ target: RelocateTarget) {
            name = RelocateName(target.fileName)
            size = target.fileSize.flatMap { $0 > 0 ? $0 : nil }
            length = target.lengthSeconds.flatMap { $0 > 0 ? Double($0) : nil }
            // 암호화된 제목(`$A7:…`)은 태그와 견줄 수 없다.
            title = target.title.hasPrefix("$A7:") ? nil : RelocateName.tagKey(target.title)
            artist = RelocateName.tagKey(target.artist)
        }
    }

    private struct PreparedFile {
        let file: RelocateFile
        let name: RelocateName
        let title: String?
        let artist: String?

        init(_ file: RelocateFile) {
            self.file = file
            name = RelocateName(file.name)
            title = file.title?.hasPrefix("$A7:") == true ? nil : RelocateName.tagKey(file.title)
            artist = RelocateName.tagKey(file.artist)
        }
    }

    /// 곡 하나가 후보로 삼을 수 있는 파일(이름·줄기·크기가 맞는 것)만 빠르게 찾는 색인.
    private struct FileIndex {
        private var byName: [String: [Int]] = [:]
        private var byStem: [String: [Int]] = [:]
        private var bySize: [Int64: [Int]] = [:]

        init(_ files: [PreparedFile]) {
            for (index, file) in files.enumerated() {
                byName[file.name.folded, default: []].append(index)
                byStem[file.name.stem, default: []].append(index)
                if file.file.size > 0 { bySize[file.file.size, default: []].append(index) }
            }
        }

        func possible(for target: PreparedTarget) -> [Int] {
            var seen = Set<Int>()
            var result: [Int] = []
            func add(_ indices: [Int]?) {
                for index in indices ?? [] where seen.insert(index).inserted { result.append(index) }
            }
            add(byName[target.name.folded])
            add(byStem[target.name.stem])
            if let size = target.size { add(bySize[size]) }
            return result
        }
    }

    private static func evidence(_ target: PreparedTarget, _ file: PreparedFile) -> RelocateEvidence {
        let name: RelocateEvidence.Name
        if target.name.nfc == file.name.nfc {
            name = .exact
        } else if target.name.folded == file.name.folded {
            name = .caseInsensitive
        } else if target.name.stem == file.name.stem {
            name = .stemOnly
        } else {
            name = .different
        }
        let size: RelocateEvidence.Check = if let want = target.size, file.file.size > 0 {
            want == file.file.size ? .equal : .different
        } else {
            .unknown
        }
        let duration: RelocateEvidence.Check = if let want = target.length, let have = file.file.durationSeconds, have > 0 {
            abs(want - have) <= RelocateRules.durationToleranceSeconds ? .equal : .different
        } else {
            .unknown
        }
        return RelocateEvidence(name: name, sameExtension: target.name.ext == file.name.ext, size: size, duration: duration,
                                title: check(target.title, file.title), artist: check(target.artist, file.artist))
    }

    private static func check(_ wanted: String?, _ found: String?) -> RelocateEvidence.Check {
        guard let wanted, let found else { return .unknown }
        return wanted == found ? .equal : .different
    }
}
