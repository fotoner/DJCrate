@testable import DJCrate
import DJCAdapters
import DJCApplication
import AppKit
import DJCDomain
import DJCStorage
import Foundation
import RekordboxFixtures
import RekordboxKit
import SwiftUI
import Testing

/// 막힌 초안 복구 시트(#232). 곡·종류·재생 목록을 한 시트의 줄로 보고 줄마다 고른 뒤 한 번에 저장해도,
/// 같은 선택을 예전 연속 창 흐름(`LegacyRecoveryFlow`)으로 한 것과 같은 초안 상태가 되어야 한다.
@MainActor
@Suite("막힌 초안 복구 시트", .serialized)
struct RecoverySheetTests {
    typealias Target = RecoveryScenario.Target

    /// 줄마다 고른 것. 큐 대상을 다시 지정해야 하는 줄(C 큐)의 "내 편집 유지"는 현재 큐를 이어 준 것으로 본다.
    struct Plan: CustomTestStringConvertible {
        var name: String
        var choices: [Target: RecoveryChoice]
        var testDescription: String { name }

        static let mixed = Plan(name: "줄마다 다르게", choices: [
            .draft("A", .tags): .keep, .draft("A", .cues): .useCurrent, .draft("B", .tags): .later, .draft("B", .grid): .keep,
            .draft("C", .cues): .keep, .playlist("P1"): .keep, .playlist("P2"): .useCurrent,
        ])
        static let opposite = Plan(name: "반대로", choices: [
            .draft("A", .tags): .useCurrent, .draft("A", .cues): .keep, .draft("B", .tags): .keep, .draft("B", .grid): .useCurrent,
            .draft("C", .cues): .useCurrent, .playlist("P1"): .useCurrent, .playlist("P2"): .keep,
        ])
    }

    func model(_ scenario: RecoveryScenario, _ targets: [Target] = RecoveryScenario.allTargets) -> RecoverySheetModel {
        RecoverySheetModel(host: scenario.store, requests: targets.map { Self.request(scenario, $0) },
                           dependencies: .init())
    }

    static func request(_ scenario: RecoveryScenario, _ target: Target) -> RecoveryRequest {
        switch target {
        case let .draft(name, kind): .draft(scenario.rows[name]!, kind)
        case let .playlist(id): .playlist(id)
        }
    }

    func line(_ model: RecoverySheetModel, _ scenario: RecoveryScenario, _ target: Target) throws -> RecoveryLine {
        let id = Self.request(scenario, target).id
        return try #require(model.lines.first { $0.id == id }, "줄이 없음: \(target.label)")
    }

    /// 시트에서 계획대로 고른다(대상을 다시 지정해야 하는 줄은 후보를 이어 준다).
    func apply(_ plan: Plan, to model: RecoverySheetModel, _ scenario: RecoveryScenario) throws {
        for target in RecoveryScenario.allTargets {
            let line = try line(model, scenario, target)
            let choice = try #require(plan.choices[target])
            if choice == .keep, let mapping = line.cueMapping {
                for old in mapping.missing {
                    let candidate = try #require(mapping.candidates.first)
                    model.mapCue(old.sourceID!, to: candidate.sourceID, in: line)
                }
            }
            model.choose(choice, for: line)
            #expect(line.choice == choice, "고르지 못함: \(target.label) \(choice)")
        }
    }

    // MARK: - 지금 흐름과 같은 결과

    /// 두 계획이 줄마다 내 편집 유지·현재값 쓰기를 한 번씩 고른다. 나중에는 `.mixed`의 B 태그 줄, 나중에만 고른 시트는
    /// 저장 자체가 막힌다(`save`는 `canSave`를 먼저 본다, `나중에만_고르면_저장할_수_없다`).
    @Test(arguments: [Plan.mixed, .opposite])
    func 줄마다_다르게_고른_결과가_연속_창_흐름과_같다(plan: Plan) async throws {
        let legacy = try await RecoveryScenario.make(), sheet = try await RecoveryScenario.make()
        let initial = sheet.outcome()
        #expect(legacy.outcome() == initial, "시작 상태가 다름: \(legacy.differences(legacy.outcome(), initial))")

        for target in RecoveryScenario.allTargets {
            guard case let .draft(name, kind) = target else { continue }
            try await LegacyRecoveryFlow.recoverDraft(legacy, row: name, kind: kind, choice: try #require(plan.choices[target]))
        }
        try await LegacyRecoveryFlow.recoverPlaylists(legacy, choices: [("P1", try #require(plan.choices[.playlist("P1")])), ("P2", try #require(plan.choices[.playlist("P2")]))])

        let model = model(sheet)
        await model.load()
        #expect(model.lines.count == 7 && model.lines.allSatisfy { $0.phase == .ready })
        try apply(plan, to: model, sheet)
        let saved = await model.save()
        let failures = model.lines.compactMap { line -> String? in
            if case let .failed(reason) = line.phase { "\(line.title) \(line.kindLabel): \(reason)" } else { nil }
        }
        #expect(failures.isEmpty, "저장하지 못한 줄: \(failures)")
        #expect(saved)

        #expect(sheet.outcome() == legacy.outcome(), "결과가 다름: \(sheet.differences(sheet.outcome(), legacy.outcome()))")
        #expect(sheet.outcome() != initial, "고른 줄은 초안이 바뀌어야 한다")
        #expect(model.isClosed)
    }

    // MARK: - 줄과 기본 선택

    @Test func 한_곡_한_종류만_고른_진입은_그_줄만_든_시트다() async throws {
        let scenario = try await RecoveryScenario.make()
        let model = model(scenario, [.draft("A", .tags)])
        await model.load()
        #expect(model.lines.count == 1)
        let line = try line(model, scenario, .draft("A", .tags))
        #expect(line.title == scenario.rows["A"]?.title && line.kindLabel == DraftRecoveryKind.tags.label && line.phase == .ready)
    }

    @Test func 합칠_수_있는_줄은_내_편집_유지가_처음_골라져_있고_합칠_수_없는_줄은_나중에다() async throws {
        let scenario = try await RecoveryScenario.make()
        let model = model(scenario)
        await model.load()
        for target in RecoveryScenario.allTargets where target != .draft("C", .cues) {
            let line = try line(model, scenario, target)
            #expect(line.choice == .keep && line.options == [.keep, .useCurrent, .later], "\(target.label)")
        }
        let blocked = try line(model, scenario, .draft("C", .cues))
        #expect(blocked.choice == .later && blocked.options == [.useCurrent, .later])
        #expect(blocked.keepBlockedReason != nil && blocked.cueMapping?.missing.count == 1)
    }

    @Test func 큐_대상을_모두_이어야_내_편집_유지를_고를_수_있다() async throws {
        let scenario = try await RecoveryScenario.make()
        let target = Target.draft("C", .cues)
        let model = model(scenario, [target])
        await model.load()
        let line = try line(model, scenario, target)
        let mapping = try #require(line.cueMapping)
        let old = try #require(mapping.missing.first?.sourceID)
        #expect(mapping.candidates.compactMap(\.sourceID) == ["cue-c-new"])
        model.choose(.keep, for: line)
        #expect(line.choice == .later, "대상을 잇기 전에는 고를 수 없다")
        model.mapCue(old, to: "cue-c-new", in: line)
        #expect(line.options.contains(.keep) && line.choice == .keep)
        #expect(line.details.contains("직접 지정한 큐 대응:"))
        model.mapCue(old, to: nil, in: line)
        #expect(!line.options.contains(.keep) && line.choice == .later)
        // 후보가 아닌 큐로는 이을 수 없다
        model.mapCue(old, to: "없는 큐", in: line)
        #expect(!line.options.contains(.keep))
        let outcome = scenario.outcome()
        #expect(outcome.cues["C"] == nil, "고르는 동안 초안을 바꾸지 않는다")
    }

    @Test func 줄마다_무엇이_바뀌었는지_한_줄로_보인다() async throws {
        let scenario = try await RecoveryScenario.make()
        let model = model(scenario)
        await model.load()
        func summary(_ target: Target) throws -> String { try line(model, scenario, target).summary }
        #expect(try summary(.draft("A", .tags)).contains("제목") && summary(.draft("A", .tags)).contains("코멘트"))
        #expect(try summary(.draft("A", .cues)) == "rekordbox에서 바뀐 큐: 변경 1")
        #expect(try summary(.draft("B", .tags)).contains("장르") && summary(.draft("B", .tags)).contains("아티스트"))
        #expect(try summary(.draft("B", .grid)) == "rekordbox에서 바뀐 그리드: 120.00 → 160.00 BPM")
        #expect(try summary(.draft("C", .cues)) == "rekordbox에서 바뀐 큐: 추가 1 · 삭제 1")
        #expect(try summary(.playlist("P1")).contains("‘합성 목록 하나’ → ‘외부 이름 하나’"))
        #expect(try line(model, scenario, .playlist("P2")).title == "외부 이름 둘" && line(model, scenario, .playlist("P2")).kindLabel == "재생 목록")
    }

    // MARK: - 저장·취소

    @Test func 취소하면_아무것도_바꾸지_않는다() async throws {
        let scenario = try await RecoveryScenario.make()
        let initial = scenario.outcome()
        let model = model(scenario)
        await model.load()
        try apply(.mixed, to: model, scenario)
        model.cancel()
        #expect(model.isClosed && scenario.outcome() == initial)
        await model.waitUntilClosed()
        let saved = await model.save()
        #expect(!saved && scenario.outcome() == initial, "닫은 시트는 저장하지 않는다")
    }

    @Test func 한_줄이_저장에_실패해도_다른_줄은_저장하고_실패한_줄은_초안을_남긴다() async throws {
        let scenario = try await RecoveryScenario.make()
        let targets: [Target] = [.draft("A", .tags), .draft("B", .grid)]
        let model = model(scenario, targets)
        await model.load()
        let before = try #require(scenario.store.tagDrafts[RecoveryScenario.uuid("A")])
        // 비교하는 사이 rekordbox에서 A의 제목이 또 바뀌었다
        try scenario.fixture.execute("UPDATE djmdContent SET Title = '또 바뀐 제목' WHERE ID = '91'")
        let saved = await model.save()
        #expect(!saved && !model.isClosed)
        #expect(scenario.store.toast?.kind == .warning, "일부만 저장했으면 성공으로 알리지 않는다")
        guard case let .failed(reason) = try line(model, scenario, targets[0]).phase else {
            Issue.record("실패한 줄이 실패로 보이지 않음"); return
        }
        // 저장 실패 이유는 무엇을 하면 되는지까지 한 문장이고, 일반 안내가 겹쳐 붙지 않는다.
        if case let .writeRefused(refusal) = scenario.store.recoveryChangedError() { #expect(reason == refusal) }
        #expect(scenario.store.tagDrafts[RecoveryScenario.uuid("A")] == before)
        #expect(try line(model, scenario, targets[1]).phase == .saved)
        #expect(scenario.outcome().grids["B"] != nil, "다른 줄은 저장했다")
        #expect(!model.canSave)
    }

    @Test func 나중에만_고르면_저장할_수_없다() async throws {
        let scenario = try await RecoveryScenario.make()
        let model = model(scenario, [.draft("A", .tags)])
        await model.load()
        #expect(model.canSave)
        model.choose(.later, for: try line(model, scenario, .draft("A", .tags)))
        #expect(!model.canSave)
    }

    // MARK: - 진입

    @Test func 쓰기_결과의_막힌_초안은_창_없이_시트_하나에_줄로_모인다() async throws {
        let scenario = try await RecoveryScenario.make()
        let prompter = ScriptedPrompter()
        prompter.onReview = { model in
            for line in model.lines { model.choose(line.options.contains(.keep) ? .keep : .later, for: line) }
            _ = await model.save()
        }
        let requests = RecoveryScenario.allTargets.map { Self.request(scenario, $0) }
        await ReflectionCoordinator.test(store: scenario.store, prompter: prompter).recover(requests: requests)
        #expect(prompter.shown.isEmpty, "연속 창이 뜨면 안 된다")
        #expect(prompter.reviewed.count == 1 && prompter.reviewed[0].lines.count == 7)
        #expect(scenario.store.toast?.kind == .success)
        #expect(scenario.store.recoverySheet == nil)
    }

    @Test func 쓰기_결과의_줄은_막힌_곡의_복구할_종류와_막힌_재생_목록이다() async throws {
        let scenario = try await RecoveryScenario.make()
        let targets = ["A", "B", "C"].compactMap { scenario.rows[$0] }
        let all = Dictionary(uniqueKeysWithValues: targets.map { ($0.track.uuid, Set(DraftRecoveryKind.allCases)) })
        let ids = ReflectionCoordinator.recoveryRequests(store: scenario.store, targets: targets, blocked: .init(kinds: all, playlists: true)).map(\.id)
        #expect(ids == RecoveryScenario.allTargets.map { Self.request(scenario, $0).id })
        let tracksOnly = ReflectionCoordinator.recoveryRequests(store: scenario.store, targets: targets, blocked: .init(kinds: all, playlists: false))
        #expect(tracksOnly.count == 5)
        // 미리 보기에서 막히지 않은 종류와 곡은 줄이 되지 않는다.
        let a = try #require(scenario.rows["A"])
        let onlyCues = ReflectionCoordinator.recoveryRequests(store: scenario.store, targets: targets, blocked: .init(kinds: [a.track.uuid: [.cues]], playlists: false))
        #expect(onlyCues.map(\.id) == [Self.request(scenario, .draft("A", .cues)).id])
        #expect(ReflectionCoordinator.recoveryRequests(store: scenario.store, targets: [], blocked: .init(kinds: all, playlists: false)).isEmpty)
    }

    // MARK: - 쓰기에서 열리는 시트(#232 리뷰)

    /// 쓰기 미리 보기가 읽는 초안은 파일이라, 시험 폴더(DJC_HOME)에 남겼다가 지운다.
    @Test(.enabled(if: LiveDraftHome.isIsolated))
    func 쓰기에서_시트는_rekordbox가_바뀌어_막힌_줄만_연다() async throws {
        let scenario = try await RecoveryScenario.make(withHalfAnalysedTrack: true)
        try scenario.saveDraftFiles()
        defer { scenario.removeDraftFiles() }
        let rows = ["A", "B", "C", "D"].compactMap { scenario.rows[$0] }
        let prompter = ScriptedPrompter()
        await ReflectionCoordinator.test(store: scenario.store, prompter: prompter).write(rows: rows, playlists: false)
        #expect(prompter.shown.isEmpty, "연속 창이 뜨면 안 된다")
        // D의 그리드는 기준이 지금과 같고 반쪽 분석이라 막힌 것이다. 시트에는 rekordbox가 바뀌어 막힌 줄만 든다.
        let expected: [Target] = [.draft("A", .tags), .draft("A", .cues), .draft("B", .tags), .draft("B", .grid), .draft("C", .cues)]
        #expect(prompter.reviewed.first?.lines.map(\.id) == expected.map { Self.request(scenario, $0).id })
        // 다른 이유로 막힌 곡의 이유는 결과(토스트·결과 보기)에 남는다.
        let result = try #require(scenario.store.resultHistory.latest)
        #expect(result.text.contains("합성 곡 D"), "막힌 이유가 결과에 없음: \(result.text)")
    }

    @Test(.enabled(if: LiveDraftHome.isIsolated))
    func 쓰기에서_다른_이유로만_막혔으면_시트를_열지_않고_이유를_결과에_남긴다() async throws {
        let scenario = try await RecoveryScenario.make(withHalfAnalysedTrack: true)
        try scenario.saveDraftFiles()
        defer { scenario.removeDraftFiles() }
        let prompter = ScriptedPrompter()
        await ReflectionCoordinator.test(store: scenario.store, prompter: prompter)
            .write(rows: [try #require(scenario.rows["D"])], playlists: false)
        #expect(prompter.reviewed.isEmpty && prompter.shown.isEmpty && scenario.store.recoverySheet == nil)
        let result = try #require(scenario.store.resultHistory.latest)
        #expect(result.text.contains("합성 곡 D") && scenario.store.toast != nil)
    }

    @Test func 기준이_지금과_같은_줄은_바뀌었다고_알리지_않고_나중에가_처음_골라져_있다() async throws {
        let scenario = try await RecoveryScenario.make(withHalfAnalysedTrack: true)
        let target = Target.draft("D", .grid)
        let model = RecoverySheetModel(host: scenario.store, requests: [Self.request(scenario, target)], dependencies: .init())
        await model.load()
        let line = try #require(model.lines.first)
        #expect(line.phase == .ready && !line.isStale)
        #expect(!line.summary.contains("바뀌"), "바뀌지 않았는데 바뀌었다고 알림: \(line.summary)")
        #expect(line.choice == .later && line.options == [.useCurrent, .later] && line.keepBlockedReason != nil)
        // 바뀐 줄은 그대로 바뀐 줄이다.
        let stale = RecoverySheetModel(host: scenario.store, requests: [Self.request(scenario, .draft("B", .grid))], dependencies: .init())
        await stale.load()
        #expect(stale.lines.first?.isStale == true)
    }

    // MARK: - 줄·저장 경계(#232 리뷰)

    @Test func 같은_곡이_대상에_두_번_있어도_줄은_하나다() async throws {
        let scenario = try await RecoveryScenario.make()
        let a = try #require(scenario.rows["A"])
        let ids = ReflectionCoordinator.recoveryRequests(store: scenario.store, targets: [a, a], blocked: .init(kinds: [a.track.uuid: [.tags, .cues]], playlists: false)).map(\.id)
        #expect(ids == [Self.request(scenario, .draft("A", .tags)).id, Self.request(scenario, .draft("A", .cues)).id])
        let model = RecoverySheetModel(host: scenario.store, requests: [.draft(a, .tags), .draft(a, .tags)], dependencies: .init())
        #expect(model.lines.count == 1)
    }

    @Test func 둘째_저장에서도_재생_목록_줄은_앞_줄이_바꾼_초안을_다시_비교해_적용한다() async throws {
        let scenario = try await RecoveryScenario.make()
        let tags = Target.draft("A", .tags), first = Target.playlist("P1"), second = Target.playlist("P2")
        // A 태그는 저장에 실패하고(저장 폴더 권한), P1만 저장한다(P2는 나중에). 합성 사본의 곡 정보는 그대로 둔다(재생 목록 비교가 곡 정보를 읽는다).
        let model = RecoverySheetModel(host: scenario.store, requests: [tags, first, second].map { Self.request(scenario, $0) },
                                       dependencies: .init(save: { draft in
                                           if case .tags = draft { throw CocoaError(.fileWriteNoPermission) }
                                       }))
        await model.load()
        model.choose(.later, for: try line(model, scenario, second))
        let firstSave = await model.save()
        let p1 = try line(model, scenario, first), p2 = try line(model, scenario, second)
        #expect(!firstSave && !model.isClosed && p1.phase == .saved && p2.phase == .ready)
        // 이어서 P2도 저장한다: P1을 저장하며 초안이 바뀌었어도 다시 비교해 적용한다.
        model.choose(.keep, for: p2)
        let saved = await model.save()
        #expect(p2.phase == .saved, "둘째 저장에서 P2: \(p2.phase)")
        #expect(saved && !model.isClosed, "고른 줄은 모두 저장했고, 앞서 실패한 A 태그가 남아 시트는 열려 있다")
        #expect(scenario.store.blockedPlaylistEditCount == 0)
    }

    @Test func 고르는_사이_비교_내용이_바뀐_재생_목록_줄은_적용하지_않고_초안을_남긴다() async throws {
        let scenario = try await RecoveryScenario.make()
        let first = Target.playlist("P1"), second = Target.playlist("P2")
        let model = model(scenario, [first, second])
        await model.load()
        // 고르는 사이 P2의 편집이 하나 늘었다. P1은 그대로라 다시 비교해 적용하고, P2는 본 것과 다르니 적용하지 않는다.
        var changed = scenario.store.playlistDraft
        try changed.append(.addTracks(playlist: .id("P2"), contentIDs: ["91"]), rekordbox: scenario.store.rekordboxPlaylists)
        scenario.store.playlistDraft = changed
        let saved = await model.save()
        let p1 = try line(model, scenario, first), p2 = try line(model, scenario, second)
        #expect(!saved && !model.isClosed)
        #expect(p1.phase == .saved)
        guard case let .failed(reason) = p2.phase else {
            Issue.record("본 것과 달라진 줄이 적용됨"); return
        }
        #expect(reason.contains("다시 열어 확인하세요"))
        let kept = scenario.store.playlistDraft.steps.filter { $0.edit.playlist.layoutID == "P2" }
        #expect(kept.count == 2, "P2의 막힌 편집이 초안에 그대로 남아야 한다")
    }

    @Test func 현재값_사용을_고른_줄은_큐_대상을_이어도_선택이_바뀌지_않는다() async throws {
        let scenario = try await RecoveryScenario.make()
        let target = Target.draft("C", .cues)
        let model = model(scenario, [target])
        await model.load()
        let line = try line(model, scenario, target)
        let old = try #require(line.cueMapping?.missing.first?.sourceID)
        model.choose(.useCurrent, for: line)
        model.mapCue(old, to: "cue-c-new", in: line)
        #expect(line.options.contains(.keep) && line.choice == .useCurrent, "이어 주기가 고른 것을 바꿈: \(line.choice)")
        // 나중에였을 때만 내 편집 유지로 바뀐다.
        model.choose(.later, for: line)
        model.mapCue(old, to: nil, in: line)
        model.mapCue(old, to: "cue-c-new", in: line)
        #expect(line.choice == .keep)
    }

    // MARK: - 사본 읽기·입구·문구(#232 리뷰)

    @Test func 시트_하나는_줄이_여럿이어도_사본을_곡_줄과_재생_목록_줄에_한_번씩만_읽는다() async throws {
        let scenario = try await RecoveryScenario.make()
        let model = model(scenario)
        await model.load()
        #expect(scenario.store.recoverySnapshotReads == 2, "불러올 때 사본 읽기: \(scenario.store.recoverySnapshotReads)")
        try apply(.mixed, to: model, scenario)
        #expect(await model.save())
        // 저장 직전에 다시 읽는 것도 곡 줄 전체와 재생 목록 줄 전체에 한 번씩이다(재생 목록 줄을 다시 비교해도 더 읽지 않는다).
        #expect(scenario.store.recoverySnapshotReads == 4, "저장까지 사본 읽기: \(scenario.store.recoverySnapshotReads)")
    }

    @Test func 시트가_열려_있으면_쓰기_입구는_시작하지_않고_안내하고_메뉴는_막힌다() async throws {
        let scenario = try await RecoveryScenario.make()
        let store = scenario.store, a = try #require(scenario.rows["A"])
        store.selection = [a.id]
        let reflect = LibraryMenuAction.reflect, remove = LibraryMenuAction.removeTracks
        #expect(reflect.isEnabled(in: store) && remove.isEnabled(in: store), "시트가 없으면 열려 있어야 한다")
        let sheet = RecoverySheetModel(host: store, requests: [Self.request(scenario, .draft("A", .tags))], anchor: .editWindow,
                                       dependencies: .init())
        store.recoverySheet = sheet
        #expect(!reflect.isEnabled(in: store) && !remove.isEnabled(in: store) && !LibraryMenuAction.restore.isEnabled(in: store))
        #expect(reflect.disabledReason(in: store) == LibraryStore.writesBlockedBySheetReason)
        let reflection = ReflectionCoordinator.test(store: store)
        for entry in [{ reflection.startWrite(rows: [a]) }, { reflection.startAddTracks(rows: [a]) },
                      { reflection.startDeleteTracks(rows: [a]) }, { reflect.perform(in: store, reflection: reflection) }] {
            store.toast = nil
            entry()
            #expect(store.toast?.isNotice == true, "쓰지 않은 까닭을 안내한다")
            #expect(store.writeTask == nil && !store.isWritingRekordbox)
        }
        // 비교 창을 또 열려 해도 안내한다.
        store.toast = nil
        reflection.startRecovery(row: a, kind: .tags)
        #expect(store.toast?.isNotice == true && store.writeTask == nil)
        sheet.cancel()
        #expect(reflect.isEnabled(in: store) && reflect.disabledReason(in: store) == nil)
    }

    @Test func 곡_편집_창이_닫히면_그_창에_붙은_시트만_닫는다() async throws {
        let scenario = try await RecoveryScenario.make()
        let store = scenario.store
        let window = TrackEditWindow()
        let deck = DeckModel.test(audio: FakeDeckAudio(), storage: .memory(MemoryDrafts()), runsAnalysis: false)
        window.attach(EditWindowLinks(deck: deck, store: store, writer: .live(home: scenario.home), makeAudio: { EditAudioPlayer() }, showStaged: { _, _ in }))
        func sheet(_ anchor: RecoverySheetAnchor) -> RecoverySheetModel {
            RecoverySheetModel(host: store, requests: [Self.request(scenario, .draft("A", .tags))], anchor: anchor, dependencies: .init())
        }
        let closing = Notification(name: NSWindow.willCloseNotification)
        let main = sheet(.library)
        store.recoverySheet = main
        window.windowWillClose(closing)
        #expect(!main.isClosed && store.recoverySheet === main, "메인 창의 시트는 편집 창이 닫혀도 그대로다")
        main.cancel()
        let edit = sheet(.editWindow)
        store.recoverySheet = edit
        window.windowWillClose(closing)
        #expect(edit.isClosed && store.recoverySheet == nil && !store.writesBlockedBySheet)
        await edit.waitUntilClosed()
    }

    @Test func 줄에_남기는_이유는_한_문장이고_저장_실패에_일반_안내가_겹치지_않는다() async throws {
        func oneSentence(_ text: String?) -> Bool {
            guard let text else { return false }
            let body = text.trimmingCharacters(in: .whitespaces).dropLast()
            return !body.contains(". ") && !body.contains("。") && !text.contains("안내된 조건")
        }
        let scenario = try await RecoveryScenario.make(withHalfAnalysedTrack: true)
        let model = model(scenario, [.draft("C", .cues), .playlist("P1")])
        await model.load()
        #expect(oneSentence(try line(model, scenario, .draft("C", .cues)).keepBlockedReason))
        let d = RecoverySheetModel(host: scenario.store, requests: [Self.request(scenario, .draft("D", .grid))], dependencies: .init())
        await d.load()
        #expect(oneSentence(d.lines.first?.keepBlockedReason))
        #expect(oneSentence(RecoverySheetModel.message(for: CancellationError())))
        #expect(oneSentence(RecoverySheetModel.message(for: DraftRecoveryError.ambiguousIdentity)))
        #expect(RecoverySheetModel.message(for: DJCError.writeRefused("저장 폴더 권한을 확인하세요.")) == "저장 폴더 권한을 확인하세요.")
    }

    @Test func 시트를_띄우지_않는_프롬프터는_시트를_기다리지_않고_닫는다() async throws {
        struct Headless: HeadlessReflectionPrompter {
            func show(_ prompt: ReflectionPrompt) -> Bool { false }
        }
        let scenario = try await RecoveryScenario.make()
        let headless = RecoverySheetModel(host: scenario.store, requests: [Self.request(scenario, .draft("A", .tags))], dependencies: .init())
        await Headless().review(headless)
        #expect(headless.isClosed)
        // 시트가 열리면 안 되는 시험용 프롬프터는 끝없이 기다리지 않고 시험을 실패시킨다.
        let model = RecoverySheetModel(host: scenario.store, requests: [Self.request(scenario, .draft("A", .tags))], dependencies: .init())
        await withKnownIssue { await CancellingPrompter().review(model) }
        #expect(model.isClosed)
    }

    @Test func 기본_시트는_스토어에_올리고_닫으면_내린다() async throws {
        let scenario = try await RecoveryScenario.make()
        let model = model(scenario, [.draft("A", .tags)])
        let shown = Task { await AlertPrompter().review(model) }
        await Task.yield()
        #expect(scenario.store.recoverySheet === model)
        model.cancel()
        await shown.value
        #expect(scenario.store.recoverySheet == nil && model.isClosed)
    }
}

/// #232 이전의 곡·종류별 연속 창 흐름의 사본. 창 문구는 빼고, 어느 단추를 누르면 무엇을 저장하는지만 그대로 둔다.
/// 시트가 같은 선택으로 같은 초안 상태를 만드는지 견주는 기준이다(예전 코드는 `git show 468e7b7:Sources/DJCrate/Reflection/…`).
@MainActor
enum LegacyRecoveryFlow {
    /// 곡 하나·종류 하나: "현재값을 가져올까요?" → 비교 창 → (큐 대상 다시 지정 창) → 저장
    static func recoverDraft(_ scenario: RecoveryScenario, row name: String, kind: DraftRecoveryKind, choice: RecoveryChoice) async throws {
        guard choice != .later else { return }
        let remap = name == "C" && kind == .cues && choice == .keep
        let prompter = ScriptedPrompter()
        prompter.choices = remap ? [.confirm, .confirm, .confirm] : choice == .keep ? [.confirm] : [.alternate]
        let store = scenario.store, row = scenario.rows[name]!
        var review = try await store.prepareDraftRecovery(row: row, kind: kind)
        let refusal = review.keepRefusal
        let keep = refusal == nil ? try? review.original.resolved(onto: review.current, choice: .keepEditing) : nil
        let missing = missingCueMappings(review)
        var prompt = ReflectionPrompt(title: "비교", text: "", confirm: keep != nil ? "내 편집 유지·재적용" : "현재값 사용",
                                      destructive: keep == nil, alternate: keep != nil ? "현재값 사용" : nil)
        if keep == nil, !missing.isEmpty { prompt.confirm = "큐 대상 다시 지정…"; prompt.alternate = "현재값 사용"; prompt.destructive = false }
        var answer = prompter.choose(prompt)
        if answer == .cancel { return }
        let action: DraftRecoveryChoice
        if keep == nil, !missing.isEmpty, answer == .confirm {
            guard let mappings = chooseCueMappings(review, missing: missing, prompter: prompter) else { return }
            review.cueSourceMappings = mappings
            _ = try review.original.resolved(onto: review.current, choice: .keepEditing, sourceMappings: mappings)
            answer = prompter.choose(ReflectionPrompt(title: "비교", text: "", confirm: "내 편집 유지·재적용", alternate: "현재값 사용"))
            if answer == .cancel { return }
            action = answer == .confirm ? .keepEditing : .useCurrent
        } else {
            action = keep != nil && answer == .confirm ? .keepEditing : .useCurrent
        }
        try await store.applyDraftRecovery(review, choice: action)
        #expect(prompter.choices.isEmpty, "예전 흐름이 고른 답을 다 쓰지 않음: \(name) \(kind)")
    }

    private static func missingCueMappings(_ review: DraftRecoveryReview) -> [EditableCue] {
        guard case let .cues(draft) = review.original, case let .cues(current) = review.current else { return [] }
        let sources = Set(current.base.compactMap(\.sourceID))
        return draft.changes.compactMap {
            if case let .modified(old, _) = $0, let source = old.sourceID, !sources.contains(source) { return old }
            return nil
        }
    }

    private static func chooseCueMappings(_ review: DraftRecoveryReview, missing: [EditableCue], prompter: ReflectionPrompter) -> [String: String]? {
        guard case let .cues(draft) = review.original, case let .cues(current) = review.current else { return nil }
        let known = Set(draft.base.compactMap(\.sourceID))
        var mappings: [String: String] = [:]
        for old in missing {
            guard let oldSource = old.sourceID else { return nil }
            let candidates = current.base.filter { cue in
                cue.sourceID.map { !known.contains($0) && !mappings.values.contains($0) } ?? false
            }
            var selected = false
            for (index, candidate) in candidates.enumerated() {
                let prompt = ReflectionPrompt(title: "연결", text: "", confirm: "이 현재 큐에 연결", alternate: index + 1 < candidates.count ? "다음 큐" : nil)
                switch prompter.choose(prompt) {
                case .cancel: return nil
                case .alternate: continue
                case .confirm:
                    mappings[oldSource] = candidate.sourceID
                    selected = true
                }
                if selected { break }
            }
            if !selected { return nil }
        }
        return mappings
    }

    /// 목록마다 창: 앞 목록을 저장한 뒤 다음 목록을 새로 비교한다. 이미 막혀 있지 않으면 건너뛴다.
    static func recoverPlaylists(_ scenario: RecoveryScenario, choices: [(String, RecoveryChoice)]) async throws {
        let store = scenario.store
        for (id, choice) in choices {
            if !store.blockedPlaylistRecoveryIDs.contains(id) { continue }
            let prompter = ScriptedPrompter()
            prompter.choices = [choice == .keep ? .confirm : choice == .useCurrent ? .alternate : .cancel]
            let review = try await store.preparePlaylistRecovery(playlist: id)
            let canReapply = !review.recovery.reapplied.isEmpty
            switch prompter.choose(ReflectionPrompt(title: "비교", text: "", confirm: canReapply ? "다시 적용" : "초안 버리기",
                                                   destructive: !canReapply, alternate: canReapply ? "초안 버리기" : nil, cancel: "선택하지 않고 남기기")) {
            case .cancel: continue
            case .confirm: try await store.applyPlaylistRecovery(review, reapply: canReapply)
            case .alternate: try await store.applyPlaylistRecovery(review, reapply: false)
            }
        }
    }
}

/// 확인 창마다 취소하는 프롬프터. 복구 시트가 열리면 시험을 실패시킨다(`NoRecoverySheetPrompter`).
@MainActor
private final class CancellingPrompter: NoRecoverySheetPrompter {
    func show(_ prompt: ReflectionPrompt) -> Bool { false }
    func choose(_ prompt: ReflectionPrompt) -> ReflectionChoice { .cancel }
}
