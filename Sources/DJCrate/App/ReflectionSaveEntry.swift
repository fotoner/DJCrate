import DJCApplication
import DJCDomain
import Foundation

extension LibraryStore {
    /// 저장할 편집이 있다(곡·재생 목록·재생 기록)
    var hasSavableEdits: Bool {
        pendingLibraryCount > 0 || playlists.hasPlaylistDrafts || history.hasHistoryDrafts
    }
}

/// 저장 단추가 있는 모든 자리(상태 줄·상태 팝오버·저장 대기 목록 머리 줄·곡 메뉴)와 ⌘S가 같은 저장 입구로 실행한다(R3 표).
/// 엔진이 있는 앱은 이 입구가 줄(`ReflectionStatusRow`)에 따라 입력 확정 → 줄·대상 계산 → 이유 보이기·저장·대기열 보관을 한다.
/// 엔진이 없는 조립(화면 시험·진단)은 지금 동작 그대로 저장한다.
extension LibraryWindowModel {
    /// 저장할 곡의 범위
    enum SaveScope {
        /// 저장 대기 전체. 엔진이 있으면 선택·필터와 무관하다(R3 8번 줄: 남은 편집을 모두 저장한다)
        case all
        /// 곡 메뉴처럼 고른 곡만(재생 목록 초안 포함 여부를 함께 준다)
        case rows([TrackRow], playlists: Bool)
    }

    /// 저장 단추·⌘S가 쓸 곡: 선택·필터와 무관하게 저장 대기 곡 전체(보이는 목록 순서, 목록에 없는 대기 곡은 그 뒤)
    var saveRows: [TrackRow] {
        let pending = store.pendingUUIDs
        let listed = store.rows.filter { pending.contains($0.track.uuid) && !$0.isStaged }
        let known = Set(listed.map(\.track.uuid))
        let rest = pending.subtracting(known).sorted().compactMap { store.rowsByUUID[$0] }.filter { !$0.isStaged }
        return listed + rest
    }

    /// 저장 요청 하나. 입력 중인 칸이 있으면 확정이 끝나기를 기다린 뒤 줄과 대상을 계산한다(R19).
    /// - 1·2·3번 줄: 쓰지 않고 이유를 보인다(3번 줄은 엔진이 알린 뒤 열린 시트·USB 쓰기도 지금 상태로 본다)
    /// - 5번 줄(쓰는 중): 요청 하나를 보관해 지금 쓰기 뒤 다음 자동 저장보다 먼저 한다
    /// - 그 밖: 지금 저장한다
    func requestSave(_ scope: SaveScope = .all, reflection: ReflectionCoordinator?) {
        guard autoFeed != nil else {
            // 엔진이 없는 조립은 지금 동작 그대로다
            switch scope {
            case .all: reflection?.startWrite(rows: store.reflectionPreviewRows)
            case let .rows(rows, playlists): reflection?.startWrite(rows: rows, playlists: playlists)
            }
            return
        }
        // 입력 중이거나, 입력 중은 아니어도(시작 때 글과 같음) 칸과 모델 값이 갈려 확정 대기가 있으면 확정한다(#405 컨실 3라운드 O14).
        // 칸이 확정을 거절하면(입력 검증이 포커스를 놓지 못하게 함) 칸의 값이 빠진 채 저장하지 않는다
        let typing = isEditingInput
        if typing, !fieldEditing.commit() { return store.showToast(.notice(text: Self.commitFailedText, kind: .warning)) }
        guard typing else { return follow(scope, reflection: reflection) }
        // 칸의 확정이 끝났다는 신호를 받은 뒤에 줄과 대상을 계산한다: 포커스를 잃은 뒤 다음 갱신에서 값을 넣는 칸(SwiftUI)이 있다.
        // 신호가 한도 안에 오지 않으면 저장하지 않고 이유를 알린다
        Task { @MainActor [weak self] in
            guard let self else { return }
            let deadline = ContinuousClock.now + fieldEditing.settleLimit
            while fieldEditing.isEditing || fieldEditing.hasPendingCommit() {
                guard ContinuousClock.now < deadline else { return store.showToast(.notice(text: Self.commitFailedText, kind: .warning)) }
                try? await Task.sleep(for: .milliseconds(10))
            }
            // 값을 넣는 일이 끝났는데 저장 대기에 아직 안 보이면 잠깐 더 본다
            for _ in 0..<20 where !store.hasSavableEdits { try? await Task.sleep(for: .milliseconds(10)) }
            follow(scope, reflection: reflection)
        }
    }

    /// ⌘Q 저장(R17) 앞의 입력 확정: ⌘S와 같은 감지기로 입력 중이거나 확정 대기 칸이 있을 때만 확정한다(#405).
    /// 확정을 거절하거나 한도 안에 끝나지 않아도 종료는 막지 않는다(칸의 값만 남지 않는다)
    func commitInputBeforeQuit() async {
        guard isEditingInput else { return }
        _ = fieldEditing.commit()
        let deadline = ContinuousClock.now + fieldEditing.settleLimit
        while fieldEditing.isEditing || fieldEditing.hasPendingCommit(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        // 값을 넣는 일이 끝났는데 저장 대기에 아직 안 보이면 잠깐 더 본다(⌘S와 같다): 엔진의 ⌘Q 저장이 그 편집까지 다시 판정한다
        for _ in 0..<20 where !store.hasSavableEdits { try? await Task.sleep(for: .milliseconds(10)) }
    }

    static var commitFailedText: String {
        String(ui: "입력 중인 칸을 확정하지 못해 저장하지 않았습니다. 칸의 값을 고치거나 Return을 누른 뒤 다시 저장하세요")
    }

    /// 입력 확정 뒤 지금 상태로 줄을 다시 계산해 한다
    private func follow(_ scope: SaveScope, reflection: ReflectionCoordinator?) {
        guard let conditions = saveConditions else { return }
        let row = ReflectionStatusRow.first(conditions)
        if showsRefusal(row, conditions) { return }
        switch row.saveCommand {
        case .restoreOnly, .refuseWithReason:
            break
        case .queueFront:
            // 보관한 요청은 범위를 그대로 지니고, 차례를 받은 뒤 같은 입구 판정을 다시 한다
            let admits: @MainActor () -> Bool = { [weak self] in self?.admitsSaveNow() ?? false }
            switch scope {
            case .all: reflection?.queueSave(.init(rows: { [weak self] in self?.saveRows ?? [] }, admits: admits))
            case let .rows(rows, playlists): reflection?.queueSave(.init(rows: { rows }, playlists: playlists, admits: admits))
            }
        case .commitFieldThenFollow, .saveNow, .saveAndResume, .saveAllLeftovers, .saveNowIfAllowed:
            guard store.writesBlockedBySheet || store.hasSavableEdits else {
                store.showToast(.notice(text: LibraryMenuAction.noEditsReason, kind: .warning))
                return
            }
            switch scope {
            case .all: reflection?.startWrite(rows: saveRows)
            case let .rows(rows, playlists): reflection?.startWrite(rows: rows, playlists: playlists)
            }
        }
    }

    /// 보관한 저장이 엔진의 차례를 받은 뒤 지금 상태로 시작해도 되는지(1~3번 줄이면 이유를 알리고 false)
    private func admitsSaveNow() -> Bool {
        guard let conditions = saveConditions else { return true }
        return !showsRefusal(ReflectionStatusRow.first(conditions), conditions)
    }

    /// 1~3번 줄이면 쓰지 않고 이유를 알린다(true)
    private func showsRefusal(_ row: ReflectionStatusRow, _ conditions: ReflectionConditions) -> Bool {
        switch row.saveCommand {
        case .restoreOnly:
            store.showToast(.notice(text: String(ui: "이 라이브러리에 끝나지 않은 저장 기록이 남아 있어 저장하지 않았습니다. DJCrate 상태 줄에서 기록으로 복원하거나 이대로 두세요"),
                                    kind: .warning))
            return true
        case .refuseWithReason:
            refuse(row, conditions)
            return true
        default:
            return false
        }
    }

    /// 쓰지 않고 이유를 보인다(R3 2·3번 줄): 종료 중·쓸 수 없음·켜짐·시트·USB·정리 못 마침
    private func refuse(_ row: ReflectionStatusRow, _ conditions: ReflectionConditions) {
        if let refusal = store.writeRefusal {
            store.showToast(.notice(refusal, nil))
        } else if row == .unwritable {
            let help = ReflectionStatusText.line(status: .saved, conditions: conditions, row: row, count: PendingWriteCount(items: 0, playlistEdits: 0),
                                                 showsWriting: false).help
            store.showToast(.notice(text: help ?? LibraryMenuAction.noEditsReason, kind: .warning))
        } else if ReflectionStatusText.topBusyHold(conditions) == .blockedDraftsOpen {
            store.announceWritesBlockedBySheet()
        } else if let refusal = ReflectionStatusText.refusal(conditions) {
            store.showToast(.notice(refusal.title, refusal.detail))
        }
    }
}
