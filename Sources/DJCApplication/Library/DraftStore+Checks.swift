import DJCDomain
import Foundation

extension DraftStore {
    /// 저장이 끝나지 않았거나 실패한 초안이 있으면 막는다(디스크의 옛 초안을 쓰거나 내보내지 않게, #170)
    public func requireSaved(_ uuids: Set<String>) throws {
        flush()
        if let failure = failures().first(where: { uuids.contains($0.trackUUID) }) {
            throw DJCError.writeRefused(failure.message)
        }
        guard unsavedUUIDs().isDisjoint(with: uuids) else {
            throw DJCError.writeRefused(String(ui: "초안 저장이 끝나지 않았으니 저장을 마친 뒤 쓰기를 다시 시도하세요."))
        }
    }

    /// 쓰기·복원 뒤 초안 저장에 실패한 곡이 있으면 그 경고(쓰기는 이미 끝났으니 실패로 바꾸지 않는다)
    public func saveWarning(for uuids: Set<String>, restoring: Bool) -> String? {
        flush()
        guard let failure = failures().first(where: { uuids.contains($0.trackUUID) }) else { return nil }
        let result = restoring ? String(ui: "rekordbox는 복원했지만 초안을 저장하지 못했습니다.")
            : String(ui: "rekordbox에는 썼지만 초안을 정리하지 못했습니다.")
        return result + " " + failure.message
    }
}
