#if DEBUG
import AppKit
import DJCApplication
import DJCDomain
import Foundation

/// 사이드바 여러 개 고르기(#261)를 합성 사본으로 확인한다. 실제 마우스·키 대신 사이드바 목록(`NSOutlineView`)의 고르기를 바꾸고
/// (⌘ 클릭 = 고르기 늘리기, 빈 곳 누르기 = 모두 풀기) ⌫는 응답 사슬로 보낸다. 끌어 놓기는 화면 모델을 부른다.
/// - `--sidebar-multi-capture=<폴더>`: 여럿 고르기 → 지우기 확인 창 → 지운 뒤 → ⌘Z 한 번 → 여럿 옮기기(건너뛰기 알림) → ⌘Z 한 번을 캡처한다.
///   `PlaylistWriteFixtureCapture`를 `DJC_PLAYLIST_FIXTURE_SMART=1`로 만든 사본(인텔리전트 목록 하나 더)을 쓴다.
/// - `--sidebar-multi-write=bulk|single`: 같은 편집(목록 둘을 폴더 앞으로 옮기고 폴더·목록 지우기)을 묶음 또는 하나씩 쌓아 사본에 쓴다.
///   두 사본을 `djc lab db-diff`로 견준다.
@MainActor
enum SidebarMultiCapture {
    static func runIfRequested(store: LibraryStore, sidebar: PlaylistSidebarModel, reflection: ReflectionCoordinator) {
        let args = ProcessInfo.processInfo.arguments
        let capture = args.first { $0.hasPrefix("--sidebar-multi-capture=") }.map { String($0.dropFirst("--sidebar-multi-capture=".count)) }
        let write = args.first { $0.hasPrefix("--sidebar-multi-write=") }.map { String($0.dropFirst("--sidebar-multi-write=".count)) }
        guard capture != nil || write != nil else { return }
        Task {
            do {
                // `..`·링크로 임시 폴더를 벗어나지 않게 풀어서 견준다
                func resolved(_ path: String) -> String { URL(filePath: path).standardizedFileURL.resolvingSymlinksInPath().path }
                let environment = ProcessInfo.processInfo.environment
                let temporary = resolved(FileManager.default.temporaryDirectory.path) + "/"
                guard let home = environment["DJC_HOME"], let root = environment["DJC_REKORDBOX_DIR"],
                      resolved(home).hasPrefix(temporary), resolved(root).hasPrefix(temporary) else {
                    throw DJCError.writeRefused("합성 사본(DJC_REKORDBOX_DIR)과 임시 데이터(DJC_HOME)를 임시 폴더 안에 주세요")
                }
                for _ in 0..<100 {
                    if case .loaded = store.phase { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard case .loaded = store.phase, store.rows.allSatisfy({ $0.title.hasPrefix("합성 곡 ") }),
                      store.playlists.playlistItem("1001")?.isFolder == true else {
                    throw DJCError.writeRefused("합성 재생 목록 사본을 읽지 못했습니다")
                }
                if let capture { try await runCapture(store: store, sidebar: sidebar, directory: URL(filePath: capture)) }
                if let write { try await runWrite(store: store, sidebar: sidebar, reflection: reflection, bulk: write == "bulk") }
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("사이드바 여러 개 시험 실패: \(DJCError.reason(of: error))\n".utf8))
                exit(2)
            }
        }
    }

    private static func check(_ condition: Bool, _ reason: String) throws {
        if !condition { throw DJCError.writeRefused(reason) }
    }

    /// 실행 취소가 앞 동작과 한 묶음이 되지 않게 런 루프를 한 번 돌린다(앱의 이벤트마다 묶기와 같다)
    private static func settle() async throws { try await Task.sleep(for: .milliseconds(400)) }

    private static func runCapture(store: LibraryStore, sidebar: PlaylistSidebarModel, directory: URL) async throws {
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain }), let undo = store.undoManager else {
            throw DJCError.writeRefused("주 창을 찾지 못했습니다")
        }
        let playlists = store.playlists
        guard let smart = playlists.playlistProjection.layout.outline.first(where: \.isSmart) else {
            throw DJCError.writeRefused("인텔리전트 목록이 있는 사본(DJC_PLAYLIST_FIXTURE_SMART=1)을 주세요")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // 이벤트 없이 부르면 런 루프 묶기가 앞뒤 동작을 한 실행 취소로 합친다. 사용자 동작 하나 = 묶음 하나로 직접 묶는다
        undo.groupsByEvent = false
        func action<T>(_ body: () throws -> T) rethrows -> T {
            undo.beginUndoGrouping()
            defer { undo.endUndoGrouping() }
            return try body()
        }
        NSApp.appearance = NSAppearance(named: .aqua)
        window.setContentSize(NSSize(width: 1100, height: 700))
        // 고를 항목을 더 만든다: 합성 폴더 안 폴더, 맨 위 목록 둘
        let inner = action { playlists.createPlaylist(isFolder: true, in: "1001", name: "합성 안 폴더") }
        try await settle()
        let second = action { playlists.createPlaylist(isFolder: false, in: PlaylistLayout.root, name: "합성 둘째 목록") }
        try await settle()
        let third = action { playlists.createPlaylist(isFolder: false, in: PlaylistLayout.root, name: "합성 셋째 목록") }
        sidebar.cancelRenaming()
        try await settle()
        guard let inner, let second, let third else { throw DJCError.writeRefused("고를 목록을 만들지 못했습니다") }
        sidebar.setExpanded("1001", true)

        // 1. 사이드바 목록에서 고르기를 늘려(⌘ 클릭과 같은 경로) 셋(인텔리전트 목록 섞임)을 고른다. 곡 목록은 마지막에 고른 목록이다
        guard let outline = Self.outline(in: window.contentView) else { throw DJCError.writeRefused("사이드바 목록을 찾지 못했습니다") }
        var rows: [String: Int] = [:]
        for id in ["1003", second, smart.id] {
            sidebar.select([.playlist(id)])
            try await settle()
            rows[id] = outline.selectedRow
        }
        sidebar.select([.playlist("1003")])
        try await settle()
        for id in [second, smart.id] {
            outline.selectRowIndexes(IndexSet(integer: rows[id] ?? -1), byExtendingSelection: true)
            try await settle()
        }
        try check(store.sidebar == .playlist(smart.id) && sidebar.selection == [.playlist("1003"), .playlist(second), .playlist(smart.id)],
                  "목록에서 여러 개를 고르지 못했습니다: \(sidebar.selection)")
        try check(outline.selectedRowIndexes.count == 3, "목록 강조가 셋이 아닙니다")
        try capture(window, directory.appending(path: "1-selected.jpg"))
        // 빈 곳 누르기(모두 풀기): 고르기를 그대로 두고 강조를 되살린다
        outline.deselectAll(nil)
        try await settle()
        try check(sidebar.selection.count == 3 && outline.selectedRowIndexes.count == 3,
                  "모두 풀린 강조를 되살리지 못했습니다(강조 \(outline.selectedRowIndexes.count)줄)")

        // 2. ⌫(응답 사슬의 delete:): 확인 창(개수·이름·건너뛸 항목)을 캡처하고 지운다
        let prompter = ConfirmCapturePrompter(url: directory.appending(path: "2-delete-alert.jpg"))
        sidebar.prompter = prompter
        let beforeDelete = playlists.playlistDraft
        window.makeFirstResponder(outline)
        let viaResponder = action { outline.tryToPerform(#selector(NSText.delete(_:)), with: nil) }
        if !viaResponder { action { sidebar.deleteSelection() } }
        try await settle()
        let layout = { playlists.playlistProjection.layout }
        let deleting = 2
        try check(prompter.shown?.title == String(ui: "재생 목록 \(deleting)개를 지울까요?"), "확인 창 제목이 다릅니다: \(prompter.shown?.title ?? "-")")
        try check(layout().item("1003") == nil && layout().item(second) == nil && layout().item(smart.id) != nil, "고른 목록을 지우지 못했습니다")
        try check(playlists.playlistMessage?.kind == .warning, "건너뛴 인텔리전트 목록을 알리지 않았습니다")
        try capture(window, directory.appending(path: "3-deleted.jpg"))

        // 3. ⌘Z 한 번에 모두 돌아온다
        let undoName = undo.undoActionName
        undo.undo()
        try await settle()
        try check(layout().item("1003") != nil && layout().item(second) != nil && playlists.playlistDraft == beforeDelete,
                  "⌘Z 한 번에 되돌리지 못했습니다(되돌린 동작 \(undoName), 1003 \(layout().item("1003") != nil), 둘째 \(layout().item(second) != nil), 초안 단계 \(playlists.playlistDraft.steps.count)/\(beforeDelete.steps.count), 안내 \(playlists.playlistMessage?.text ?? "-"))")
        try capture(window, directory.appending(path: "4-delete-undone.jpg"))

        // 4. 끌어 옮기기: 합성 폴더·맨 위 목록·셋째 목록을 합성 안 폴더로. 폴더는 제 안이라 건너뛰고 나머지는 사이드바 순서로 옮긴다
        sidebar.select([.playlist("1001")])
        sidebar.select([.playlist("1001"), .playlist("1003")])
        sidebar.select([.playlist("1001"), .playlist("1003"), .playlist(third)])
        let beforeMove = playlists.playlistDraft
        // 새 목록은 부모 맨 위에 생기므로 사이드바 순서는 셋째 목록 → 맨 위 목록이다
        let expected = layout().outline.map(\.id).filter { $0 == "1003" || $0 == third }
        let dragged = sidebar.dragIDs(for: "1003")
        try check(sidebar.refusesPlaylistDrop(on: third) && !sidebar.refusesPlaylistDrop(on: inner), "끄는 항목 위 놓기 판정이 다릅니다")
        action { sidebar.movePlaylists(dragged, to: .into(inner)) }
        sidebar.setExpanded(inner, true)
        try await settle()
        try check(layout().childIDs(of: inner) == expected && expected.count == 2, "사이드바 순서로 옮기지 못했습니다: \(layout().childIDs(of: inner))")
        try check(layout().item("1001")?.parentID == PlaylistLayout.root, "제 안으로 옮기는 폴더를 건너뛰지 않았습니다")
        try check(playlists.playlistMessage?.kind == .warning, "건너뛴 폴더를 알리지 않았습니다")
        try capture(window, directory.appending(path: "5-moved.jpg"))
        undo.undo()
        try await settle()
        try check(layout().childIDs(of: inner).isEmpty && playlists.playlistDraft == beforeMove, "옮기기를 ⌘Z 한 번에 되돌리지 못했습니다")
        try capture(window, directory.appending(path: "6-move-undone.jpg"))
        let path = viaResponder ? "응답 사슬" : "화면 모델(응답 사슬이 받지 않음)"
        FileHandle.standardError.write(Data("사이드바 여러 개 캡처 통과: 고르기 3(강조 3, 모두 풀기 뒤 3) → ⌫(\(path)) 지움 2·건너뜀 1 → ⌘Z 1번 · 옮김 2·건너뜀 1 → ⌘Z 1번\n".utf8))
    }

    private static func outline(in view: NSView?) -> NSOutlineView? {
        guard let view else { return nil }
        if let outline = view as? NSOutlineView { return outline }
        for child in view.subviews { if let found = outline(in: child) { return found } }
        return nil
    }

    /// 목록 둘을 폴더 앞으로 옮기고 폴더와 목록 하나를 지운다(묶음 또는 하나씩). 쓴 뒤 rekordbox 모양을 알린다
    private static func runWrite(store: LibraryStore, sidebar: PlaylistSidebarModel, reflection: ReflectionCoordinator, bulk: Bool) async throws {
        let playlists = store.playlists
        if bulk {
            sidebar.movePlaylists(["1003", "1002"], to: .before("1001"))
            try await settle()
            sidebar.prompter = ConfirmCapturePrompter(url: nil)
            sidebar.deletePlaylists(["1003", "1001"])
        } else {
            playlists.movePlaylist("1002", into: PlaylistLayout.root, before: "1001")
            try await settle()
            playlists.movePlaylist("1003", into: PlaylistLayout.root, before: "1001")
            try await settle()
            playlists.deletePlaylist("1003")
            try await settle()
            playlists.deletePlaylist("1001")
        }
        try await settle()
        let edits = playlists.playlistDraft.edits
        store.setWriteLock(true)
        let preview = try await reflection.session.previewWrite(rows: [], playlists: true)
        try check(preview.report.playlistBlocked.isEmpty, "쓰기 미리 보기가 막혔습니다")
        let report = try await reflection.session.writeDrafts(DraftWriteBatch(playlists: preview.batch.playlists), to: reflection.session.target)
        store.setWriteLock(false)
        try await Task.sleep(for: .milliseconds(1500))
        let shape = playlists.rekordboxPlaylists.outline.map { "\($0.parentID)/\($0.id)" }.joined(separator: ",")
        let kind = bulk ? "묶음" : "하나씩"
        FileHandle.standardError.write(Data("사이드바 여러 개 쓰기 통과(\(kind)): 편집 \(edits.count)건 · 씀 \(report.playlistWritten.count)건 · 모양 \(shape) · 남은 초안 \(playlists.playlistDraft.edits.count)건\n".utf8))
    }

    fileprivate static func capture(_ window: NSWindow, _ url: URL) throws {
        guard !NSApp.isActive else { throw DJCError.writeRefused("앱이 활성화되어 캡처를 중단했습니다") }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-t", "jpg", "-l", String(window.windowNumber), url.path]
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw DJCError.writeRefused("창을 캡처하지 못했습니다") }
    }
}

/// 확인 창을 실제 알림 모양으로 그려 캡처하고(`url`이 있을 때) 확인을 누른다
@MainActor
private final class ConfirmCapturePrompter: HeadlessReflectionPrompter {
    let url: URL?
    var shown: ReflectionPrompt?
    init(url: URL?) { self.url = url }

    func choose(_ prompt: ReflectionPrompt) -> ReflectionChoice {
        shown = prompt
        guard let url else { return .confirm }
        let alert = AlertPrompter().makeAlert(prompt)
        alert.layout()
        alert.window.orderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        try? SidebarMultiCapture.capture(alert.window, url)
        alert.window.orderOut(nil)
        return .confirm
    }
    func show(_ prompt: ReflectionPrompt) -> Bool { choose(prompt) == .confirm }
}
#endif
