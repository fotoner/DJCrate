import DJCDomain
import Foundation

/// 두 USB 폴더의 파일 트리와 분석 파일(ANLZ) 태그를 비교한다(실험·쓰기 뒤 확인). 읽기만 한다.
/// 결과에는 경로를 넣지 않는다. 묶음 이름·곡 id·태그 이름·수만 적는다.
public enum UsbFileDiff {
    public struct Options: Sendable {
        /// 파일 트리(NFC 경로 → 크기·SHA-256) 비교
        public var files = true
        /// 분석 파일을 (PPTH, 확장자)로 짝지어 태그 목록·태그 바이트 비교
        public var anlz = true
        /// 파일 트리에서도 USBANLZ 파일을 경로 대신 (PPTH, 확장자)로 짝짓는다
        public var ignoreAnalysisFolder = false
        /// PPTH 경로(NFC) → 곡 id. 분석 파일 차이를 경로 대신 곡 id로 적는다
        public var trackIDs: [String: Int] = [:]
        /// 내용이 같은 파일의 수정 시각도 비교한다(FAT는 2초 단위로 적으므로 2초 단위로 내려서)
        public var mtime = false

        public init(files: Bool = true, anlz: Bool = true, ignoreAnalysisFolder: Bool = false, trackIDs: [String: Int] = [:],
                    mtime: Bool = false) {
            self.files = files
            self.anlz = anlz
            self.ignoreAnalysisFolder = ignoreAnalysisFolder
            self.trackIDs = trackIDs
            self.mtime = mtime
        }
    }

    /// 파일 묶음(차이를 경로 대신 이 이름으로 센다). 순서가 출력 순서다
    static let groups = ["DB", "설정", "USBANLZ", "Artwork", "Contents", "그 밖"]

    static func group(_ path: String) -> String {
        let parts = path.split(separator: "/").map { UsbLayout.collisionKey(String($0)) }
        guard let first = parts.first else { return "그 밖" }
        if first == UsbLayout.collisionKey(UsbLayout.contents) { return "Contents" }
        guard first == UsbLayout.collisionKey("PIONEER"), parts.count >= 2 else { return "그 밖" }
        switch parts[1] {
        case UsbLayout.collisionKey("rekordbox"): return "DB"
        case UsbLayout.collisionKey("USBANLZ"): return "USBANLZ"
        case UsbLayout.collisionKey("Artwork"): return "Artwork"
        default: return parts.count == 2 && parts[1].hasSuffix(".dat") ? "설정" : "그 밖"
        }
    }

    public static func compare(_ a: UsbRoot, _ b: UsbRoot, options: Options) throws
        -> (fileSummary: String, anlzSummary: String, differences: [String]) {
        var differences: [String] = []
        var fileSummary = "", anlzSummary = ""
        if options.files {
            let result = try compareFiles(a, b, options: options)
            fileSummary = result.summary
            differences += result.differences
        }
        if options.anlz {
            let result = try compareAnalysis(a, b, options: options)
            anlzSummary = result.summary
            differences += result.differences
        }
        return (fileSummary, anlzSummary, differences)
    }

    // MARK: - 파일 트리

    /// 비교 키 → (묶음, 크기·해시, 상대 경로). ignoreAnalysisFolder면 USBANLZ 파일은 (PPTH, 확장자) 키
    static func fileKeys(_ root: UsbRoot, options: Options) throws -> [String: (group: String, stamp: UsbTreeStamp, path: String)] {
        var keys: [String: (group: String, stamp: UsbTreeStamp, path: String)] = [:]
        for (path, stamp) in try UsbTree.fingerprint(root).files {
            let group = group(path)
            var key = "path:" + path
            if options.ignoreAnalysisFolder, group == "USBANLZ", let pair = try? analysisKey(root, path) { key = "ppth:" + pair }
            // 같은 PPTH 키가 둘이면 뒤엣것은 경로로 둔다
            if keys[key] != nil { key = "path:" + path }
            keys[key] = (group, stamp, path)
        }
        return keys
    }

    /// 수정 시각을 FAT 단위(2초)로 내린 값. 읽지 못하면 nil
    static func fatTime(_ root: UsbRoot, _ path: String) -> Int64? {
        guard let url = try? root.url(for: path),
              let date = try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date else { return nil }
        let seconds = Int64(date.timeIntervalSince1970.rounded(.down))
        return seconds - ((seconds % 2) + 2) % 2
    }

    static func compareFiles(_ a: UsbRoot, _ b: UsbRoot, options: Options) throws -> (summary: String, differences: [String]) {
        let left = try fileKeys(a, options: options), right = try fileKeys(b, options: options)
        var same = 0, timeSame = 0
        var onlyA: [String: Int] = [:], onlyB: [String: Int] = [:], changed: [String: Int] = [:], timeChanged: [String: Int] = [:]
        var differences: [String] = []
        for key in Set(left.keys).union(right.keys).sorted() {
            switch (left[key], right[key]) {
            case let (l?, r?):
                if l.stamp == r.stamp {
                    same += 1
                    guard options.mtime else { continue }
                    if let x = fatTime(a, l.path), x == fatTime(b, r.path) { timeSame += 1 } else {
                        timeChanged[l.group, default: 0] += 1
                        differences.append("파일 mtime 다름: \(l.group)")
                    }
                } else {
                    changed[l.group, default: 0] += 1
                    differences.append("파일 내용 다름: \(l.group)")
                }
            case let (l?, nil):
                onlyA[l.group, default: 0] += 1
                differences.append("파일 한쪽에만 A: \(l.group)")
            case let (nil, r?):
                onlyB[r.group, default: 0] += 1
                differences.append("파일 한쪽에만 B: \(r.group)")
            case (nil, nil): break
            }
        }
        func total(_ counts: [String: Int]) -> Int { counts.values.reduce(0, +) }
        func breakdown(_ counts: [String: Int]) -> String {
            groups.compactMap { name in counts[name].map { "\(name) \($0)" } }.joined(separator: ", ")
        }
        var summary = "파일 \(same)/\(max(left.count, right.count)) 같음, 한쪽에만 \(total(onlyA))/\(total(onlyB)), 내용 다름 \(total(changed))"
        let parts = [("한쪽에만 A", onlyA), ("한쪽에만 B", onlyB), ("내용 다름", changed)]
            .filter { !$0.1.isEmpty }.map { "\($0.0): \(breakdown($0.1))" }
        if !parts.isEmpty { summary += " (" + parts.joined(separator: " · ") + ")" }
        if options.mtime {
            summary += ", mtime(2초 단위) 같음 \(timeSame)/\(same)"
            if !timeChanged.isEmpty { summary += " (mtime 다름: \(breakdown(timeChanged)))" }
        }
        return (summary, differences)
    }

    // MARK: - 분석 파일

    /// "PPTH(NFC)\u{0}확장자". PPTH를 읽지 못하면 던진다
    static func analysisKey(_ root: UsbRoot, _ path: String) throws -> String {
        let file = try AnlzFile(data: Data(contentsOf: root.url(for: path)))
        guard let tag = file.tag("PPTH") else { throw UsbError.readFailed(detail: "no PPTH") }
        return UsbLayout.nfc(try AnlzPathTag.decode(tag.bytes)) + "\u{0}" + extensionOf(path)
    }

    static func extensionOf(_ path: String) -> String {
        (path.split(separator: "/").last.map(String.init) ?? path).split(separator: ".").last.map { String($0).uppercased() } ?? ""
    }

    /// 한 쪽의 분석 파일. 같은 (PPTH, 확장자) 키에 파일이 여럿일 수 있다(같은 곡의 분석 파일을 다른 폴더에 한 벌 더 둔 실험 사본 등)
    struct AnalysisSide {
        /// 키 → 그 키의 파일(경로 순)
        var files: [String: [AnlzFile]] = [:]
        /// PPTH를 읽지 못한 파일 수
        var unreadable = 0
        /// 모든 분석 파일 수(PPTH를 읽지 못한 것 포함)
        var total: Int { files.values.reduce(unreadable) { $0 + $1.count } }
        /// 같은 키의 두 번째부터의 파일 수
        var duplicates: Int { files.values.reduce(0) { $0 + max(0, $1.count - 1) } }
    }

    /// USBANLZ 아래 ANLZ*.DAT·.EXT·.2EX 파일을 (PPTH, 확장자) 키로 모은다. 같은 키의 파일은 버리지 않고 모두 둔다
    static func analysisFiles(_ root: UsbRoot) throws -> AnalysisSide {
        let start = UsbLayout.analysisRoot
        var side = AnalysisSide()
        guard (try? root.url(for: start)).map({ FileManager.default.fileExists(atPath: $0.path) }) == true else { return side }
        for entry in try UsbTree.walk(root, under: start) where !entry.isDirectory && !entry.isSymlink {
            let name = entry.relativePath.split(separator: "/").last.map(String.init) ?? ""
            guard name.uppercased().hasPrefix("ANLZ"), ["DAT", "EXT", "2EX"].contains(extensionOf(name)) else { continue }
            guard let file = try? AnlzFile(data: Data(contentsOf: root.url(for: entry.relativePath))), let tag = file.tag("PPTH"),
                  let path = try? AnlzPathTag.decode(tag.bytes) else { side.unreadable += 1; continue }
            side.files[UsbLayout.nfc(path) + "\u{0}" + extensionOf(name), default: []].append(file)
        }
        return side
    }

    static func compareAnalysis(_ a: UsbRoot, _ b: UsbRoot, options: Options) throws -> (summary: String, differences: [String]) {
        let left = try analysisFiles(a), right = try analysisFiles(b)
        let keys = Set(left.files.keys).union(right.files.keys).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        var same = 0, onlyA = 0, onlyB = 0
        var tagCounts: [String: Int] = [:]
        var differences: [String] = []
        // 읽지 못한 파일을 빼면 비교가 끝나지 않았는데도 "차이 0"으로 보고한다
        differences.append(contentsOf: repeatElement("ANLZ A: 비교 불가(PPTH 못 읽음)", count: left.unreadable))
        differences.append(contentsOf: repeatElement("ANLZ B: 비교 불가(PPTH 못 읽음)", count: right.unreadable))
        for (index, key) in keys.enumerated() {
            let parts = key.split(separator: "\u{0}", omittingEmptySubsequences: false)
            let label = options.trackIDs[String(parts[0])].map { "곡 \($0)" } ?? "짝 \(index + 1)"
            let ext = parts.count > 1 ? String(parts[1]) : ""
            let l = left.files[key] ?? [], r = right.files[key] ?? []
            if r.isEmpty {
                onlyA += l.count
                differences.append("ANLZ \(label) \(ext): A에만")
                continue
            }
            if l.isEmpty {
                onlyB += r.count
                differences.append("ANLZ \(label) \(ext): B에만")
                continue
            }
            func record(_ x: AnlzFile, _ y: AnlzFile, note: String) {
                let tags = differingTags(x, y)
                if tags.isEmpty { same += 1; return }
                for tag in tags { tagCounts[tag, default: 0] += 1 }
                differences.append("ANLZ \(label) \(ext)\(note): " + tags.joined(separator: ", "))
            }
            // 같은 차례끼리 짝짓고(같은 트리면 겹친 파일도 그대로 같다), 한쪽에만 남은 겹친 파일은 다른 쪽 첫 파일과 비교한다
            for i in 0..<min(l.count, r.count) { record(l[i], r[i], note: i == 0 ? "" : " 겹침") }
            for extra in l.dropFirst(r.count) { record(extra, r[0], note: " A 겹침") }
            for extra in r.dropFirst(l.count) { record(l[0], extra, note: " B 겹침") }
        }
        var summary = "ANLZ \(same)/\(max(left.total, right.total)) 바이트 같음"
        if !tagCounts.isEmpty {
            summary += ", 다른 태그: " + tagCounts.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: ", ")
        }
        if onlyA + onlyB > 0 { summary += ", 짝 없음 \(onlyA)/\(onlyB)" }
        if left.duplicates + right.duplicates > 0 { summary += ", PPTH 겹침 \(left.duplicates)/\(right.duplicates)" }
        if left.unreadable + right.unreadable > 0 { summary += ", PPTH 못 읽음 \(left.unreadable)/\(right.unreadable)" }
        return (summary, differences)
    }

    /// 다른 태그 이름(같은 이름 태그는 나온 순서로 짝짓는다). 머리가 다르면 "PMAI"
    static func differingTags(_ a: AnlzFile, _ b: AnlzFile) -> [String] {
        var names: [String] = []
        if a.header != b.header { names.append("PMAI") }
        func grouped(_ file: AnlzFile) -> [String: [Data]] {
            Dictionary(grouping: file.tags, by: \.fourcc).mapValues { $0.map(\.bytes) }
        }
        let left = grouped(a), right = grouped(b)
        for name in Set(left.keys).union(right.keys).sorted() {
            let l = left[name] ?? [], r = right[name] ?? []
            for index in 0..<max(l.count, r.count) where index >= l.count || index >= r.count || l[index] != r[index] {
                names.append(name)
            }
        }
        // 태그가 같은데 순서만 다르면 목록 차이로 적는다
        if names.isEmpty, a.tags.map(\.fourcc) != b.tags.map(\.fourcc) { names.append("태그 순서") }
        return names
    }
}
