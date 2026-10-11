import DJCDomain
import Foundation
import Testing

@Suite("USB 확인 안 된 규칙")
struct UsbProvisionalRuleTests {
    @Test("처음에는 확인한 규칙이 없다")
    func allRulesStartUnconfirmed() {
        #expect(UsbProvisionalRule.confirmed.isEmpty)
        #expect(UsbProvisionalRule.allCases.allSatisfy { !$0.isConfirmed })
    }

    @Test("늘 막는 규칙은 기기 기록 행 옮기기 하나뿐")
    func onlyCarriedDeviceRowsAlwaysBlocks() {
        #expect(UsbProvisionalRule.allCases.filter(\.alwaysBlocks) == [.carriedDeviceRows])
    }

    @Test("CDJ에서 확인하지 않은 항목으로 알리는 규칙: 흐름 규칙·관문 규칙·늘 막는 규칙을 뺀 곡 내용 규칙")
    func deviceCheckRules() {
        #expect(UsbProvisionalRule.flowRules == [.analysisFolderNaming, .playlistSiblingBase, .playlistFolderRow,
                                                 .editAddTracks, .editRemoveTracks, .editPlaylists, .trackRemovalFiles,
                                                 .pdbRegeneratedEdit, .deviceLibraryMigration])
        #expect(UsbProvisionalRule.cueVariant.needsDeviceCheck)
        #expect(UsbProvisionalRule.artworkMissing.needsDeviceCheck)
        #expect(!UsbProvisionalRule.analysisFolderNaming.needsDeviceCheck)
        #expect(!UsbProvisionalRule.physicalVolume.needsDeviceCheck)
        #expect(!UsbProvisionalRule.carriedDeviceRows.needsDeviceCheck)
        #expect(UsbProvisionalRule.deviceCheckRules([.cueVariant, .analysisFolderNaming, .artworkMissing, .physicalVolume])
            == [.artworkMissing, .cueVariant])
    }

    @Test("관문으로만 푸는 규칙은 실물 볼륨 하나뿐")
    func onlyPhysicalVolumeIsGateOnly() {
        #expect(UsbProvisionalRule.allCases.filter(\.isGateOnly) == [.physicalVolume])
    }

    @Test("저장되는 이름이 바뀌지 않는다")
    func rawValuesAreStable() {
        // 계획·초안에 rawValue로 저장한다. 이름을 바꾸면 저장한 값을 읽지 못한다.
        #expect(UsbProvisionalRule.allCases.map(\.rawValue) == [
            "physicalVolume",
            "analysisFolderNaming", "analysisSlotCollision",
            "playlistSiblingBase", "playlistFolderRow", "myTagLinks", "myTagMasterDBID",
            "artworkFolderSplit", "artworkMissing",
            "fileNameTruncation", "forbiddenCharacters", "pathCollision", "emptyArtistAlbum", "supplementaryCharacters", "leadingSpace",
            "cueSeekFields", "cueVariant", "fileTypeUnverified", "metadataSeenEmptyOnly",
            "pdbLongAscii", "pdbFarOffsetRows",
            "carriedDeviceRows",
            "settingFiles",
            "pdbRegeneratedEdit", "trackRemovalFiles",
            "editRefreshTracks", "editRemoveTracks", "editAddTracks", "editPlaylists",
            "deviceLibraryMigration",
            "audioChangedSinceAnalysis",
            "pdbStringNFC",
        ])
        let decoded = try? JSONDecoder().decode([UsbProvisionalRule].self, from: Data(#"["cueVariant","physicalVolume"]"#.utf8))
        #expect(decoded == [.cueVariant, .physicalVolume])
    }

    @Test("모든 규칙에 한 줄 설명이 있다")
    func everyRuleHasSummary() {
        for rule in UsbProvisionalRule.allCases {
            #expect(!rule.summary.trimmingCharacters(in: .whitespaces).isEmpty, "\(rule.rawValue)")
        }
        #expect(Set(UsbProvisionalRule.allCases.map(\.summary)).count == UsbProvisionalRule.allCases.count)
    }

    @Test("형식 기본값은 두 형식 모두")
    func defaultFormatsAreBoth() {
        #expect(UsbFormat.defaultSet == [.oneLibrary, .deviceLibrary])
        #expect(UsbFormat.allCases.map(\.rawValue) == ["oneLibrary", "deviceLibrary"])
    }
}
