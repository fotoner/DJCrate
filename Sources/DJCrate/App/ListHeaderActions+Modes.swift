import DJCDomain
import Foundation

/// 사이드바 항목(모드)마다 머리 줄 오른쪽 구성을 값으로 만든다. 화면 모델(`ListActionBarModel.actions`)이 저장소 값을 모아 넘긴다.
/// 한 화면에서 같은 이유는 한 곳에서만 말한다(STR-21): 곡이 없으면 가운데 안내(`EmptyListNotice`)가, 곡이 있으면 이 구성이 말한다.
/// 막힌 이유 문구(`LibraryStore.writesBlockedBySheetReason`)가 메인 액터 값이라 빌더도 메인 액터다.
@MainActor
extension ListHeaderActions {
    /// 쓰는 동안·비교 창이 열려 있는 동안·편집 잠금
    struct Locks: Equatable {
        var busy = false
        var sheetBlocked = false
        var editsFrozen = false
    }

    /// 쓰기 전으로 복원 항목: 복원할 백업이 있는지와 툴팁(막힌 이유 또는 결과 범위)
    struct Restore: Equatable {
        var isEnabled: Bool
        var help: String
    }

    /// 연결되지 않은 외장 디스크 하나
    struct MissingVolume: Equatable {
        var name: String
        var trackCount: Int
    }

    // MARK: - 단추 이름: 대상과 개수

    static func addTitle(selected: Bool, count: Int) -> String {
        selected ? String(ui: "고른 \(count)곡 바로 넣기") : String(ui: "전체 \(count)곡 바로 넣기")
    }

    /// 쓰기 단추 이름. 단추가 부르는 `startWrite(rows:)`는 재생 목록 편집·재생 기록도 늘 함께 쓰므로 그 건수를 이름에 붙인다.
    /// 고른 곡이 없으면 단추는 보이는 곡만 쓴다(메뉴·상태 줄의 쓰기는 고른 곡이 없으면 검색·필터와 상관없이 쓰기 대기 전체). 검색·필터로 좁혔으면(`narrowed`) 「전체」가 아니라 「보이는」이다.
    /// 곡은 「곡」, 재생 목록·재생 기록은 「건」이다(상태 줄 칩의 「쓰기 대기 N건」은 곡과 재생 기록을 합친 다른 수다)
    static func writeTitle(selected: Bool, narrowed: Bool = false, tracks: Int, playlistEdits: Int, histories: Int) -> String {
        let base = writeBase(selected: selected, narrowed: narrowed, tracks: tracks)
        guard let together = writtenTogether(playlistEdits: playlistEdits, histories: histories) else { return base }
        return String(ui: "\(base) (\(together))")
    }

    private static func writeBase(selected: Bool, narrowed: Bool, tracks: Int) -> String {
        if selected { return String(ui: "고른 \(tracks)곡 저장") }
        return narrowed ? String(ui: "보이는 \(tracks)곡 저장") : String(ui: "전체 \(tracks)곡 저장")
    }

    /// 곡과 함께 쓰는 재생 목록 편집·재생 기록 건수(없으면 nil)
    private static func writtenTogether(playlistEdits: Int, histories: Int) -> String? {
        var parts: [String] = []
        if playlistEdits > 0 { parts.append(String(ui: "재생 목록 \(playlistEdits)건")) }
        if histories > 0 { parts.append(String(ui: "재생 기록 \(histories)건")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - 추가한 곡

    static func staged(selected: Bool, count: Int, canRemove: Bool, canExportXML: Bool, importedCount: Int, locks: Locks) -> Self {
        var menu: [MenuItem] = [
            .command(Command(title: String(ui: "곡 추가…"), systemImage: "plus", action: .chooseFiles)),
            .command(Command(title: String(ui: "추가 목록에서 제거"), systemImage: "minus", action: .removeSelectedStaged, isEnabled: canRemove,
                             help: String(ui: "파일은 지우지 않습니다."))),
            .command(Command(title: String(ui: "XML 만들기"), systemImage: "doc.text", action: .exportStagedXML, isEnabled: canExportXML)),
        ]
        if importedCount > 0 {
            menu.append(.command(Command(title: String(ui: "가져온 곡 정리 (\(importedCount)곡)"), systemImage: "checkmark.circle",
                                         action: .removeImportedStaged)))
        }
        let blocked = count == 0 || locks.busy || locks.sheetBlocked
        let add = Command(title: addTitle(selected: selected, count: count), systemImage: "tray.and.arrow.down", action: .addStaged,
                          isEnabled: !blocked, help: locks.sheetBlocked ? LibraryStore.writesBlockedBySheetReason : nil, isProminent: true)
        return Self(primary: add, menu: menu, status: locks.busy ? .writing : nil)
    }

    // MARK: - rekordbox 쓰기 대기

    static func pending(selected: Bool, narrowed: Bool = false, tracks: Int, playlistEdits: Int, histories: [HistoryMenu.Entry], unlinkedDrafts: Int,
                        restore: Restore, locks: Locks) -> Self {
        var menu: [MenuItem] = []
        if !histories.isEmpty {
            // 쓰기 대기 재생 기록(#43)은 곡 줄이 아니라 이 메뉴에서 보고(고르면 그 기록으로) 뺀다
            let excludeAll = Command(title: String(ui: "모두 rekordbox 저장 대기에서 빼기"), systemImage: "minus.circle",
                                     action: .excludePendingHistories, isEnabled: !locks.editsFrozen)
            menu.append(.histories(HistoryMenu(title: String(ui: "재생 기록 \(histories.count)건"), systemImage: "clock.arrow.circlepath",
                                               entries: histories, excludeAll: excludeAll)))
        }
        if playlistEdits > 0 {
            menu.append(.command(Command(title: String(ui: "재생 목록 편집 버리기"), systemImage: "trash", action: .discardPlaylistDrafts,
                                         isEnabled: !locks.editsFrozen, help: String(ui: "⌘Z로 되돌릴 수 있습니다."))))
        }
        menu.append(.command(Command(title: String(ui: "XML 만들기"), systemImage: "doc.text", action: .exportPendingXML, isEnabled: tracks > 0)))
        menu.append(.divider)
        // 라이브러리 전체를 되돌리는 항목이라 늘 확인 창이 뜬다(STR-11). 입구는 상태 줄 팝오버·메뉴에도 있다
        menu.append(.command(Command(title: String(ui: "저장 전으로 복원…"), systemImage: "arrow.uturn.backward", action: .restoreLatest,
                                     isEnabled: restore.isEnabled && !locks.busy && !locks.sheetBlocked, help: restore.help)))

        let blocked = (tracks == 0 && playlistEdits == 0 && histories.isEmpty) || locks.busy || locks.sheetBlocked
        var write = Command(title: writeTitle(selected: selected, narrowed: narrowed, tracks: tracks, playlistEdits: playlistEdits,
                                              histories: histories.count),
                            systemImage: "square.and.arrow.up.on.square", action: .writePending, isEnabled: !blocked,
                            help: locks.sheetBlocked ? LibraryStore.writesBlockedBySheetReason : nil, isProminent: true)
        // 폭이 모자라면 곡 수만 남기고, 함께 쓰는 건수는 툴팁이 말한다(막힌 이유가 있으면 그 이유가 먼저다)
        if let together = writtenTogether(playlistEdits: playlistEdits, histories: histories.count) {
            write.compactTitle = writeBase(selected: selected, narrowed: narrowed, tracks: tracks)
            write.compactHelp = write.help ?? String(ui: "\(together)도 함께 저장합니다.")
        }
        var status: Status?
        if locks.busy {
            status = .writing
        } else if unlinkedDrafts > 0 {
            // 어떤 초안인지는 시트가 말한다(#175)
            status = Status(kind: .hint, title: String(ui: "연결되지 않은 편집 \(unlinkedDrafts)곡"), symbol: "questionmark.folder",
                            command: Command(title: String(ui: "보기…"), systemImage: "", action: .openUnlinkedDrafts))
        }
        return Self(primary: write, menu: menu, status: status)
    }

    // MARK: - Music·재생 목록

    /// Music 목록: 연결하지 못한 곡이 있으면 할 일이 있는 경고가, 없으면 잠금 표시가 상태다(한 화면에 상태는 하나)
    static func music(unavailable: Int) -> Self {
        if unavailable > 0 {
            return Self(status: Status(kind: .warning, title: String(ui: "연결하지 못한 \(unavailable)곡은 rekordbox 컬렉션 등록과 파일 위치를 확인하세요")))
        }
        return Self(status: Status(kind: .readOnly, title: String(ui: "목록 구성은 Music에서 바꿉니다")))
    }

    /// 실험실에서 보는 인텔리전트 목록(#68). 계산하지 못한 목록은 곡이 없어 가운데 안내가 말하므로 머리 줄은 말하지 않는다
    static func smartPlaylist(unsupported: Bool) -> Self {
        guard !unsupported else { return .none }
        return Self(status: Status(kind: .readOnly, title: String(ui: "읽기 전용"),
                                   info: [String(ui: "DJCrate가 조건으로 계산한 목록입니다. rekordbox 화면과 곡이 다를 수 있습니다.")]))
    }

    /// 상태는 하나: 할 일이 있는 막힘 > 숨긴 스트리밍 곡(순서를 못 바꾸는 이유) > 초안 표시
    static func playlist(id: String, isDraft: Bool, blockedReason: String?, hiddenStreaming: Int?, canCompare: Bool, locks: Locks) -> Self {
        var result = Self.none
        if let blockedReason {
            result.primary = Command(title: String(ui: "현재 목록 비교…"), systemImage: "arrow.left.arrow.right", action: .comparePlaylist(id),
                                     isEnabled: canCompare)
            result.status = Status(kind: .warning, title: String(ui: "이 목록의 편집 일부를 저장할 수 없습니다: \(blockedReason)"))
        } else if isDraft {
            result.primary = Command(title: String(ui: "이 목록의 편집 버리기"), systemImage: "trash", action: .discardPlaylistDraft(id),
                                     isEnabled: !locks.editsFrozen, help: String(ui: "⌘Z로 되돌릴 수 있습니다."))
        }
        if result.status == nil, let hiddenStreaming, hiddenStreaming > 0 {
            result.status = Status(kind: .hidden, title: String(ui: "스트리밍 \(hiddenStreaming)곡 숨김"),
                                   detail: String(ui: "숨긴 곡이 있으면 끌어서 순서를 바꿀 수 없습니다."),
                                   command: Command(title: String(ui: "보이기"), systemImage: "", action: .showStreaming))
        }
        if result.status == nil, isDraft {
            result.status = Status(kind: .draft, title: String(ui: "저장 전 목록 편집"))
        }
        return result
    }

    // MARK: - USB

    static func usb(volumeKey: String, editing: (updatable: Int, blockReason: String?, draftCount: Int)?, playlistMismatch: Bool) -> Self {
        var result = Self.none
        if let editing {
            // 막힐 반영이면(실물 USB 등) 누를 수 없게 하고 이유를 툴팁으로
            let help = editing.blockReason ?? String(ui: "로컬에서 더 고친 곡을 USB 쓰기 대기에 더합니다.")
            result.primary = Command(title: String(ui: "로컬 변경을 USB에 쓰기 (\(editing.updatable)곡)"), systemImage: "arrow.triangle.2.circlepath",
                                     action: .refreshUsbLocalChanges(volumeKey), isEnabled: editing.updatable > 0 && editing.blockReason == nil,
                                     help: help, compactTitle: String(ui: "USB에 쓰기 (\(editing.updatable)곡)"), compactHelp: help)
            result.menu = [.command(Command(title: String(ui: "USB 쓰기 대기 (\(editing.draftCount)건)"), systemImage: "square.and.arrow.up.on.square",
                                            action: .showUsbPending(volumeKey)))]
        }
        if playlistMismatch {
            result.status = Status(kind: .warning, title: String(ui: "두 형식의 재생 목록 내용이 다릅니다"))
        } else if editing == nil {
            result.status = Status(kind: .readOnly, title: String(ui: "USB의 곡·재생 목록은 읽기만 합니다"))
        }
        return result
    }

    // MARK: - 파일 없음(#126)

    /// 상태는 하나: 확인 중 > 연결되지 않은 외장 디스크(디스크째 알린다) > 파일 없는 곡이 있을 때의 단서
    static func missingFiles(volumes: [MissingVolume], checking: Bool, hasMissing: Bool, canFindInFolder: Bool) -> Self {
        let find = Command(title: String(ui: "폴더에서 찾기…"), systemImage: "folder.badge.questionmark", action: .findInFolder,
                           isEnabled: !checking && hasMissing && canFindInFolder,
                           help: String(ui: "고른 폴더에서 파일 없는 곡의 새 위치 후보를 찾아 미리 봅니다."))
        let recheck = Command(title: String(ui: "다시 확인"), systemImage: "arrow.clockwise", action: .recheckFiles, isEnabled: !checking)
        var status: Status?
        if checking {
            status = Status(kind: .progress, title: String(ui: "파일을 확인하는 중…"))
        } else if !volumes.isEmpty {
            // 하나면 무엇을 꽂을지 이름을 보이고, 여럿이면 개수를 보인다(이름·곡 수는 툴팁이 모두 말한다)
            let title = volumes.count == 1 ? String(ui: "연결되지 않은 외장 디스크: \(volumes[0].name)")
                : String(ui: "연결되지 않은 외장 디스크 \(volumes.count)개")
            status = Status(kind: .warning, title: title,
                            detail: volumes.map { String(ui: "\($0.name)(\($0.trackCount)곡)") }.joined(separator: ", "))
        } else if hasMissing {
            status = Status(kind: .hint, title: String(ui: "옮긴 음원은 rekordbox의 Relocate로 다시 연결하세요"))
        }
        return Self(primary: find, menu: [.command(recheck)], status: status)
    }

    // MARK: - BPM 없는 곡

    static func gridEstimate(count: Int, blocked: Bool) -> Self {
        Self(primary: Command(title: String(ui: "이 목록 그리드 추정 (\(count)곡)"), systemImage: "metronome", action: .estimateGrids,
                              isEnabled: !blocked,
                              help: String(ui: "rekordbox가 분석하지 않은 곡의 BPM·박 위치를 추정해 그리드 편집으로 보관합니다.")))
    }
}

extension ListHeaderActions.Status {
    /// rekordbox에 쓰는 동안 진행 표시. 쓰는 동안 끄지 말라는 안내는 창을 덮는 진행 카드 한 곳이 맡는다(STR-24)
    static var writing: Self {
        Self(kind: .progress, title: String(ui: "rekordbox 라이브러리 확인·저장하는 중…"))
    }
}
