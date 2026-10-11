import DJCApplication
import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit

extension UsbHistoryFiles {
    /// 보존 기록 폴더(`directory`, 앱은 DJC_HOME의 `usb-histories/`)의 기록 파일(DJCStorage `UsbHistoryStore`).
    /// 해석하지 못한 파일은 `home`의 `damaged-drafts/usb-histories/`로 옮긴다. 폴더는 조립 지점이 정한다
    public static func live(directory: URL, home: URL, fileSystem: any UsbFileSystem = PosixUsbFileSystem()) -> UsbHistoryFiles {
        let store = UsbHistoryStore(directory: directory, home: home, fileSystem: fileSystem)
        return UsbHistoryFiles(
            load: {
                let loaded = store.load()
                return ArchivedHistoryLoad(histories: loaded.histories, damaged: loaded.damaged, unreadable: loaded.unreadable)
            },
            save: { history in
                do { try store.save([history]) } catch {
                    FileHandle.standardError.write(Data("[USB 재생 기록] 보존 실패 \(history.id): \(error)\n".utf8))
                    throw error
                }
            },
            containsExact: { store.containsExact($0) })
    }
}
