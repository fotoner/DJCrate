import DJCDomain
import Foundation

/// USB 기기 재생 기록 보존(유스케이스, #43): 보존한 기록 읽기, USB에서 읽은 새 기록의 보존(후보 → 계획 → 짝 다시 검증 → 저장),
/// 바뀐 보존본(쓰기 대기에서 빼기·rekordbox에 쓴 표시) 저장. USB·rekordbox 라이브러리에는 쓰지 않는다.
/// 판정은 순수 규칙(`UsbHistoryImport`·`UsbHistoryRules`)에 있다. 가져오기와 저장을 한 줄로 세우는 일과 화면 상태는 화면 모델이 맡는다.
/// 파일 읽기·쓰기는 메인 밖에서 한다.
public struct ArchiveUsbHistories: Sendable {
    let files: UsbHistoryFiles
    /// 가져온 시각(이름 "HISTORY yyyy-MM-dd"와 트리 자리)
    let now: @Sendable () -> Date
    /// 새 기록 ID 뒷부분(앱은 UUID)
    let newID: @Sendable () -> String

    public init(files: UsbHistoryFiles, now: @escaping @Sendable () -> Date, newID: @escaping @Sendable () -> String) {
        self.files = files
        self.now = now
        self.newID = newID
    }

    /// 보존한 기록을 읽는다(메인 밖에서)
    public func load() async -> ArchivedHistoryLoad {
        let files = files
        return (try? await LoadLibrary.background(qos: .utility) { files.load() }) ?? ArchivedHistoryLoad()
    }

    /// 한 번 보존한 결과
    public struct Imported: Sendable, Equatable {
        /// 계획이 새로 보존하려던 기록(저장하지 못한 것도 든다. 알림은 `saved`와 견줘 고른다)
        public var added: [ArchivedHistory]
        /// 저장됐거나 현재 파일 내용이 일치해 채택할 기록(새 기록과 짝을 채운 보존본)
        public var saved: [ArchivedHistory]
        /// 내구 쓰기에 실패한 기록이 있다(그 뒤 기록은 저장하지 않았다)
        public var failed: Bool
    }

    /// USB 라이브러리의 새 기기 기록을 보존한다. 같은 USB 기록은 다시 보존하지 않고 모르던 로컬 짝만 채운다(`UsbHistoryImport.plan`).
    /// 이름은 보존본끼리 매긴다(rekordbox 이름을 피하면 같은 이름으로 중복을 검증할 수 없다. rekordbox에 쓸 때의 이름 충돌은 쓰기 관문이 푼다).
    /// 기록마다 따로 저장해 저장된 것만 돌려준다: 한꺼번에 저장하다 중간에 실패하면 디스크에는 남았는데 상태에 없는 기록이 생기고,
    /// 다음 시도가 새 ID로 또 저장해 다시 켤 때 같은 기록이 둘이 된다. 보존할 것이 없으면 nil.
    /// - Parameters:
    ///   - matches: 합친 라이브러리의 USB content_id → 로컬 ContentID(`UsbStore.localMatches`)
    ///   - existing: 지금 보존한 기록 전부(앞선 보존이 끝난 뒤의 상태)
    ///   - local: 채택한 스냅샷의 짝짓기 키(짝을 다시 검증한다)
    ///   - calendar: 가져온 날짜를 정할 달력(앱은 이 Mac의 달력)
    public func importFrom(volumeKey: String, volumeName: String, library: UsbLibrary, matches: [Int: String], existing: [ArchivedHistory],
                           local: LocalLibraryKeys?, calendar: Calendar) async -> Imported? {
        let candidates = UsbHistoryCandidates.make(library: library, volumeKey: volumeKey, volumeName: volumeName, matches: matches)
        guard !candidates.isEmpty else { return nil }
        let plan = UsbHistoryImport.plan(existing: existing, candidates: candidates, reservedNames: [], now: now(), calendar: calendar,
                                         makeID: newID)
        guard !plan.isEmpty else { return nil }
        let pending = UsbHistoryRules.rematch(plan.updated + plan.added, local: local)
        let files = files
        let (saved, failed) = (try? await LoadLibrary.background(qos: .utility) { () -> ([ArchivedHistory], Bool) in
            var done: [ArchivedHistory] = []
            for history in pending {
                let result = Self.saveOne(history, files: files)
                if result.accepted { done.append(history) }
                if result.failed { return (done, true) }
            }
            return (done, false)
        }) ?? ([], true)
        return Imported(added: plan.added, saved: saved, failed: failed)
    }

    /// 보존본을 기록마다 따로 내구 쓰기한다(메인 밖에서). 저장하지 못한 기록 수.
    /// 화면에는 이미 이 상태가 있다. 파일 일치 확인이 돼도 실패로 세어 경고를 남기고, 상태는 되돌리지 않는다
    public func save(_ histories: [ArchivedHistory]) async -> Int {
        guard !histories.isEmpty else { return 0 }
        let files = files
        return (try? await LoadLibrary.background(qos: .utility) { () -> Int in
            histories.reduce(0) { failed, history in Self.saveOne(history, files: files).failed ? failed + 1 : failed }
        }) ?? histories.count
    }

    /// 기록 하나 저장. rename 뒤 폴더 fsync만 실패했다면 같은 ID의 파일을 채택해(`accepted`) 다음 가져오기가 새 ID를 만들지 않게 한다
    static func saveOne(_ history: ArchivedHistory, files: UsbHistoryFiles) -> (accepted: Bool, failed: Bool) {
        do {
            try files.save(history)
            return (true, false)
        } catch {
            return (files.containsExact(history), true)
        }
    }
}
