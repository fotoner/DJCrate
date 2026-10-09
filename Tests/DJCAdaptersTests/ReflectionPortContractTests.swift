import DJCAdapters
import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import PortTestKit
import RekordboxFixtures
import RekordboxKit
import Testing

/// 반영 세션 포트의 계약(실제 구현): 세션 시험(DJCApplicationTests)이 가짜에 돌리는 계약 함수(PortTestKit)를 실제 구현(DJCAdapters)에 돌린다
/// (adv4 T7: 가짜와 실제가 갈라져도 세션 시험이 모르고 통과했다). 실제 구현은 합성 rekordbox 사본·임시 폴더로만 시험한다.
@MainActor
@Suite("반영 포트 계약(실제)")
struct ReflectionPortContractTests {
    static let copyGuard = RekordboxWriteGuard(isLive: { _ in false }, isRekordboxRunning: { false }, appVersion: { "7.2.18" })

    @Test func 백업_폴더_실제_구현() throws {
        let folder = try TemporaryFolder(prefix: "djc-backups-contract")
        // 곡 넣기 백업 폴더는 쓰기 관문이 만든 뒤에 남긴다
        try FileManager.default.createDirectory(at: folder.url.appending(path: backupContractName), withIntermediateDirectories: true)
        try backupsContract(.live(), folder: folder.url)
    }

    @Test func 백업에_남기지_못하면_던진다() throws {
        let folder = try TemporaryFolder(prefix: "djc-backups-contract")
        backupsSaveFailureContract(.live(writeFile: { _, _ in throw CocoaError(.fileWriteNoPermission) }),
                                   backup: folder.url.appending(path: backupContractName))
    }

    @Test func 쓰기_관문_실제() async throws {
        let fixture = try RekordboxFixture(localUpdateCount: 1000)
        let spec = TrackSpec()
        try fixture.add(spec)
        try Self.emptyPlaylistsXML.write(to: fixture.root.appending(path: "masterPlaylists6.xml"), atomically: true, encoding: .utf8)
        var cue = CueDraft(trackUUID: spec.uuid)
        cue.place(EditableCue(kind: .hot(0), time: 4))
        try await writeGateContract(.live(guard: Self.copyGuard),
                                    target: RekordboxWriteTarget(database: fixture.database, shareRoot: fixture.shareRoot, backups: fixture.backups),
                                    batch: DraftWriteBatch(drafts: [cue]))
    }

    /// 목록이 없는 masterPlaylists6.xml(재생 목록 쓰기의 출발점)
    static let emptyPlaylistsXML = [
        #"<?xml version="1.0" encoding="UTF-8"?>"#, "",
        #"<MASTER_PLAYLIST Version="3.0.0" AutomaticSync="0">"#,
        #"  <PRODUCT Name="rekordbox" Version="6.6.11" Company="Pioneer DJ"/>"#,
        "  <PLAYLISTS>", "  </PLAYLISTS>", "</MASTER_PLAYLIST>", "",
    ].joined(separator: "\r\n")
}

/// 음원 읽기 포트의 실제 구현(분석 붙이기·곡 넣기가 쓰는 값)
@Suite("음원 읽기(실제)")
struct TrackAudioReaderLiveTests {
    @Test func 분석_전_곡_판정과_태그_넣기_계획() async throws {
        let folder = try TemporaryFolder(prefix: "djc-audio-reader")
        let url = try AudioFixture.wav(seconds: 0.5, in: folder.url, name: "a.wav")
        let audio = TrackAudioReader.live { _ in nil }
        #expect(audio.needsAnalysis(nil) && audio.needsAnalysis("") && !audio.needsAnalysis("/PIONEER/USBANLZ/P000/0000/ANLZ0000.DAT"))
        let tags = try await audio.tags(url)
        #expect(tags.duration > 0.4)
        let plan = try audio.addPlan(url, tags)
        #expect(plan.fileName == "a.wav" && plan.duration == tags.duration)
        #expect(await audio.loudness(url) == nil, "음량은 준 쪽(캐시)이 잰다")
    }
}

/// 반영 XML 계획 묶음 저장 포트의 계약(실제): 남긴 것을 그대로 읽고, nil을 남기면 지운다.
@Suite("반영 묶음 저장 계약(실제)")
struct ReflectionBatchStoreContractTests {
    @Test func 실제_구현() throws {
        let folder = try TemporaryFolder(prefix: "djc-reflection-batch")
        try reflectionBatchStoreContract(.live(url: folder.url.appending(path: "home/reflection.json")))
    }
}
