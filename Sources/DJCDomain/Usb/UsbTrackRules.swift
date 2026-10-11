import Foundation

/// 곡 정보 칸 중 rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)에서 빈 값으로만 본 칸에 값이 있는지
public struct UsbTrackMetadataFlags: Codable, Sendable, Hashable {
    public var hasLabel = false
    public var hasRemixer = false
    public var hasOriginalArtist = false
    public var hasLyricist = false
    public var hasColor = false
    public var hasRating = false
    public var hasSubtitle = false
    public var hasSearchString = false
    public var isCompilation = false

    public init(hasLabel: Bool = false, hasRemixer: Bool = false, hasOriginalArtist: Bool = false, hasLyricist: Bool = false,
                hasColor: Bool = false, hasRating: Bool = false, hasSubtitle: Bool = false, hasSearchString: Bool = false,
                isCompilation: Bool = false) {
        self.hasLabel = hasLabel
        self.hasRemixer = hasRemixer
        self.hasOriginalArtist = hasOriginalArtist
        self.hasLyricist = hasLyricist
        self.hasColor = hasColor
        self.hasRating = hasRating
        self.hasSubtitle = hasSubtitle
        self.hasSearchString = hasSearchString
        self.isCompilation = isCompilation
    }

    public var hasAny: Bool {
        hasLabel || hasRemixer || hasOriginalArtist || hasLyricist || hasColor || hasRating || hasSubtitle || hasSearchString
            || isCompilation
    }
}

/// 곡 칸·문자열 → 확인 안 된 규칙
public enum UsbTrackRules {
    /// 짧은 ASCII 문자열 머리 ((n+1)<<1)+1 이 u8에 들어가는 한계는 n ≤ 126. 그보다 긴 ASCII는 긴 머리로 써야 한다.
    public static let longAsciiThreshold = 127

    /// 로컬 djmdContent.FileType → USB 파일 확장자. 모르면 nil(내보내지 않는다).
    /// 1 MP3, 4 M4A, 5 FLAC, 11 WAV, 12 AIFF. 3 → mp4·6 → m4a 대응은 추정(확인 전)이라 fileTypeUnverified로 막는다.
    /// 그 밖의 값은 모른다. 1·4·5 밖의 형식은 모두 fileTypeUnverified를 싣는다.
    public static let knownFileTypes: [Int: String] = [1: "mp3", 3: "mp4", 4: "m4a", 5: "flac", 6: "m4a", 11: "wav", 12: "aiff"]

    /// rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)
    static let verifiedFileTypes: Set<Int> = [1, 4, 5]

    public static func rules(fileType: Int, metadata: UsbTrackMetadataFlags) -> Set<UsbProvisionalRule> {
        var rules: Set<UsbProvisionalRule> = []
        if !verifiedFileTypes.contains(fileType) { rules.insert(.fileTypeUnverified) }
        if metadata.hasAny { rules.insert(.metadataSeenEmptyOnly) }
        return rules
    }

    /// pdb에 문자열로 들어가는 값 중 순수 ASCII이고 127자 이상인 것이 있으면 [.pdbLongAscii].
    /// 긴 ASCII(0x40)는 rekordbox 7.2.x 경계 실험(2026-10-08)에서 트랙 행 문자열·아티스트·앨범 이름으로만 봤다.
    /// 그 밖의 칸(재생 목록·장르·키·레이블 이름)만 이 함수로 판정한다.
    public static func pdbStringRules(_ strings: [String]) -> Set<UsbProvisionalRule> {
        let long = strings.contains { text in
            text.unicodeScalars.count >= longAsciiThreshold && text.unicodeScalars.allSatisfy { $0.value < 0x80 }
        }
        return long ? [.pdbLongAscii] : []
    }
}
