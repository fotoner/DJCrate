import Foundation
import Testing

/// 자동 저장은 기본 동작이고 끄는 설정이 없다(#404, R3 첫 문장). 설정 키와 설정 화면의 소스에 자동 저장을 켜고 끄는 항목이 없다.
/// 성공 토스트를 보인 횟수 키(`activity.writeToastsShown`)는 켜고 끄는 값이 아니라 센 수다.
@Suite("자동 저장 끄는 설정 없음")
struct AutoSaveHasNoSwitchTests {
    static let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// 주석을 뺀 소스 줄
    static func codeLines(_ relative: String) throws -> [String] {
        try String(contentsOf: root.appending(path: relative), encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }

    @Test func 설정_키_이름에_자동_저장이_없다() throws {
        let lines = try Self.codeLines("Sources/DJCDomain/Settings/SettingKeys.swift")
        let names = lines.compactMap { line -> String? in
            guard let start = line.range(of: "SettingKey"), let open = line[start.upperBound...].firstIndex(of: "\"") else { return nil }
            let rest = line[line.index(after: open)...]
            return rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
        }
        #expect(names.count > 20, "키 이름을 읽었다")
        for name in names {
            let lowered = name.lowercased()
            #expect(!lowered.contains("autosave") && !lowered.contains("autoreflect") && !lowered.contains("autowrite"), "\(name)")
        }
    }

    @Test func 설정_화면_문구에_자동_저장이_없다() throws {
        let folder = Self.root.appending(path: "Sources/DJCrate/Settings")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        #expect(files.count > 5)
        for file in files {
            let lines = try Self.codeLines("Sources/DJCrate/Settings/" + file.lastPathComponent)
            for line in lines where line.contains("\"") {
                #expect(!line.contains("자동 저장"), "\(file.lastPathComponent): \(line)")
            }
        }
    }
}
