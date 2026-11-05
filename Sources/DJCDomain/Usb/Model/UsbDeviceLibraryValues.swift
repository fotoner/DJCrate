import Foundation

/// 합칠 때 두 형식 모두에 있고 두 형식 모두의 칸 값이 달랐던 행 하나: 합친 대표 행(OneLibrary 값)과 Device Library 행(#238)
struct UsbDifferingRow<Row: Hashable & Sendable>: Hashable, Sendable {
    var merged: Row
    var deviceLibrary: Row

    /// Device Library 투영 행에서 합칠 때 달랐던 칸 가운데 지금도 대표 값 그대로인 칸(편집이 바꾸지 않은 칸)을 Device Library 값으로 되돌린다
    func restoring(_ row: Row, rules: [UsbFieldRule<Row>]) -> Row {
        var row = row
        for rule in rules where rule.formats.contains(.oneLibrary) && rule.formats.contains(.deviceLibrary)
            && !rule.same(merged, deviceLibrary) && rule.same(row, merged) {
            rule.take(&row, deviceLibrary)
        }
        return row
    }
}

/// 두 형식 값이 달랐던 곡·공유 표 행·property의 Device Library 값. 표마다 id → 행.
/// 합친 모델은 OneLibrary 값을 대표로 두고, Device Library 투영이 이 값으로 그 형식 값을 지킨다(전에는 다시 쓰면 OneLibrary 값으로 바뀌었다)
struct UsbDeviceLibraryValues: Hashable, Sendable {
    var tracks: [Int: UsbDifferingRow<UsbTrack>] = [:]
    var artists: [Int: UsbDifferingRow<UsbNamedRow>] = [:]
    var albums: [Int: UsbDifferingRow<UsbAlbum>] = [:]
    var genres: [Int: UsbDifferingRow<UsbNamedRow>] = [:]
    var keys: [Int: UsbDifferingRow<UsbNamedRow>] = [:]
    var labels: [Int: UsbDifferingRow<UsbNamedRow>] = [:]
    var colors: [Int: UsbDifferingRow<UsbNamedRow>] = [:]
    var images: [Int: UsbDifferingRow<UsbImage>] = [:]
    var myTags: [Int: UsbDifferingRow<UsbMyTag>] = [:]
    var menuItems: [Int: UsbDifferingRow<UsbMenuItem>] = [:]
    var categories: [Int: UsbDifferingRow<UsbCategory>] = [:]
    var sorts: [Int: UsbDifferingRow<UsbSort>] = [:]
    var property: UsbDifferingRow<UsbProperty>?

    var isEmpty: Bool { self == UsbDeviceLibraryValues() }
}

extension UsbLibrary {
    /// Device Library 투영의 곡·공유 표 행·property에 그 형식 값을 되돌린다(`UsbDifferingRow.restoring`).
    /// 한 형식 행 거르기(`dropOtherFormatRows`)보다 먼저 해야 Device Library 값의 참조(곡 keyID 등)가 가리키는 행이 남는다
    mutating func restoreDeviceLibraryValues(_ values: UsbDeviceLibraryValues) {
        func restore<Row>(_ rows: inout [Row], id: KeyPath<Row, Int>, _ stored: [Int: UsbDifferingRow<Row>], rules: [UsbFieldRule<Row>]) {
            guard !stored.isEmpty else { return }
            for index in rows.indices {
                if let pair = stored[rows[index][keyPath: id]] { rows[index] = pair.restoring(rows[index], rules: rules) }
            }
        }
        restore(&tracks, id: \.id, values.tracks, rules: UsbFieldFormats.track)
        restore(&artists, id: \.id, values.artists, rules: UsbFieldFormats.namedRow)
        restore(&albums, id: \.id, values.albums, rules: UsbFieldFormats.album)
        restore(&genres, id: \.id, values.genres, rules: UsbFieldFormats.namedRow)
        restore(&keys, id: \.id, values.keys, rules: UsbFieldFormats.namedRow)
        restore(&labels, id: \.id, values.labels, rules: UsbFieldFormats.namedRow)
        restore(&colors, id: \.id, values.colors, rules: UsbFieldFormats.namedRow)
        restore(&images, id: \.id, values.images, rules: UsbFieldFormats.image)
        restore(&myTags, id: \.intID, values.myTags, rules: UsbFieldFormats.myTag)
        restore(&menuItems, id: \.id, values.menuItems, rules: UsbFieldFormats.menuItem)
        restore(&categories, id: \.id, values.categories, rules: UsbFieldFormats.category)
        restore(&sorts, id: \.id, values.sorts, rules: UsbFieldFormats.sort)
        if let pair = values.property { property = pair.restoring(property, rules: UsbFieldFormats.property) }
    }
}

extension UsbLibrary {
    /// 합칠 때 두 형식 값이 달라 Device Library 값을 따로 둔 곡·행이 있는지(#238).
    /// 있으면 Device Library 투영의 참조(곡 artistID·imageID 등)가 합친 모델과 다를 수 있다. 가리키는 행을 셀 때 그 투영도 함께 본다
    public var hasDeviceLibraryValues: Bool { !deviceLibraryValues.isEmpty }

    /// 이 곡의 Device Library 투영 값(두 형식 값이 다른 칸은 그 형식 값). 곡 갱신이 같은 갱신을 이 곡에도 적용해 Device Library 값을 정한다
    public func deviceLibraryTrack(_ id: Int) -> UsbTrack? {
        guard let track = tracks.first(where: { $0.id == id }) else { return nil }
        return deviceLibraryValues.tracks[id].map { $0.restoring(track, rules: UsbFieldFormats.track) } ?? track
    }

    /// 편집이 다시 쓴 곡의 Device Library 값을 정한다(#238). `deviceLibrary`는 합친 모델의 곡에 한 갱신을 Device Library 값에도 한 곡이다.
    /// 갱신이 쓴 칸은 두 형식이 같아지고, 쓰지 않은 칸은 그 형식 값 그대로다. 두 형식 모두의 칸이 모두 같으면 따로 두지 않는다
    public mutating func setDeviceLibraryTrack(_ deviceLibrary: UsbTrack) {
        guard let track = tracks.first(where: { $0.id == deviceLibrary.id }) else { return }
        let differs = UsbFieldFormats.track.contains {
            $0.formats.contains(.oneLibrary) && $0.formats.contains(.deviceLibrary) && !$0.same(track, deviceLibrary)
        }
        deviceLibraryValues.tracks[track.id] = differs ? UsbDifferingRow(merged: track, deviceLibrary: deviceLibrary) : nil
    }

    /// Device Library 값을 따로 둔 행 id. 표 이름은 `sharedRowDiffers`와 같고 곡은 "content"다.
    /// 이 행은 형식마다 이름 등이 달라, 새 곡이 이름으로 다시 쓰면 한 형식에서 다른 값을 가리키게 된다
    public func deviceLibraryValueIDs(table: String) -> Set<Int> {
        let values = deviceLibraryValues
        return switch table {
        case "content": Set(values.tracks.keys)
        case "artist": Set(values.artists.keys)
        case "album": Set(values.albums.keys)
        case "genre": Set(values.genres.keys)
        case "key": Set(values.keys.keys)
        case "label": Set(values.labels.keys)
        case "color": Set(values.colors.keys)
        case "image": Set(values.images.keys)
        case "myTag": Set(values.myTags.keys)
        case "menuItem": Set(values.menuItems.keys)
        case "category": Set(values.categories.keys)
        case "sort": Set(values.sorts.keys)
        default: []
        }
    }
}
