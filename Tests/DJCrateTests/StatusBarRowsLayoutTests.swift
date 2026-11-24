@testable import DJCrate
import AppKit
import DJCApplication
import DJCDomain
import Foundation
import SwiftUI
import Testing

/// 상태 줄이 R3 표의 줄마다 칩 글자와 단추를 한 줄에 담는다(#404). 실제 `StatusBar` 뷰를 합성 상태로 그려 최소 창 폭에서 잘림 없이 들어가는지 본다.
/// `DJC_STATUS_BAR_CAPTURE=<폴더>`를 주면 줄마다 PNG를 남긴다(UI-15: 변경 화면 캡처, 합성 상태라 실제 rekordbox를 건드리지 않는다).
@MainActor
@Suite("상태 줄 R3 줄 배치", .serialized)
struct StatusBarRowsLayoutTests {
    struct Row {
        let name: String
        let status: AutoReflectionStatus
        let holds: Set<ReflectionHold>
        var leftovers: Set<ReflectionLeftover> = []
        var autoSaves = true
        var pending = true
        var changedSince: Bool?
    }

    static let rows: [Row] = [
        Row(name: "1-중단", status: .interrupted(recoveryFailed: false), holds: [.interrupted(recoveryFailed: false)]),
        Row(name: "1-중단-바뀜", status: .interrupted(recoveryFailed: false), holds: [.interrupted(recoveryFailed: false)], changedSince: true),
        Row(name: "1-복구실패", status: .interrupted(recoveryFailed: true), holds: [.interrupted(recoveryFailed: true)]),
        Row(name: "2-쓸수없음", status: .held(.unwritable(.counters)), holds: [.unwritable(.counters)]),
        Row(name: "3-rekordbox켜짐", status: .rekordboxRunning(agentOnly: false), holds: [.rekordboxRunning]),
        Row(name: "3-USB와-제안", status: .held(.usbBusy), holds: [.usbBusy], leftovers: [.suggestion]),
        Row(name: "3-디버그와-rekordbox켜짐", status: .held(.notAutoRun(.debugBuild)), holds: [.notAutoRun(.debugBuild), .rekordboxRunning], autoSaves: false),
        Row(name: "4-저장됨", status: .saved, holds: [], pending: false),
        Row(name: "4-멈춤과-대기없음", status: .stopped(.stoppedAfterFailure), holds: [.stoppedAfterFailure], pending: false),
        Row(name: "5-쓰는중", status: .writing, holds: []),
        Row(name: "6-디버그실행", status: .held(.notAutoRun(.debugBuild)), holds: [.notAutoRun(.debugBuild)], autoSaves: false),
        Row(name: "7-멈춤", status: .stopped(.stoppedAfterFailure), holds: [.stoppedAfterFailure]),
        Row(name: "8-남은편집", status: .leftover(count: 1), holds: [], leftovers: [.outsideScope, .suggestion]),
        Row(name: "9-저장대기", status: .pending, holds: []),
        Row(name: "9-유예", status: .grace(secondsLeft: 24), holds: []),
        Row(name: "9-조용함", status: .quietWaiting, holds: [.quietWaiting]),
    ]

    func render(_ row: Row, appearance: String, legacy: Bool = false) throws -> (size: CGSize, image: NSBitmapImageRep, titles: [String]) {
        let h = ReflectionStatusModelTests.Harness()
        let feed = AutoReflectionFeed()
        // 엔진이 없는 조립(변경 전과 같은 한 가지 모양: 저장 대기가 있으면 [저장])은 피드를 붙이지 않는다
        if !legacy { h.window.autoFeed = feed }
        if row.pending {
            h.addRows("a")
            h.store.setDraftMark(.cue, trackUUID: "a", exists: true)
        }
        feed.update(row.status, ReflectionConditions(holds: row.holds, leftovers: row.leftovers, writing: row.status == .writing, hasPending: row.pending,
                                                     autoSaves: row.autoSaves))
        if let changedSince = row.changedSince {
            let journal = RekordboxWriteJournal(operationID: "op", kind: .counter, entry: .drafts, startCounter: 3)
            feed.setFinding(RekordboxJournalFinding(journal: journal, changedSince: changedSince, database: nil))
        }
        h.model.refresh()
        let bar = StatusBarModel(log: h.store.activityLog, settings: SettingsStore(persist: false))
        bar.write = h.model
        let view = NSHostingView(rootView: StatusBar(model: bar).frame(width: 1000).background(Color(nsColor: .windowBackgroundColor)))
        view.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        view.frame = NSRect(x: 0, y: 0, width: 1000, height: StatusBar.height)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let fitting = view.fittingSize
        return (fitting, bitmap, [h.model.line.title] + h.model.journalActions.map(\.title))
    }

    @Test(arguments: ["light", "dark"]) func 줄마다_상태_줄이_한_줄에_들어가고_캡처를_남긴다(_ appearance: String) throws {
        _ = NSApplication.shared
        let folder = ProcessInfo.processInfo.environment["DJC_STATUS_BAR_CAPTURE"].map { URL(filePath: $0) }
        // 캡처는 임시 폴더에만 쓴다(사용자 폴더·rekordbox 폴더를 쓰지 않는다)
        if let folder {
            let path = folder.path
            let allowed = ["/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/", FileManager.default.temporaryDirectory.path + "/"]
            #expect(allowed.contains { path.hasPrefix($0) }, "캡처 폴더는 임시 폴더 아래여야 한다: \(path)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        // 변경 전(엔진 없음)과 같은 모양: 줄을 가르지 않고 저장 대기가 있으면 [저장]
        if let folder {
            let before = try render(Row(name: "0-변경전", status: .pending, holds: [], autoSaves: false), appearance: appearance, legacy: true)
            if let png = before.image.representation(using: .png, properties: [:]) {
                try png.write(to: folder.appending(path: "status-bar-0-변경전-\(appearance).png"))
            }
        }
        for row in Self.rows {
            let (size, bitmap, _) = try render(row, appearance: appearance)
            #expect(size.width <= 1000 && size.height <= StatusBar.height + 1, "\(row.name): \(size)")
            if let folder, let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: folder.appending(path: "status-bar-\(row.name)-\(appearance).png"))
            }
        }
    }

    @Test func 단추는_줄마다_정해진_것만_보인다() throws {
        _ = NSApplication.shared
        var shown: [String: [String]] = [:]
        for row in Self.rows {
            let h = ReflectionStatusModelTests.Harness()
            let feed = AutoReflectionFeed()
            h.window.autoFeed = feed
            if row.pending {
                h.addRows("a")
                h.store.setDraftMark(.cue, trackUUID: "a", exists: true)
            }
            feed.update(row.status, ReflectionConditions(holds: row.holds, leftovers: row.leftovers, writing: row.status == .writing,
                                                         hasPending: row.pending, autoSaves: row.autoSaves))
            h.model.refresh()
            var buttons: [String] = []
            if h.model.graceSecondsLeft != nil { buttons.append("취소") }
            buttons += h.model.journalActions.map(\.title)
            if h.model.showsWriteButton { buttons.append(h.model.writeButtonTitle) }
            shown[row.name] = buttons
        }
        #expect(shown["1-중단"] == ["기록으로 복원…", "이대로 두기…"])
        #expect(shown["1-복구실패"] == ["기록으로 복원…", "이대로 두기…"])
        for name in ["2-쓸수없음", "3-rekordbox켜짐", "3-USB와-제안", "3-디버그와-rekordbox켜짐", "4-저장됨", "4-멈춤과-대기없음", "5-쓰는중", "9-저장대기", "9-조용함"] {
            #expect(shown[name]?.isEmpty == true, "\(name): \(String(describing: shown[name]))")
        }
        #expect(shown["9-유예"] == ["취소"])
        for name in ["6-디버그실행", "7-멈춤", "8-남은편집"] { #expect(shown[name] == ["저장"], "\(name)") }
    }
}
