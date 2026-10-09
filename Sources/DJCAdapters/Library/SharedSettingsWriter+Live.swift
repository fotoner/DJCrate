import DJCApplication
import DJCDomain
import DJCStorage
import Foundation

extension SharedSettingsWriter {
    /// 공유 설정 파일 `file`(DJCStorage `SharedSettingsFile`의 규칙)
    public static func live(file: URL) -> SharedSettingsWriter {
        SharedSettingsWriter(names: SharedSettingsFile.names, set: { try SharedSettingsFile.set($0, in: file) })
    }

    /// 이 프로세스의 데이터 폴더(`DJC_HOME`을 따른다)의 공유 설정 파일
    public static var live: SharedSettingsWriter { live(file: SharedSettingsFile.file) }
}
