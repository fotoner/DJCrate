import Foundation

/// 로컬 스냅샷 사본을 뜬 시각을 어디서 알았는지(RekordboxKit `UsbSnapshotTime.resolve`)
public enum UsbSnapshotTimeSource: String, Sendable { case explicit, fileName, modificationDate }
