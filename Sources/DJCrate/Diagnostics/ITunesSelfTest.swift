#if DEBUG
import AppKit
import DJCApplication
import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit

extension DevSelfTests {
    static func runITunesSelfTestIfRequested(store: LibraryStore, deck: DeckModel) {
        guard ProcessInfo.processInfo.arguments.contains("--itunes-selftest") else { return }
        let env = ProcessInfo.processInfo.environment
        func log(_ message: String) { FileHandle.standardError.write(Data("iTunes 시험: \(message)\n".utf8)) }
        guard env["DJC_HOME"]?.isEmpty == false, env["DJC_REKORDBOX_DIR"]?.isEmpty == false else {
            log("임시 DJC_HOME과 합성 DJC_REKORDBOX_DIR가 필요합니다"); exit(2)
        }
        Task {
            @MainActor func check(_ condition: Bool, _ message: String) {
                log("\(condition ? "통과" : "실패") · \(message)")
                if !condition { exit(1) }
            }
            for _ in 0..<300 {
                if case .loaded = store.phase { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let snapshot = store.snapshotURL, let before = try? Data(contentsOf: snapshot) else {
                log("실패 · 합성 라이브러리 로드"); exit(1)
            }
            check(store.iTunesLibrary.index["itunes:A"]?.name == "iTunes 합성 목록", "합성 iTunes 목록 로드")
            // 동기화가 쓰는 곳: 명시한 사본이면 그 사본 옆, 아니면 라이브 rekordbox 폴더(저장소의 위치 값)
            let syncDirectory = store.location.iTunesSyncTarget(opened: snapshot).deletingLastPathComponent()
            let syncURL = syncDirectory.appending(path: "playlists3.sync")
            let syncBefore = try? Data(contentsOf: syncURL)
            @MainActor func button(_ id: String, in view: NSView) -> NSButton? {
                if let button = view as? NSButton, button.identifier?.rawValue == id { return button }
                return view.subviews.lazy.compactMap { button(id, in: $0) }.first
            }
            @MainActor func checkbox(_ id: String) -> NSButton? {
                NSApp.windows.lazy.compactMap { $0.contentView.flatMap { button("itunes-sync-\(id)", in: $0) } }.first
            }
            @MainActor func captureSyncWindow(_ prefix: String) {
                guard let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) }),
                      let window = NSApp.windows.first(where: { $0.contentView.flatMap { button("itunes-sync-C", in: $0) } != nil })
                else { return }
                let capture = Process()
                capture.executableURL = URL(filePath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", "-l", String(window.windowNumber), String(arg.dropFirst(prefix.count))]
                try? capture.run()
                capture.waitUntilExit()
                check(capture.terminationStatus == 0, "선택 창 화면 저장")
            }
            // 뒤에서 Music을 읽는 동안 연 선택 창: 캐시를 보여 주되 낡은 폴더 계층으로 쓰지 않게 기다린다.
            let musicGate = DispatchSemaphore(value: 0)
            let latestMusic = store.iTunesSnapshot
            let musicRefresh = store.startSimulatedITunesRefresh { musicGate.wait(); return latestMusic }
            store.presentITunesSync()
            for _ in 0..<100 {
                if !store.iTunesSync.isLoading, checkbox("C") != nil { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            try? await Task.sleep(for: .milliseconds(300))
            captureSyncWindow("--itunes-sync-waiting-capture=")
            check(store.iTunesSync.isWaitingForMusic && !store.iTunesSync.canSync && checkbox("C") != nil,
                  "Music을 읽는 동안 캐시 목록을 보여 주고 동기화를 막음")
            musicGate.signal()
            await musicRefresh?.value
            for _ in 0..<50 {
                if store.iTunesSync.canSync { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            check(!store.iTunesSync.isWaitingForMusic && store.iTunesSync.canSync, "Music을 다 읽은 뒤 동기화 허용")
            store.showingITunesSync = false
            try? await Task.sleep(for: .milliseconds(300))
            store.presentITunesSync()
            for _ in 0..<100 {
                if !store.iTunesSync.isLoading, checkbox("C") != nil { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            check(checkbox("C") != nil && store.iTunesSync.canSync, "실제 동기화 선택 창과 체크박스")
            checkbox("C")?.performClick(nil)
            check(store.iTunesSync.selection.selectedIDs.contains("C") && store.iTunesLibrary.index["itunes:C"] == nil,
                  "체크박스로 선택하고 적용 전 기존 목록 유지")
            store.showingITunesSync = false
            try? await Task.sleep(for: .milliseconds(300))
            check((try? Data(contentsOf: syncURL)) == syncBefore, "취소하면 rekordbox 동기화 선택 불변")
            store.presentITunesSync()
            for _ in 0..<100 {
                if !store.iTunesSync.isLoading, checkbox("C") != nil { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            checkbox("C")?.performClick(nil)
            if store.iTunesSync.selection.state(of: "F", in: store.iTunesSync.nodes) == .on { checkbox("F")?.performClick(nil) }
            checkbox("F")?.performClick(nil)
            check(store.iTunesSync.selection.state(of: "F", in: store.iTunesSync.nodes) == .on, "폴더와 하위 목록 전체 선택")
            try? await Task.sleep(for: .milliseconds(300))
            captureSyncWindow("--itunes-sync-capture=")
            let synced = await store.iTunesSync.sync(store: store)
            check(synced && store.iTunesLibrary.index["itunes:C"] != nil, "동기화 즉시 사이드바에 추가")
            check((try? Data(contentsOf: syncURL)) != syncBefore, "rekordbox 동기화 파일에 반영")
            store.showingITunesSync = false
            await store.refreshITunesPlaylists()
            check(store.iTunesLibrary.index["itunes:C"] != nil, "다시 읽은 뒤에도 선택 유지")
            if !store.location.opensExplicitCopy {
                check(store.snapshotURL.map { LibrarySnapshot.sameDirectory($0.deletingLastPathComponent(), store.location.snapshotDirectory) } == true,
                      "사본 폴더 모드의 새 스냅샷으로 갱신")
            }
            store.sidebar = .itunesPlaylist("itunes:A")
            check(store.displayRows.map(\.track.id) == ["2", "1", "2"]
                  && Set(store.displayRows.map(\.id)).count == 3
                  && store.displayRows.map(\.playlistTrackNumber) == [1, 2, 3], "반복 곡과 원본 순서")
            store.selection = [store.displayRows[2].id]
            check(store.selectedRows.map(\.track.id) == ["2"] && store.primaryRow?.track.id == "2", "반복 행 선택을 기존 곡에 연결")
            check(store.iTunesLibrary.index["itunes:A"]?.unavailableTrackCount == 1, "미연결 곡 안내")
            check(store.editablePlaylistID == nil && !store.canReorderDisplayedTracks
                  && !LibraryMenuAction.removeTracks.isEnabled(in: store), "순서 변경·목록 삭제·컬렉션 삭제 차단")
            guard let row = store.displayRows.first else { log("실패 · 곡 선택"); exit(1) }
            store.setTag(.comment, "iTunes 시험 초안", rows: [row])
            check(store.tagDrafts[row.track.uuid]?.fields.comment == "iTunes 시험 초안", "기존 곡에 태그 초안")
            store.loadToDeck(row)
            for _ in 0..<150 {
                if deck.canPlay, deck.row?.track.id == row.track.id, deck.draft?.trackUUID == row.track.uuid { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            deck.pressHotCue(slot: 0)
            check(deck.row?.track.id == row.track.id && deck.hotCue(slot: 0) != nil, "기존 곡에 핫큐 초안")
            store.useCases.watch.flush()
            check(CueDraftStore.load(trackUUID: row.track.uuid)?.hasChanges == true, "핫큐 초안 파일 저장")
            check((try? Data(contentsOf: snapshot)) == before && store.playlistDraft.isEmpty, "DB 사본과 목록 구성 불변")
            log("전체 통과 · 동기화 선택·취소·저장·다시 읽기·기존 9개 검증")
            exit(0)
        }
    }
}
#endif
