#if DEBUG
import AppKit
import DJCAdapters
import DJCApplication
import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit

/// 합성 사본으로 히스토리 표시·미리 보기·쓰기·다시 읽기·복원과 보존본 재대기를 확인한다.
@MainActor
enum HistorySelfTest {
    /// 저장소를 만들기 전에 검사해 잘못된 자가 테스트 인자가 사용자 초안을 읽고 옮기지 않게 한다.
    static func startupDatabase(arguments: [String], environment: [String: String]) throws -> URL {
        guard let home = environment["DJC_HOME"], let root = environment["DJC_REKORDBOX_DIR"] else {
            throw SelfTestError.invalidStartup
        }
        _ = try UsbScratchPath.check(home, as: .existingDirectory)
        _ = try UsbScratchPath.check(root, as: .existingDirectory)
        let explicit: String?
        if let index = arguments.firstIndex(of: "--db"), arguments.indices.contains(index + 1) { explicit = arguments[index + 1] }
        else { explicit = environment["DJC_DB"] }
        guard let explicit, !explicit.isEmpty else { throw SelfTestError.invalidStartup }
        let database = try checkedDatabase(URL(filePath: root).appending(path: "master.db"), snapshot: URL(filePath: explicit))
        guard try UsbScratchPath.check(explicit, as: .existingFile) != database.path else { throw SelfTestError.databaseMismatch }
        return database
    }

    /// 라이브 DB·하드 링크를 거부하고, 읽기 스냅샷과 쓰기 대상이 같은 합성 DB의 사본인지 바이트로 확인한다.
    static func checkedDatabase(_ database: URL, snapshot: URL? = nil,
                                liveDatabase: URL = LibrarySnapshot.realRekordboxDirectory.appending(path: "master.db")) throws -> URL {
        let checked = URL(filePath: try UsbScratchPath.check(database.path, as: .existingFile))
        _ = try LibraryRead.resolve(database: checked, liveDatabase: liveDatabase)
        let attributes = try FileManager.default.attributesOfItem(atPath: checked.path)
        guard (attributes[.referenceCount] as? NSNumber)?.intValue == 1 else { throw SelfTestError.databaseMismatch }
        if let snapshot {
            _ = try LibraryRead.resolve(database: snapshot, liveDatabase: liveDatabase)
            let readCopy = URL(filePath: try UsbScratchPath.check(snapshot.path, as: .existingFile))
            guard try Data(contentsOf: readCopy) == Data(contentsOf: checked) else {
                throw SelfTestError.databaseMismatch
            }
        }
        return checked
    }

    static func runIfRequested(store: LibraryStore, reflection: ReflectionCoordinator) {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--history-selftest") else { return }
        func log(_ message: String) { FileHandle.standardError.write(Data("[히스토리 시험] \(message)\n".utf8)) }
        let env = ProcessInfo.processInfo.environment
        guard let home = env["DJC_HOME"], let root = env["DJC_REKORDBOX_DIR"],
              (try? UsbScratchPath.check(home, as: .existingDirectory)) != nil,
              (try? UsbScratchPath.check(root, as: .existingDirectory)) != nil else {
            log("미검증: 임시 사본 폴더가 필요합니다"); exit(2)
        }
        guard let database = try? checkedDatabase(URL(filePath: root).appending(path: "master.db")) else {
            log("미검증: 쓰기 대상은 라이브 DB에 이어지지 않은 합성 사본이어야 합니다"); exit(2)
        }
        // 쓰기·복원 대상과 쓴 뒤 다시 읽기의 출처는 위치 값이 정한다(`DJC_REKORDBOX_DIR`의 master.db, 스냅샷은 그 안 djc-snapshots/).
        let session = reflection.session
        guard session.target.database.standardizedFileURL == database.standardizedFileURL, store.location.allowsSnapshot else {
            log("미검증: 쓰기 대상이 합성 사본이 아닙니다"); exit(2)
        }
        Task {
            for _ in 0..<300 {
                if case .loaded = store.phase { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !store.rows.isEmpty, store.rows.allSatisfy({ $0.title.hasPrefix("히스토리 시험 ") }),
                  let row = store.rowsByID["101"], let snapshot = store.snapshotURL,
                  let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }) else {
                log("미검증: 히스토리 합성 사본을 읽지 못했습니다"); exit(2)
            }
            do {
                _ = try checkedDatabase(database, snapshot: snapshot)
                let before = try Data(contentsOf: database)
                let keys = try await BlockingWork.run(qos: .default) { try LocalLibraryKeysReader.load(snapshot: snapshot) }
                guard let key = keys.tracks.first(where: { $0.contentID == row.track.id }) else { exit(2) }
                let archive = ArchivedHistory(id: "usbhistory-selftest", name: "HISTORY 2026-10-09", importedAt: Date(timeIntervalSince1970: 1_791_524_834),
                    sequence: 1, source: .init(volumeKey: "SELFTEST", volumeName: "합성 USB", format: "deviceLibrary", historyID: 1, historyName: "HISTORY 001"),
                    entries: [.init(trackNumber: 1, usbContentID: 1, contentID: row.track.id, title: row.title, artist: row.track.artist,
                                    path: "/Contents/test.mp3", masterDbId: keys.masterDBID(of: row.track.id),
                                    masterContentId: Int64(key.masterSongID) ?? 0,
                                    fileName: UsbPathRules.audioFileName(sourcePath: key.folderPath, fileNameL: key.fileNameL))])
                let archiveStore = UsbHistoryStore(directory: URL(filePath: home).appending(path: "usb-histories"), home: URL(filePath: home))
                try await BlockingWork.run(qos: .default) { try archiveStore.save([archive]) }
                store.usbHistories = ArchiveUsbHistories(files: .live(directory: archiveStore.directory, home: URL(filePath: home)),
                                                         now: { Date() }, newID: { UUID().uuidString })
                await store.loadArchivedHistories()
                store.writesHistories = true
                store.sidebar = .history(archive.id)
                guard store.pendingHistoryIDs == [archive.id], store.displayRows.count == 1 else {
                    log("실패: 보존본 표시·쓰기 대기"); exit(1)
                }
                @MainActor func capture(_ name: String) async throws {
                    guard let arg = args.first(where: { $0.hasPrefix("--history-capture=") }) else { return }
                    let folder = URL(filePath: String(arg.dropFirst("--history-capture=".count)))
                    _ = try UsbScratchPath.check(folder.path, as: .existingDirectory)
                    store.usb = nil
                    window.setContentSize(NSSize(width: 1440, height: 900))
                    try await Task.sleep(for: .milliseconds(500))
                    let process = Process()
                    process.executableURL = URL(filePath: "/usr/sbin/screencapture")
                    process.arguments = ["-x", "-o", "-l", String(window.windowNumber), folder.appending(path: name + ".png").path]
                    try process.run(); process.waitUntilExit()
                    guard process.terminationStatus == 0 else { throw SelfTestError.capture }
                }
                try await capture("pending")
                store.setWriteLock(true)
                let preview = try await session.previewWrite(rows: [], playlists: true)
                guard preview.report.historyWritten.count == 1, try Data(contentsOf: database) == before else {
                    log("실패: 미리 보기·DB 불변"); exit(1)
                }
                let report = try await session.writeDrafts(preview.writableBatch, to: session.target)
                guard report.historyWritten.count == 1, store.pendingHistories.isEmpty,
                      let id = report.historyWritten.first?.historyID, store.histories.contains(where: { $0.id == id }),
                      let backup = session.writeBackups().first(where: \.isWrite) else {
                    log("실패: 쓰기·다시 읽기·보존 표시"); exit(1)
                }
                store.sidebar = .history(id)
                try await capture("written")
                _ = try await session.restoreBackup(backup, to: session.target)
                store.setWriteLock(false)
                guard store.pendingHistoryIDs == [archive.id], try Data(contentsOf: database) == before,
                      archiveStore.load().histories.count == 1 else {
                    log("실패: 복원·재대기·보존본 유지"); exit(1)
                }
                store.sidebar = .history(archive.id)
                try await capture("restored")
                log("히스토리 시험 통과: 미리 보기 1/1 · 쓰기 1/1 · 다시 읽기 1/1 · 복원 1/1 · 재대기 1/1")
                exit(0)
            } catch { log("실패: \(error)"); exit(1) }
        }
    }

    private enum SelfTestError: Error { case capture, databaseMismatch, invalidStartup }
}
#endif
