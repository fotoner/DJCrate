@testable import DJCrate
import DJCApplication
import AppKit
@testable import RekordboxKit
import DJCDomain
import Testing

@MainActor
@Suite("반영 확인 창 목록")
struct ReflectionPromptLayoutTests {
    typealias Fixture = ReflectionPresenterTests

    func detailText(_ prompt: ReflectionPrompt) throws -> String {
        _ = NSApplication.shared
        let alert = AlertPrompter().makeAlert(prompt)
        let scroll = try #require(alert.accessoryView as? NSScrollView)
        let textView = try #require(scroll.documentView as? NSTextView)
        #expect(scroll.hasVerticalScroller && !scroll.hasHorizontalScroller)
        #expect(scroll.frame.height <= 240)
        #expect(!textView.isEditable)
        return textView.string
    }

    @Test func 목록이_없으면_기존_알림을_유지하고_짧은_목록은_작게_보인다() throws {
        _ = NSApplication.shared
        let plain = AlertPrompter().makeAlert(ReflectionPrompt(title: "알림", text: "안내"))
        #expect(plain.accessoryView == nil)
        let short = AlertPrompter().makeAlert(ReflectionPrompt(title: "알림", text: "안내", details: ["• 시험 곡"]))
        let scroll = try #require(short.accessoryView as? NSScrollView)
        #expect(scroll.frame.height < 100)
    }

    @Test func 연동_안내는_경로만_본문에_두고_단계는_스크롤로_보여_준다() throws {
        _ = NSApplication.shared
        let url = URL(filePath: "/tmp/djc-layout/djcrate-rekordbox.xml")
        let alert = RekordboxLink.setupAlert(for: url)
        #expect(alert.informativeText.components(separatedBy: "\n").count == 2)
        #expect(alert.informativeText.contains(url.path))
        #expect(!alert.informativeText.contains("1. rekordbox"))
        #expect(alert.buttons.map(\.title) == ["확인", "Finder에서 보기"])
        let scroll = try #require(alert.accessoryView as? NSScrollView)
        let textView = try #require(scroll.documentView as? NSTextView)
        #expect(scroll.frame.height <= 240)
        #expect(textView.string.contains("1. rekordbox") && textView.string.contains("2. 트리에"))
        #expect(textView.string.contains("Import To Collection") && textView.string.contains("라이브러리 백업"))
    }

    /// XML 만들기는 연동 파일만 쓰므로 묻지 않고, 막혀서 뺀 곡과 XML에 넣지 않은 초안을 결과 줄에 알린다(#212).
    @Test func XML_결과_줄은_막힌_곡과_넣지_않은_초안을_알린다() {
        var plan = Reflection.plan(track: Fixture.row("x").track, rawCues: [], cueDraft: nil, gridDraft: nil)
        plan.blockers = ["막힌 이유"]
        let clean = ReflectionPanels.resultMessage(written: 2, blocked: [], exclusions: [])
        #expect(clean.kind == .success && clean.text.hasPrefix("2곡을 연동 XML에 썼습니다"))
        let warned = ReflectionPanels.resultMessage(written: 1, blocked: [plan],
                                                    exclusions: ["• 곡 x: 막힌 이유", "• 곡 t: 태그 쓰지 않음: 기존 곡의 XML은 큐·그리드만 지원하니…"])
        #expect(warned.kind == .warning)
        #expect(warned.text.contains("막혀서 뺀 곡 1: 곡 x(막힌 이유)"))
        #expect(warned.text.contains("XML에 넣지 않은 초안 1: 곡 t: 태그 쓰지 않음"))
    }

    /// XML로 만들 곡이 없으면 창을 띄우지 않고 XML 결과 줄 자리에 남긴다(#230). 막힌 곡은 결과 줄처럼 앞 둘과 수를 적는다.
    @Test func XML로_만들_곡이_없으면_창_대신_결과_줄로_알린다() {
        let plans = (1...100).map { index in
            var plan = Reflection.plan(track: Fixture.row("xml-\(index)").track, rawCues: [], cueDraft: nil, gridDraft: nil)
            plan.blockers = ["막힌 이유"]
            return plan
        }
        let message = ReflectionPanels.blockedMessage(plans)
        #expect(message.kind == .warning)
        #expect(message.text == "XML로 만들 곡이 없습니다 · 막혀서 뺀 곡 100: 곡 xml-1(막힌 이유), 곡 xml-2(막힌 이유)")
        let empty = ReflectionPanels.blockedMessage([])
        #expect(empty.kind == .warning && empty.text == "XML로 만들 곡이 없습니다 · 고른 곡에 rekordbox와 다른 큐·그리드 초안이 없습니다.")
    }

    /// 곡이 많아도 쓴 곡마다의 결과는 쓰기 결과에 남는다(묻지 않고 모두 쓰는 판정은 반영 세션 시험).
    @Test func 그리드와_게인_각_100곡을_쓴_결과는_곡마다_남는다() throws {
        let store = LibraryStore.test(resultHistory: WriteResultHistory(), feedback: AppFeedback(announce: { _ in }))
        let report = Fixture.preview(cues: [], grids: (1...100).map { Fixture.outcome("grid-\($0)", .written, added: 64) },
                                     gains: (1...100).map { Fixture.outcome("gain-\($0)", .written, added: -250) }).report
        ReflectionPresenter(store: store, prompter: ScriptedPrompter()).publish(.written(report, preview: report, followUp: []))
        let lines = try #require(store.resultHistory.latest).text.components(separatedBy: "\n")
        #expect(lines.contains("• 곡 grid-100 — 그리드 쓰기 완료") && lines.contains("• 곡 gain-100 — 게인 쓰기 완료"))
    }

    @Test func 쓰지_않는_이유는_끝까지_보이고_쓰는_곡_줄은_넣지_않는다() throws {
        let preview = Fixture.preview(
            cues: (1...100).map { Fixture.outcome("cue-\($0)", .written) }
                + (1...100).map { Fixture.outcome("blocked-\($0)", .blocked, reason: "분석 전") },
            analyses: (1...100).map { Fixture.outcome("analysis-\($0)", .written, added: 96) })
        let prompt = ReflectionPrompts.confirmation(preview.report)
        #expect(prompt.text.count < 180)
        let lines = try detailText(prompt).components(separatedBy: "\n")
        #expect(lines == ["쓰지 않는 것 100:"] + (1...100).map { "• 곡 blocked-\($0): 분석 전" })
        #expect(!lines.contains { $0.hasPrefix("… 외") })
    }

    @Test func 넣기와_빼기는_100곡과_제외_이유를_생략하지_않는다() throws {
        let outcomes = (1...100).map { Fixture.track("track-\($0)") }
            + (1...100).map { Fixture.track("blocked-\($0)", written: false, reason: "막힌 이유") }
        var deleted = RekordboxTrackWriter.Report(dryRun: true)
        deleted.deleted = outcomes
        let prompts = [
            ReflectionPrompts.addConfirmation(Fixture.addPreview(outcomes), writesArtwork: true),
            ReflectionPrompts.deleteConfirmation(.init(report: deleted, contentIDs: [])),
        ]
        for prompt in prompts {
            #expect(prompt.text.count < 180)
            let lines = try detailText(prompt).components(separatedBy: "\n")
            for index in 1...100 {
                // 넣기는 빠지는 것이 없는 곡의 줄을 넣지 않는다(#210). 빼기는 뺄 곡을 모두 보인다.
                #expect(lines.contains("• 곡 track-\(index)") == (prompt.confirm == "rekordbox에서 빼기"))
                #expect(lines.contains("• 곡 blocked-\(index): 막힌 이유"))
            }
            #expect(!lines.contains { $0.hasPrefix("… 외") })
        }
    }

    @Test func 되돌리기는_경고_본문을_유지하고_100곡을_목록에_보여_준다() throws {
        let report = Fixture.preview(cues: (1...100).map { Fixture.outcome("restore-\($0)", .written) }).report
        let backup = RekordboxWriter.Backup(url: URL(filePath: "/tmp/layout-test"), createdAt: .now, isWrite: true, report: report)
        let prompt = ReflectionPrompts.restoreConfirmation(backup, changedSince: true)
        #expect(!prompt.text.contains("곡 restore-"))
        #expect(prompt.text.contains("복원하면 그 변경도 함께 사라집니다"))
        #expect(prompt.critical && prompt.destructive)
        let lines = try detailText(prompt).components(separatedBy: "\n")
        for index in 1...100 { #expect(lines.contains("• 곡 restore-\(index)")) }
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func 긴_제목_100곡도_창과_버튼이_화면_안에_있다(appearance: NSAppearance.Name) throws {
        _ = NSApplication.shared
        let preview = Fixture.preview(cues: [], grids: [Fixture.outcome("쓰는 곡", .written)] + (1...100).map {
            Fixture.outcome("\($0) " + String(repeating: "긴 제목 ", count: 30), .blocked, reason: "막힌 이유")
        })
        let alert = AlertPrompter().makeAlert(ReflectionPrompts.confirmation(preview.report))
        alert.window.appearance = NSAppearance(named: appearance)
        alert.layout()
        let screen = try #require(alert.window.screen ?? NSScreen.main)
        #expect(alert.window.frame.height < screen.visibleFrame.height)
        #expect(alert.window.frame.width < screen.visibleFrame.width)
        let content = try #require(alert.window.contentView)
        for button in alert.buttons {
            #expect(content.bounds.contains(button.convert(button.bounds, to: content)))
        }
        let scroll = try #require(alert.accessoryView as? NSScrollView)
        let textView = try #require(scroll.documentView as? NSTextView)
        #expect(scroll.frame.height <= 240)
        #expect(textView.frame.height > scroll.contentSize.height)
        #expect(scroll.contentView.bounds.minY == 0)
        textView.scrollRangeToVisible(NSRange(location: textView.string.utf16.count - 1, length: 1))
        #expect(scroll.contentView.bounds.minY > 0)
        #expect(alert.buttons.first?.keyEquivalent == "\r")
        #expect(alert.buttons.last?.keyEquivalent == "\u{1b}")
    }

    @Test func 읽기_전용_목록이_기본_버튼의_입력_초점을_빼앗지_않는다() throws {
        _ = NSApplication.shared
        let prompt = ReflectionPrompt(title: "목록 시험", text: "안내", confirm: "쓰기",
                                      details: (1...200).map { "• 시험 곡 \($0)" })
        let alert = AlertPrompter().makeAlert(prompt)
        alert.layout()
        let scroll = try #require(alert.accessoryView as? NSScrollView)
        let textView = try #require(scroll.documentView as? NSTextView)
        #expect(!textView.acceptsFirstResponder)
        #expect(scroll.contentView.bounds.minY == 0)
        #expect(alert.buttons.first?.keyEquivalent == "\r")
        #expect(alert.buttons.last?.keyEquivalent == "\u{1b}")
    }
}
