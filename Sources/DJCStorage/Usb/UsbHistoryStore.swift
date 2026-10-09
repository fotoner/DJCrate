import DJCDomain
import Foundation
import RekordboxKit

/// USB에서 가져와 보존한 기기 재생 기록(`usb-histories/<id>.json`, 기록마다 한 파일, #43).
/// USB → Mac 보존만 한다(USB·rekordbox 라이브러리에는 쓰지 않는다). 쓰기는 내구 쓰기(임시 파일 → fsync → rename)라
/// 끊겨도 옛것 또는 새것만 남는다. 읽지 못한 파일은 지우거나 덮지 않고 `damaged-drafts/usb-histories/`로 옮긴다.
public struct UsbHistoryStore: Sendable {
    public let directory: URL
    /// 손상 파일을 옮길 DJCrate 데이터 폴더(그 아래 damaged-drafts/)
    let home: URL
    private let fileSystem: any UsbFileSystem

    /// home: 손상 파일을 옮길 DJCrate 데이터 폴더(그 아래 damaged-drafts/)
    public init(directory: URL, home: URL, fileSystem: any UsbFileSystem = PosixUsbFileSystem()) {
        self.directory = directory
        self.home = home
        self.fileSystem = fileSystem
    }

    public struct Loaded: Sendable, Equatable {
        public var histories: [ArchivedHistory]
        /// 읽지 못해 damaged-drafts로 옮긴 파일 이름
        public var damaged: [String]
        /// 읽기·손상 보관에 실패해 그대로 둔 파일 이름. 폴더 열거 실패면 폴더 이름
        public var unreadable: [String]

        public init(histories: [ArchivedHistory] = [], damaged: [String] = [], unreadable: [String] = []) {
            self.histories = histories
            self.damaged = damaged
            self.unreadable = unreadable
        }
    }

    /// 저장할 수 없는 기록 ID: 접두사가 없거나, 파일 이름에 안전하지 않은 글자가 있거나, 한 번에 같은 ID가 둘
    public struct InvalidID: Error, Equatable, Sendable {
        public var id: String
    }

    /// 폴더가 없으면 빈 결과. *.json만 읽는다. 손상 파일은 DamagedDrafts 규칙대로 옮기고 읽기·보관 실패는 unreadable로 알린다.
    /// 옮긴 파일은 초안 손상 알림(`DamagedDrafts.take`)에 넣지 않는다(그 문구는 초안용이라, 앱이 `damaged`로 따로 알린다)
    public func load() -> Loaded {
        let names: [String]
        do {
            guard try fileSystem.stat(directory) != nil else { return Loaded() }
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch { return Loaded(unreadable: [directory.lastPathComponent]) }
        var result = Loaded()
        for name in names.sorted() where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let url = directory.appending(path: name)
            // 권한·폴더 등으로 읽지 못한 것은 손상이 아닐 수 있어 그대로 둔다
            let data: Data
            do { data = try Data(contentsOf: url) }
            catch {
                result.unreadable.append(name)
                continue
            }
            // 파일 이름과 ID가 다르면 다음 저장이 다른 파일에 써서 같은 기록이 둘이 된다. 우리가 쓴 모양이 아니라 손상으로 본다
            if let history = try? Self.decoder().decode(ArchivedHistory.self, from: data),
               Self.isSafe(history.id), name == Self.fileName(history.id) {
                result.histories.append(history)
                continue
            }
            do {
                try DamagedDrafts.preserve(url, home: home, trackUUID: nil, logged: false)
                result.damaged.append(name)
            } catch {
                // 옮기지 못하면 그 자리에 둔다(지우지 않는다)
                result.unreadable.append(name)
            }
        }
        result.histories.sort { ($0.importedAt, $0.sequence, $0.id) < ($1.importedAt, $1.sequence, $1.id) }
        return result
    }

    /// 기록마다 "<id>.json"으로 원자적으로(임시 파일 → fsync → rename) 쓴다. id가 `ArchivedHistory.idPrefix`로 시작하고
    /// 파일 이름에 안전한 글자(영숫자·'-')만 있을 때만. 아니면 아무것도 쓰지 않고 던진다
    public func save(_ histories: [ArchivedHistory]) throws {
        var seen: Set<String> = []
        for history in histories {
            guard Self.isSafe(history.id), seen.insert(history.id).inserted else { throw InvalidID(id: history.id) }
        }
        let encoder = Self.encoder()
        let files = try histories.map { (directory.appending(path: Self.fileName($0.id)), try encoder.encode($0)) }
        for (url, data) in files {
            try preserveIfDamaged(url)
            try UsbDurableFile.write(data, to: url, fileSystem: fileSystem)
        }
    }

    /// save 오류 뒤 같은 ID의 파일 내용이 이번 저장과 일치하는지 읽기만 해서 확인한다.
    /// rename 뒤 폴더 fsync가 실패하면 새 파일이 이미 있어, 호출자는 이 기록을 같은 ID로 상태에 넣어 UUID 중복을 피한다.
    /// 초 아래는 저장 형식대로 비교한다. true는 현재 파일 내용 확인이며 내구 쓰기의 성공을 뜻하지 않는다
    public func containsExact(_ history: ArchivedHistory) -> Bool {
        guard Self.isSafe(history.id),
              let data = try? Data(contentsOf: directory.appending(path: Self.fileName(history.id))),
              let stored = try? Self.decoder().decode(ArchivedHistory.self, from: data),
              let encoded = try? Self.encoder().encode(history),
              let expected = try? Self.decoder().decode(ArchivedHistory.self, from: encoded) else { return false }
        return stored == expected
    }

    /// 덮어쓰기 전에: 있던 파일을 해석하지 못하면 옮겨 둔다. 읽기 자체가 안 되면(권한 등) 던져서 덮지 않는다
    private func preserveIfDamaged(_ url: URL) throws {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch CocoaError.fileReadNoSuchFile { return }
        if let history = try? Self.decoder().decode(ArchivedHistory.self, from: data),
           Self.isSafe(history.id), url.lastPathComponent == Self.fileName(history.id) { return }
        try DamagedDrafts.preserve(url, home: home, trackUUID: nil, logged: false)
    }

    static func fileName(_ id: String) -> String { id + ".json" }

    /// 접두사 + 영숫자·'-'만. 길이는 임시 파일 이름(".<이름>.tmp-xxxxxxxx")까지 255바이트 안에 들게 한다
    static func isSafe(_ id: String) -> Bool {
        guard id.hasPrefix(ArchivedHistory.idPrefix), id.count > ArchivedHistory.idPrefix.count, id.utf8.count <= 200 else { return false }
        return id.allSatisfy { safeCharacters.contains($0) }
    }

    private static let safeCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")

    /// 저장 모양(읽기·쓰기가 같은 규칙): 날짜는 ISO 8601(초 단위라 초 아래는 버려진다), 키 정렬
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
