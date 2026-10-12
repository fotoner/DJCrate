import DJCAdapters
import DJCApplication
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import PortTestKit
import Testing

/// 초안 저장소·추가 목록 포트의 계약(실제 구현, 초안 파일): 가짜(`MemoryDrafts`·`MemoryStaging`)에 DJCApplicationTests가 돌리는
/// 같은 계약 함수(PortTestKit)를 돌린다(adv4 T7: 가짜만 고친 것이 없는 초안을 남겨 실제와 갈렸다).
@MainActor
@Suite("초안 저장소 계약(실제)")
struct DraftStoreContractTests {
    @Test func 실제_구현() throws {
        let folder = try TemporaryFolder()
        try draftStoreContract(DraftStore.live(writer: DraftWriter(), home: folder.url))
    }

    /// 켜진 앱은 재생 목록 초안 파일의 수정 시각으로 CLI의 변경을 알아챈다(#260). 같은 URL 값으로 읽으면
    /// Foundation이 캐시한 첫 시각이 남아 두 번째 변경부터 놓쳤다(260-e2e).
    @Test func 재생_목록_초안_시각은_바뀔_때마다_새로_읽는다() throws {
        let folder = try TemporaryFolder()
        let drafts = DraftStore.live(writer: DraftWriter(), home: folder.url)
        // CLI가 만든 초안 파일처럼 둔다(내용은 시각 판정과 관계없다)
        let path = folder.url.appending(path: DraftFileNames.playlist).path
        try Data("{}".utf8).write(to: URL(filePath: path))
        #expect(drafts.fileStamps()[path] != nil)
        for offset in [60.0, 120.0] {
            let date = Date(timeIntervalSince1970: 2_000_000_000 + offset)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
            #expect(drafts.fileStamps()[path] == date)
        }
    }

    /// 추가 목록 포트(`StagingStore`, `DraftStore`에서 옮김): 파일로 읽고 쓴다
    @Test func 추가_목록_실제_구현() throws {
        let folder = try TemporaryFolder()
        try stagingStoreContract(StagingStore.live(home: folder.url))
    }
}
