import DJCApplication
import DJCDomain
import Foundation
import Observation

/// 설정 › 저장 공간(#227): 캐시 종류별 용량·비우기와 백업 용량(읽기만).
/// 캐시는 다시 만들어지므로 확인 창 없이 비우고 결과를 한 줄로 알린다. 지우는 규칙은 캐시 폴더 포트(`CacheFiles`) 한 곳이다(#215).
/// 용량 계산·비우기는 메인 액터 밖에서, 탭을 열 때와 비운 뒤에만 한다. 앱 화면의 모델은 조립 지점이 만든다(`AppComposition.storageSettings`).
@MainActor @Observable
final class StorageSettingsModel {
    private(set) var usage: [DJCCacheUsage]?
    private(set) var backups: [DJCBackupUsage] = []
    /// 지금 비우면 실제로 지울 양(남기는 사본·USB 쓰기 중 건너뜀을 뺀 것). 0이면 그 종류의 단추를 막는다
    private(set) var clearable: [DJCCacheKind: Int64] = [:]
    private(set) var isWorking = false
    /// 마지막 비우기 결과 한 줄
    private(set) var message: String?

    let paths: DJCCachePaths
    @ObservationIgnored private let files: CacheFiles
    /// 자동 시점 스냅샷 보관 일수(#223 결정, 설정에서 일수만). 시험은 설정 없이 기본값만 본다
    var autoSnapshotDays: Int {
        didSet { settings?.set(SettingKeys.pointSnapshotAutoDays, Double(autoSnapshotDays)) }
    }
    /// 하루 한 번 자동 시점 스냅샷(#228)
    var autoSnapshotEnabled: Bool {
        didSet { settings?.set(SettingKeys.pointSnapshotAuto, autoSnapshotEnabled) }
    }
    /// 클론이 안 돼(다른 디스크) 자동 스냅샷을 뜨지 않을 때의 안내
    private(set) var autoSnapshotNote: String?
    @ObservationIgnored private let settings: SettingsStore?
    @ObservationIgnored private let canClone: @Sendable () -> Bool
    @ObservationIgnored private let openSnapshot: () -> URL?
    @ObservationIgnored private let busy: () -> String?
    /// 파일을 지우기 전에 앱 메모리의 캐시를 비운다(메모리의 옛 값을 다시 저장하지 않게). 시험은 비워 둔다
    @ObservationIgnored private let clearMemory: ([DJCCacheKind]) async -> Void
    /// 지운 뒤 화면에 보이는 캐시를 다시 채운다(목록 미리 보기 파형)
    @ObservationIgnored private let rebuild: ([DJCCacheKind]) -> Void

    /// - Parameters:
    ///   - paths: 캐시 자리(앱은 이 프로세스의 데이터 폴더, 시험은 임시 폴더)
    ///   - files: 캐시 폴더 읽기·비우기
    init(paths: DJCCachePaths, files: CacheFiles, settings: SettingsStore? = nil, openSnapshot: @escaping () -> URL? = { nil },
         busyReason: @escaping () -> String? = { nil }, canClone: @escaping @Sendable () -> Bool = { true },
         clearMemory: @escaping ([DJCCacheKind]) async -> Void = { _ in }, rebuild: @escaping ([DJCCacheKind]) -> Void = { _ in }) {
        self.paths = paths
        self.files = files
        self.settings = settings
        autoSnapshotDays = Int(settings?.value(SettingKeys.pointSnapshotAutoDays) ?? SettingKeys.pointSnapshotAutoDays.defaultValue)
        autoSnapshotEnabled = settings?.value(SettingKeys.pointSnapshotAuto) ?? SettingKeys.pointSnapshotAuto.defaultValue
        self.canClone = canClone
        self.openSnapshot = openSnapshot
        self.busy = busyReason
        self.clearMemory = clearMemory
        self.rebuild = rebuild
    }

    /// 앱이 쓰는 중인지: rekordbox 쓰기와 USB 쓰기(진행 중·볼륨을 붙잡은 작업)
    static func busyReason(store: LibraryStore) -> String? {
        busyReason(writingRekordbox: store.isWritingRekordbox,
                   writingUsb: store.usb.map { $0.activeWrite != nil || !$0.busyVolumes.isEmpty } ?? false)
    }

    /// 비우기 단추를 막는 이유(도움말로 보인다)
    var blockReason: String? { busy() }

    nonisolated static func busyReason(writingRekordbox: Bool, writingUsb: Bool) -> String? {
        if writingRekordbox { return String(ui: "rekordbox에 쓰는 중에는 비울 수 없습니다. 쓰기가 끝난 뒤 비우세요") }
        if writingUsb { return String(ui: "USB에 쓰는 중에는 비울 수 없습니다. 쓰기가 끝난 뒤 비우세요") }
        return nil
    }

    func refresh() async {
        let paths = paths, files = files, keep = [openSnapshot()].compactMap { $0 }, canClone = canClone
        // 폴더를 훑는 동기 입출력이라 협력 풀 밖에서 한다
        let result = await BlockingWork.run {
            (files.usage(paths), files.backupUsage(paths.root), files.clear(DJCCacheKind.allCases, paths, keep, true), canClone())
        }
        usage = result.0
        backups = result.1
        clearable = Dictionary(uniqueKeysWithValues: result.2.map { ($0.kind, $0.freedBytes) })
        autoSnapshotNote = result.3 ? nil
            : String(ui: "DJCrate 데이터 폴더가 rekordbox와 다른 디스크라 자동 시점 스냅샷을 남기지 않습니다(라이브러리 전체를 매일 복사하지 않게).")
    }

    /// 비우기 단추가 마지막으로 시작한 일. 설정 창을 닫아도 끝까지 간다. 시험은 이것을 기다린다
    @ObservationIgnored private(set) var task: Task<Void, Never>?

    func startClear(_ kinds: [DJCCacheKind]) { task = Task { await clear(kinds) } }

    func clear(_ kinds: [DJCCacheKind]) async {
        guard !isWorking, blockReason == nil else { return }
        isWorking = true
        defer { isWorking = false }
        let paths = paths, files = files, keep = [openSnapshot()].compactMap { $0 }
        await clearMemory(kinds)
        let outcomes = await BlockingWork.run { files.clear(kinds, paths, keep, false) }
        rebuild(kinds)
        message = Self.summary(outcomes)
        await refresh()
    }

    static func summary(_ outcomes: [DJCCacheOutcome]) -> String {
        let freed = StorageSize.text(outcomes.reduce(0) { $0 + $1.freedBytes })
        var line = outcomes.count == 1
            ? String(ui: "\(outcomes[0].kind.title) \(freed)를 비웠습니다.")
            : String(ui: "캐시 \(freed)를 비웠습니다.")
        if let skipped = outcomes.first(where: { $0.skipped != nil })?.skipped { line += " " + skipped }
        return line
    }
}

enum StorageSize {
    /// 파일 크기 표기. 화면 언어(`UIStrings.locale`)를 따르고 0도 숫자로 쓴다
    static func text(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file, spellsOutZero: false).locale(UIStrings.locale))
    }
}
