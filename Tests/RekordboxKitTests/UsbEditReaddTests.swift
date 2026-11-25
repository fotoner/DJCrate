import DJCDomain
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

/// USB 수정에서 곡을 빼고 같은 로컬 곡을 다시 넣는 묶음(#391). 합성 USB(곡 101~105, 목록 "합성 목록")에서
/// 한 묶음(빼기 → 더하기)과 두 묶음(빼기를 먼저 쓰고 다음 묶음에서 더하기, 대조군)이 같은 결과가 되어야 한다.
/// 다시 넣은 곡은 새 USB ID를 받고 음원·분석 파일은 같은 경로를 가리킨다
@Suite("USB 수정 곡 빼고 다시 넣기")
struct UsbEditReaddTests {
    static let ids = ["101", "102", "103", "104", "105"]

    /// 곡 2(로컬 102)를 빼고 102를 다시 넣는 편집. `list`면 합성 목록(1) 끝에 넣는다
    static func edits(list: Bool) -> [UsbLibraryEdit] {
        [.removeTracks(usbContentIDs: [2]), .addTracks(localContentIDs: ["102"], playlist: list ? .id("1") : nil)]
    }

    /// 계획 결과를 한 줄로(실패 메시지용): 편집별 결과, 막힘 코드, 지울 파일·만들 파일·바꿀 파일
    static func summary(_ result: UsbEditResult) -> String {
        let outcomes = result.outcomes.map { entry -> String in
            if case let .blocked(block) = entry.outcome { return "\(entry.edit):blocked(\(block.code))" }
            return "\(entry.edit):\(entry.outcome.name)"
        }
        let changes = result.changes
        let creates = changes?.writes.filter { $0.disposition == .create }.map(\.destination) ?? []
        let replaces = changes?.writes.filter { $0.disposition != .create }.map(\.destination) ?? []
        return "결과 \(outcomes) 막힘 \(result.blocks.map(\.code)) 곡 막힘 \(result.trackBlocks.map(\.code)) "
            + "지울 파일 \(changes?.removals.map(\.path) ?? []) 새로 만들 파일 \(creates) 바꿀 파일 \(replaces)"
    }

    /// 쓰기를 시도한다. 거부하면 막힘 코드와 대상을 돌려준다
    static func write(_ env: UsbEditFixture, _ result: UsbEditResult) throws -> (report: UsbWriteReport?, refused: [String]) {
        do {
            return (try env.write(result), [])
        } catch let UsbError.writeRefused(blocks) {
            return (nil, blocks.map { "\($0.code) \($0.scope)" })
        }
    }

    static func plan(_ env: UsbEditFixture, _ edits: [UsbLibraryEdit]) throws -> UsbEditResult {
        try env.plan(edits, highWater: env.usb.journal()?.changes.idHighWater ?? [:])
    }

    /// 곡 2를 빼 먼저 쓰고 다음 묶음에서 102를 다시 넣어 쓴다(대조군). 다시 넣은 곡의 USB 곡
    @discardableResult
    static func twoBatches(_ env: UsbEditFixture) throws -> UsbTrack {
        let (first, firstReport) = try env.edit([.removeTracks(usbContentIDs: [2])])
        #expect(first.outcome(1) == .written && firstReport.outcome == .written, "\(summary(first))")
        let (second, secondReport) = try env.edit([.addTracks(localContentIDs: ["102"], playlist: nil)])
        #expect(second.outcome(1) == .written && secondReport.outcome == .written, "\(summary(second))")
        try UsbEditInvariantTests.check(env, second)
        return try #require(try env.read().tracks.first { $0.id == 6 })
    }

    static func isAnalysis(_ path: String) -> Bool { path.hasPrefix("PIONEER/USBANLZ/") }

    /// 곡의 음원·분석 파일 셋(.DAT .EXT .2EX)의 바이트(경로 → 바이트)
    static func files(_ env: UsbEditFixture, _ track: UsbTrack) -> [String: Data?] {
        var result: [String: Data?] = [String(track.path.dropFirst()): env.usb.data(String(track.path.dropFirst()))]
        for ext in [".DAT", ".EXT", ".2EX"] {
            let path = String(track.analysisDataPath.dropFirst().dropLast(4)) + ext
            result[path] = env.usb.data(path)
        }
        return result
    }

    @Test("한 묶음에서 곡을 빼고 다시 넣으면 계획이 통과하는 만큼 쓰기도 통과한다", arguments: [false, true])
    func sameBatchRemoveThenAdd(list: Bool) throws {
        let env = try UsbEditEngineTests.exported(Self.ids)
        let before = try env.read()
        let removed = try #require(before.tracks.first { $0.id == 2 })
        let result = try Self.plan(env, Self.edits(list: list))
        let context = "목록 \(list ? "지정" : "없음"): \(Self.summary(result))"
        #expect(result.outcomes.allSatisfy { $0.outcome == .written }, "\(context)")
        let (report, refused) = try Self.write(env, result)
        #expect(refused.isEmpty, "쓰기 사전 확인이 거부함 \(refused). \(context)")
        guard report != nil else { return }
        #expect(report?.outcome == .written, "\(context)")
        // 곡 2는 사라지고, 같은 경로의 곡이 새 ID로 다시 들어온다. 목록은 곡 2를 잃고 다시 넣은 곡은 목록을 지정했을 때만 끝에 든다
        let after = try env.read()
        #expect(after.tracks.map(\.id).sorted() == [1, 3, 4, 5, 6], "곡 ID \(after.tracks.map(\.id).sorted()). \(context)")
        let readded = try #require(after.tracks.first { $0.id == 6 }, "\(context)")
        #expect(readded.path == removed.path, "다시 넣은 곡의 경로 \(readded.path). \(context)")
        let entries = after.playlists.first { $0.id == 1 }?.entries
        let expected = list ? [1, 3, 4, 5, 6] : [1, 3, 4, 5]
        #expect(entries?[.oneLibrary] == expected && entries?[.deviceLibrary] == expected, "목록 항목 \(String(describing: entries)). \(context)")
        // 음원·분석 파일 셋이 USB에 있고 같은 곡 경로(PPTH)를 가리킨다
        #expect(env.usb.exists(String(readded.path.dropFirst())), "\(context)")
        for ext in [".DAT", ".EXT", ".2EX"] {
            let analysis = String(readded.analysisDataPath.dropFirst().dropLast(4)) + ext
            #expect(env.usb.exists(analysis), "분석 파일 없음 \(analysis). \(context)")
        }
        #expect(UsbExportAssembly.ppthReader(try #require(env.usb.data(String(readded.analysisDataPath.dropFirst())))) == readded.path, "\(context)")
        try UsbEditInvariantTests.check(env, result, context)
    }

    @Test("로컬 분석이 그대로면 빼고 다시 넣어도 분석 파일을 새로 만들지도 쓰지도 않고 두 묶음과 같은 파일이 된다")
    func unchangedAnalysisIsKept() throws {
        let env = try UsbEditEngineTests.exported(Self.ids)
        let untouched = env.usb.tree()
        let result = try Self.plan(env, Self.edits(list: false))
        let analysis = result.changes?.writes.filter { Self.isAnalysis($0.destination) } ?? []
        #expect(analysis.isEmpty, "분석 파일 쓰기가 남음 \(analysis.map { "\($0.destination) \($0.disposition)" }). \(Self.summary(result))")
        let (report, refused) = try Self.write(env, result)
        #expect(refused.isEmpty && report?.outcome == .written, "거부 \(refused). \(Self.summary(result))")
        let readded = try #require(try env.read().tracks.first { $0.id == 6 })

        let control = try UsbEditEngineTests.exported(Self.ids)
        let controlTrack = try Self.twoBatches(control)
        #expect(controlTrack.path == readded.path && controlTrack.analysisDataPath == readded.analysisDataPath)
        #expect(Self.files(control, controlTrack) == Self.files(env, readded), "두 묶음 결과와 파일이 다름")
        // 쓰기 전 백업으로 되돌리면 USB 트리가 쓰기 전과 같다
        #expect(try env.usb.restore().outcome == .restored)
        #expect(env.usb.tree() == untouched, "되돌린 USB가 쓰기 전과 다름")
    }

    @Test("로컬 분석이 바뀌었으면 PPTH·해시를 확인하는 덮어쓰기로 계획하고 두 묶음과 같은 파일이 된다")
    func changedAnalysisIsOverwritten() throws {
        let env = try UsbEditEngineTests.exported(Self.ids)
        let old = try #require(try env.read().tracks.first { $0.id == 2 })
        let oldDAT = try #require(env.usb.data(String(old.analysisDataPath.dropFirst())))
        let untouched = env.usb.tree()
        var spec = TrackSpec(id: "102")
        spec.uuid = UUID().uuidString.lowercased()
        try env.local.local.addCue(track: spec, kind: 1, inMsec: 1_500)
        try env.updateLocal("102", "CueUpdated = '2'")

        let result = try Self.plan(env, Self.edits(list: false))
        let context = Self.summary(result)
        #expect(result.outcomes.allSatisfy { $0.outcome == .written }, "\(context)")
        let dat = String(old.analysisDataPath.dropFirst())
        let write = try #require(result.changes?.writes.first { $0.destination == dat }, "\(context)")
        #expect(write.disposition == .overwrite && write.expectedExistingPPTH == old.path && write.expectedExistingSHA256 == UsbEditEngineTests.sha256(oldDAT),
                "\(context)")
        // 덮어쓰는 파일은 모두 USB에 있던 같은 곡 것이고, 만들 분석 파일은 없다
        let analysis = result.changes?.writes.filter { Self.isAnalysis($0.destination) } ?? []
        #expect(!analysis.isEmpty && analysis.allSatisfy { $0.disposition == .overwrite && $0.expectedExistingPPTH == old.path }, "\(context)")
        let (report, refused) = try Self.write(env, result)
        #expect(refused.isEmpty && report?.outcome == .written, "거부 \(refused). \(context)")
        #expect((report?.filesOverwritten ?? 0) >= 1, "\(String(describing: report))")
        let readded = try #require(try env.read().tracks.first { $0.id == 6 })
        #expect(env.usb.data(dat) != oldDAT, "분석 파일이 그대로임")
        try UsbEditInvariantTests.check(env, result, context)

        let control = try UsbEditEngineTests.exported(Self.ids)
        var controlSpec = TrackSpec(id: "102")
        controlSpec.uuid = UUID().uuidString.lowercased()
        try control.local.local.addCue(track: controlSpec, kind: 1, inMsec: 1_500)
        try control.updateLocal("102", "CueUpdated = '2'")
        let controlTrack = try Self.twoBatches(control)
        #expect(Self.files(control, controlTrack) == Self.files(env, readded), "두 묶음 결과와 파일이 다름")
        // 덮어쓴 분석 파일도 쓰기 전 백업으로 되돌아온다
        #expect(try env.usb.restore().outcome == .restored)
        #expect(env.usb.tree() == untouched, "되돌린 USB가 쓰기 전과 다름")
        #expect(env.usb.data(dat) == oldDAT)
    }

    @Test("그 자리의 분석 파일이 다른 곡 것이면 덮어쓰지 않고 다음 번호에 만든다(다른 곡 파일은 그대로)")
    func foreignAnalysisIsNotOverwritten() throws {
        let env = try UsbEditEngineTests.exported(Self.ids)
        let old = try #require(try env.read().tracks.first { $0.id == 2 })
        let dat = String(old.analysisDataPath.dropFirst())
        // 곡 2의 분석 파일 자리에 다른 곡 경로의 파일을 둔다(번호가 엉킨 USB)
        let foreign = UsbLibraryFixture.dat(path: "/Contents/합성 다른 곡.mp3", hotCueA: nil)
        env.usb.write(dat, foreign)
        let result = try Self.plan(env, Self.edits(list: false))
        let context = Self.summary(result)
        #expect(result.outcomes.allSatisfy { $0.outcome == .written }, "\(context)")
        #expect(result.changes?.writes.contains { $0.destination == dat } == false, "다른 곡 파일 자리를 건드림. \(context)")
        let (report, refused) = try Self.write(env, result)
        #expect(refused.isEmpty && report?.outcome == .written, "거부 \(refused). \(context)")
        #expect(env.usb.data(dat) == foreign, "다른 곡 파일이 바뀜")
        let readded = try #require(try env.read().tracks.first { $0.id == 6 })
        #expect(readded.analysisDataPath.hasSuffix("ANLZ0001.DAT"), "\(readded.analysisDataPath)")
    }

    @Test("두 형식의 분석 파일 번호가 달라도 지운 곡의 자리를 다시 쓴다")
    func reusesDeviceLibrarySlotWhenPathsDiffer() throws {
        let env = try UsbEditEngineTests.exported(Self.ids)
        let track = try #require(try env.read().tracks.first { $0.id == 2 })
        let other = track.analysisDataPath.replacingOccurrences(of: "ANLZ0000", with: "ANLZ0001")
        try #require(other != track.analysisDataPath)
        for ext in [".DAT", ".EXT", ".2EX"] {
            let first = String(track.analysisDataPath.dropFirst().dropLast(4)) + ext
            env.usb.write(String(other.dropFirst().dropLast(4)) + ext, try #require(env.usb.data(first)))
        }
        try env.oneLibrarySQL("UPDATE content SET analysisDataFilePath = ? WHERE content_id = 2", [.text(other)])
        let result = try Self.plan(env, Self.edits(list: false))
        let (report, refused) = try Self.write(env, result)
        #expect(refused.isEmpty && report?.outcome == .written, "거부 \(refused)")
        #expect(try env.read().tracks.first { $0.id == 6 }?.analysisDataPath == track.analysisDataPath)
    }

    @Test("빼기를 먼저 쓰고 다음 묶음에서 더하면 통과한다(대조군)")
    func twoBatchesPass() throws {
        let env = try UsbEditEngineTests.exported(Self.ids)
        let removed = try #require(try env.read().tracks.first { $0.id == 2 })
        let track = try Self.twoBatches(env)
        let after = try env.read()
        #expect(after.tracks.map(\.id).sorted() == [1, 3, 4, 5, 6], "곡 ID \(after.tracks.map(\.id).sorted())")
        #expect(track.path == removed.path)
    }
}
