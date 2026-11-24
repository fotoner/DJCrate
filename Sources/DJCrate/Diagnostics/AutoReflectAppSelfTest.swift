#if DEBUG
import AppKit
import AVFoundation
import DJCAdapters
import DJCApplication
import DJCDomain
import Foundation
import RekordboxKit

/// 자동 저장 사본 자가 테스트(`--auto-reflect-selftest=<save|two-process|kill-detect>`, R18). 디버그 빌드에서 사본에만 자동 저장하는 유일한 예외다.
/// 조립 지점이 쓰기 전 확인(대상·`DJC_HOME`이 임시 폴더 아래, 실제 폴더와 겹치지 않음, 사본의 분석 폴더가 링크가 아님)을 채웠을 때만 엔진이
/// 자가 테스트 실행이 된다. 아니면 종료 코드 2다. 픽스처는 `AutoReflectFixtureCapture`가 만든다(`--db`는 주지 않는다).
/// - `save`(R1·R21): 연속 사인 곡을 덱에서 틀어 둔 채 그 곡의 평점을 열 번 바꾼다. 앱의 자동 저장 엔진이 저장할 때마다 다시 읽은 사본 DB 값을 보고,
///   그동안 덱 재생이 멈추지 않고 창 덮개가 뜨지 않으며 곡 믹서 출력에서 신호가 끊긴 구간이 0인지 본다
/// - `two-process`(R9): 자식 프로세스(다른 `DJC_HOME`)가 커밋 직후에서 쓰기 잠금을 쥔 채 멈춘 동안 이 프로세스의 자동 저장은 잠금 보류로 기다리고,
///   자식이 끝난 뒤에 쓴다. 두 편집이 모두 사본 DB에 남는다
/// - `kill-detect`(R11): 자식 프로세스가 커밋 직후에서 멈추면 그 PID를 강제 종료한다. 다시 켠 자식이 시작 판정에서 중단으로 보고 기록으로 복원한 뒤,
///   사본 DB가 그 쓰기 전과 같고 쓰기 기록·준비 폴더가 남지 않는지 본다
/// 세 경우 모두 자가 테스트 전후로 사용자 환경설정이 같은지 본다. 끝은 `_exit`로 한다: 뒤에서 도는 SQLCipher 열기와 프로세스 정리(`exit`)가 겹쳐
/// 가끔 죽는 일을 피한다. 결과는 표준 오류의 "[자동 저장 시험]" 줄이다.
///
/// `save`에 `DJC_AUTO_REFLECT_E1=<회차>`를 주면 소리 대신 출시 관문 측정(E1)을 한다: 사본에 K행(큐·그리드·재생 목록) 묶음을 그 회차만큼 자동 저장 단계로 쓰고
/// "마지막 재확인부터 그 단계 끝까지"의 최댓값과 "커밋부터 마지막 파일 단계까지"를 잰다(숫자만 남긴다).
@MainActor
enum AutoReflectAppSelfTest {
    /// 자식 프로세스의 역할(부모가 정한다)
    enum Role: String {
        /// 붙잡는 관문으로 자동 저장 한 번을 직접 쓰고 커밋 직후에서 멈춘다
        case writer
        /// 다시 켠 앱: 시작 판정에서 중단을 보고 기록으로 복원한다
        case detect
    }

    static let roleKey = "DJC_AUTO_REFLECT_ROLE"
    static let trackKey = "DJC_AUTO_REFLECT_TRACK"
    static let ratingKey = "DJC_AUTO_REFLECT_RATING"
    static let e1Key = "DJC_AUTO_REFLECT_E1"
    static let pausedName = "auto-reflect-paused"
    static let resumeName = "auto-reflect-resume"

    /// 앱을 조립하기 전에 거절할 이유(없으면 nil). 조립(활동 기록·설정·초안 저장소)이 사용자 폴더를 건드리기 전에 본다:
    /// 인자의 경우를 알고, `DJC_REKORDBOX_DIR`·`DJC_HOME`을 함께 주고, 실행 조건 판정이 자가 테스트 실행이어야 한다(임시 폴더·겹침·링크, `--db` 없음)
    static func startupRefusal(arguments: [String], environment: [String: String]) -> String? {
        guard AutoReflectSelfTest.isRequested(arguments: arguments) else { return nil }
        guard AutoReflectSelfTest.requested(arguments: arguments) != nil else {
            return "경우를 모릅니다. save·two-process·kill-detect 가운데 하나를 주세요"
        }
        guard environment["DJC_REKORDBOX_DIR"]?.isEmpty == false, environment["DJC_HOME"]?.isEmpty == false else {
            return "DJC_REKORDBOX_DIR(임시 사본)과 DJC_HOME(임시 폴더)을 함께 주세요"
        }
        let location = LibraryLocation.resolve(arguments: arguments, environment: environment)
        guard case .selfTest = AutoReflectionRun.decide(AppComposition.autoReflectionFacts(arguments: arguments, environment: environment,
                                                                                           location: location)) else {
            return "쓰기 전 확인을 채우지 못했습니다. 사본과 DJC_HOME을 임시 폴더 아래에 두고, 분석 폴더는 링크 없이 복사하고, --db는 빼세요"
        }
        // 다른 개발용 인자는 함께 주지 않는다: 그 인자가 사용자 환경설정에 쓸 수 있다(예: --sheet의 보기 모드, 컨실 2라운드 K).
        // ⌘Q 저장 자가 테스트(--quit-wait-selftest)만 함께 돈다. AppKit 인자(-NS…)는 상관하지 않는다
        let companions: Set<String> = ["--quit-wait-selftest"]
        if let other = arguments.dropFirst().first(where: { $0.hasPrefix("--") && !AutoReflectSelfTest.isRequested(arguments: ["", $0]) && !companions.contains($0) }) {
            return "다른 개발용 인자(\(other))와 함께 돌리지 않습니다. 그 인자를 빼고 다시 띄우세요"
        }
        return nil
    }

    static func runIfRequested(store: LibraryStore, deck: DeckModel, reflection: ReflectionCoordinator) {
        // ⌘Q 저장 자가 테스트(`--quit-wait-selftest`와 함께 준 실행)는 그 시험이 맡는다
        guard DiagnosticRun.isAutoReflectSelfTest(), !QuitWaitSelfTest.isRequested else { return }
        let env = ProcessInfo.processInfo.environment
        guard let test = AutoReflectSelfTest.requested(arguments: ProcessInfo.processInfo.arguments) else {
            log("경우를 모릅니다. save·two-process·kill-detect 가운데 하나를 주세요"); finish(2)
        }
        guard let engine = reflection.engine, engine.run == .selfTest(test) else {
            log("쓰기 전 확인을 채우지 못해 자동 저장하지 않는 실행입니다(\(String(describing: reflection.engine?.run))). "
                + "DJC_REKORDBOX_DIR·DJC_HOME을 임시 폴더 아래 사본으로 주고 --db는 빼세요")
            finish(2)
        }
        let preferences = PreferencesProbe()
        let role = env[roleKey].flatMap(Role.init(rawValue:))
        // SwiftUI의 사이드바 분할 보기는 칸 크기를 스스로 환경설정에 남긴다(창 크기가 사용자와 다르면 값이 바뀐다). 이 실행에서는 남기지 않는다
        stopSplitViewAutosave()
        Task {
            var code: Int32
            switch (test, role) {
            case (_, .writer?): code = await runWriter(store: store, reflection: reflection, test: test)
            case (.killDetect, .detect?): code = await runDetect(store: store, engine: engine)
            case (.save, nil):
                if let rounds = env[e1Key].flatMap(Int.init) {
                    code = await runE1(store: store, reflection: reflection, rounds: max(1, rounds))
                } else {
                    code = await runSave(store: store, deck: deck, engine: engine)
                }
            case (.twoProcess, nil): code = await runTwoProcess(store: store, engine: engine)
            case (.killDetect, nil): code = await runKillDetect(store: store, reflection: reflection)
            default:
                log("이 경우에 없는 역할입니다: \(env[roleKey] ?? "-")")
                code = 2
            }
            let changed = preferences.changedKeys()
            if changed.isEmpty {
                log("통과: 자가 테스트 전후로 사용자 환경설정이 같다")
            } else {
                log("실패: 자가 테스트가 사용자 환경설정을 바꿨다(키 \(changed.count)개: \(changed.prefix(8).joined(separator: ", ")))")
                if code == 0 { code = 1 }
            }
            log(code == 0 ? "자동 저장 시험 통과(\(test.rawValue)\(role.map { "·\($0.rawValue)" } ?? ""))" : "실패로 끝남(종료 코드 \(code))")
            finish(code)
        }
    }

    // MARK: - save(R1·R21)

    private static func runSave(store: LibraryStore, deck: DeckModel, engine: AutoReflection) async -> Int32 {
        var failures = 0
        func check(_ ok: Bool, _ text: String) {
            if !ok { failures += 1 }
            log("\(ok ? "통과" : "실패"): \(text)")
        }
        guard await loadLibrary(store) else { return 1 }
        guard let row = store.rows.first(where: { $0.title == "자동 저장 소리 시험" }) else {
            log("픽스처 곡이 없습니다(AutoReflectFixtureCapture로 만든 사본을 주세요)"); return 2
        }
        let uuid = row.track.uuid
        store.loadToDeck(row)
        guard await until(60, { deck.row?.track.uuid == uuid && deck.canPlay }) else { log("덱에 곡을 올리지 못했습니다"); return 1 }
        guard let audio = deck.audio as? DeckAudio, await until(10, { audio.isOutputReady }) else { log("오디오 출력을 준비하지 못했습니다"); return 1 }
        // 곡 믹서 출력(속도 변환 전)을 받는다. 스피커는 음소거된다
        deck.volume = 1
        let probe = AudioGapProbe()
        audio.debugCaptureTrackTimed(AudioGapProbe.handler(probe))
        deck.togglePlay()
        guard await until(10, { deck.isPlaying }) else { log("재생을 시작하지 못했습니다"); return 1 }
        await sleep(1)
        probe.mark(playhead: deck.currentTime)
        var stopped = 0, overlays = 0
        var rating = store.rowsByUUID[uuid]?.track.rating ?? 0
        let writesBefore = engine.autoWrites
        for index in 1...10 {
            rating = rating >= 5 ? 1 : rating + 1
            guard let current = store.rowsByUUID[uuid] else { log("곡을 잃었습니다"); return 1 }
            store.tags.setTag(.rating, "\(rating)", rows: [current])
            let expected = rating
            // 저장 완료 상태: 엔진이 썼고, 다시 읽은 사본 DB 값이 그 값이고, 초안이 정리됐고, 칩이 저장됨이다
            let saved = await until(120) {
                if !deck.isPlaying { stopped += 1 }
                if store.showsWriteOverlay { overlays += 1 }
                return engine.autoWrites >= writesBefore + index && store.rowsByUUID[uuid]?.track.rating == expected
                    && store.tagDrafts[uuid] == nil && settled(engine) && !store.libraryBusy
            }
            check(saved, "\(index)번째 자동 저장: 다시 읽은 사본 DB 평점 \(store.rowsByUUID[uuid]?.track.rating ?? -1)(기대 \(expected)) · 자동 저장 \(engine.autoWrites - writesBefore)회 · 칩 \(engine.status)")
            if !saved { break }
        }
        probe.mark(playhead: deck.currentTime)
        deck.togglePlay()
        let result = probe.analyze()
        check(stopped == 0, "자동 저장하는 동안 덱 재생이 멈추지 않았다(멈춤을 본 횟수 \(stopped))")
        check(overlays == 0, "자동 저장하는 동안 창 덮개가 뜨지 않았다(본 횟수 \(overlays))")
        log(String(format: "곡 믹서 출력: %.1f초 · 10ms 구간 %d개 · 중앙 RMS %.4f · 끊긴 구간 %d개 · 가장 긴 버퍼 간격 %.3f초 · 받은 시간/벽시계 %.3f · 받은 시간/재생 위치 %.3f · 누적 부족분 범위 %.3f초 · 경계 간격 %.3f초",
                   result.seconds, result.windows, result.medianRMS, result.quietWindows, result.longestArrivalGap, result.wallCoverage,
                   result.playheadCoverage, result.deficitRange, result.boundaryGap))
        let problems = result.problems
        check(problems.isEmpty, "곡 믹서 출력에서 신호가 끊긴 구간이 0이다\(problems.isEmpty ? "" : "(\(problems.joined(separator: " · ")))")")
        return failures == 0 ? 0 : 1
    }

    // MARK: - two-process(R9)

    private static func runTwoProcess(store: LibraryStore, engine: AutoReflection) async -> Int32 {
        var failures = 0
        func check(_ ok: Bool, _ text: String) {
            if !ok { failures += 1 }
            log("\(ok ? "통과" : "실패"): \(text)")
        }
        guard await loadLibrary(store) else { return 1 }
        guard let mine = store.rows.first(where: { $0.title == "자동 저장 시험 둘" }),
              let theirs = store.rows.first(where: { $0.title == "자동 저장 시험 셋" }) else {
            log("픽스처 곡이 없습니다(AutoReflectFixtureCapture로 만든 사본을 주세요)"); return 2
        }
        let myRating = mine.track.rating == 4 ? 5 : 4, theirRating = theirs.track.rating == 2 ? 3 : 2
        guard let home = childHome("two-process") else { return 1 }
        let child: Process
        do { child = try spawn(.writer, home: home, track: theirs.track.uuid, rating: theirRating) } catch {
            log("자식 프로세스를 띄우지 못했습니다: \(error)"); return 1
        }
        defer { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }
        let paused = home.appending(path: pausedName)
        guard await until(180, { FileManager.default.fileExists(atPath: paused.path) || !child.isRunning }), child.isRunning else {
            log("자식이 쓰기 중간에 이르지 못했습니다"); return 1
        }
        log("자식(PID \(child.processIdentifier))이 커밋 직후에서 쓰기 잠금을 쥔 채 멈췄다")
        store.tags.setTag(.rating, "\(myRating)", rows: [store.rowsByUUID[mine.track.uuid] ?? mine])
        // 이 프로세스의 자동 저장은 잠금을 잡지 못해 쓰지 않고 기다린다(비차단 시도 → 잠금 보류)
        let held = await until(120) { engine.conditions.holds.contains(.lockBusy) || engine.status == .held(.lockBusy) }
        check(held, "다른 프로세스가 쓰는 동안 자동 저장이 잠금 보류로 기다린다(칩 \(engine.status))")
        check(engine.autoWrites == 0, "그동안 이 프로세스는 쓰지 않았다(자동 저장 \(engine.autoWrites)회)")
        await sleep(2)
        check(engine.autoWrites == 0 && child.isRunning, "잠금을 쥔 동안 계속 쓰지 않았다")
        FileManager.default.createFile(atPath: home.appending(path: resumeName).path, contents: Data())
        guard await until(120, { !child.isRunning }) else { log("자식이 끝나지 않았습니다"); return 1 }
        check(child.terminationReason == .exit && child.terminationStatus == 0, "자식이 자기 쓰기를 마쳤다(종료 코드 \(child.terminationStatus))")
        let wrote = await until(120) {
            engine.autoWrites >= 1 && store.rowsByUUID[mine.track.uuid]?.track.rating == myRating && settled(engine) && !store.libraryBusy
        }
        check(wrote, "자식이 끝난 뒤 이 프로세스가 썼다(자동 저장 \(engine.autoWrites)회 · 칩 \(engine.status))")
        check(store.rowsByUUID[theirs.track.uuid]?.track.rating == theirRating,
              "두 프로세스의 편집이 모두 사본 DB에 남았다(내 평점 \(store.rowsByUUID[mine.track.uuid]?.track.rating ?? -1)·자식 평점 \(store.rowsByUUID[theirs.track.uuid]?.track.rating ?? -1))")
        return failures == 0 ? 0 : 1
    }

    // MARK: - kill-detect(R11)

    private static func runKillDetect(store: LibraryStore, reflection: ReflectionCoordinator) async -> Int32 {
        var failures = 0
        func check(_ ok: Bool, _ text: String) {
            if !ok { failures += 1 }
            log("\(ok ? "통과" : "실패"): \(text)")
        }
        // 이 프로세스는 지켜보기만 한다(기록을 판정·정리하지 않게 엔진을 멈춘다)
        reflection.engine?.stop()
        guard await loadLibrary(store) else { return 1 }
        guard let row = store.rows.first(where: { $0.title == "자동 저장 시험 셋" }) else {
            log("픽스처 곡이 없습니다(AutoReflectFixtureCapture로 만든 사본을 주세요)"); return 2
        }
        let original = row.track.rating, written = original == 2 ? 3 : 2
        guard let home = childHome("kill-detect") else { return 1 }
        let writer: Process
        do { writer = try spawn(.writer, home: home, track: row.track.uuid, rating: written) } catch {
            log("자식 프로세스를 띄우지 못했습니다: \(error)"); return 1
        }
        defer { if writer.isRunning { kill(writer.processIdentifier, SIGKILL) } }
        guard await until(180, { FileManager.default.fileExists(atPath: home.appending(path: pausedName).path) || !writer.isRunning }),
              writer.isRunning else {
            log("자식이 쓰기 중간에 이르지 못했습니다"); return 1
        }
        let database = store.rekordboxDatabase
        let journal = database.deletingLastPathComponent().appending(path: database.lastPathComponent + ".djc-write")
        check(FileManager.default.fileExists(atPath: journal.path), "커밋 직후 쓰기 기록이 있다")
        // 띄운 자식 PID만 강제 종료한다
        kill(writer.processIdentifier, SIGKILL)
        guard await until(30, { !writer.isRunning }) else { log("자식이 끝나지 않았습니다"); return 1 }
        check(writer.terminationReason == .uncaughtSignal && writer.terminationStatus == SIGKILL,
              "자식이 쓰다가 강제 종료됐다(신호 \(writer.terminationStatus))")
        check(FileManager.default.fileExists(atPath: journal.path), "강제 종료 뒤 쓰기 기록이 남았다")
        // 같은 DJC_HOME으로 다시 켠다: 시작 판정이 중단으로 보고 기록으로 복원한다
        let detector: Process
        do { detector = try spawn(.detect, home: home, track: row.track.uuid, rating: original) } catch {
            log("다시 켠 앱을 띄우지 못했습니다: \(error)"); return 1
        }
        defer { if detector.isRunning { kill(detector.processIdentifier, SIGKILL) } }
        guard await until(240, { !detector.isRunning }) else { log("다시 켠 앱이 끝나지 않았습니다"); return 1 }
        check(detector.terminationReason == .exit && detector.terminationStatus == 0,
              "다시 켠 앱이 중단을 보고 기록으로 복원했다(종료 코드 \(detector.terminationStatus))")
        check(!FileManager.default.fileExists(atPath: journal.path), "복원 뒤 쓰기 기록이 남지 않았다")
        check(stagingLeft(database: database, share: store.shareRoot).isEmpty, "복원 뒤 준비 폴더가 남지 않았다")
        return failures == 0 ? 0 : 1
    }

    /// 다시 켠 앱(자식): 엔진이 시작 판정에서 중단으로 보고, 기록으로 복원하면 사본 DB가 그 쓰기 전과 같다
    private static func runDetect(store: LibraryStore, engine: AutoReflection) async -> Int32 {
        var failures = 0
        func check(_ ok: Bool, _ text: String) {
            if !ok { failures += 1 }
            log("\(ok ? "통과" : "실패"): \(text)")
        }
        let env = ProcessInfo.processInfo.environment
        guard let uuid = env[trackKey], let original = env[ratingKey].flatMap(Int.init) else { log("곡·평점을 받지 못했습니다"); return 2 }
        let interrupted = await until(120) { engine.status == .interrupted(recoveryFailed: false) }
        check(interrupted, "다시 켠 앱의 시작 판정이 중단이다(칩 \(engine.status))")
        guard interrupted else { return 1 }
        guard await loadLibrary(store) else { return 1 }
        // 상태 줄 [기록으로 복원…]과 같은 흐름. 확인 창만 자가 테스트가 확인한다
        let coordinator = AppComposition.reflection(store: store, prompter: AutoConfirmPrompter())
        coordinator.engine = engine
        await coordinator.restoreJournal()
        let database = store.rekordboxDatabase
        let journal = database.deletingLastPathComponent().appending(path: database.lastPathComponent + ".djc-write")
        check(!FileManager.default.fileExists(atPath: journal.path), "기록으로 복원한 뒤 쓰기 기록이 없다")
        let restored = await until(120) { store.rowsByUUID[uuid]?.track.rating == original && !store.isLoading }
        check(restored, "사본 DB가 그 쓰기 전과 같다(평점 \(store.rowsByUUID[uuid]?.track.rating ?? -1), 기대 \(original))")
        check(await until(30) { if case .interrupted = engine.status { false } else { true } }, "복원 뒤 중단이 풀렸다(칩 \(engine.status))")
        check(stagingLeft(database: database, share: store.shareRoot).isEmpty, "준비 폴더가 남지 않았다")
        return failures == 0 ? 0 : 1
    }

    // MARK: - 자식: 붙잡는 관문으로 자동 저장 한 번

    /// 이 프로세스의 엔진은 멈추고(쓰지 않게), 붙잡는 관문을 끼운 반영 세션으로 엔진과 같은 자동 쓰기 단계(`autoWrite`)를 한 번 한다.
    /// 커밋 직후(`after(.commit)`)에서 표시 파일을 만들고 멈춘다. 부모가 다시 가라는 파일을 두면 이어서 끝낸다(강제 종료 시험은 그 전에 죽는다)
    private static func runWriter(store: LibraryStore, reflection: ReflectionCoordinator, test: AutoReflectSelfTest) async -> Int32 {
        // 이 프로세스의 엔진이 훅 없는 관문으로 먼저 쓰지 않게 가장 먼저 멈춘다
        reflection.engine?.stop()
        let env = ProcessInfo.processInfo.environment
        guard let uuid = env[trackKey], let rating = env[ratingKey], let homePath = env["DJC_HOME"] else { log("곡·평점을 받지 못했습니다"); return 2 }
        guard await loadLibrary(store), let row = store.rowsByUUID[uuid] else { log("곡을 찾지 못했습니다"); return 1 }
        store.tags.setTag(.rating, rating, rows: [row])
        let home = URL(filePath: homePath)
        let paused = home.appending(path: pausedName), resume = home.appending(path: resumeName)
        var writeGuard = RekordboxWriteGuard.system
        writeGuard.hooks = RekordboxWriteHooks(checkpoint: { moment in
            guard moment == .after(.commit) else { return }
            FileManager.default.createFile(atPath: paused.path, contents: Data())
            // 부모가 다시 가라고 하거나(두 프로세스) 이 PID를 강제 종료할 때까지(강제 종료) 잠금을 쥔 채 기다린다. 부모가 사라져도 5분 뒤에는 이어 간다
            for _ in 0..<6000 where !FileManager.default.fileExists(atPath: resume.path) { Thread.sleep(forTimeInterval: 0.05) }
        })
        let session = AppComposition.reflection(store: store, gate: .live(guard: writeGuard), prompter: AutoConfirmPrompter()).session
        let inventory = await session.autoInventory(cancelled: [], needsConfirmation: [])
        guard let chunk = inventory.chunk(rowLimit: AutoReflectionTiming.standard.rowLimit) else { log("자동으로 쓸 묶음이 없습니다"); return 1 }
        let outcome = await session.autoWrite(chunk)
        guard case .written = outcome else { log("쓰지 못했습니다: \(outcome)"); return 1 }
        log("자식(\(test.rawValue)): 자동 저장 한 번을 끝까지 썼다")
        return 0
    }

    // MARK: - E1(출시 관문 측정)

    /// 사본에 큐·그리드·재생 목록이 섞인 K행 묶음을 엔진과 같은 자동 쓰기 단계로 `rounds`번 쓰고, 쓰기 입구의 시각 훅으로
    /// "마지막 재확인부터 그 단계 끝까지"(관문 값)와 "커밋부터 마지막 파일 단계까지"(참고값)를 잰다. 곡 수·경로는 남기지 않는다
    private static func runE1(store: LibraryStore, reflection: ReflectionCoordinator, rounds: Int) async -> Int32 {
        reflection.engine?.stop()
        guard await loadLibrary(store) else { return 1 }
        let timings = WriteTimings()
        var writeGuard = RekordboxWriteGuard.system
        // 단계 시작(`before`)도 남긴다: 시작한 파일 교체마다 재확인·완료 짝을 대조한다(컨실 2라운드 M)
        writeGuard.hooks = RekordboxWriteHooks(checkpoint: { moment in if case .before = moment { timings.add(moment, .now) } },
                                               timing: { moment, instant in timings.add(moment, instant) })
        let coordinator = AppComposition.reflection(store: store, gate: .live(guard: writeGuard), prompter: AutoConfirmPrompter())
        let session = coordinator.session, drafts = session.ports.drafts
        let rowLimit = AutoReflectionTiming.standard.rowLimit
        var gateMax: Duration = .zero, referenceMax: Duration = .zero, totalMax: Duration = .zero
        var perStep: [RekordboxWriteStep: Duration] = [:]
        for round in 1...rounds {
            // 분석 파일(.EXT 포함)이 있는 곡만 고른다(그리드 쓰기 조건, RBW-28). 회차마다 다른 곡을 쓴다
            // 큐·그리드 쓰기는 음원을 읽어 위치를 맞춘다(VBR·FLAC 탐색 정보): 이 실행에서 음원을 읽을 수 있는 곡만 고른다
            let candidates = store.rows.filter {
                !$0.isStaged && !$0.track.isStreaming && RekordboxShare.hasWaveformAnalysis($0.track.analysisDataPath, root: store.rekordboxShareRoot)
                    && FileManager.default.isReadableFile(atPath: $0.track.folderPath)
                    && store.cueDraftUUIDs.contains($0.track.uuid) == false && store.gridDraftUUIDs.contains($0.track.uuid) == false
            }
            guard candidates.count >= 200 else { log("E1: 음원을 읽을 수 있는 분석한 곡이 200곡보다 적습니다"); return 1 }
            // 회차마다 다른 곡부터 쓴다(모자라면 앞으로 돌아간다. 쓴 초안은 정리되므로 같은 곡을 다시 써도 된다)
            let offset = ((round - 1) * 200) % (candidates.count - 199)
            let picked = Array(candidates[offset..<(offset + 200)])
            let cueRows = picked[0..<80], gridRows = picked[80..<140], listRows = picked[140..<200]
            for row in cueRows {
                var draft = CueDraft(trackUUID: row.track.uuid, rekordboxCues: row.cues, newID: { UUID() })
                draft.cues.append(EditableCue(id: UUID(), kind: .memory, time: min(30, Double(row.track.lengthSeconds) / 2) + Double(round) * 0.25))
                drafts.saveCue(draft)
                store.cueDraftChanged(draft)
                store.draftChanged(trackUUID: row.track.uuid, kind: .cue, exists: true)
            }
            var grids = 0
            for row in gridRows {
                guard let url = RekordboxShare.analysisURL(row.track.analysisDataPath, root: store.rekordboxShareRoot),
                      let grid = try? BeatGrid.load(anlz: url), !grid.beats.isEmpty else { continue }
                var draft = GridDraft(trackUUID: row.track.uuid, grid: grid)
                draft.segments = draft.segments.map { GridSegment(start: $0.start + 0.005, bpm: $0.bpm, firstBeatNumber: $0.firstBeatNumber) }
                drafts.saveGrid(draft)
                store.draftChanged(trackUUID: row.track.uuid, kind: .grid, exists: true)
                grids += 1
            }
            _ = store.playlists.createPlaylist(isFolder: false, in: PlaylistLayout.root, name: "E1 측정 \(round)", tracks: Array(listRows))
            await BlockingWork.run { drafts.flush() }
            let inventory = await session.autoInventory(cancelled: [], needsConfirmation: [])
            guard let chunk = inventory.chunk(rowLimit: rowLimit) else { log("E1: 자동으로 쓸 묶음이 없습니다"); return 1 }
            if round == 1 {
                // 첫 회차만: 잴 구간 밖에서 미리 보아 막히는 이유를 남긴다(곡 이름·경로 없이 이유 글만)
                store.setWriteLock(true)
                if let preview = try? await session.previewWrite(rows: Array(picked), playlists: true) {
                    let report = preview.report
                    let reasons = Set((report.blocked + report.gridBlocked).compactMap(\.reason)).sorted().prefix(6)
                    log("E1 미리 보기: 큐 씀 \(report.written.count)·막힘 \(report.blocked.count) · 그리드 씀 \(report.gridWritten.count)·막힘 \(report.gridBlocked.count) · 이유: \(reasons.joined(separator: " / "))")
                }
                store.setWriteLock(false)
                log("E1 나눈 묶음: 곡 \(chunk.tracks.count)·재생 목록 단계 \(chunk.playlistSteps) · 남은 편집 \(inventory.leftoverCount(rowLimit: rowLimit))")
            }
            timings.reset()
            let started = ContinuousClock.now
            let outcome = await session.autoWrite(chunk)
            let total = ContinuousClock.now - started
            guard case let .written(report, unwritten) = outcome else { log("E1: 쓰지 못했습니다: \(outcome)"); return 1 }
            // 막힌 이유(곡 이름·경로 없이 이유 글만, 같은 이유는 한 번)
            let reasons = Set((report.blocked + report.gridBlocked).compactMap(\.reason)).sorted().prefix(6)
            log("E1 \(round)회 막힘: 큐 \(report.blocked.count)·그리드 \(report.gridBlocked.count)·쓰지 않은 판 \(unwritten.count) · 이유: \(reasons.joined(separator: " / "))")
            // 실제로 쓴 행: 큐·그리드를 쓴 곡과 다 쓴 재생 목록 단계의 행
            let stepRows = inventory.steps.filter { step in step.revision.map { chunk.stepRevisions.contains($0) } ?? false }.reduce(0) { $0 + $1.rows }
            let rows = report.written.count + report.gridWritten.count + (report.playlistWritten.count == chunk.playlistSteps ? stepRows : 0)
            if let problem = E1Measurement.mixedBatchProblem(cues: report.written.count, grids: report.gridWritten.count,
                                                             playlistStepsWritten: report.playlistWritten.count,
                                                             playlistStepsPlanned: chunk.playlistSteps, rows: rows, rowLimit: rowLimit) {
                log("E1 \(round)회 실패: \(problem)")
                return 1
            }
            guard let measured = timings.measure() else {
                log("E1 \(round)회 실패: 필수 측정 구간(커밋·파일 교체의 재확인 → 단계 끝 짝)이 없다")
                return 1
            }
            gateMax = max(gateMax, measured.gate)
            referenceMax = max(referenceMax, measured.reference)
            totalMax = max(totalMax, total)
            for (step, value) in measured.perStep { perStep[step] = max(perStep[step] ?? .zero, value) }
            log("E1 \(round)회: 쓴 묶음 \(rows)행(큐 \(report.written.count)·그리드 \(report.gridWritten.count)/\(grids)·재생 목록 \(report.playlistWritten.count)단계) · "
                + "재확인→단계 끝 최댓값 \(seconds(measured.gate)) · 커밋 완료→마지막 파일 단계 완료 \(seconds(measured.reference)) · 쓰기 전체 \(seconds(total))")
            _ = await until(300) { !store.libraryBusy && !store.isLoading }
        }
        log("E1 결과(\(rounds)회): 관문 값(재확인→단계 끝 최댓값) \(seconds(gateMax)) · 참고값(커밋 완료→마지막 파일 단계 완료 최댓값) \(seconds(referenceMax)) · 쓰기 전체 최댓값 \(seconds(totalMax))")
        log("E1 단계별 최댓값: " + perStep.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue) \(seconds($0.value))" }.joined(separator: " · "))
        let code = E1Measurement.exitCode(gate: gateMax)
        log("E1 관문(2×E1 < E2′ 최솟값 2.154초): \(code == 0 ? "통과" : "넘지 못함")")
        return code
    }

    // MARK: - 도움

    /// 저장 완료 상태: 쓰는 중이 아니고 자동으로 쓸 편집이 남지 않았다(저장됨, 또는 자동 저장하지 않는 편집만 남음)
    private static func settled(_ engine: AutoReflection) -> Bool {
        if engine.isWriting { return false }
        switch engine.status {
        case .saved, .leftover: return true
        default: return false
        }
    }

    /// 쓰기 입구가 넘긴 시각(재확인·단계 끝)을 모은다. 훅은 쓰는 스레드에서 불린다
    final class WriteTimings: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [(RekordboxWriteMoment, ContinuousClock.Instant)] = []

        func add(_ moment: RekordboxWriteMoment, _ instant: ContinuousClock.Instant) { lock.withLock { events.append((moment, instant)) } }
        func reset() { lock.withLock { events = [] } }

        func measure() -> E1Measurement? { E1Measurement.measure(lock.withLock { events }) }
    }

    /// 쓰기 한 번의 E1 값. 필수 구간(커밋과 파일 교체 하나 이상의 "재확인 → 그 단계 끝" 짝)이 없으면 만들지 않는다.
    /// 시작한 파일 교체(`before`)마다 그 앞의 재확인과 뒤의 완료가 모두 있어야 한다: 하나라도 빠지면 그 회를 받지 않는다(컨실 2라운드 M)
    struct E1Measurement: Equatable {
        /// 관문 값: 단계 끝마다 그 단계의 마지막 재확인부터 잰 값의 최댓값
        var gate: Duration
        /// 참고값: 커밋 완료부터 마지막 파일 단계 완료까지
        var reference: Duration
        var perStep: [RekordboxWriteStep: Duration]

        static func measure(_ events: [(RekordboxWriteMoment, ContinuousClock.Instant)]) -> Self? {
            var lastRecheck: [RekordboxWriteStep: ContinuousClock.Instant] = [:]
            var gate: Duration = .zero, perStep: [RekordboxWriteStep: Duration] = [:]
            var committed: ContinuousClock.Instant?, lastFile: ContinuousClock.Instant?
            // 파일 교체: 재확인 뒤 아직 시작하지 않음 / 시작했고 아직 끝나지 않음
            var replaceRechecked = false, replaceOpen = false, unpaired = false
            for (moment, instant) in events {
                switch moment {
                case let .recheck(step):
                    lastRecheck[step] = instant
                    if step == .fileReplace { replaceRechecked = true }
                case .before(.fileReplace):
                    if replaceOpen || !replaceRechecked { unpaired = true }
                    replaceOpen = true
                    replaceRechecked = false
                case let .after(step):
                    if step == .fileReplace {
                        if !replaceOpen { unpaired = true }
                        replaceOpen = false
                    }
                    if let start = lastRecheck[step] {
                        let window = instant - start
                        gate = max(gate, window)
                        perStep[step] = max(perStep[step] ?? .zero, window)
                    }
                    if step == .commit { committed = instant }
                    if [.fileReplace, .sidecarRemove, .databaseReplace].contains(step) { lastFile = instant }
                case .before: break
                }
            }
            // 끝에 시작으로 이어지지 않은 재확인이 남아도 받지 않는다(다음 교체의 재확인만 기록됐다, 컨실 3라운드 S)
            guard !unpaired, !replaceOpen, !replaceRechecked else { return nil }
            guard perStep[.commit] != nil, perStep[.fileReplace] != nil, let committed, let lastFile, lastFile >= committed else { return nil }
            return Self(gate: gate, reference: lastFile - committed, perStep: perStep)
        }

        /// E1 관문(2×E1이 E2′ 최솟값 2.154초보다 짧다)을 지나면 0, 넘지 못하면 1(컨실 2라운드 N)
        static func exitCode(gate: Duration) -> Int32 { gate * 2 < .milliseconds(2154) ? 0 : 1 }

        /// 실제로 쓴 결과가 큐·그리드·재생 목록이 섞인 약 K행 묶음인지. 아니면 그 까닭
        static func mixedBatchProblem(cues: Int, grids: Int, playlistStepsWritten: Int, playlistStepsPlanned: Int, rows: Int, rowLimit: Int) -> String? {
            if cues == 0 || grids == 0 || playlistStepsPlanned == 0 || playlistStepsWritten != playlistStepsPlanned {
                return "섞인 묶음이 아니다(큐 \(cues)·그리드 \(grids)·재생 목록 \(playlistStepsWritten)/\(playlistStepsPlanned)단계)"
            }
            if rows * 10 < rowLimit * 9 || rows > rowLimit { return "묶음이 약 K행이 아니다(\(rows)행, K \(rowLimit))" }
            return nil
        }
    }

    /// 곡 믹서 출력에서 신호가 끊긴 구간을 센다: 10ms 구간의 RMS가 중앙값의 30%보다 작으면 끊긴 것으로 본다(연속 사인 곡).
    /// 출력 버퍼가 오는 간격과 받은 프레임 수도 본다(엔진이 멈추면 버퍼가 오지 않는다)
    final class AudioGapProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [Float] = []
        private var windows: [Float] = []
        private var arrivals: [(time: Double, rendered: Double?, window: Int)] = []
        private var rate = 0.0
        private var marks: [(time: Double, window: Int, playhead: Double)] = []

        nonisolated static func handler(_ probe: AudioGapProbe) -> @Sendable (AVReadOnlyAudioPCMBuffer, AVAudioTime) -> Void {
            { @Sendable buffer, when in probe.record(buffer, when: when) }
        }

        /// 버퍼가 온 시각(콜백)과 렌더 시각(호스트 시각이 있으면)을 함께 남긴다: 누적 부족분은 콜백 도착 지터 없이 렌더 시각으로 잰다(컨실 3라운드 O15)
        nonisolated func record(_ buffer: AVReadOnlyAudioPCMBuffer, when: AVAudioTime) {
            guard case let .float(samples) = buffer.channelData(0) else { return }
            let count = Int(buffer.frameLength), now = ProcessInfo.processInfo.systemUptime
            let rendered: Double? = when.isHostTimeValid ? AVAudioTime.seconds(forHostTime: when.hostTime) : nil
            lock.withLock {
                rate = buffer.format.sampleRate
                let size = max(1, Int(rate / 100))
                for index in 0..<count { pending.append(samples[index]) }
                while pending.count >= size {
                    var sum: Float = 0
                    for index in 0..<size { sum += pending[index] * pending[index] }
                    windows.append((sum / Float(size)).squareRoot())
                    pending.removeFirst(size)
                }
                arrivals.append((now, rendered, windows.count))
            }
        }

        /// 잴 구간의 시작·끝 표시. 덱의 재생 위치(초)도 함께 남겨, 받은 샘플이 재생이 나아간 만큼인지 대조한다
        func mark(playhead: Double) {
            lock.withLock { marks.append((ProcessInfo.processInfo.systemUptime, windows.count, playhead)) }
        }

        func analyze() -> AudioContinuity {
            lock.withLock {
                guard marks.count >= 2, marks[1].window >= marks[0].window, rate > 0 else { return .measure(windows: [], arrivals: [], seconds: 0, playheadAdvance: 0) }
                // 시각은 측정 시작 표식에서 잰다(표식과 첫·마지막 버퍼 사이 간격도 본다, 컨실 3라운드 R)
                let start = marks[0].window, begin = marks[0].time
                let inside = arrivals.filter { $0.time >= marks[0].time && $0.time <= marks[1].time }
                    .map { AudioContinuity.Arrival(time: $0.time - begin, received: Double($0.window - start) / 100, rendered: $0.rendered) }
                return .measure(windows: Array(windows[marks[0].window..<marks[1].window]), arrivals: inside, seconds: marks[1].time - marks[0].time,
                                playheadAdvance: marks[1].playhead - marks[0].playhead)
            }
        }
    }

    /// 곡 믹서 출력의 끊김 판정(연속 사인 곡, R21). 10ms 구간의 RMS로 본다
    /// - 신호 세기: 중앙 RMS가 `minimumRMS`보다 작으면 무음이라 통과하지 않는다
    /// - 끊긴 구간: RMS가 중앙값의 30%(그리고 최소 세기의 30%)보다 작은 구간
    /// - 빠진 샘플: 받은 시간이 벽시계로 지난 시간과, 덱 재생 위치가 나아간 시간과 5% 넘게 다르면 끊긴 것이다. 버퍼가 0.25초 넘게 오지 않아도 같다
    /// - 누적 부족분: 버퍼가 올 때마다 "지난 시간 − 받은 소리"를 구한다. 그 범위가 0.1초(버퍼 하나 + 지터)를 넘으면 끊긴 것이다.
    ///   짧은 멈춤이 여러 번 쌓여 위 두 기준을 지나는 경우를 잡는다(컨실 2라운드 L). 지난 시간은 버퍼의 렌더 시각으로 잰다(콜백 도착 지터를 빼다, 3라운드 O15)
    /// - 경계: 측정 시작 표식부터 첫 버퍼, 마지막 버퍼부터 끝 표식까지도 버퍼 간격으로 본다. 0.1초를 넘으면 끊긴 것이다
    ///   (끝 직전에 끊겨 그 뒤 버퍼 없이 측정이 닫힌 경우, 3라운드 R). 시각은 시작 표식에서 잰 초다
    struct AudioContinuity: Equatable {
        static let minimumRMS: Float = 0.05
        static let maximumDeficitRange = 0.1
        var seconds: Double
        var windows: Int
        var medianRMS: Float
        var quietWindows: Int
        var longestArrivalGap: Double
        var wallCoverage: Double
        var playheadCoverage: Double
        /// 누적 부족분(지난 시간 − 받은 소리)의 범위(초)
        var deficitRange: Double
        /// 측정 시작 표식 → 첫 버퍼, 마지막 버퍼 → 끝 표식 가운데 긴 쪽(초)
        var boundaryGap: Double

        /// 출력 버퍼 하나가 온 때(벽시계 초)와 그때까지 받은 소리(초)
        struct Arrival: Equatable, Sendable {
            var time: Double
            var received: Double
            /// 버퍼의 렌더 시각(초, 호스트 시각). 없으면 누적 부족분도 `time`으로 잰다
            var rendered: Double? = nil
        }

        static func measure(windows: [Float], arrivals: [Arrival], seconds: Double, playheadAdvance: Double) -> Self {
            let median = windows.isEmpty ? 0 : windows.sorted()[windows.count / 2]
            let threshold = max(median, minimumRMS) * 0.3
            let received = Double(windows.count) / 100
            let times = arrivals.map(\.time)
            let boundary = max(times.first ?? .infinity, seconds - (times.last ?? 0))
            let longest = (zip(times, times.dropFirst()).map { $1 - $0 } + [boundary]).max() ?? .infinity
            let clock = arrivals.map { $0.rendered ?? $0.time }
            let deficits = zip(clock, arrivals).map { ($0 - (clock.first ?? 0)) - ($1.received - (arrivals.first?.received ?? 0)) }
            return Self(seconds: seconds, windows: windows.count, medianRMS: median, quietWindows: windows.filter { $0 < threshold }.count,
                        longestArrivalGap: longest, wallCoverage: seconds > 0 ? received / seconds : 0,
                        playheadCoverage: playheadAdvance > 0 ? received / playheadAdvance : 0,
                        deficitRange: (deficits.max() ?? 0) - (deficits.min() ?? 0), boundaryGap: boundary)
        }

        /// 통과하지 못한 까닭(없으면 통과)
        var problems: [String] {
            var problems: [String] = []
            if windows < 1000 { problems.append("들은 시간이 짧다(10ms 구간 \(windows)개)") }
            if medianRMS < Self.minimumRMS { problems.append(String(format: "신호가 약하다(중앙 RMS %.4f)", medianRMS)) }
            if quietWindows > 0 { problems.append("끊긴 10ms 구간 \(quietWindows)개") }
            if !(longestArrivalGap < 0.25) { problems.append(String(format: "출력 버퍼가 %.3f초 동안 오지 않았다", longestArrivalGap)) }
            if abs(wallCoverage - 1) >= 0.05 { problems.append(String(format: "받은 시간/벽시계 %.3f", wallCoverage)) }
            if abs(playheadCoverage - 1) >= 0.05 { problems.append(String(format: "받은 시간/재생 위치 %.3f(빠진 샘플)", playheadCoverage)) }
            if !(deficitRange <= Self.maximumDeficitRange) {
                problems.append(String(format: "받은 소리가 벽시계보다 누적 %.3f초 모자랐다(짧은 끊김이 쌓임)", deficitRange))
            }
            if !(boundaryGap <= Self.maximumDeficitRange) {
                problems.append(String(format: "측정 경계에서 %.3f초 동안 버퍼가 없었다(측정 끝 직전·시작 직후 끊김)", boundaryGap))
            }
            return problems
        }
    }

    /// 자가 테스트 전후의 사용자 환경설정(이 앱의 영역). 바뀐 키 이름만 돌려준다(값은 남기지 않는다)
    struct PreferencesProbe: @unchecked Sendable {
        let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        let before: [String: Any]

        init() { before = UserDefaults.standard.persistentDomain(forName: domain) ?? [:] }

        func changedKeys() -> [String] {
            let after = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
            return Set(before.keys).union(after.keys).filter { key in
                switch (before[key], after[key]) {
                case (nil, nil): false
                case let (old?, new?): !(old as AnyObject).isEqual(new)
                default: true
                }
            }.sorted()
        }
    }

    /// 창 안 분할 보기의 칸 크기 자동 저장을 끈다. 분할 보기가 늦게 만들어질 수 있어 처음 몇 초 동안 몇 번 더 본다
    static func stopSplitViewAutosave() {
        func pass() { NSApp.windows.forEach { ViewPreferences.stopSplitViewAutosave(in: $0) } }
        pass()
        Task { @MainActor in
            for delay in [0.05, 0.2, 0.5, 1, 2, 4] {
                try? await Task.sleep(for: .seconds(delay))
                pass()
            }
        }
    }

    /// 확인 창을 띄우지 않고 늘 확인한다
    final class AutoConfirmPrompter: HeadlessReflectionPrompter {
        func show(_ prompt: ReflectionPrompt) -> Bool { true }
    }

    /// 자식 프로세스: 같은 실행 파일·인자, 다른 `DJC_HOME`과 역할
    private static func spawn(_ role: Role, home: URL, track: String, rating: Int) throws -> Process {
        let process = Process()
        process.executableURL = Bundle.main.executableURL ?? URL(filePath: CommandLine.arguments[0])
        process.arguments = Array(ProcessInfo.processInfo.arguments.dropFirst())
        var env = ProcessInfo.processInfo.environment
        env["DJC_HOME"] = home.path
        env[roleKey] = role.rawValue
        env[trackKey] = track
        env[ratingKey] = "\(rating)"
        process.environment = env
        try process.run()
        log("자식(\(role.rawValue)) PID \(process.processIdentifier)를 띄웠다")
        return process
    }

    /// 자식의 `DJC_HOME`: 이 실행의 `DJC_HOME` 아래(임시 폴더 아래라야 자식도 자가 테스트 실행이 된다)
    private static func childHome(_ name: String) -> URL? {
        guard let home = ProcessInfo.processInfo.environment["DJC_HOME"], !home.isEmpty else { return nil }
        let url = URL(filePath: home).appending(path: "child-\(name)")
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        } catch {
            log("자식 폴더를 만들지 못했습니다: \(error)")
            return nil
        }
    }

    /// 남은 준비 폴더(`.djc-staging`, DB 폴더와 분석 루트)
    private static func stagingLeft(database: URL, share: URL) -> [URL] {
        [database.deletingLastPathComponent(), share].map { $0.appending(path: ".djc-staging") }
            .filter { folder in
                ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).isEmpty == false
            }
    }

    /// 진단 실행은 스스로 읽지 않는다: 사본을 떠서 읽는다
    private static func loadLibrary(_ store: LibraryStore) async -> Bool {
        func loaded() -> Bool { if case .loaded = store.phase { !store.rows.isEmpty } else { false } }
        for _ in 0..<50 { if loaded() || store.isLoading { break }; await sleep(0.1) }
        if !loaded(), !store.isLoading { await store.takeSnapshot() }
        let ok = await until(120) { loaded() && !store.isLoading }
        if !ok { log("라이브러리를 읽지 못했습니다") }
        return ok
    }

    private static func until(_ seconds: Double, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return true }
            await sleep(0.05)
        }
        return condition()
    }

    private static func sleep(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

    private static func seconds(_ duration: Duration) -> String {
        String(format: "%.3f초", Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
    }

    static func log(_ text: String) {
        FileHandle.standardError.write(Data("[자동 저장 시험] \(text)\n".utf8))
    }

    /// 끝낸다. `exit`는 프로세스 정리(정적 소멸자·atexit)를 돌려 뒤에서 도는 SQLCipher 열기와 겹치면 가끔 죽는다: 출력만 비우고 바로 끝낸다
    static func finish(_ code: Int32) -> Never {
        fflush(stdout)
        fflush(stderr)
        _exit(code)
    }
}
#endif
