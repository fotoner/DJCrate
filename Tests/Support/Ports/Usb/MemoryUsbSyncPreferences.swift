import DJCApplication
import DJCDomain
import Foundation
import Synchronization

/// USB 동기화 설정의 메모리 구현: 볼륨키별로 저장한 것을 읽고, 저장한 차례를 남긴다(`saves`).
/// 실제(`UsbSyncFiles.live.preferences`)와 같은 약속인지는 `usbSyncPreferencesContract`가 본다
public final class MemoryUsbSyncPreferences: Sendable {
    private let state = Mutex<(stored: [String: UsbSyncPreferences], saves: [UsbSyncPreferences])>(([:], []))

    public init() {}

    /// 저장한 설정(차례대로)
    public var saves: [UsbSyncPreferences] { state.withLock { $0.saves } }

    public var files: UsbSyncPreferencesFiles {
        UsbSyncPreferencesFiles(load: { key in self.state.withLock { $0.stored[key] } },
                                save: { prefs in
                                    self.state.withLock { state in
                                        state.stored[prefs.volumeKey] = prefs
                                        state.saves.append(prefs)
                                    }
                                })
    }
}
