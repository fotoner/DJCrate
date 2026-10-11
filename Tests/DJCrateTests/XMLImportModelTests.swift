@testable import DJCrate
import DJCApplication
import DJCDomain
import Foundation
import Testing

/// rekordbox XML 가져오기 화면 모델(#249): 읽는 중 → 미리 보기 → 초안 결과의 상태와, 시트에서 고른 차이를 가짜 포트로 본다.
/// 실제 사본으로 도는 흐름은 `RekordboxXMLImportTests`가 본다.
@Suite("rekordbox XML 가져오기 화면 모델")
@MainActor
struct XMLImportModelTests {
    nonisolated static let snapshot = URL(filePath: "/fake/master.db")
    static let xmlURL = URL(filePath: "/fake/import.xml")

    /// 곡 1은 제목·큐(더하기), 곡 2는 큐 빼기만, XML에만 있는 목록 하나, 못 맞춘 곡 하나
    nonisolated static func comparison() -> XMLImportComparison {
        let mark = XMLLibrary.Mark(kind: .hot(0), start: 1, name: ""), extra = XMLLibrary.Mark(kind: .hot(1), start: 5, name: "")
        let library = XMLLibrary(tracks: [XMLLibrary.Track(key: "1", path: "/m/1.mp3", tags: [.title: "곡 1"]),
                                          XMLLibrary.Track(key: "2", path: "/m/2.mp3", tags: [.title: "곡 2"], marks: [mark, extra])])
        let xml = XMLLibrary(tracks: [XMLLibrary.Track(key: "x1", path: "/m/1.mp3", tags: [.title: "새 곡 1"], marks: [mark]),
                                      XMLLibrary.Track(key: "x2", path: "/m/2.mp3", tags: [.title: "곡 2"], marks: [mark]),
                                      XMLLibrary.Track(key: "x3", path: "/m/없는.mp3", tags: [.title: "없는 곡"])],
                             lists: [XMLLibrary.Node(name: "가져온 목록", entries: ["x1"])])
        return XMLImportComparison(snapshot: snapshot, share: nil, xml: xml, library: library,
                                   diff: XMLLibraryDiff.compute(xml: xml, library: library))
    }

    @MainActor final class Fake {
        var snapshot: URL? = XMLImportModelTests.snapshot
        var compared: [(xml: URL, share: URL?)] = []
        var compare: @Sendable () async throws -> XMLImportComparison = { XMLImportModelTests.comparison() }
        var made: [XMLImportDrafts.Selection] = []
        var makeResult: Result<XMLImportDraftResult, any Error> = .success(XMLImportDraftResult(cues: 1, tags: 1))
        var refreshed = 0
        var failures: [String] = []
        var writing = false
    }

    func model(_ fake: Fake) -> XMLImportModel {
        XMLImportModel(ports: XMLImportModel.Ports(
            snapshot: { fake.snapshot },
            share: { $0 ?? URL(filePath: "/fake/share") },
            compare: { xml, _, share in
                let body = await MainActor.run {
                    fake.compared.append((xml, share))
                    return fake.compare
                }
                return try await body()
            },
            makeDrafts: { _, selection in
                fake.made.append(selection)
                return try fake.makeResult.get()
            },
            draftsChanged: { fake.refreshed += 1 },
            isWriting: { fake.writing },
            fail: { fake.failures.append($0) }))
    }

    func opened(_ fake: Fake = Fake()) async throws -> XMLImportModel {
        let model = model(fake)
        model.start(from: Self.xmlURL)
        await model.task?.value
        _ = try #require(model.preview)
        return model
    }

    @Test func 읽는_동안은_읽는_중이고_끝나면_미리_보기와_기본_선택이_생긴다() async throws {
        let fake = Fake()
        let model = model(fake)
        model.start(from: Self.xmlURL)
        #expect(model.isReading && model.isBusy)
        await model.task?.value
        #expect(!model.isReading)
        let preview = try #require(model.preview)
        #expect(preview.fileName == "import.xml")
        #expect(fake.compared.first?.share == URL(filePath: "/fake/share"))
        // 빼기만 있는 큐(곡 2)는 처음에 고르지 않는다
        #expect(model.chosen[.cue] == ["1"] && model.chosen[.tag] == ["1"])
        #expect(model.chosenLists == [["가져온 목록"]])
        #expect(model.tab == .cue && model.chosenCount == 3)
        #expect(model.count(.unmatched) == 1 && model.unmatched.map(\.title) == ["없는 곡"])
    }

    @Test func 사본이_없으면_읽지_않는다() {
        let fake = Fake()
        fake.snapshot = nil
        let model = model(fake)
        model.start(from: Self.xmlURL)
        #expect(!model.isReading && model.task == nil && fake.compared.isEmpty)
    }

    @Test func 읽지_못하면_미리_보기_없이_이유를_알린다() async {
        let fake = Fake()
        fake.compare = { throw XMLReadError(reason: "깨진 파일") }
        let model = model(fake)
        model.start(from: Self.xmlURL)
        await model.task?.value
        #expect(model.preview == nil && !model.isReading && !model.isBusy)
        #expect(fake.failures == ["rekordbox XML을 가져오지 못했습니다: 깨진 파일"])
    }

    @Test func 취소하면_읽기를_멈추고_미리_보기를_열지_않는다() async {
        let fake = Fake()
        fake.compare = {
            try await Task.sleep(for: .seconds(60))
            return XMLImportModelTests.comparison()
        }
        let model = model(fake)
        model.start(from: Self.xmlURL)
        model.cancel()
        #expect(!model.isReading)
        await model.task?.value
        #expect(model.preview == nil && fake.failures.isEmpty)
    }

    @Test func 탭_모두_고르기와_빼기는_그_탭만_바꾼다() async throws {
        let model = try await opened()
        model.tab = .cue
        model.setAll(true)
        #expect(model.chosen[.cue] == ["1", "2"])
        model.setAll(false)
        #expect(model.chosen[.cue] == [] && model.chosen[.tag] == ["1"])
        model.tab = .playlist
        model.setAll(false)
        #expect(model.chosenLists.isEmpty)
        model.setChosen(true, kind: .tag, key: "1")
        model.setChosen(false, kind: .tag, key: "1")
        #expect(model.isChosen(kind: .tag, key: "1") == false)
        #expect(model.chosenCount == 0 && !model.canMakeDrafts)
    }

    @Test func 초안으로_만들면_고른_차이를_넘기고_결과를_보이며_초안을_다시_읽는다() async throws {
        let fake = Fake()
        let model = try await opened(fake)
        #expect(model.canMakeDrafts)
        fake.writing = true
        #expect(!model.canMakeDrafts, "rekordbox에 쓰는 동안은 만들지 않는다")
        fake.writing = false
        model.startDrafts()
        await model.draftTask?.value
        #expect(fake.made.first?.tracksByKind[.cue] == ["1"])
        #expect(fake.made.first?.playlistPaths == [["가져온 목록"]])
        #expect(model.result == XMLImportDraftResult(cues: 1, tags: 1) && !model.isMakingDrafts)
        #expect(fake.refreshed == 1)
        // 시트를 닫으면(미리 보기 없음) 결과도 지운다
        model.preview = nil
        #expect(model.result == nil && !model.isBusy)
    }

    @Test func 초안을_만들지_못하면_결과에_이유를_적고_초안을_다시_읽지_않는다() async throws {
        let fake = Fake()
        fake.makeResult = .failure(CocoaError(.fileWriteNoPermission))
        let model = try await opened(fake)
        let result = await model.makeDrafts(try #require(model.preview), selection: .all)
        #expect(result.failure?.hasPrefix("초안을 만들지 못했습니다: ") == true)
        #expect(model.result?.failure == result.failure && fake.refreshed == 0)
    }

    @Test func 다른_미리_보기로_바뀐_뒤_끝난_결과는_보이지_않는다() async throws {
        let model = try await opened()
        let old = try #require(model.preview)
        model.start(from: Self.xmlURL)
        await model.task?.value
        #expect(model.preview?.id != old.id)
        _ = await model.makeDrafts(old, selection: .all)
        #expect(model.result == nil)
    }
}
