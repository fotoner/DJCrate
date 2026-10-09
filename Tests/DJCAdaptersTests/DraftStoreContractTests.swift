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

    /// 추가 목록 포트(`StagingStore`, `DraftStore`에서 옮김): 파일로 읽고 쓴다
    @Test func 추가_목록_실제_구현() throws {
        let folder = try TemporaryFolder()
        try stagingStoreContract(StagingStore.live(home: folder.url))
    }
}
