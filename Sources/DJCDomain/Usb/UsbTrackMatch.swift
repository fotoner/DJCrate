import Foundation

/// USB 곡 행에서 로컬 곡을 찾는 열쇠(OneLibrary content의 masterDbId·masterContentId = pdb 트랙 0x18·0x14, 경로 끝 성분)
public struct UsbTrackKey: Sendable, Hashable {
    public var masterDbId: Int64
    public var masterContentId: Int64
    public var fileName: String

    public init(masterDbId: Int64, masterContentId: Int64, fileName: String) {
        self.masterDbId = masterDbId
        self.masterContentId = masterContentId
        self.fileName = fileName
    }
}

/// 로컬 곡 쪽 열쇠(djmdContent)
public struct UsbLocalTrackKey: Sendable, Hashable {
    public var contentID: String
    public var masterSongID: String
    public var fileNameL: String
    /// djmdContent.FolderPath(음원 절대 경로). 내보내기는 이 경로의 끝 성분으로 USB 파일 이름을 짓는다
    public var folderPath: String?

    public init(contentID: String, masterSongID: String, fileNameL: String, folderPath: String? = nil) {
        self.contentID = contentID
        self.masterSongID = masterSongID
        self.fileNameL = fileNameL
        self.folderPath = folderPath
    }

    /// USB 파일 이름이 될 수 있는 원본 이름: 음원 경로의 끝 성분과 `FileNameL`(옛 DJCrate는 `FileNameL`로 지었다)
    var sourceNames: [String] {
        let audio = UsbPathRules.audioFileName(sourcePath: folderPath, fileNameL: fileNameL)
        return audio == fileNameL ? [fileNameL] : [audio, fileNameL]
    }
}

public enum UsbTrackMatch {
    /// 같은 이름이 있을 때 내보내기가 붙이는 번호(`UsbExportPlanner`: " (2)" … " (99)")
    static let suffixNumbers = 2...99

    /// 이 로컬 라이브러리에서 내보낸 곡(DB ID)이고 곡 ID(`MasterSongID`)가 같은 로컬 곡 중, USB 경로 끝 성분이 그 곡의 파일 이름인 곡 하나.
    /// 없거나 둘 이상이면 nil.
    /// - 경로 끝 성분은 원본 이름(음원 경로의 끝 성분·`FileNameL`) 그대로이거나 내보내기 이름 규칙(`UsbPathRules.fileName` — 금지 글자·자르기)으로
    ///   지은 이름, 그 이름에 번호(`withSuffix`)를 붙인 이름이어야 한다. 2026-10-09 전 규칙(`~`를 그대로 둠)으로 지은 이름도 받는다(그때 쓴 USB).
    ///   FAT처럼 대소문자·NFC/NFD를 가리지 않는다(같은 파일을 USB 철자로 가리킨다).
    /// - 그대로 맞는 곡이 번호를 붙여 맞는 곡보다 앞선다.
    /// - 아티스트·앨범 폴더 성분은 보지 않는다(로컬에서 이름을 바꾼 곡도 갱신할 수 있게).
    public static func match(_ usb: UsbTrackKey, localDBID: Int64, local: [UsbLocalTrackKey]) -> String? {
        guard usb.masterDbId == localDBID else { return nil }
        let candidates = local.filter { Int64($0.masterSongID) == usb.masterContentId }
        guard !candidates.isEmpty else { return nil }
        let name = UsbLayout.collisionKey(usb.fileName)
        let exact = Set(candidates.filter { candidate in
            candidate.sourceNames.contains { exportNames($0).contains(name) }
        }.map(\.contentID))
        if !exact.isEmpty { return exact.count == 1 ? exact.first : nil }
        let numbered = Set(candidates.filter { candidate in
            let bases = Set(candidate.sourceNames.flatMap { [UsbPathRules.fileName($0).value, UsbPathRules.legacyFileName($0)] })
            return bases.contains { base in
                suffixNumbers.contains { UsbLayout.collisionKey(UsbPathRules.withSuffix(base, number: $0)) == name }
            }
        }.map(\.contentID))
        return numbered.count == 1 ? numbered.first : nil
    }

    /// 원본 이름 하나가 USB에서 될 수 있는 이름(번호 없음, 충돌 키): 그대로, 지금 규칙, 2026-10-09 전 규칙
    static func exportNames(_ source: String) -> Set<String> {
        [UsbLayout.collisionKey(source), UsbLayout.collisionKey(UsbPathRules.fileName(source).value),
         UsbLayout.collisionKey(UsbPathRules.legacyFileName(source))]
    }
}
