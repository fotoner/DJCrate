import DJCApplication
import DJCDomain
import Foundation
import Synchronization
import Testing

/// 라이브 쓰기 전 확인(`djc compat`)의 순서: 앱 버전 → 사본 구조 → 변경 카운터. 확인한 줄은 하나씩 알리고, 막히면 그 자리에서 멈춘다(알린 줄은 남는다).
@Suite("rekordbox 쓰기 전 확인")
struct CompatibilityCheckTests {
    struct Failure: Error, Equatable { let step: String }

    /// 가짜 rekordbox·사본. 막을 단계와 부른 차례를 적는다
    final class World: Sendable {
        struct State {
            var failAt: String?
            var counters: (local: Int?, cloud: Int?) = (5, 3)
            var calls: [String] = []
        }
        let state = Mutex(State())

        func fail(_ step: String) throws {
            try state.withLock { state in
                state.calls.append(step)
                if state.failAt == step { throw Failure(step: step) }
            }
        }

        var ports: CompatibilityPorts {
            CompatibilityPorts(
                installedAppVersion: { "7.2.18" }, verifiedAppVersions: ["7.2"],
                checkApp: { _ in try self.fail("app") }, databaseVersion: "6000",
                openSnapshot: { database in
                    try self.fail("open \(database?.lastPathComponent ?? "-")")
                    return CompatibilitySnapshot(fileName: "snapshot.db", checkSchema: { try self.fail("schema") },
                                                 updateCounters: {
                                                     try self.fail("counters")
                                                     return self.state.withLock { $0.counters }
                                                 },
                                                 close: { self.state.withLock { $0.calls.append("close") } })
                },
                checkCounters: { local, cloud in try self.fail("check \(local) \(cloud.map(String.init) ?? "-")") })
        }
    }

    func run(_ world: World, database: URL? = URL(filePath: "/tmp/djc-compat/copy.db")) -> ([CompatibilityCheck.Finding], Failure?) {
        var findings: [CompatibilityCheck.Finding] = []
        do {
            try CompatibilityCheck(ports: world.ports).run(database: database) { findings.append($0) }
            return (findings, nil)
        } catch {
            return (findings, error as? Failure)
        }
    }

    @Test func 확인한_것을_차례로_알리고_카운터까지_본다() {
        let world = World()
        let (findings, failure) = run(world)
        #expect(failure == nil)
        #expect(findings == [.app(installed: "7.2.18", verified: ["7.2"]), .schema(databaseVersion: "6000", file: "snapshot.db"),
                             .counters(local: 5, cloud: 3)])
        #expect(world.state.withLock { $0.calls } == ["app", "open copy.db", "schema", "counters", "check 5 3", "close"])
    }

    @Test func 앱_버전이_막히면_버전_줄만_알리고_사본을_열지_않는다() {
        let world = World()
        world.state.withLock { $0.failAt = "app" }
        let (findings, failure) = run(world)
        #expect(failure == Failure(step: "app"))
        #expect(findings == [.app(installed: "7.2.18", verified: ["7.2"])])
        #expect(world.state.withLock { $0.calls } == ["app"])
    }

    @Test func 구조가_다르면_사본을_닫고_구조_줄을_알리지_않는다() {
        let world = World()
        world.state.withLock { $0.failAt = "schema" }
        let (findings, failure) = run(world, database: nil)
        #expect(failure == Failure(step: "schema"))
        #expect(findings.count == 1)
        #expect(world.state.withLock { $0.calls } == ["app", "open -", "schema", "close"])
    }

    @Test func 로컬_카운터가_없으면_카운터_판정을_하지_않는다() {
        let world = World()
        world.state.withLock { $0.counters = (nil, 3) }
        let (findings, failure) = run(world)
        #expect(failure == nil && findings.last == .counters(local: nil, cloud: 3))
        #expect(!world.state.withLock { $0.calls }.contains { $0.hasPrefix("check") })
    }
}
