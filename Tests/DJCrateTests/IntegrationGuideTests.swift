@testable import DJCrate
import AppKit
import DJCApplication
import DJCDomain
import Foundation
import Testing

/// 연동 안내(#315): 절차는 안내 창 하나에 두고, 도움말 메뉴·결과 줄·가져오기 창은 그 창을 여는 입구만 가진다.
@MainActor
@Suite("연동 안내 — 메뉴·결과 줄·가져오기 창")
struct IntegrationGuideTests {
    /// 연동 안내 창을 연 기록. 저장소의 열기 입구(조립 지점이 실제 창을 잇는다)에 가짜로 붙인다
    final class Opened {
        var topics: [IntegrationGuide.Topic] = []
    }

    func store(_ opened: Opened) -> LibraryStore {
        let store = LibraryStore.test(activityLog: ActivityLog(url: nil), saveTagDrafts: { _ in })
        store.showIntegrationGuide = { opened.topics.append($0) }
        return store
    }

    // MARK: - 도움말 메뉴

    @Test func 도움말_메뉴에_연동_안내가_복원_앞에_있고_다른_메뉴에는_없다() {
        #expect(LibraryMenuAction.helpActions == [.integrationGuide, .restore])
        #expect(LibraryMenuAction.integrationGuide.title == "연동 안내")
        #expect(LibraryMenuAction.integrationGuide.shortcut == nil)
        #expect(!(LibraryMenuAction.fileActions + LibraryMenuAction.rekordboxActions + LibraryMenuAction.editActions).contains(.integrationGuide))
        #expect(LibraryMenuAction.fileActions + LibraryMenuAction.rekordboxActions + LibraryMenuAction.editActions + [.integrationGuide] == LibraryMenuAction.allCases)
    }

    @Test func 연동_안내는_언제든_열리고_rekordbox_절차를_보인다() {
        let opened = Opened()
        let store = store(opened)
        let window = LibraryWindowModel(store: store)
        let action = LibraryMenuAction.integrationGuide
        #expect(action.isEnabled(in: window) && action.disabledReason(in: window) == nil)
        // 읽는 동안·쓰는 동안에도 읽기만 하는 안내라 막지 않는다
        store.isWritingRekordbox = true
        #expect(action.isEnabled(in: window) && action.disabledReason(in: window) == nil)
        action.perform(in: window)
        #expect(opened.topics == [.rekordbox])
    }

    // MARK: - 안내 창의 내용

    @Test func 연동_절차는_연동_안내_한_곳에_모여_있다() {
        #expect(IntegrationGuide.Topic.allCases == [.rekordbox, .appleMusic])
        let rekordbox = IntegrationGuide.Topic.rekordbox.lines.joined(separator: "\n")
        for part in ["환경설정 › 고급 › 데이터베이스 › rekordbox xml", "\"rekordbox xml\"이 보이게", "새로고침", "Import To Collection",
                     "\"DJCrate 반영\"", "\"DJCrate 추가\"", "rekordbox와 동기화(⟳)", "라이브러리 백업"] {
            #expect(rekordbox.contains(part), "rekordbox 절차에 「\(part)」가 있어야 한다")
        }
        // 단계 번호 순서: 1단계(환경설정에서 지정) → 2단계(트리에 보이게)
        let lines = IntegrationGuide.Topic.rekordbox.lines
        #expect(lines[0].hasPrefix("1. rekordbox") && lines[1].hasPrefix("2. 트리에"))
        let appleMusic = IntegrationGuide.Topic.appleMusic.lines.joined(separator: "\n")
        #expect(appleMusic.contains("보관함 내보내기") && appleMusic.contains("재생 목록 내보내기"))
    }

    /// 닫거나 최소화한 안내 창을 다시 열어도 새 창이 생기지 않고 같은 창에서 보는 쪽만 바뀐다(리뷰 지적: 최소화한 창을 다시 열면 창이 둘이 됐다)
    @Test func 안내_창은_닫았다_다시_열어도_같은_창을_쓴다() {
        _ = NSApplication.shared
        var shown: [NSWindow] = []
        let guide = IntegrationGuideWindow(show: { shown.append($0) })
        let file = URL(filePath: "/tmp/djc-guide/djcrate-rekordbox.xml")
        guide.open(file: file, topic: .rekordbox)
        #expect(shown.count == 1 && guide.model?.topic == .rekordbox)
        shown[0].close()
        guide.open(file: file, topic: .appleMusic)
        #expect(shown.count == 2 && shown[1] === shown[0], "닫은 창도 새로 만들지 않고 다시 보인다")
        #expect(guide.model?.topic == .appleMusic)
        guide.open(file: file, topic: .rekordbox)
        #expect(shown.count == 3 && shown[2] === shown[0] && guide.model?.topic == .rekordbox)
        shown[0].close()
    }

    @Test func 경로_복사와_Finder에서_보기는_연동_파일을_가리킨다() {
        let url = URL(filePath: "/tmp/djc-guide/djcrate-rekordbox.xml")
        var copied: String?
        var revealed: URL?
        let model = IntegrationGuideModel(xmlFile: url, topic: .rekordbox, copy: { copied = $0 }, reveal: { revealed = $0 })
        #expect(model.path == url.path && model.topic == .rekordbox)
        model.copyPath()
        model.revealInFinder()
        #expect(copied == url.path && revealed == url)
    }

    @Test func Finder에서_보기는_파일이_없으면_있는_가장_가까운_폴더를_가리킨다() {
        let file = URL(filePath: "/tmp/djc-guide/DJCrate/djcrate-rekordbox.xml")
        #expect(IntegrationGuide.revealTarget(for: file) { _ in true } == file)
        #expect(IntegrationGuide.revealTarget(for: file) { $0.path == "/tmp/djc-guide" || $0.path == "/tmp" || $0.path == "/" }.path == "/tmp/djc-guide")
        #expect(IntegrationGuide.revealTarget(for: file) { $0.path == "/" }.path == "/")
    }

    // MARK: - 결과 줄

    /// 추가한 곡의 XML 만들기 결과: 메뉴 경로 글 대신 결과 한 줄과 [가져오는 방법]. 그리드 없음·뺀 곡 이유는 있을 때만 붙는다
    @Test func 추가한_곡_XML_결과_줄은_결과와_가져오는_방법_링크뿐이다() {
        let clean = StagingPanels.resultMessage(count: 3, withoutGrid: 0, skipped: [])
        #expect(clean.title == "3곡을 연동 XML에 썼습니다" && clean.detail == nil)
        #expect(clean.kind == .success && !clean.showsResult)
        #expect(clean.action == .openIntegrationGuide(.rekordbox) && clean.action?.title == "가져오는 방법")
        let warned = StagingPanels.resultMessage(count: 3, withoutGrid: 1, skipped: ["• 곡 a: 키를 골라 둔 곡"])
        #expect(warned.kind == .warning)
        #expect(warned.detail == "1곡은 그리드 없이(rekordbox가 분석)\n• 곡 a: 키를 골라 둔 곡")
        #expect(warned.action == .openIntegrationGuide(.rekordbox))
        for toast in [clean, warned] {
            #expect(!toast.text.contains("Import To Collection") && !toast.text.contains("새로고침") && !toast.text.contains("rekordbox xml"))
        }
    }

    @Test func 알림의_가져오는_방법은_연동_안내를_연다() async {
        let opened = Opened()
        let window = LibraryWindowModel(store: store(opened))
        await window.performToastAction(.openIntegrationGuide(.rekordbox)).value
        await window.performToastAction(.openIntegrationGuide(.appleMusic)).value
        #expect(opened.topics == [.rekordbox, .appleMusic])
    }

    // MARK: - Apple Music 가져오기 창

    @Test func Apple_Music_가져오기_창의_가져오는_방법은_연동_안내의_Apple_Music을_연다() {
        let opened = Opened()
        let store = store(opened)
        let model = AppleMusicImportModel(staging: store.staging, appleMusic: store.useCases.appleMusic, openGuide: { opened.topics.append($0) })
        model.showGuide()
        #expect(opened.topics == [.appleMusic])
    }

    /// 창을 열 때마다 내보내는 법을 글로 안내하던 문장은 창에 없다(안내 창으로 옮겼다)
    @Test func Apple_Music_가져오기_창에는_내보내는_법_문장이_없다() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let window = try String(contentsOf: root.appending(path: "Sources/DJCrate/Reflection/AppleMusicImportWindow.swift"), encoding: .utf8)
        #expect(!window.contains("보관함 내보내기"))
        #expect(window.contains("가져오는 방법"))
    }

    // MARK: - 처음 한 번

    @Test func 처음_XML을_만들면_연동_안내가_한_번만_저절로_열린다() {
        let opened = Opened()
        let store = store(opened)
        RekordboxLink.showSetupIfNeeded(store: store)
        RekordboxLink.showSetupIfNeeded(store: store)
        #expect(opened.topics == [.rekordbox])
        // 이미 안내를 본 사용자의 옛 설정 이름을 그대로 쓴다(바꾸면 다시 뜬다, UI-11)
        #expect(SettingKeys.rekordboxLinkSetupShown.name == "rekordboxLinkSetupShown")
        #expect(SettingKeys.all.contains(SettingKeys.rekordboxLinkSetupShown.name))
    }

    @Test func 안내_창_입구가_없으면_본_것으로_치지_않는다() {
        let store = LibraryStore.test(activityLog: ActivityLog(url: nil), saveTagDrafts: { _ in })
        RekordboxLink.showSetupIfNeeded(store: store)
        #expect(store.settings.value(SettingKeys.rekordboxLinkSetupShown) == false)
    }
}
