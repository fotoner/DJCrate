import DJCDomain
import Foundation
import RekordboxKit
import Synchronization

/// SQLCipher를 프로세스에서 처음 쓰는 순간의 동시 열기 실험(#154).
enum CipherLab {
    static let all: [Command] = [
        Command("cipher-cold-open", "[--threads N]",
                "새 프로세스에서 스레드 N개가 동시에 처음으로 새 DB를 열어 키 설정이 실패한 스레드 수를 센다(임시 폴더에만 쓴다). 실패가 있으면 종료 코드 1",
                CipherLab.coldOpen),
    ]

    /// 모든 스레드가 같은 순간에 출발하게 하는 신호
    private final class Start: Sendable {
        let go = Atomic<Bool>(false)
    }

    /// 프로세스에서 SQLCipher를 처음 부르는 스레드들이 서로 겹치면, 전역 초기화가 끝나기 전에 들어온 스레드가 `PRAGMA key`에서
    /// 실패한다. 이 명령은 그 상황을 새 프로세스에서 만든다(시험이 여러 번 불러서 확인한다).
    static func coldOpen(_ args: [String]) async throws {
        let threads = max(2, Int(value(after: "--threads", in: args) ?? "") ?? 32)
        let messages = try openConcurrently(threads: threads)
        if let first = messages.first {
            print("열기 실패 \(messages.count)/\(threads): \(first)")
            exit(1)
        }
        print("열기 성공 \(threads)/\(threads)")
    }

    /// 스레드를 막고 기다리므로 async 밖에서 돌린다. 실패한 스레드의 오류 문구를 돌려준다.
    private static func openConcurrently(threads: Int) throws -> [String] {
        let key = try RekordboxKey.derive()
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appending(path: "djc-cold-open-\(UUID().uuidString)")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }

        let ready = DispatchSemaphore(value: 0)
        let start = Start()
        let group = DispatchGroup()
        let failures = Mutex<[String]>([])
        for index in 0..<threads {
            group.enter()
            let thread = Thread {
                defer { group.leave() }
                let path = directory.appending(path: "master-\(index).db").path
                let created = FileManager.default.createFile(atPath: path, contents: nil)
                ready.signal()
                while !start.go.load(ordering: .acquiring) {}
                do {
                    guard created else { throw DJCError.databaseOpenFailed(path: path, message: "파일을 만들지 못했습니다") }
                    let db = try CipherDatabase(path: path, key: key, writable: true)
                    db.close()
                } catch {
                    failures.withLock { $0.append(redacted("\(error)")) }
                }
            }
            thread.qualityOfService = .userInteractive
            thread.start()
        }
        for _ in 0..<threads { ready.wait() }
        start.go.store(true, ordering: .releasing)
        group.wait()
        return failures.withLock { $0 }
    }

    /// 오류 문구에 들어 있는 키(16진수 32자 이상)는 로그에 남기지 않는다.
    private static func redacted(_ text: String) -> String {
        text.replacingOccurrences(of: "[0-9a-fA-F]{32,}", with: "…", options: .regularExpression)
            .replacingOccurrences(of: "\n", with: " ")
    }
}
