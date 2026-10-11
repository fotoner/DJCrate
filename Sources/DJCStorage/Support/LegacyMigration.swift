import DJCDomain
import Foundation

/// 옛 이름(anicue)의 데이터 폴더와 설정을 DJCrate로 옮긴다. 이미 옮겼으면 아무것도 하지 않는다.
/// 같은 볼륨 안에서 폴더 이름만 바꾸므로 스냅샷·백업(수백 MB)도 바로 끝난다.
public enum LegacyMigration {
    public struct Result: Equatable, Sendable {
        public var movedSupport = false
        public var movedDocuments = false
        public var copiedDefaults = 0

        public init(movedSupport: Bool = false, movedDocuments: Bool = false, copiedDefaults: Int = 0) {
            self.movedSupport = movedSupport
            self.movedDocuments = movedDocuments
            self.copiedDefaults = copiedDefaults
        }
    }

    /// 앱과 CLI가 시작할 때 부른다(목록·덱이 설정을 읽기 전에).
    @discardableResult
    public static func run() -> Result {
        run(support: URL.applicationSupportDirectory, documents: URL.documentsDirectory, defaults: .standard,
            legacyDefaults: UserDefaults.standard.persistentDomain(forName: DJCIdentity.legacyBundleID),
            legacyAppRunning: isLegacyAppRunning())
    }

    /// - Parameter legacyAppRunning: 옛 앱이 켜져 있으면 아무것도 옮기지 않고 다음 실행으로 미룬다.
    ///   켜진 채 옮기면 옛 앱이 옛 이름으로 폴더를 다시 만들어 쓴다(2026-09-26 실제로 겪음).
    public static func run(support: URL, documents: URL, defaults: UserDefaults, legacyDefaults: [String: Any]?,
                           legacyAppRunning: Bool = false) -> Result {
        let fm = FileManager.default
        var result = Result()
        guard !legacyAppRunning else { return result }
        let oldSupport = support.appending(path: DJCIdentity.legacyName), newSupport = support.appending(path: DJCIdentity.name)
        if fm.fileExists(atPath: oldSupport.path), !fm.fileExists(atPath: newSupport.path) {
            result.movedSupport = (try? fm.moveItem(at: oldSupport, to: newSupport)) != nil
        }
        // rekordbox 연동 XML 폴더(파일 이름도 새 이름으로)
        let oldDocs = documents.appending(path: DJCIdentity.legacyName), newDocs = documents.appending(path: DJCIdentity.name)
        if fm.fileExists(atPath: oldDocs.path), !fm.fileExists(atPath: newDocs.path), (try? fm.moveItem(at: oldDocs, to: newDocs)) != nil {
            result.movedDocuments = true
            let oldXML = newDocs.appending(path: "\(DJCIdentity.legacyName)-rekordbox.xml")
            if fm.fileExists(atPath: oldXML.path) { try? fm.moveItem(at: oldXML, to: newDocs.appending(path: "djcrate-rekordbox.xml")) }
        }
        // 설정: 한 번만. 키 앞머리 "anicue."는 "djc."로(목록 칸 배치·정렬 등)
        let flag = "djc.migratedLegacyDefaults"
        if !defaults.bool(forKey: flag), let legacyDefaults {
            for (key, value) in legacyDefaults {
                let newKey = key.replacingOccurrences(of: "\(DJCIdentity.legacyName).", with: "djc.")
                guard defaults.object(forKey: newKey) == nil else { continue }
                defaults.set(value, forKey: newKey)
                result.copiedDefaults += 1
            }
            defaults.set(true, forKey: flag)
        }
        return result
    }

    /// 옛 앱(anicue.app)이 켜져 있는지 프로세스 경로로 본다.
    public static func isLegacyAppRunning() -> Bool {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/pgrep")
        process.arguments = ["-f", "\(DJCIdentity.legacyName).app/Contents/MacOS/"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return true   // 확인하지 못하면 옮기지 않는다
        }
    }
}
