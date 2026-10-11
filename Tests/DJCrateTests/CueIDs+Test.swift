import DJCDomain
import Foundation

// 시험 도우미: 핵심부는 큐 ID를 받아서만 만든다(#167). ID 값이 상관없는 시험은 옛 모양 그대로 무작위 ID로 만든다.
// rekordbox 큐로 만드는 초안·자동 큐 채우기는 RekordboxKit의 같은 모양(`CueDraft+IDs`)을 쓴다.
extension EditableCue {
    init(sourceID: String? = nil, kind: Kind, time: Double, name: String = "", loop: Loop? = nil) {
        self.init(id: UUID(), sourceID: sourceID, kind: kind, time: time, name: name, loop: loop)
    }
}
