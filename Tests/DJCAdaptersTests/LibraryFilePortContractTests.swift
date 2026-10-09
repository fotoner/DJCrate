import DJCAdapters
import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import PortTestKit
import Testing

/// 곡별 초안 파일·재생 목록 연결 기록·XML 파일·파일 확인 포트의 계약(실제 구현): 가짜에 DJCApplicationTests가 돌리는 같은 계약 함수를 돌린다.
@Suite("라이브러리 파일 포트 계약(실제)")
struct LibraryFilePortContractTests {
    @Test func 초안_파일_실제_구현() throws {
        let folder = try TemporaryFolder(prefix: "djc-draft-files")
        try draftFilesContract(.live(home: folder.url))
        // 읽지 못하는 파일은 있는 것으로 보고(덮지 않는다) 읽으면 던진다
        let broken = folder.url.appending(path: "cue-drafts/b.json")
        try Data("{".utf8).write(to: broken)
        let files = DraftFiles.live(home: folder.url)
        #expect(files.exists(.cue, "b"))
        #expect(throws: (any Error).self) { try files.cue("b") }
    }

    @Test func 연결_기록_실제_구현() throws {
        let folder = try TemporaryFolder(prefix: "djc-playlist-imports")
        try playlistImportsContract(.live(url: folder.url.appending(path: "playlist-imports.json")), remembers: true)
    }

    @Test func XML_파일_실제_구현() throws {
        let folder = try TemporaryFolder(prefix: "djc-xml-files")
        try xmlFilesContract(.live, folder: folder.url)
        // 다른 도구가 만든 것처럼 보여도 rekordbox XML이 아니면 읽기 오류
        let text = folder.url.appending(path: "아님.xml")
        try Data("<html/>".utf8).write(to: text)
        #expect(throws: XMLReadError.self) { try XMLFiles.live.read(text) }
    }

    @Test func 파일_확인_실제_구현() throws {
        let folder = try TemporaryFolder(prefix: "djc-track-files")
        let file = folder.url.appending(path: "a.bin")
        try Data([1, 2, 3]).write(to: file)
        #expect(TrackFiles.live.exists(file.path) && !TrackFiles.live.exists(folder.url.appending(path: "없음").path))
        #expect(try TrackFiles.live.read(file) == Data([1, 2, 3]))
        #expect(TrackFiles.live.audioFiles([file]).isEmpty, "음원이 아니면 고르지 않는다")
    }
}
