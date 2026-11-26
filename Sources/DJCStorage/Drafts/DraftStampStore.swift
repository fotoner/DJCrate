import DJCDomain
import Foundation

/// 초안 도장(출처·판·내용 해시)의 사이드카(자동 저장 R5·R22). 초안 폴더 옆 `draft-stamps/`에 적는다.
/// - 곡 초안(큐·그리드·태그·그림)은 `<종류>/<곡 UUID>.json` 하나씩, 게인·합치기는 초안 파일이 한 묶음이라 `gain.json`·`merge.json`에
///   곡(합치기 ID)별 사전으로, 재생 목록은 `playlist.json`에 단계 차례대로 적는다. 판의 마지막 번호는 `revision`에 적는다.
/// - 판은 이 폴더 전체에서 겹치지 않는 번호다. 앱·CLI가 같은 초안 잠금(`draft-stamps.lock`, flock) 안에서 번호를 받고 도장을 적는다.
/// - 초안 파일을 쓴 뒤에 도장을 적는다. 중간에 멈추면 도장이 옛것이라 해시가 어긋나는(제안) 쪽으로만 틀어진다.
public enum DraftStampStore {
    public static let folderName = "draft-stamps"
    static let lockName = "draft-stamps.lock"
    static let revisionName = "revision"

    /// 도장 사이드카 폴더(초안 폴더 `home` 옆)
    public static func folder(home: URL) -> URL { home.appending(path: folderName, directoryHint: .isDirectory) }

    /// 초안 잠금 파일(앱·CLI가 함께 쓴다)
    public static func lockURL(home: URL) -> URL { home.appending(path: lockName) }

    /// 초안 잠금 안에서 일한다: 판 번호 받기, 도장 쓰기, 판 비교와 삭제가 모두 이 안에서 한다. flock이라 같은 프로세스 안에서도
    /// 따로 연 잠금끼리 막고, 프로세스가 죽으면 커널이 푼다. 재진입할 수 없다(안에서 다시 부르지 않는다).
    /// 잠금 파일을 열거나 잡지 못하면 `body`를 하지 않고 던진다: 잠금 없이 쓰면 판 번호가 겹치고 정리가 다른 프로세스의 저장과 섞인다.
    /// 앱은 지금의 저장 실패로 알리고 CLI는 초안 입출력 실패로 알린다
    public static func withLock<T>(home: URL, _ body: () throws -> T) throws -> T {
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let descriptor = open(lockURL(home: home).path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o644)
        guard descriptor >= 0 else { throw CocoaError(.fileLocking) }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { throw CocoaError(.fileLocking) }
        }
        return try body()
    }

    // MARK: 읽기

    /// 곡 초안(`DraftKey`)의 도장. 초안이 없거나 도장을 모르면 nil. 초안 파일의 내용은 읽지 않는다.
    /// 잠그지 않는다(쓰는 쪽이 파일을 통째로 바꾸므로 반쯤 쓴 도장을 읽지 않는다)
    public static func stamp(_ key: DraftKey, home: URL) -> DraftStamp? {
        guard draftExists(key, home: home) else { return nil }
        return read(key, home: home)
    }

    /// 이름을 파일 이름으로 쓸 수 있는지(도장 폴더 밖을 읽거나 쓰지 않게)
    static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.contains("\0") && name != "." && name != ".."
    }

    private static func perFile(_ kind: DraftKey.Kind) -> Bool {
        switch kind {
        case .cue, .grid, .tag, .artwork: true
        case .gain, .merge: false
        }
    }

    /// 초안 파일이 있는지(종류마다 파일이 하나인 종류만 본다. 게인·합치기는 도장을 지울 때 함께 지운다)
    private static func draftExists(_ key: DraftKey, home: URL) -> Bool {
        guard perFile(key.kind) else { return true }
        guard isSafeName(key.id) else { return false }
        let places = DraftLocations(home: home)
        let directory: URL = switch key.kind {
        case .cue: places.cue
        case .grid: places.grid
        case .tag: places.tags
        default: places.artwork
        }
        return FileManager.default.fileExists(atPath: directory.appending(path: "\(key.id).json").path)
    }

    private static func fileURL(_ key: DraftKey, home: URL) -> URL? {
        let base = folder(home: home)
        if perFile(key.kind) {
            guard isSafeName(key.id) else { return nil }
            return base.appending(path: key.kind.rawValue, directoryHint: .isDirectory).appending(path: "\(key.id).json")
        }
        return base.appending(path: "\(key.kind.rawValue).json")
    }

    /// 도장 하나(초안 파일이 있는지는 보지 않는다)
    static func read(_ key: DraftKey, home: URL) -> DraftStamp? {
        guard let url = fileURL(key, home: home), let data = try? Data(contentsOf: url) else { return nil }
        if perFile(key.kind) { return try? JSONDecoder().decode(DraftStamp.self, from: data) }
        return (try? JSONDecoder().decode([String: DraftStamp].self, from: data))?[key.id]
    }

    // MARK: 쓰기(잠금 안에서 부른다)

    private static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    /// 도장 하나를 적는다(nil이면 지운다). 이름을 쓸 수 없는 곡은 건너뛴다
    static func write(_ stamp: DraftStamp?, for key: DraftKey, home: URL) throws {
        guard let url = fileURL(key, home: home) else { return }
        if perFile(key.kind) {
            guard let stamp else {
                do { try FileManager.default.removeItem(at: url) } catch CocoaError.fileNoSuchFile {}
                return
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encode(stamp).write(to: url, options: .atomic)
            return
        }
        var stamps = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: DraftStamp].self, from: $0) } ?? [:]
        stamps[key.id] = stamp
        try writeAggregate(stamps, to: url)
    }

    /// 게인·합치기 도장 묶음을 통째로 적는다(비면 파일을 지운다)
    static func writeAggregate(_ stamps: [String: DraftStamp], to url: URL) throws {
        guard !stamps.isEmpty else {
            do { try FileManager.default.removeItem(at: url) } catch CocoaError.fileNoSuchFile {}
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encode(stamps).write(to: url, options: .atomic)
    }

    /// 초안 하나를 저장한 뒤 새 판으로 도장을 적는다. 출처는 이번 출처(포트의 출처, 저장 큐가 앞서 실패한 입력들의 출처를 더한 것)에 앞 도장의 출처를 모은다. 저장 전에 파일이 있었는데
    /// 도장이 없으면 업데이트 전부터 있던 초안이라 출처를 모름으로 모은다. `hash`가 nil이면 초안이 없어진 것이라 도장도 지운다
    /// `outside`: 덮어쓰기 전 파일 내용이 도장의 해시와 달랐다(바깥에서 고쳤다). 그 위에 쓴 초안이라 모름도 더한다
    static func restamp(_ key: DraftKey, home: URL, existed: Bool, origins given: Set<DraftOrigin>, hash: DraftContentHash?, outside: Bool = false) throws {
        guard isSafeName(key.id) || !perFile(key.kind) else { return }
        guard let hash else {
            try write(nil, for: key, home: home)
            return
        }
        var origins = given
        if existed { origins.formUnion(read(key, home: home)?.origins ?? [.unknown]) }
        if outside { origins.insert(.unknown) }
        let revision = try nextRevisions(1, home: home)[0]
        try write(DraftStamp(revision: revision, origins: origins, contentHash: hash), for: key, home: home)
    }

    // MARK: 판 번호

    /// 판 번호를 `count`개 받는다. 번호 파일을 잃었거나 읽지 못하면 남은 도장 가운데 가장 큰 판 뒤로 잇는다(번호를 다시 쓰지 않는다)
    static func nextRevisions(_ count: Int, home: URL) throws -> [DraftRevision] {
        guard count > 0 else { return [] }
        let file = folder(home: home).appending(path: revisionName)
        let recorded = (try? String(contentsOf: file, encoding: .utf8)).flatMap { UInt64($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let last = recorded ?? highestStampedRevision(home: home)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(String(last + UInt64(count)).utf8).write(to: file, options: .atomic)
        return (1...count).map { DraftRevision(last + UInt64($0)) }
    }

    /// 사이드카에 적힌 가장 큰 판(번호 파일을 잃었을 때만 센다)
    private static func highestStampedRevision(home: URL) -> UInt64 {
        let root = folder(home: home)
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return 0 }
        var highest: UInt64 = 0
        for case let url as URL in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url) else { continue }
            let decoder = JSONDecoder()
            if let stamp = try? decoder.decode(DraftStamp.self, from: data) {
                highest = max(highest, stamp.revision.value)
            } else if let stamps = try? decoder.decode([String: DraftStamp].self, from: data) {
                highest = max(highest, stamps.values.map(\.revision.value).max() ?? 0)
            } else if let entries = try? decoder.decode([PlaylistStampEntry].self, from: data) {
                highest = max(highest, entries.map(\.stamp.revision.value).max() ?? 0)
            }
        }
        return highest
    }
}
