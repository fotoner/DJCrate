import Foundation

/// 모델 칸 하나: 이름, 그 값을 실제로 담는 형식, 비교·기본값·옮기기.
/// 한 형식만 담는 칸의 `reset`은 그 칸이 없는 형식의 리더가 넣는 기본값으로 바꾼다.
struct UsbFieldRule<Root> {
    let name: String
    let formats: Set<UsbFormat>
    let same: (Root, Root) -> Bool
    let reset: (inout Root) -> Void
    let take: (inout Root, Root) -> Void

    /// 두 형식 모두의 칸
    static func shared<V: Equatable>(_ name: String, _ path: WritableKeyPath<Root, V>,
                                     same: @escaping (V, V) -> Bool = { $0 == $1 }) -> Self {
        Self(name: name, formats: UsbFormat.defaultSet, same: { same($0[keyPath: path], $1[keyPath: path]) },
             reset: { _ in }, take: { $0[keyPath: path] = $1[keyPath: path] })
    }

    /// 한 형식만 담는 칸. `value`는 다른 형식 리더가 넣는 기본값
    static func only<V: Equatable>(_ format: UsbFormat, _ name: String, _ path: WritableKeyPath<Root, V>, default value: V) -> Self {
        Self(name: name, formats: [format], same: { $0[keyPath: path] == $1[keyPath: path] },
             reset: { $0[keyPath: path] = value }, take: { $0[keyPath: path] = $1[keyPath: path] })
    }
}

/// 칸의 형식 소속 표. merge·projected·`UsbLibraryDiff`가 같이 쓴다.
/// 여기에 `only`로 적지 않은 칸은 두 형식 모두의 칸이다. 형식별로 이미 나뉜 것(`presentIn`, 목록 `sortOrder`·`entries`,
/// `deviceFields`, 기록·`unknownRows`의 `format`, My Tag 연결 `presentIn`)은 키로 형식이 정해져 여기 두지 않는다.
public enum UsbFieldFormats {
    static var track: [UsbFieldRule<UsbTrack>] {
        [
            .shared("title", \.title),
            .only(.oneLibrary, "titleForSearch", \.titleForSearch, default: nil),
            .shared("subtitle", \.subtitle),
            .shared("bpmx100", \.bpmx100),
            .shared("lengthSeconds", \.lengthSeconds),
            .shared("trackNo", \.trackNo),
            .shared("discNo", \.discNo),
            .shared("artistID", \.artistID),
            .shared("remixerID", \.remixerID),
            .shared("originalArtistID", \.originalArtistID),
            .shared("composerID", \.composerID),
            .only(.oneLibrary, "lyricistArtistID", \.lyricistArtistID, default: nil),
            .only(.deviceLibrary, "lyricist", \.lyricist, default: ""),
            .shared("albumID", \.albumID),
            .shared("genreID", \.genreID),
            .shared("labelID", \.labelID),
            .shared("keyID", \.keyID),
            .shared("colorID", \.colorID),
            .shared("imageID", \.imageID),
            .shared("comment", \.comment),
            .shared("rating", \.rating),
            .shared("releaseYear", \.releaseYear),
            .shared("releaseDate", \.releaseDate),
            .shared("dateCreated", \.dateCreated),
            .shared("dateAdded", \.dateAdded),
            // 경로는 NFC·NFD만 다르면 같은 파일이다(FAT가 같은 이름으로 본다).
            .shared("path", \.path, same: { UsbLayout.nfc($0) == UsbLayout.nfc($1) }),
            .shared("fileName", \.fileName),
            .shared("fileSize", \.fileSize),
            .shared("fileType", \.fileType),
            .shared("bitrate", \.bitrate),
            .shared("bitDepth", \.bitDepth),
            .shared("sampleRate", \.sampleRate),
            .shared("isrc", \.isrc),
            .shared("djPlayCount", \.djPlayCount),
            .shared("hotCueAutoLoad", \.hotCueAutoLoad),
            .shared("kuvoDeliver", \.kuvoDeliver),
            .only(.oneLibrary, "kuvoDeliveryComment", \.kuvoDeliveryComment, default: ""),
            .shared("masterDbId", \.masterDbId),
            .shared("masterContentId", \.masterContentId),
            .shared("analysisDataPath", \.analysisDataPath),
            .only(.oneLibrary, "analysedBits", \.analysedBits, default: 0),
            .only(.oneLibrary, "contentLink", \.contentLink, default: 0),
            .only(.oneLibrary, "hasModified", \.hasModified, default: 0),
            .shared("cueUpdateCount", \.cueUpdateCount),
            .shared("analysisDataUpdateCount", \.analysisDataUpdateCount),
            .shared("informationUpdateCount", \.informationUpdateCount),
        ]
    }

    /// artist·genre·key·label·color. nameForSearch는 OneLibrary artist에만 있고 다른 표는 두 리더 모두 nil이다.
    static var namedRow: [UsbFieldRule<UsbNamedRow>] {
        [.shared("name", \.name), .only(.oneLibrary, "nameForSearch", \.nameForSearch, default: nil)]
    }

    static var album: [UsbFieldRule<UsbAlbum>] {
        [
            .shared("name", \.name),
            .shared("artistID", \.artistID),
            .only(.oneLibrary, "imageID", \.imageID, default: nil),
            .only(.oneLibrary, "isCompilation", \.isCompilation, default: 0),
            .only(.oneLibrary, "nameForSearch", \.nameForSearch, default: nil),
        ]
    }

    static var image: [UsbFieldRule<UsbImage>] {
        [.only(.oneLibrary, "oneLibraryPath", \.oneLibraryPath, default: nil), .only(.deviceLibrary, "pdbPath", \.pdbPath, default: nil)]
    }

    /// 목록 자체의 칸(항목·순서는 형식별로 따로)
    static var playlist: [UsbFieldRule<UsbPlaylist>] {
        [.shared("name", \.name), .shared("parentID", \.parentID), .shared("attribute", \.attribute),
         .only(.oneLibrary, "imageID", \.imageID, default: nil)]
    }

    static var myTag: [UsbFieldRule<UsbMyTag>] {
        [.shared("parentID", \.parentID), .shared("sequenceNo", \.sequenceNo), .shared("name", \.name), .shared("isCategory", \.isCategory)]
    }

    static var menuItem: [UsbFieldRule<UsbMenuItem>] {
        [.shared("kind", \.kind), .shared("name", \.name)]
    }

    static var category: [UsbFieldRule<UsbCategory>] {
        [
            .shared("menuItemID", \.menuItemID),
            .shared("sequenceNo", \.sequenceNo),
            .shared("isVisible", \.isVisible),
            .only(.deviceLibrary, "infoOrder", \.infoOrder, default: nil),
            .only(.deviceLibrary, "disable", \.disable, default: nil),
        ]
    }

    static var sort: [UsbFieldRule<UsbSort>] {
        [
            .shared("menuItemID", \.menuItemID),
            .shared("sequenceNo", \.sequenceNo),
            .shared("isVisible", \.isVisible),
            .shared("isSelectedAsSubColumn", \.isSelectedAsSubColumn),
            .only(.deviceLibrary, "disable", \.disable, default: nil),
        ]
    }

    static var property: [UsbFieldRule<UsbProperty>] {
        [
            .only(.oneLibrary, "deviceName", \.deviceName, default: ""),
            .shared("dbVersion", \.dbVersion),
            .shared("numberOfContents", \.numberOfContents),
            .only(.oneLibrary, "createdDate", \.createdDate, default: ""),
            .only(.oneLibrary, "backgroundColorType", \.backgroundColorType, default: 0),
            .shared("myTagMasterDBID", \.myTagMasterDBID),
            .only(.deviceLibrary, "pdbDate", \.pdbDate, default: nil),
            .only(.deviceLibrary, "pdbDeviceName", \.pdbDeviceName, default: nil),
        ]
    }

    /// 모델 전체 칸(pdb 죽은 행 ID·트랙 행 관찰값)
    static var library: [UsbFieldRule<UsbLibrary>] {
        [.only(.deviceLibrary, "trackRowExtras", \.trackRowExtras, default: [:]), .only(.deviceLibrary, "deadIDs", \.deadIDs, default: [:])]
    }

    /// 표·칸 이름 → 그 칸을 담는 형식. 표는 `UsbLibraryDiff`의 표 이름(content·artist·album·…·property·library)
    public static func formats(table: String, field: String) -> Set<UsbFormat> {
        func find<Root>(_ rules: [UsbFieldRule<Root>]) -> Set<UsbFormat>? { rules.first { $0.name == field }?.formats }
        let found: Set<UsbFormat>? = switch table {
        case "content": find(track)
        case "artist", "genre", "key", "label", "color": find(namedRow)
        case "album": find(album)
        case "image": find(image)
        case "playlist": find(playlist)
        case "myTag": find(myTag)
        case "menuItem": find(menuItem)
        case "category": find(category)
        case "sort": find(sort)
        case "property": find(property)
        case "library": find(library)
        default: nil
        }
        return found ?? UsbFormat.defaultSet
    }
}

extension Array {
    /// `format`이 담지 않는 칸을 그 형식 리더의 기본값으로 바꾼다
    func projecting<Root>(_ value: Root, to format: UsbFormat) -> Root where Element == UsbFieldRule<Root> {
        var copy = value
        for rule in self where !rule.formats.contains(format) { rule.reset(&copy) }
        return copy
    }

    /// 같은 행의 두 형식 값을 합친다. OneLibrary 행에서 시작해 OneLibrary가 담지 않는 칸은 Device Library 값을 가져온다.
    /// 두 형식 모두의 칸이 다르면 그 칸 이름을 돌려준다(값은 OneLibrary 쪽).
    func merging<Root>(oneLibrary: Root, deviceLibrary: Root) -> (Root, differing: [String]) where Element == UsbFieldRule<Root> {
        var merged = oneLibrary
        var differing: [String] = []
        for rule in self {
            if !rule.formats.contains(.oneLibrary) {
                rule.take(&merged, deviceLibrary)
            } else if rule.formats.contains(.deviceLibrary), !rule.same(oneLibrary, deviceLibrary) {
                differing.append(rule.name)
            }
        }
        return (merged, differing)
    }
}
