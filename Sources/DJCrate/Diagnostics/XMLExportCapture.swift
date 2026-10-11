#if DEBUG
import AppKit
import DJCDomain
import Foundation
import RekordboxKit

extension DevSelfTests {
    /// 라이브러리 XML 내보내기(#72)를 합성 라이브러리로 해 보고 화면을 캡처한다(`--xml-export-capture=<폴더>`).
    /// 내보낸 파일을 다시 읽어 곡·재생 목록 수를 확인하고 사본 DB가 그대로인지 본다("라이브러리 XML 시험 통과" 줄).
    /// 창을 앞으로 가져오지 않고 이 앱의 창 번호로만 찍는다. 합성 사본(곡 제목이 "합성 곡"으로 시작)과 사본 폴더(`DJC_REKORDBOX_DIR`)·임시 `DJC_HOME`에서만 돈다.
    static func runXMLExportCaptureIfRequested(store: LibraryStore) {
        guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--xml-export-capture=") }),
              ProcessInfo.processInfo.environment["DJC_HOME"] != nil,
              ProcessInfo.processInfo.environment["DJC_REKORDBOX_DIR"]?.isEmpty == false else { return }
        let directory = URL(filePath: String(argument.dropFirst("--xml-export-capture=".count)))
        func log(_ text: String) { FileHandle.standardError.write(Data("[라이브러리 XML 시험] \(text)\n".utf8)) }
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
            @MainActor func capture(_ name: String) {
                // 이 Mac에 붙은 실제 볼륨 이름이 사이드바 USB 절에 찍히지 않게 한다.
                store.usb = nil
                let process = Process()
                process.executableURL = URL(filePath: "/usr/sbin/screencapture")
                process.arguments = ["-x", "-o", "-l", String(window.windowNumber), directory.appending(path: "\(name).png").path]
                do { try process.run(); process.waitUntilExit() } catch { failures += 1; return }
                if process.terminationStatus != 0 { failures += 1 }
            }
            let before = try? Data(contentsOf: snapshot)
            store.sidebar = .filter(.all)
            store.usb = nil
            await wait(1.5)
            capture("before")
            // 진행 줄: 곡이 몇 곡 안 돼 실제 진행은 눈 깜짝할 새라, 줄 모양만 값을 직접 주어 한 컷 찍는다.
            store.staging.xmlExportJob = LibraryXMLExportJob(fraction: 0.45, isPreparing: false)
            await wait(1)
            capture("progress")
            store.staging.xmlExportJob = nil
            let out = directory.appending(path: "library.xml")
            try? FileManager.default.removeItem(at: out)
            store.staging.exportLibraryXML(to: out)
            check(store.staging.hasXMLExportJob, "시작하자마자 진행 줄이 서야 합니다")
            await store.staging.xmlExportTask?.value
            store.usb = nil
            await wait(1.5)
            capture("after")
            check(store.staging.stagingMessage?.kind == .success, "완료 안내(\(store.staging.stagingMessage?.text ?? "없음"))")
            check(!store.staging.hasXMLExportJob, "끝나면 진행 줄이 빠져야 합니다")
            let xml = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
            let tracks = xml.components(separatedBy: "\n").filter { $0.contains("<TRACK TrackID=") }.count
            let lists = xml.components(separatedBy: "\n").filter { $0.contains(#" Type="1" KeyType="0""#) }.count
            check(tracks == store.rows.filter { !$0.track.isStreaming }.count, "곡 수 \(tracks)")
            check(lists == 2, "재생 목록 수 \(lists)")
            check(!xml.contains("apple-music"), "스트리밍 곡은 넣지 않습니다")
            check(XMLParser(data: Data(xml.utf8)).parse(), "올바른 XML이어야 합니다")
            check((try? Data(contentsOf: snapshot)) == before, "사본 DB가 그대로여야 합니다")
            log("곡 \(tracks) · 재생 목록 \(lists) · 안내: \(store.staging.stagingMessage?.text.components(separatedBy: "\n").first ?? "")")
            log(failures == 0 ? "라이브러리 XML 시험 통과" : "라이브러리 XML 시험 실패 \(failures)건")
            exit(failures == 0 ? 0 : 1)
        }
    }
}
#endif
