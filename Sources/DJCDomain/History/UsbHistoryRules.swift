import Foundation

/// 사이드바 재생 기록 트리와 rekordbox 쓰기 대기에 보일 것(입출력 없음, #43). 기록·보존본·스냅샷 키가 바뀔 때 다시 계산한다(#141).
public struct UsbHistoryView: Sendable, Equatable {
    /// rekordbox 기록과 숨기지 않은 보존 기록의 연 › 월 › 기록 트리
    public var tree: HistoryTree
    /// rekordbox도 가져온 같은 USB 기록이라 트리에서 숨긴 보존 기록(파일은 그대로)
    public var shadowed: Set<String>
    /// rekordbox 쓰기 대기에 오른 보존 기록(가져온 차례)
    public var pending: [ArchivedHistory]

    public init(tree: HistoryTree = HistoryTree(), shadowed: Set<String> = [], pending: [ArchivedHistory] = []) {
        self.tree = tree
        self.shadowed = shadowed
        self.pending = pending
    }
}

/// 보존한 기기 재생 기록의 판정(입출력 없음, #43): 쓴 표시 검증, 트리·숨김·쓰기 대기, 쓰기 입력, 쓴 표시·쓰기 대기 빼기 반영.
/// 화면 모델(`LibraryStore`)은 지금 상태를 넘겨 결과만 적용한다. 보존·저장 흐름은 유스케이스 `ArchiveUsbHistories`에 있다.
public enum UsbHistoryRules {
    /// 보존한 USB 원본 키로 짝을 다시 검증한다(`UsbHistoryMatches`). 키를 모르면 짝을 비운다
    public static func rematch(_ archived: [ArchivedHistory], local: LocalLibraryKeys?) -> [ArchivedHistory] {
        UsbHistoryMatches.rematch(archived, localDBID: local?.localDBID, local: local?.tracks ?? [], masterDBIDs: local?.masterDBIDs ?? [:])
    }

    /// 쓴 ID는 라이브러리별 값이다. 라이브러리 ID가 있으면 지금 라이브러리와 같아야 하고, 옛 파일(라이브러리 ID 없음)은
    /// 지금 원본 곡 키·이름·전체 순서까지 그 rekordbox 기록과 같아야 그 표시를 믿는다.
    /// - Parameters:
    ///   - rekordbox: 지금 스냅샷의 rekordbox 기록(ID → 기록)
    ///   - inCollection: 그 ContentID의 곡이 지금 컬렉션에 있는지(화면 모델의 곡 색인을 그대로 본다. 곡 ID를 모두 옮겨 담지 않게)
    public static func hasValidWrittenMarker(_ history: ArchivedHistory, local: LocalLibraryKeys?, rekordbox: [String: RekordboxHistory],
                                             inCollection: (String) -> Bool) -> Bool {
        guard let local, let writtenID = history.rekordboxHistoryID else { return false }
        if let recordedLibrary = history.rekordboxLibraryID { return recordedLibrary == String(local.localDBID) }
        guard let record = rekordbox[writtenID] else { return false }
        return !history.entries.isEmpty && history.entries.allSatisfy { entry in entry.contentID.map(inCollection) ?? false }
            && rematch([history], local: local).first?.entries == history.entries && history.name == record.name
            && history.matchedContentIDs == record.entries.sorted { $0.trackNumber < $1.trackNumber }.map(\.contentID)
    }

    /// 검증하지 못한 쓴 ID를 지운 보존본(쓰기 대기를 고를 때 쓴다)
    public static func validatedMarkers(_ archived: [ArchivedHistory], local: LocalLibraryKeys?, rekordbox: [String: RekordboxHistory],
                                        inCollection: (String) -> Bool) -> [ArchivedHistory] {
        archived.map { history in
            guard history.rekordboxHistoryID != nil,
                  !hasValidWrittenMarker(history, local: local, rekordbox: rekordbox, inCollection: inCollection) else { return history }
            var history = history
            history.rekordboxHistoryID = nil
            return history
        }
    }

    /// 숨김 판정에 넘길 보존본. 검증하지 못한 쓴 ID는 이름으로 다른 ID를 추측하는 데도 쓰지 않고 보존본을 계속 보인다.
    /// 스냅샷 키를 모르면 아무것도 숨기지 않는다
    public static func forDuplicateMatching(_ archived: [ArchivedHistory], local: LocalLibraryKeys?, rekordbox: [String: RekordboxHistory],
                                            inCollection: (String) -> Bool) -> [ArchivedHistory] {
        guard local != nil else { return [] }
        return archived.filter {
            $0.rekordboxHistoryID == nil || hasValidWrittenMarker($0, local: local, rekordbox: rekordbox, inCollection: inCollection)
        }
    }

    /// 트리·숨김·쓰기 대기.
    /// - Parameters:
    ///   - queueOpen: 쓰기 대기를 고를지. 라이브러리를 읽기 전(쓴 기록이 rekordbox에 있는지 아직 모른다)·스냅샷 키를 모를 때·
    ///     재생 기록 쓰기 관문이 닫혀 있을 때는 비워 둔다
    ///   - awaitingReload: rekordbox에 썼지만 아직 새 스냅샷으로 읽지 못한 기록 ID(다시 읽을 때까지 rekordbox에 있는 것으로 본다)
    ///   - calendar: 보존 기록의 연·월을 정할 달력(앱은 이 Mac의 달력)
    ///   - inCollection: 그 ContentID의 곡이 지금 컬렉션에 있는지
    public static func view(histories: [RekordboxHistory], archived: [ArchivedHistory], local: LocalLibraryKeys?, inCollection: (String) -> Bool,
                            queueOpen: Bool, awaitingReload: Set<String>, calendar: Calendar) -> UsbHistoryView {
        let index = Dictionary(histories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let records = histories.map { history in
            HistoryDuplicates.Record(id: history.id, name: history.name, dateCreated: history.dateCreated,
                                     contentIDs: history.entries.sorted { $0.trackNumber < $1.trackNumber }.map(\.contentID))
        }
        let shadowed = HistoryDuplicates.shadowedArchiveIDs(
            archived: forDuplicateMatching(archived, local: local, rekordbox: index, inCollection: inCollection), rekordbox: records)
        let tree = HistoryTree.make(histories: histories, archived: archived.filter { !shadowed.contains($0.id) }, calendar: calendar)
        let pending = !queueOpen || local == nil ? [] : HistoryWriteQueue.pending(
            validatedMarkers(archived, local: local, rekordbox: index, inCollection: inCollection), shadowed: shadowed,
            rekordboxHistoryIDs: Set(index.keys).union(awaitingReload))
        return UsbHistoryView(tree: tree, shadowed: shadowed, pending: pending)
    }

    /// 쓰기 대기 기록 → rekordbox 쓰기 입력(가져온 차례). 컬렉션 짝이 있는 곡만 재생 순서대로 넘긴다
    /// (반복 재생 포함, 컬렉션에 없는 곡은 rekordbox처럼 뺀다). 만든 시각은 가져온 시각이다.
    /// 짝을 확인한 컬렉션 DBID와 USB 원본 곡 키를 함께 넘겨 쓰기 관문이 최신 대상에서 다시 확인한다
    public static func imports(_ pending: [ArchivedHistory], local: LocalLibraryKeys?, inCollection: (String) -> Bool) -> [HistoryImport] {
        pending.map { history in
            let ids = history.entries.compactMap { entry in entry.contentID.flatMap { inCollection($0) ? $0 : nil } }
            let identities = history.entries.compactMap { entry -> HistoryImport.TrackIdentity? in
                guard let id = entry.contentID, inCollection(id) else { return nil }
                return .init(contentID: id, masterDbId: entry.masterDbId, masterContentId: entry.masterContentId, fileName: entry.fileName)
            }
            return HistoryImport(id: history.id, name: history.name, dateCreated: history.importedAt, contentIDs: ids,
                                 skippedBeforeMatching: history.entries.count - ids.count,
                                 expectedLibraryID: local.map { String($0.localDBID) }, existingHistoryID: history.rekordboxHistoryID,
                                 trackIdentities: identities)
        }
    }

    /// rekordbox에 쓴(또는 이미 있던) 기록에 rekordbox 기록 ID와 라이브러리 ID를 남긴 보존본과 그 rekordbox ID. 막힌 결과는 표시하지 않는다
    public static func markWritten(_ archived: [ArchivedHistory], outcomes: [RekordboxHistoryOutcome],
                                   local: LocalLibraryKeys?) -> (changed: [ArchivedHistory], historyIDs: Set<String>) {
        var written: [String: String] = [:]
        for outcome in outcomes where outcome.status == .written || outcome.status == .unchanged {
            if let historyID = outcome.historyID { written[outcome.id] = historyID }
        }
        let changed = archived.compactMap { history -> ArchivedHistory? in
            guard let historyID = written[history.id] else { return nil }
            var history = history
            history.rekordboxHistoryID = historyID
            history.rekordboxLibraryID = local.map { String($0.localDBID) }
            return history
        }
        return (changed, Set(written.values))
    }

    /// 쓰기 대기에서 빼거나 다시 넣을 보존본(상태가 바뀌는 것만)
    public static func excluding(_ archived: [ArchivedHistory], ids: [String], excluded: Bool) -> [ArchivedHistory] {
        let index = Dictionary(archived.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        return ids.compactMap { index[$0] }.filter { $0.excludedFromRekordbox != excluded }.map { history in
            var history = history
            history.excludedFromRekordbox = excluded
            return history
        }
    }

    /// 같은 ID의 보존본을 바꾼다(없는 ID는 더하지 않는다)
    public static func replacing(_ current: [ArchivedHistory], with updated: [ArchivedHistory]) -> [ArchivedHistory] {
        guard !updated.isEmpty else { return current }
        var merged = current
        let positions = Dictionary(merged.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        for history in updated {
            if let index = positions[history.id] { merged[index] = history }
        }
        return merged
    }

    /// 새로 보존한 기록을 지금 상태에 넣는다. 계획을 세운 뒤 바뀐 쓰기 상태(쓰기 대기에서 빼기·rekordbox에 쓴 표시)는 지금 값을 남긴다
    /// (그 변경의 파일 저장은 이 보존 뒤에 줄을 서 있어 지금 값으로 다시 쓴다). 새 기록은 끝에 더한다
    public static func merging(saved: [ArchivedHistory], into current: [ArchivedHistory]) -> [ArchivedHistory] {
        var merged = current
        var positions = Dictionary(merged.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        for history in saved {
            if let index = positions[history.id] {
                var updated = history
                updated.rekordboxHistoryID = merged[index].rekordboxHistoryID
                updated.rekordboxLibraryID = merged[index].rekordboxLibraryID
                updated.excludedFromRekordbox = merged[index].excludedFromRekordbox
                merged[index] = updated
            } else {
                positions[history.id] = merged.count
                merged.append(history)
            }
        }
        return merged
    }
}
