@testable import DJCDomain
import Foundation
import Testing

/// 제안 판정(R5): 사람 편집만 든 도장이고 지금 내용이 기록한 해시와 같을 때만 자동 저장 대상이다. 나머지는 제안이라 ⌘S·단추로 함께 쓴다.
@Suite("초안 제안 판정")
struct DraftSuggestionTests {
    private static func hash(_ text: String) throws -> DraftContentHash { try DraftContentHash(of: text) }

    private static func stamp(_ origins: Set<DraftOrigin>, content: String = "a") throws -> DraftStamp {
        DraftStamp(revision: DraftRevision(1), origins: origins, contentHash: try hash(content))
    }

    @Test func 사람_편집만_들고_해시가_맞으면_제안이_아니다() throws {
        let stamp = try Self.stamp([.human])
        #expect(DraftSuggestion.judge(stamp: stamp, currentHash: try Self.hash("a")) == nil)
    }

    @Test func 사람_편집이_아닌_출처는_제안이다() throws {
        for origin in [DraftOrigin.cli, .agent, .link, .restored] {
            #expect(DraftSuggestion.judge(stamp: try Self.stamp([origin]), currentHash: try Self.hash("a")) == .notHuman, "\(origin)")
        }
    }

    @Test func 출처를_모르는_초안은_제안이다() throws {
        // 업데이트 전부터 있던 초안은 도장이 없다
        #expect(DraftSuggestion.judge(stamp: nil, currentHash: try Self.hash("a")) == .unknownOrigin)
        #expect(DraftSuggestion.judge(stamp: try Self.stamp([.unknown]), currentHash: try Self.hash("a")) == .unknownOrigin)
        #expect(DraftSuggestion.judge(stamp: try Self.stamp([]), currentHash: try Self.hash("a")) == .unknownOrigin)
        // 사람 편집에 모름이 섞여도 모름이 먼저다
        #expect(DraftSuggestion.judge(stamp: try Self.stamp([.human, .unknown]), currentHash: try Self.hash("a")) == .unknownOrigin)
    }

    @Test func 사람_편집과_다른_출처가_섞이면_제안이다() throws {
        #expect(DraftSuggestion.judge(stamp: try Self.stamp([.human, .cli]), currentHash: try Self.hash("a")) == .mixedOrigins)
        #expect(DraftSuggestion.judge(stamp: try Self.stamp([.human, .link, .restored]), currentHash: try Self.hash("a")) == .mixedOrigins)
    }

    @Test func 내용_해시가_기록과_맞지_않으면_제안이다() throws {
        let stamp = try Self.stamp([.human])
        #expect(DraftSuggestion.judge(stamp: stamp, currentHash: try Self.hash("바깥에서 고침")) == .contentChanged)
        // 지금 내용을 읽지 못해도(해시를 못 구함) 자동으로 쓰지 않는다
        #expect(DraftSuggestion.judge(stamp: stamp, currentHash: nil) == .contentChanged)
    }

    @Test func 출처_판정이_해시_판정보다_먼저다() throws {
        // CLI 초안은 해시가 달라도 사유는 출처다(제안 사유 하나만 보인다)
        #expect(DraftSuggestion.judge(stamp: try Self.stamp([.cli]), currentHash: try Self.hash("바깥")) == .notHuman)
    }

    @Test func 사유_원시값은_JSON에_그대로_쓴다() {
        #expect(DraftSuggestion.allCases.map(\.rawValue) == ["not_human", "mixed_origins", "unknown_origin", "content_changed"])
    }

    /// 그림 초안의 해시는 그림 바이트가 아니라 초안의 `imageSHA256`로 본다(같은 그림이면 같고, 그림이 바뀌면 다르다)
    @Test func 그림_초안_해시는_초안_칸으로_본다() throws {
        func edit(_ sha: String) -> ArtworkEdit {
            ArtworkEdit(draft: ArtworkDraft(trackUUID: "t", change: .set, base: ArtworkBase(imagePath: ""), imageName: "a.png", imageSHA256: sha), image: Data(sha.utf8))
        }
        #expect(try DraftContentHash(artwork: edit("aa")) == DraftContentHash(artwork: edit("aa")))
        #expect(try DraftContentHash(artwork: edit("aa")) != DraftContentHash(artwork: edit("bb")))
        #expect(try DraftContentHash(artwork: edit("aa")) == DraftContentHash(of: edit("aa").draft))
    }
}
