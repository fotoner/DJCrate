import DJCDomain
import Foundation

/// 로컬 스냅샷 사본을 뜬 시각. USB 계획·쓰기가 "이 시각 뒤에 로컬에서 바뀐 곡"을 가리는 기준이다.
public enum UsbSnapshotTime {
    public typealias Source = UsbSnapshotTimeSource

    /// 순서: explicit(ISO 8601, 예 "2026-09-27T11:41:08Z") → 파일 이름(`LibrarySnapshot.takenAt`, UTC) → 파일 mtime.
    /// explicit이 있는데 못 풀면 던진다. 셋 다 없으면 던진다(추측하지 않음).
    public static func resolve(explicit: String?, database: URL) throws -> (date: Date, source: Source) {
        if let explicit {
            guard let date = parse(explicit) else {
                throw UsbError.writeRefused([UsbBlock(
                    code: "snapshotTimeInvalid", scope: .volume,
                    message: String(ui: "스냅샷 시각(\(explicit))을 읽지 못했습니다. 시간대를 넣은 ISO 8601 시각(예: 2026-09-27T11:41:08Z)으로 주세요"))])
            }
            return (date, .explicit)
        }
        if let date = LibrarySnapshot.takenAt(database) { return (date, .fileName) }
        if let date = try? FileManager.default.attributesOfItem(atPath: database.path)[.modificationDate] as? Date {
            return (date, .modificationDate)
        }
        throw UsbError.writeRefused([UsbBlock(
            code: "snapshotTimeUnknown", scope: .volume,
            message: String(ui: "로컬 라이브러리 사본을 뜬 시각을 알 수 없습니다. 스냅샷을 다시 뜨거나 --snapshot-time에 시각을 주세요"))])
    }

    /// 시간대가 있어야 한다(없으면 어느 시각인지 추측하게 된다). 소수 초도 받는다.
    static func parse(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return plain.date(from: text) ?? fractional.date(from: text)
    }
}
