@testable import DJCrate
import AppKit
import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import RekordboxFixtures
import SwiftUI
import Testing

@MainActor
@Suite("반영 — 알림·진행 표시 배치", .serialized)
struct ReflectionLayoutTests {
    @Test(arguments: ["light", "dark"]) func 결과_알림은_최소_창의_detail_아래쪽에_보인다(_ appearance: String) async throws {
        _ = NSApplication.shared
        // 시험 프로세스 공용 defaults(swiftpm-testing-helper)에는 이전 실행·다른 워크트리가 남긴 창 배치 값(사이드바·툴바)이 있다.
        // 화면이 그 값에 따라 달라지지 않게 배치 값을 시험 전용 저장소로 고정하고, 공용 툴바 설정은 시험 동안 비웠다 되돌린다.
        let defaults = TestDefaults.make("reflection-layout")
        defaults.set(false, forKey: SettingKeys.sidebarVisible.name)
        let toolbarKey = "NSToolbar Configuration main"
        let savedToolbar = UserDefaults.standard.object(forKey: toolbarKey)
        UserDefaults.standard.removeObject(forKey: toolbarKey)
        defer { UserDefaults.standard.set(savedToolbar, forKey: toolbarKey) }

        // detail을 안내 뷰(.idle)가 아니라 창을 채우는 덱·곡 목록(.loaded, 합성 곡)으로 두어 알림이 창 아래쪽에 붙게 한다.
        let fixture = try RekordboxFixture()
        for index in 1...5 {
            var track = TrackSpec(id: String(100 + index))
            track.title = "합성 곡 \(index)"
            try fixture.add(track)
        }
        let store = LibraryStore.test(settings: SettingsStore(defaults: defaults, persist: false),
                                 resultHistory: WriteResultHistory(url: nil), feedback: AppFeedback(announce: { _ in }),
                                 rekordboxDatabase: fixture.database, rekordboxShareRoot: fixture.shareRoot)
        await store.load(snapshot: fixture.database)
        let deck = DeckModel.test(audio: FakeDeckAudio(), storage: .memory(MemoryDrafts()), runsAnalysis: false)
        store.toast = AppToast(kind: .warning, title: "배치 시험 결과", detail: "합성 데이터로 확인합니다")
        let toastID = try #require(store.toast?.id)
        let toastKey = "toast.\(toastID)", contentKey = "reflectionLayout.\(toastID)"
        defer {
            SelfTestFrames.frames.removeValue(forKey: toastKey)
            SelfTestFrames.frames.removeValue(forKey: contentKey)
        }
        let controller = NSHostingController(rootView: ContentView(store: store, deck: deck, app: AppComposition(store: store, deck: deck))
            .defaultAppStorage(defaults).selfTestFrame(contentKey))
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        window.setContentSize(NSSize(width: 1100, height: 700))
        defer { window.close() }
        // 비트맵의 주황색도 색 공간 변환 뒤 픽셀 기준에서 빠졌다(#185). 실제 SwiftUI 배치의 카드 전체를 잰다.
        // 창을 띄우지 않아 화면 잠김·가림·창 뒤 내용에 기대지 않고, 올바른 위치인지와 별개로 배치가 안정됐는지 기다린다.
        var previous: (content: CGRect, toast: CGRect)?
        var settled = 0
        for _ in 0..<80 where settled < 2 {
            window.contentView?.layoutSubtreeIfNeeded()
            if let content = SelfTestFrames.frames[contentKey], let toast = SelfTestFrames.frames[toastKey],
               !content.isEmpty, !toast.isEmpty {
                settled = previous?.content == content && previous?.toast == toast ? settled + 1 : 0
                previous = (content, toast)
            } else {
                settled = 0
                previous = nil
            }
            if settled < 2 { try await Task.sleep(for: .milliseconds(50)) }
        }
        let content = try #require(SelfTestFrames.frames[contentKey])
        let toast = try #require(SelfTestFrames.frames[toastKey])
        let bottomInset = content.maxY - toast.maxY
        print("[알림 배치] 본문=\(content) 알림=\(toast) 아래 여백=\(bottomInset) 창 표시=\(window.isVisible) 화면 모드=\(appearance)")
        #expect(settled == 2)
        #expect(!toast.isEmpty)
        #expect(toast.midY > content.midY)
        #expect(bottomInset * window.backingScaleFactor > 8)
        #expect(abs(bottomInset - 16) < 1)
        #expect(content.contains(toast))
        #expect(!window.isVisible)
    }

    /// 넓은 창에서도 진행 카드는 막대가 남는 폭을 다 차지하지 않고 문구에 맞는 폭(최대 폭 안)으로 뜬다(#122).
    @Test(arguments: [1.0, 1.4]) func 진행_카드는_넓은_창에서도_최대_폭_안에_뜬다(_ scale: Double) {
        _ = NSApplication.shared
        func width(_ stage: WriteStage) -> Double {
            let card = WritingStageCard(stage: stage, onCancel: {}).environment(\.textScale, scale)
            return NSHostingController(rootView: card).sizeThatFits(in: CGSize(width: 1800, height: 900)).width
        }
        let preview = width(WriteStage(String(ui: "미리 보기 2/2단계 · 바꿀 내용을 검사하는 중…"), completed: 1, total: 2, cancellable: true))
        let writing = width(WriteStage(String(ui: "rekordbox에 쓰는 중…")))
        // 내용 최대 폭 400pt(글자 배율만큼) + 좌우 여백 28pt씩
        let limit = TextScale.length(400, scale: scale) + 56
        #expect(preview <= limit)
        #expect(writing <= limit)
        // 막대가 있어도 단계 문구가 한 줄 이상 읽히는 폭은 남긴다.
        #expect(preview >= TextScale.length(240, scale: scale))
    }

    /// 문구가 최소 폭보다 짧아도 표시와 글자는 카드 가운데에 모인다(왼쪽에 붙어 치우쳐 보였다, #148).
    @Test(arguments: ["light", "dark"]) func 진행_카드의_표시와_글자는_카드_가운데에_있다(_ appearance: String) throws {
        _ = NSApplication.shared
        let view = NSHostingView(rootView: WritingStageCard(stage: .reloadingLibrary, onCancel: {}))
        view.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        view.frame = CGRect(origin: .zero, size: view.fittingSize)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        func brightness(_ x: Int, _ y: Int) -> Double? {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.5 else { return nil }
            return (color.redComponent + color.greenComponent + color.blueComponent) / 3
        }
        // 좌우 여백(28pt) 안쪽 한 점을 카드 바탕으로 보고, 바탕과 밝기가 크게 다른 점(글자·표시)의 가로 범위를 잰다.
        let background = try #require(brightness(4, bitmap.pixelsHigh / 2))
        var columns: [Int] = []
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if let value = brightness(x, y), abs(value - background) > 0.3 { columns.append(x) }
            }
        }
        let left = try #require(columns.min()), right = try #require(columns.max())
        let offset = Double(left + right) / 2 - Double(bitmap.pixelsWide) / 2
        #expect(abs(offset) <= Double(bitmap.pixelsWide) * 0.02, "내용 가운데가 카드 가운데에서 \(offset)px 벗어남")
    }

    /// 최대 폭을 넘는 긴 문구(번역·큰 글자)는 잘리지 않고 최대 폭에서 줄을 바꿔 카드가 높아진다.
    @Test func 진행_카드의_긴_문구는_최대_폭에서_줄을_바꾼다() {
        _ = NSApplication.shared
        func size(_ text: String) -> CGSize {
            NSHostingController(rootView: WritingStageCard(stage: WriteStage(text, completed: 1, total: 2), onCancel: {}))
                .sizeThatFits(in: CGSize(width: 1800, height: 900))
        }
        let short = size("짧은 단계")
        let long = size(String(repeating: "아주 긴 단계 문구 ", count: 8))
        #expect(abs(long.width - (400 + 56)) < 1)
        #expect(long.height > short.height)
    }
}
