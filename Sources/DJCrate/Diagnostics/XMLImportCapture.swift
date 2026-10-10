#if DEBUG
import AppKit
import DJCApplication
import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit

extension DevSelfTests {
    /// rekordbox XML 가져오기(#72)를 합성 라이브러리로 해 보고 미리 보기·결과 시트를 캡처한다(`--xml-import-capture=<폴더>`).
    /// 사본을 내보낸 XML을 고쳐(제목·핫큐·그리드·새 재생 목록) 가져오고, 모든 차이를 초안으로 만든 뒤
    /// 초안이 생겼는지와 사본 DB가 그대로인지 본다("rekordbox XML 가져오기 시험 통과" 줄).
    /// 창을 앞으로 가져오지 않고 이 앱의 창 번호로만 찍는다. 합성 사본(곡 제목이 "합성 곡"으로 시작)과 사본 폴더(`DJC_REKORDBOX_DIR`)·임시 `DJC_HOME`에서만 돈다.
    static func runXMLImportCaptureIfRequested(store: LibraryStore) {
        guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--xml-import-capture=") }),
              ProcessInfo.processInfo.environment["DJC_HOME"] != nil,
              ProcessInfo.processInfo.environment["DJC_REKORDBOX_DIR"]?.isEmpty == false else { return }
        let directory = URL(filePath: String(argument.dropFirst("--xml-import-capture=".count)))
        func log(_ text: String) { FileHandle.standardError.write(Data("[XML 가져오기 시험] \(text)\n".utf8)) }
        Task { @MainActor in
            func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
            for _ in 0..<100 {
                if case .loaded = store.phase { break }
                await wait(0.1)
            }
            guard !store.rows.isEmpty, store.rows.allSatisfy({ $0.title.hasPrefix("합성 곡") }),
                  let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }),
                  let snapshot = store.snapshotURL else {
                log("합성 사본이 아닙니다")
                exit(2)
            }
            var failures = 0
            @MainActor func check(_ condition: Bool, _ what: String) {
                if !condition { failures += 1; log("실패: \(what)") }
            }
            @MainActor func capture(_ name: String, _ target: NSWindow) {
                // 이 Mac에 붙은 실제 볼륨 이름이 사이드바 USB 절에 찍히지 않게 한다.
                store.usb = nil
                let process = Process()
                process.executableURL = URL(filePath: "/usr/sbin/screencapture")
                process.arguments = ["-x", "-o", "-l", String(target.windowNumber), directory.appending(path: "\(name).png").path]
                do { try process.run(); process.waitUntilExit() } catch { failures += 1; return }
                if process.terminationStatus != 0 { failures += 1 }
            }
            let before = try? Data(contentsOf: snapshot)
            // 사본을 내보낸 XML을 다른 도구가 고친 것처럼 바꾼다.
            let source: String
            do {
                source = RekordboxLibraryXML.document(try RekordboxLibraryXML.load(snapshot: snapshot, shareRoot: RekordboxShare.directory))
            } catch {
                log("내보내기 실패: \(error)")
                exit(1)
            }
            var xml = source.replacingOccurrences(of: #"Name="합성 곡 01""#, with: #"Name="합성 곡 01 (가져옴)""#)
                .replacingOccurrences(of: #"Name="합성 곡 03""#, with: #"Name="합성 곡 03 (가져옴)""#)
                .replacingOccurrences(of: #"<NODE Name="합성 목록 2""#, with: #"<NODE Name="합성 목록 3""#)
            if let range = xml.range(of: #"Type="0" Start="2"#) { xml.replaceSubrange(range, with: #"Type="0" Start="3"#) }
            if let range = xml.range(of: #"<TEMPO Inizio="0.040""#) { xml.replaceSubrange(range, with: #"<TEMPO Inizio="0.045""#) }
            let url = directory.appending(path: "import.xml")
            do { try Data(xml.utf8).write(to: url) } catch { log("XML을 쓰지 못했습니다"); exit(1) }

            store.sidebar = .filter(.all)
            store.xmlImport.start(from: url)
            check(store.xmlImport.isReading, "시작하자마자 읽는 중이어야 합니다")
            await store.xmlImport.task?.value
            guard let preview = store.xmlImport.preview else {
                log("미리 보기가 열리지 않았습니다: \(store.stagingMessage?.text ?? "")")
                exit(1)
            }
            let counts = preview.diff.counts
            check(counts.tagTracks == 2, "태그 차이 \(counts.tagTracks)")
            check(counts.cueTracks == 1, "큐 차이 \(counts.cueTracks)")
            check(counts.gridTracks == 1, "그리드 차이 \(counts.gridTracks)")
            check(counts.missingPlaylists == 1, "없는 목록 \(counts.missingPlaylists)")
            await wait(1.5)
            guard let sheet = window.attachedSheet else {
                log("미리 보기 시트가 없습니다")
                exit(1)
            }
            capture("preview", sheet)
            await store.xmlImport.makeDrafts(preview, selection: .all)
            await wait(1.5)
            capture("result", window.attachedSheet ?? sheet)
            let result = store.xmlImport.result
            check(result?.failure == nil, "실패 없음(\(result?.failure ?? ""))")
            check(result?.tags == 2 && result?.cues == 1 && result?.grids == 1 && result?.playlists == 1,
                  "초안 수 \(String(describing: result))")
            check(store.tagDrafts.values.contains { $0.fields.title == "합성 곡 01 (가져옴)" }, "태그 초안이 보여야 합니다")
            check(store.playlists.playlistDraft.project(onto: store.playlists.rekordboxPlaylists).layout.outline.contains { $0.name == "합성 목록 3" },
                  "재생 목록 초안이 보여야 합니다")
            check((try? Data(contentsOf: snapshot)) == before, "사본 DB가 그대로여야 합니다")
            log("차이: 큐 \(counts.cueTracks) · 그리드 \(counts.gridTracks) · 태그 \(counts.tagTracks) · 없는 목록 \(counts.missingPlaylists)")
            log(failures == 0 ? "rekordbox XML 가져오기 시험 통과" : "rekordbox XML 가져오기 시험 실패 \(failures)건")
            exit(failures == 0 ? 0 : 1)
        }
    }
}
#endif
