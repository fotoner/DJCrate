import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import Testing

/// 옛 이름(anicue) 데이터 옮기기
@Suite("이름 바꾼 뒤 데이터 옮기기")
struct LegacyMigrationTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "djc-migration-\(UUID().uuidString)")
    var support: URL { root.appending(path: "Application Support") }
    var documents: URL { root.appending(path: "Documents") }

    func defaults() -> UserDefaults { TestDefaults.make("migration") }

    @Test func 옛_폴더를_새_이름으로_옮기고_설정을_한_번만_복사한다() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: support.appending(path: "anicue/cue-drafts"), withIntermediateDirectories: true)
        try Data("초안".utf8).write(to: support.appending(path: "anicue/cue-drafts/a.json"))
        try fm.createDirectory(at: documents.appending(path: "anicue"), withIntermediateDirectories: true)
        try Data("<xml/>".utf8).write(to: documents.appending(path: "anicue/anicue-rekordbox.xml"))
        let d = defaults()
        let legacy: [String: Any] = ["anicue.trackList.albumColumnPlaced": true, "NSTableView Columns anicue.trackList.v2": ["a"], "gainTrim": 1.5]

        let first = LegacyMigration.run(support: support, documents: documents, defaults: d, legacyDefaults: legacy)
        #expect(first == .init(movedSupport: true, movedDocuments: true, copiedDefaults: 3))
        #expect(fm.fileExists(atPath: support.appending(path: "DJCrate/cue-drafts/a.json").path))
        #expect(!fm.fileExists(atPath: support.appending(path: "anicue").path))
        #expect(fm.fileExists(atPath: documents.appending(path: "DJCrate/djcrate-rekordbox.xml").path))
        #expect(d.bool(forKey: "djc.trackList.albumColumnPlaced") && d.array(forKey: "NSTableView Columns djc.trackList.v2") != nil)
        #expect(d.double(forKey: "gainTrim") == 1.5)

        // 두 번째는 아무것도 하지 않는다(새 값을 옛 값으로 덮지 않음)
        d.set(false, forKey: "djc.trackList.albumColumnPlaced")
        let second = LegacyMigration.run(support: support, documents: documents, defaults: d, legacyDefaults: legacy)
        #expect(second == .init())
        #expect(!d.bool(forKey: "djc.trackList.albumColumnPlaced"))
        try? fm.removeItem(at: root)
    }

    @Test func 옛_앱이_켜져_있으면_옮기지_않고_다음으로_미룬다() throws {
        // 옛 앱이 켜진 채 폴더를 옮기면 그 앱이 옛 이름으로 폴더를 다시 만들어 캐시를 쓴다(2026-09-26 실제로 겪음).
        let fm = FileManager.default
        try fm.createDirectory(at: support.appending(path: "anicue/cue-drafts"), withIntermediateDirectories: true)
        let d = defaults()
        let skipped = LegacyMigration.run(support: support, documents: documents, defaults: d, legacyDefaults: ["gainTrim": 1.0],
                                          legacyAppRunning: true)
        #expect(skipped == .init() && fm.fileExists(atPath: support.appending(path: "anicue").path))
        #expect(!d.bool(forKey: "djc.migratedLegacyDefaults"), "설정도 다음에 옮긴다")
        let later = LegacyMigration.run(support: support, documents: documents, defaults: d, legacyDefaults: ["gainTrim": 1.0],
                                        legacyAppRunning: false)
        #expect(later.movedSupport && later.copiedDefaults == 1)
        try? fm.removeItem(at: root)
    }

    @Test func 새_폴더가_이미_있으면_옛_폴더를_건드리지_않는다() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: support.appending(path: "anicue"), withIntermediateDirectories: true)
        try fm.createDirectory(at: support.appending(path: "DJCrate"), withIntermediateDirectories: true)
        let result = LegacyMigration.run(support: support, documents: documents, defaults: defaults(), legacyDefaults: nil)
        #expect(!result.movedSupport && fm.fileExists(atPath: support.appending(path: "anicue").path))
        try? fm.removeItem(at: root)
    }
}
