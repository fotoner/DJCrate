@testable import DJCrate
import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import Synchronization
import Testing

/// 저장된 읽기 사본이 없는 첫 실행(#299): 일반 실행은 단추 없이 바로 읽고, 자가 테스트·측정·캡처 실행은 지금처럼 읽지 않는다.
/// 사본 뜨기는 가짜라 실제 rekordbox 폴더를 읽지 않는다. 사본·초안 폴더는 임시 폴더다.
@MainActor
@Suite("첫 실행 읽기")
struct FirstRunReadTests {
    struct NoRekordbox: Error {}

    /// 사본 뜨기가 불린 횟수
    final class Calls: Sendable {
        private let value = Mutex(0)
        func add() { value.withLock { $0 += 1 } }
        var count: Int { value.withLock { $0 } }
    }

    /// 임시 `DJC_HOME`·`DJC_REKORDBOX_DIR`로 연 저장소(저장된 사본 없음). `takeLiveSnapshot`이 불린 횟수를 함께 돌려준다
    static func store(launch: LibraryLaunchOptions, home: TemporaryFolder, rekordbox: TemporaryFolder,
                      error: any Error = NoRekordbox()) -> (LibraryStore, Calls) {
        let calls = Calls()
        let store = LibraryStore.test(
            activityLog: ActivityLog(url: nil),
            environment: ["DJC_HOME": home.url.path, "DJC_REKORDBOX_DIR": rekordbox.url.path],
            takeLiveSnapshot: { _ in calls.add(); throw error },
            launch: launch)
        return (store, calls)
    }

    @Test func 일반_실행은_저장된_사본이_없으면_바로_사본을_뜬다() async throws {
        let home = try TemporaryFolder(), rekordbox = try TemporaryFolder()
        let (store, calls) = Self.store(launch: LibraryLaunchOptions(), home: home, rekordbox: rekordbox)

        await store.loadInitial()

        #expect(calls.count == 1)
        // 뜨지 못했으니 "사본이 없습니다"가 아니라 실패 화면이다
        guard case .failed = store.phase else {
            Issue.record("사본 뜨기에 실패했는데 실패 화면이 아니다: \(store.phase)")
            return
        }
    }

    @Test func 진단_실행은_저장된_사본이_없어도_자동으로_읽지_않는다() async throws {
        let home = try TemporaryFolder(), rekordbox = try TemporaryFolder()
        let (store, calls) = Self.store(launch: LibraryLaunchOptions(isDiagnosticRun: true), home: home, rekordbox: rekordbox)

        await store.loadInitial()

        #expect(calls.count == 0)
        guard case .idle = store.phase else {
            Issue.record("읽지 않았는데 .idle이 아니다: \(store.phase)")
            return
        }
    }

    @Test func 진단_실행_인자로_띄우면_진단_실행으로_본다() {
        #expect(LibraryLaunchOptions(arguments: ["djcrate", "--agent-tools-capture=/tmp/x"]).isDiagnosticRun)
        #expect(!LibraryLaunchOptions(arguments: ["djcrate"]).isDiagnosticRun)
    }

    @Test func 진단_실행도_첫_실행_읽기_인자를_주면_바로_읽는다() {
        let capture = ["djcrate", "--agent-tools-capture=/tmp/x"]
        #expect(!LibraryLaunchOptions(arguments: capture).readsOnFirstRun)
        #expect(LibraryLaunchOptions(arguments: capture + ["--first-run-read"]).readsOnFirstRun)
        #expect(LibraryLaunchOptions(arguments: ["djcrate"]).readsOnFirstRun)
    }

    @Test func 첫_실행_읽기_인자를_준_진단_실행은_사본이_없으면_바로_사본을_뜬다() async throws {
        let home = try TemporaryFolder(), rekordbox = try TemporaryFolder()
        let launch = LibraryLaunchOptions(arguments: ["djcrate", "--agent-tools-capture=/tmp/x", "--first-run-read"])
        let (store, calls) = Self.store(launch: launch, home: home, rekordbox: rekordbox)

        await store.loadInitial()

        #expect(calls.count == 1)
    }

    @Test func 파일이_없어_뜨지_못하면_라이브러리를_찾지_못했다고_알린다() async throws {
        let home = try TemporaryFolder(), rekordbox = try TemporaryFolder()
        let (store, _) = Self.store(launch: LibraryLaunchOptions(), home: home, rekordbox: rekordbox, error: CocoaError(.fileReadNoSuchFile))

        await store.loadInitial()

        #expect(store.lastReadFailure?.cause == .libraryMissing)
        if case let .failed(message) = store.phase {
            #expect(message == "rekordbox 라이브러리를 찾지 못했습니다. rekordbox 7을 설치하고 한 번 실행한 뒤 다시 찾아 주세요")
        } else {
            Issue.record("실패 화면이 아니다: \(store.phase)")
        }
    }

    @Test func 실패_화면의_다시_시도는_새_사본을_뜬다() async throws {
        let home = try TemporaryFolder(), rekordbox = try TemporaryFolder()
        let (store, calls) = Self.store(launch: LibraryLaunchOptions(), home: home, rekordbox: rekordbox)
        await store.loadInitial()

        await store.retryLoad()

        // 처음 열기에서 한 번, 다시 시도에서 한 번 — "사본이 없습니다"로 돌아가지 않는다
        #expect(calls.count == 2)
        guard case .failed = store.phase else {
            Issue.record("다시 시도 뒤 실패 화면이 아니다: \(store.phase)")
            return
        }
    }

    @Test func 원인_분류_없는_실패_화면은_이전_실패의_원인을_끌고_오지_않는다() async throws {
        let home = try TemporaryFolder(), rekordbox = try TemporaryFolder()
        let (store, _) = Self.store(launch: LibraryLaunchOptions(), home: home, rekordbox: rekordbox, error: CocoaError(.fileReadNoSuchFile))
        await store.loadInitial()
        #expect(store.lastReadFailure?.cause == .libraryMissing)

        // 사본을 뜨지 않은 이유처럼 원인 분류 없이 실패 화면으로 가는 길
        store.showUnclassifiedFailure("사본을 뜨지 않았습니다")

        #expect(store.lastReadFailure == nil)
        if case let .failed(message) = store.phase { #expect(message == "사본을 뜨지 않았습니다") } else { Issue.record("실패 화면이 아니다") }
    }

    /// 늘 보이는 표시는 상태 줄의 「rekordbox에 쓸 수 없음」 칩이 맡으므로(#327) 창 알림은 띄우지 않고 활동 기록에만 경고로 남긴다
    @Test func 지원하지_않는_rekordbox_버전은_창_알림을_띄우지_않고_활동_기록에_경고로_남긴다() throws {
        let home = try TemporaryFolder(), rekordbox = try TemporaryFolder()
        let (store, _) = Self.store(launch: LibraryLaunchOptions(), home: home, rekordbox: rekordbox)

        store.readScreen.apply(.unsupportedRekordbox("7.3.1"))

        #expect(store.toast == nil)
        let entry = try #require(store.activityLog.entries.first)
        #expect(entry.kind == .warning)
        #expect(entry.title == "이 rekordbox 버전(7.3)은 아직 지원하지 않습니다")
        #expect(entry.detail == "읽기만 하고 rekordbox에 쓰기는 막혀 있습니다")
        // 지금 목록은 실패 화면으로 바뀌지 않는다
        guard case .idle = store.phase else {
            Issue.record("알림만 띄워야 하는데 화면이 바뀌었다: \(store.phase)")
            return
        }
    }

    @Test func DJC_HOME만_주고_사본_rekordbox_폴더가_없으면_실제_라이브러리를_자동으로_읽지_않는다() {
        let home = ["DJC_HOME": "/tmp/x"]
        #expect(!LibraryLaunchOptions(arguments: ["djcrate"], environment: home).readsOnFirstRun)
        #expect(!LibraryLaunchOptions(arguments: ["djcrate", "--first-run-read"], environment: home).readsOnFirstRun)
        #expect(LibraryLaunchOptions(arguments: ["djcrate"], environment: home.merging(["DJC_REKORDBOX_DIR": "/tmp/y"]) { $1 }).readsOnFirstRun)
        #expect(LibraryLaunchOptions(arguments: ["djcrate"], environment: [:]).readsOnFirstRun)
    }
}
