@testable import DJCrate
import DJCTestKit
import Foundation
import Synchronization
import Testing

/// 중복 후보 화면의 합치기 준비(#244에서 뷰의 `Task`·`@State`를 옮겼다). 준비(확인 창·초안 만들기)는 가짜로 넣는다.
@MainActor
@Suite("중복 후보 화면 모델")
struct DuplicateTracksModelTests {
    @Test func 합치기를_준비하는_동안_단추를_막고_끝나면_푼다() async {
        var asked: [(String, [String])] = []
        var preparingDuringCall: Bool?
        var model: DuplicateTracksModel!
        model = DuplicateTracksModel(prepare: { keeping, removing in
            asked.append((keeping, removing))
            preparingDuringCall = model.isPreparing
        })
        model.startMerge(keeping: "2", removing: ["1", "3"])
        #expect(model.isPreparing)
        await model.task?.value
        #expect(asked.map(\.0) == ["2"] && asked.map(\.1) == [["1", "3"]])
        #expect(preparingDuringCall == true && !model.isPreparing)
    }
}
