import Foundation

/// USB `Contents/` 아래 음원 경로 규칙: 아티스트·앨범 폴더 성분과 파일 이름.
/// 성분 규칙은 rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)과 맞춘 순서다.
public enum UsbPathRules {
    /// 성분 하나의 최대 길이(유니코드 스칼라 수)
    public static let maxScalars = 48
    /// `_`로 바꾸는 글자: FAT에 쓸 수 없는 글자와 rekordbox가 바꾸는 `~`. 제어 문자(U+0000–U+001F, U+007F)도 같게 `_`로 바꾼다.
    public static let forbidden: Set<Character> = ["\"", "*", "/", ":", "<", ">", "?", "\\", "|", "~"]
    /// rekordbox가 `_`로 바꾸는 것을 본 글자(규칙 없이 통과). rekordbox 7.2.x 빈 USB 내보내기 704곡(2026-10-08)에서
    /// 폴더 성분의 `" * / : > ? ~`, 파일 이름의 `~`를 봤다. `< \ |`·제어 문자는 본 적 없어 `forbiddenCharacters`를 싣는다.
    static let confirmedForbidden: Set<Unicode.Scalar> = ["\"", "*", "/", ":", ">", "?", "~"]
    /// 2026-10-09 전 DJCrate가 `~`를 그대로 두고 지은 이름. 그때 쓴 USB의 곡을 알아볼 때만 쓴다(`UsbTrackMatch`).
    static let legacyForbidden: Set<Character> = forbidden.subtracting(["~"])

    /// 지은 이름과 그 이름에 쓴 확인 안 된 규칙
    public struct Named: Sendable, Hashable {
        public var value: String
        public var rules: Set<UsbProvisionalRule>

        public init(value: String, rules: Set<UsbProvisionalRule> = []) {
            self.value = value
            self.rules = rules
        }
    }

    /// 아티스트·앨범 폴더 성분. unknown은 "UnknownArtist"·"UnknownAlbum"
    public static func folderComponent(_ name: String?, unknown: String) -> Named {
        let empty = Named(value: unknown, rules: [.emptyArtistAlbum])
        var rules: Set<UsbProvisionalRule> = []
        // 공백·점만 있는 이름은 FAT에서 이름이 되지 않는다(끝의 점을 _로 바꾸기 전에 빈 이름으로 본다).
        let normalized = (name ?? "").precomposedStringWithCanonicalMapping
        guard normalized.unicodeScalars.contains(where: { $0 != " " && $0 != "." }) else { return empty }

        var scalars = replaceForbidden(normalized, forbidden: forbidden, rules: &rules)
        if scalars.last == "." { scalars[scalars.count - 1] = "_" }
        if scalars.count > maxScalars {
            scalars = Array(scalars.prefix(maxScalars))
            if scalars.contains(where: { $0.value > 0xFFFF }) { rules.insert(.supplementaryCharacters) }
        }
        while let last = scalars.last, last == " " || last == "." { scalars.removeLast() }
        guard !scalars.isEmpty else { return empty }
        if scalars.first == " " { rules.insert(.leadingSpace) }
        return Named(value: string(scalars), rules: rules)
    }

    /// 음원 파일 이름(`audioFileName`). 48 스칼라를 넘으면 확장자를 남기고 줄기만 자른다.
    public static func fileName(_ name: String) -> Named {
        fileName(name, forbidden: forbidden)
    }

    /// 2026-10-09 전 규칙(`~`를 그대로 둠)으로 지은 파일 이름
    static func legacyFileName(_ name: String) -> String {
        fileName(name, forbidden: legacyForbidden).value
    }

    /// USB 파일 이름의 원본: 음원 경로(`FolderPath`)의 끝 성분. 경로가 없으면 `FileNameL`.
    /// rekordbox는 `FileNameL`이 실제 파일 이름과 다른 곡(파일 이름을 바꾼 뒤 남은 옛 값)도 실제 파일 이름으로 내보냈다(2026-10-08 골든 1곡).
    public static func audioFileName(sourcePath: String?, fileNameL: String) -> String {
        guard let sourcePath, sourcePath.hasPrefix("/"),
              let last = sourcePath.split(separator: "/", omittingEmptySubsequences: true).last
        else { return fileNameL }
        return String(last)
    }

    static func fileName(_ name: String, forbidden: Set<Character>) -> Named {
        var rules: Set<UsbProvisionalRule> = []
        let scalars = replaceForbidden(name.precomposedStringWithCanonicalMapping, forbidden: forbidden, rules: &rules)
        var result = scalars
        if scalars.count > maxScalars {
            let (stem, ext) = split(scalars)
            result = trimmedStem(stem, limit: maxScalars - (ext.map { $0.count + 1 } ?? 0)) + (ext.map { ["."] + $0 } ?? [])
            rules.insert(.fileNameTruncation)
        }
        if result.isEmpty { result = ["_"] }
        if result.first == " " { rules.insert(.leadingSpace) }
        return Named(value: string(result), rules: rules)
    }

    /// "/Contents/<아티스트>/<앨범>/<파일>"(NFC). 세 성분의 규칙을 모은다.
    public static func contentsPath(artist: String?, album: String?, fileName name: String) -> Named {
        let parts = [folderComponent(artist, unknown: "UnknownArtist"), folderComponent(album, unknown: "UnknownAlbum"), fileName(name)]
        return Named(value: "/Contents/" + parts.map(\.value).joined(separator: "/"),
                     rules: parts.reduce(into: []) { $0.formUnion($1.rules) })
    }

    /// 같은 이름이 있을 때 붙이는 번호: "x (2).mp3". 48 스칼라 안으로 줄기를 더 자른다.
    public static func withSuffix(_ fileName: String, number: Int) -> String {
        let scalars = Array(fileName.unicodeScalars)
        let (stem, ext) = split(scalars)
        let suffix = Array(" (\(number))".unicodeScalars)
        let limit = maxScalars - suffix.count - (ext.map { $0.count + 1 } ?? 0)
        // 확장자가 길어 줄기를 한 글자도 남길 수 없으면 이름 전체를 줄기로 보고 자른다(48 스칼라를 넘기지 않는다).
        guard limit >= 1 else { return string(trimmedStem(scalars, limit: maxScalars - suffix.count) + suffix) }
        let head = stem.count > limit ? trimmedStem(stem, limit: limit) : stem
        return string(head + suffix + (ext.map { ["."] + $0 } ?? []))
    }

    // MARK: - 도우미

    static func replaceForbidden(_ text: String, forbidden: Set<Character>, rules: inout Set<UsbProvisionalRule>) -> [Unicode.Scalar] {
        text.unicodeScalars.map { scalar in
            let isControl = scalar.value < 0x20 || scalar.value == 0x7F
            guard isControl || forbidden.contains(Character(scalar)) else { return scalar }
            if !confirmedForbidden.contains(scalar) { rules.insert(.forbiddenCharacters) }
            return "_"
        }
    }

    /// (줄기, 확장자). 마지막 점 뒤가 확장자다. 점이 없거나 확장자가 너무 길면 전체를 줄기로 본다.
    static func split(_ scalars: [Unicode.Scalar]) -> (stem: [Unicode.Scalar], ext: [Unicode.Scalar]?) {
        guard let dot = scalars.lastIndex(of: "."), dot > 0 else { return (scalars, nil) }
        let ext = Array(scalars[(dot + 1)...])
        // 줄기를 한 글자도 남길 수 없는 확장자는 확장자로 보지 않는다.
        guard ext.count + 1 < maxScalars - 1 else { return (scalars, nil) }
        return (Array(scalars[..<dot]), ext)
    }

    /// 줄기를 limit 스칼라로 자르고 끝의 공백·점을 지운다. 비면 "_"
    static func trimmedStem(_ stem: [Unicode.Scalar], limit: Int) -> [Unicode.Scalar] {
        var cut = Array(stem.prefix(max(limit, 1)))
        while let last = cut.last, last == " " || last == "." { cut.removeLast() }
        return cut.isEmpty ? ["_"] : cut
    }

    static func string(_ scalars: [Unicode.Scalar]) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }
}
