import DJCDomain
import Foundation
import Synchronization

/// 초안 저장은 직렬 큐에서 메인 스레드 밖으로(순서 보장).
/// 큐·저장 기록은 인스턴스마다 따로다. 조립 지점이 하나를 만들어 저장소·덱·반영·복구에 나눠 준다:
/// 게인 초안은 모든 곡이 파일 하나(`gain-drafts.json`)라 그 파일을 쓰는 곳이 모두 같은 인스턴스(같은 큐)를 써야 순서가 지켜진다.
/// 시험은 저장소마다 새 인스턴스를 만들어 다른 시험의 저장을 기다리지 않는다(#167).
public final class DraftWriter: Sendable {
    public typealias Kind = DraftSaveKind
    public typealias Failure = DraftSaveFailure

    private let queue = DispatchQueue(label: "djc.draft-writer", qos: .utility)
    private let tagFailures = Mutex<[String: Set<String>]>([:])
    private let records = Mutex(Records())

    public init() {}

    public struct SaveState: Sendable {
        public var revision: UInt64
        public var savedRevision: UInt64?
        public var failure: Failure?
    }

    private struct Key: Hashable, Sendable {
        var kind: Kind
        var directory: String
        var uuid: String
    }

    private enum Input: Sendable {
        /// 게인은 nil이 초안 지우기다.
        case cue(CueDraft), grid(GridDraft), gain(Double?)
    }

    private struct Record: Sendable {
        var input: Input
        var state: SaveState
        var write: @Sendable () throws -> Void
    }

    private struct Records: Sendable {
        var revision: UInt64 = 0
        var values: [Key: Record] = [:]
    }

    private static func key(_ kind: Kind, _ uuid: String, _ directory: URL) -> Key {
        Key(kind: kind, directory: directory.resolvingSymlinksInPath().standardizedFileURL.path, uuid: uuid)
    }

    private static func located(_ key: Key, in locations: DraftLocations) -> Bool {
        key.directory == Self.key(key.kind, "", locations.url(key.kind)).directory
    }

    /// 이 자리(큐·그리드 폴더, 게인 파일)에 맡은 마지막 저장 입력 순번(목록이 바깥 초안을 읽는 사이 새 입력이 있었는지 본다).
    /// 다른 폴더의 저장은 세지 않는다.
    public func saveRevision(in locations: DraftLocations) -> UInt64 {
        // 경로 풀기(파일 시스템 조회)는 기록마다가 아니라 자리마다 한 번만 한다(화면 갱신 중 메인에서 부른다).
        let paths: [Kind: String] = [.cue: Self.key(.cue, "", locations.cue).directory, .grid: Self.key(.grid, "", locations.grid).directory,
                                     .gain: Self.key(.gain, "", locations.gain).directory]
        return records.withLock { records in
            records.values.reduce(0) { latest, entry in
                paths[entry.key.kind] == entry.key.directory ? max(latest, entry.value.state.revision) : latest
            }
        }
    }

    public func state(_ kind: Kind, trackUUID: String, directory: URL) -> SaveState? {
        records.withLock { $0.values[Self.key(kind, trackUUID, directory)]?.state }
    }

    public func pendingCue(trackUUID: String, directory: URL) -> CueDraft? {
        records.withLock {
            guard let record = $0.values[Self.key(.cue, trackUUID, directory)], record.state.revision != record.state.savedRevision,
                  case .cue(let draft) = record.input else { return nil }
            return draft
        }
    }

    public func pendingGrid(trackUUID: String, directory: URL) -> GridDraft? {
        records.withLock {
            guard let record = $0.values[Self.key(.grid, trackUUID, directory)], record.state.revision != record.state.savedRevision,
                  case .grid(let draft) = record.input else { return nil }
            return draft
        }
    }

    /// 저장하지 못한 게인 입력(바깥 nil은 기록 없음, 안쪽 nil은 초안 지우기)
    public func pendingGain(trackUUID: String, url: URL) -> Double?? {
        records.withLock {
            guard let record = $0.values[Self.key(.gain, trackUUID, url)], record.state.revision != record.state.savedRevision,
                  case .gain(let gain) = record.input else { return nil }
            return .some(gain)
        }
    }

    /// 이 자리(큐·그리드 폴더, 게인 파일)의 저장 실패
    public func failures(in locations: DraftLocations) -> [Failure] {
        records.withLock { records in
            records.values.compactMap { key, record in Self.located(key, in: locations) ? record.state.failure : nil }
        }
    }

    /// 이 자리에 맡겼지만 아직 저장하지 못한(저장 중이거나 실패한) 곡
    public func unsavedUUIDs(in locations: DraftLocations) -> Set<String> {
        records.withLock { records in
            Set(records.values.compactMap { key, record in
                Self.located(key, in: locations) && record.state.revision != record.state.savedRevision ? key.uuid : nil
            })
        }
    }

    private static func failureReason(_ error: any Error) -> String {
        // 오류 설명에 개인 경로가 들어갈 수 있어 원인과 조치만 화면에 넘긴다.
        switch (error as NSError).code {
        case NSFileWriteNoPermissionError, NSFileReadNoPermissionError:
            String(ui: "초안 폴더의 접근 권한을 확인한 뒤 다시 저장하세요.")
        case NSFileWriteOutOfSpaceError:
            String(ui: "저장 장치의 빈 공간을 확보한 뒤 다시 저장하세요.")
        default:
            String(ui: "초안 폴더와 저장할 파일을 확인한 뒤 다시 저장하세요.")
        }
    }

    private func enqueue(_ input: Input, key: Key, write: @escaping @Sendable () throws -> Void,
                         completion: @escaping @Sendable (Failure?) -> Void) {
        records.withLock { records in
            records.revision += 1
            let record = Record(input: input, state: SaveState(revision: records.revision,
                                                              savedRevision: records.values[key]?.state.savedRevision,
                                                              failure: records.values[key]?.state.failure), write: write)
            records.values[key] = record
            queue.async { self.perform(record, key: key, completion: completion) }
        }
    }

    private func perform(_ record: Record, key: Key, completion: @Sendable (Failure?) -> Void) {
        let failure: Failure?
        do { try record.write(); failure = nil }
        catch { failure = Failure(kind: key.kind, trackUUID: key.uuid, revision: record.state.revision, reason: Self.failureReason(error)) }
        records.withLock { records in
            guard var current = records.values[key] else { return }
            if failure == nil { current.state.savedRevision = record.state.revision }
            // 앞선 완료가 최신 입력의 저장 오류를 지우지 않게 한다.
            if current.state.revision == record.state.revision { current.state.failure = failure }
            records.values[key] = current
        }
        completion(failure)
    }

    /// 이 자리에 맡은 그 곡의 마지막 입력(큐·그리드·게인)을 모두 다시 저장한다.
    public func retry(trackUUID: String, in locations: DraftLocations) {
        retry(.cue, trackUUID: trackUUID, directory: locations.cue)
        retry(.grid, trackUUID: trackUUID, directory: locations.grid)
        retry(.gain, trackUUID: trackUUID, directory: locations.gain)
    }

    /// 마지막으로 맡은 입력(저장이든 지우기든)을 다시 저장한다. 덱이 아직 곡을 읽는 중이어도 그 입력을 쓴다.
    /// - Returns: 다시 저장할 기록이 있었는지(이미 저장된 기록은 건너뛴다)
    @discardableResult
    public func retry(_ kind: Kind, trackUUID: String, directory: URL,
                      completion: @escaping @Sendable (Failure?) -> Void = { _ in }) -> Bool {
        let key = Self.key(kind, trackUUID, directory)
        return records.withLock { records in
            guard let record = records.values[key], record.state.revision != record.state.savedRevision else { return false }
            queue.async { self.perform(record, key: key, completion: completion) }
            return true
        }
    }

    /// 그 실패가 뒤의 저장으로 해소됐는지(목록 복구·복원·다시 저장처럼 덱 밖에서 해소된 경우 포함)
    public func isResolved(_ failure: Failure, directory: URL) -> Bool {
        state(failure.kind, trackUUID: failure.trackUUID, directory: directory).map { $0.failure == nil } ?? false
    }

    public func failedTagSaveUUIDs(in directory: URL) -> Set<String> {
        let key = directory.resolvingSymlinksInPath().standardizedFileURL.path
        return tagFailures.withLock { $0[key] ?? [] }
    }

    public func save(_ draft: CueDraft, directory: URL,
                     write: @escaping @Sendable (CueDraft, URL) throws -> Void = { try CueDraftStore.save($0, directory: $1) },
                     completion: @escaping @Sendable (Failure?) -> Void = { _ in }) {
        enqueue(.cue(draft), key: Self.key(.cue, draft.trackUUID, directory), write: { try write(draft, directory) }, completion: completion)
    }
    /// 반영이 끝난 곡의 큐 초안을 지운다(앞서 걸린 저장 뒤에).
    public func removeCue(trackUUID: String, directory: URL) {
        save(CueDraft(trackUUID: trackUUID), directory: directory)
    }
    /// 이 인스턴스에 걸려 있는 저장을 모두 끝낸다(디스크의 초안을 읽기 전에).
    public func flush() {
        queue.sync {}
    }
    public func save(_ draft: GridDraft, directory: URL,
                     write: @escaping @Sendable (GridDraft, URL) throws -> Void = { try GridDraftStore.save($0, directory: $1) },
                     completion: @escaping @Sendable (Failure?) -> Void = { _ in }) {
        enqueue(.grid(draft), key: Self.key(.grid, draft.trackUUID, directory), write: { try write(draft, directory) }, completion: completion)
    }
    public func removeGrid(trackUUID: String, directory: URL, completion: @escaping @Sendable (Failure?) -> Void = { _ in }) {
        save(GridDraft(trackUUID: trackUUID, base: [], segments: []), directory: directory, completion: completion)
    }
    /// 게인 초안(nil이면 지우기). 모든 곡이 한 파일이라 다른 곡의 저장과 같은 큐에서 차례로 읽고 쓴다.
    public func save(gain: Double?, trackUUID: String, url: URL,
                     write: @escaping @Sendable (Double?, String, URL) throws -> Void = { try GainDraftStore.save($0, trackUUID: $1, url: $2) },
                     completion: @escaping @Sendable (Failure?) -> Void = { _ in }) {
        enqueue(.gain(gain), key: Self.key(.gain, trackUUID, url), write: { try write(gain, trackUUID, url) }, completion: completion)
    }
    public func removeGain(trackUUID: String, url: URL) { save(gain: nil, trackUUID: trackUUID, url: url) }

    /// 데이터 폴더의 손상된 초안 파일을 옮겨 보관하고 그 목록을 받는다(저장과 같은 큐에서, 막 쓴 파일을 옮기지 않게).
    public func preserveDamagedDrafts(home: URL) -> [DamagedDrafts.Entry] {
        queue.sync {
            DamagedDrafts.preserveAll(home: home)
            return DamagedDrafts.take(home: home)
        }
    }
    public func save(_ drafts: [TagDraft], directory: URL) {
        let key = directory.resolvingSymlinksInPath().standardizedFileURL.path
        queue.async {
            for draft in drafts {
                do {
                    try TagDraftStore.save(draft, directory: directory)
                    _ = self.tagFailures.withLock { $0[key]?.remove(draft.trackUUID) }
                } catch {
                    _ = self.tagFailures.withLock { $0[key, default: []].insert(draft.trackUUID) }
                }
            }
        }
    }
}

/// 초안 폴더 하나(`home`, 앱은 DJCrate 데이터 폴더) 아래의 초안 파일 자리. 폴더 배치는 여기 한 곳에서 정한다.
public struct DraftLocations: Sendable, Equatable {
    public var home: URL
    public var cue: URL
    public var grid: URL
    /// 모든 곡의 게인 초안을 담은 파일 하나
    public var gain: URL
    public var tags: URL
    public var artwork: URL
    public var playlist: URL
    public var merge: URL
    public var staged: URL
    public var playlistImports: URL
    public var writeResult: URL
    /// 내보낸 반영 XML의 계획 묶음(가져온 뒤 검증)
    public var reflection: URL

    public init(home: URL) {
        self.home = home
        cue = home.appending(path: DraftFileNames.cue)
        grid = home.appending(path: DraftFileNames.grid)
        gain = home.appending(path: DraftFileNames.gain)
        tags = home.appending(path: DraftFileNames.tag)
        artwork = home.appending(path: ArtworkDraftStore.folderName)
        playlist = home.appending(path: PlaylistDraftStore.fileName)
        merge = home.appending(path: DuplicateMergeDraftStore.fileName)
        staged = home.appending(path: StagedTrackFile.fileName)
        playlistImports = home.appending(path: PlaylistImportStore.fileName)
        writeResult = home.appending(path: "last-write-result.json")
        reflection = home.appending(path: ReflectionStore.fileName)
    }

    /// 저장 큐에 맡기는 종류(큐·그리드 폴더, 게인 파일)의 자리
    public func url(_ kind: DraftSaveKind) -> URL {
        switch kind {
        case .cue: cue
        case .grid: grid
        case .gain: gain
        }
    }
}
