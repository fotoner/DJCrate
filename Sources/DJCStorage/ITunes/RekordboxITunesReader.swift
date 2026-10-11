import DJCDomain
import Foundation
import OSLog
import iTunesLibrary
import RekordboxKit

/// rekordbox의 동기화 선택을 기준으로 같은 읽기 방식(Framework 또는 XML)을 사용한다.
public enum RekordboxITunesReader {
    public static func selectionChanged(since data: Data?, directory: URL = LibrarySnapshot.rekordboxDirectory) -> Bool {
        (try? stableRead(directory.appending(path: "playlists3.sync"))) != data
    }

    public static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Pioneer/rekordbox6/rekordbox3.settings")
    }

    public static func capture(directory: URL = LibrarySnapshot.rekordboxDirectory, settings: URL = settingsURL) -> ITunesLibrarySnapshot {
        var stage = "selection.read"
        do {
            let sync = directory.appending(path: "playlists3.sync")
            let selectionData = FileManager.default.fileExists(atPath: sync.path) ? try stableRead(sync) : nil
            stage = "selection.parse"
            let selection = try RekordboxITunesSelection.parse(selectionData ?? Data("<SYNC_ITUNES_PLAYLIST><PLAYLISTS/></SYNC_ITUNES_PLAYLIST>".utf8))
            stage = "settings.read"
            let settingsData = try stableRead(settings)
            stage = "settings.parse"
            let config = try configuration(settingsData)
            let playlists: [ITunesLibrarySnapshot.Playlist]
            switch config.method {
            case "1":
                stage = "source.framework"
                playlists = try frameworkPlaylists()
            case "0":
                guard let path = config.xmlPath, !path.isEmpty else { throw RekordboxITunesSelection.ParseError.invalidFile }
                stage = "source.xml.read"
                let data = try stableRead(URL(filePath: path))
                stage = "source.xml.parse"
                playlists = try ITunesLibrarySnapshot.parseLibraryXML(data)
            default: throw RekordboxITunesSelection.ParseError.invalidFile
            }
            stage = "selection.apply"
            var snapshot = try ITunesLibrarySnapshot.select(selection, from: playlists)
            snapshot.syncData = selectionData
            // 읽는 동안 동기화 선택·읽기 설정이 바뀌었으면 섞인 결과를 쓰지 않는다.
            stage = "source.verify"
            let latestSelection = FileManager.default.fileExists(atPath: sync.path) ? try Data(contentsOf: sync) : nil
            guard selectionData == latestSelection, settingsData == (try Data(contentsOf: settings)) else {
                throw RekordboxITunesSelection.ParseError.invalidFile
            }
            return snapshot
        } catch {
            let failure = error as NSError
            // 경로·목록·userInfo 없이 설치 앱에서도 실패 단계를 구분한다.
            Logger(subsystem: "com.fotone.djcrate", category: "iTunesRead")
                .error("iTunes 읽기 실패 stage=\(stage, privacy: .public) domain=\(failure.domain, privacy: .public) code=\(failure.code)")
            return ITunesLibrarySnapshot(status: .unavailable)
        }
    }

    static func stableRead(_ url: URL) throws -> Data {
        let before = try FileManager.default.attributesOfItem(atPath: url.path)
        let data = try Data(contentsOf: url)
        let after = try FileManager.default.attributesOfItem(atPath: url.path)
        guard before[.size] as? Int == after[.size] as? Int,
              before[.modificationDate] as? Date == after[.modificationDate] as? Date else {
            throw RekordboxITunesSelection.ParseError.invalidFile
        }
        return data
    }

    static func frameworkPlaylists() throws -> [ITunesLibrarySnapshot.Playlist] {
        let library = try ITLibrary(apiVersion: "1.0")
        var locations = ITunesLocationCache()
        // 선택 창에서 새 목록을 골라도 곡을 잃지 않게 전체 카탈로그는 유지한다.
        return library.allPlaylists.filter { !$0.isPrimary }.map { playlist in
            let id = String(playlist.persistentID.uint64Value, radix: 16, uppercase: true)
            let parent = playlist.parentID.map { String($0.uint64Value, radix: 16, uppercase: true) }
            return ITunesLibrarySnapshot.Playlist(id: id, name: playlist.name, parentID: parent,
                isFolder: playlist.kind == .folder,
                paths: playlist.kind != .folder ? playlist.items.map { item in
                    locations.path(for: item.persistentID.uint64Value) { item.location }
                } : [])
        }
    }

    static func configuration(_ data: Data) throws -> (method: String, xmlPath: String?) {
        let reader = SettingsReader()
        let parser = XMLParser(data: try readableSettings(data))
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse(), reader.hasRoot, let method = reader.values["MusicAppLoadingType"] else {
            throw RekordboxITunesSelection.ParseError.invalidFile
        }
        return (method, reader.values["itunesLibraryFile"])
    }

    private static func readableSettings(_ data: Data) throws -> Data {
        guard let text = String(data: data, encoding: .utf8) else { return data }
        let source = text as NSString
        let result = NSMutableString(string: text)
        // 주석·CDATA·속성 안의 가짜 태그를 건드리지 않고, 최종 구조 검증은 XMLParser에 맡긴다.
        let markup = try NSRegularExpression(pattern: #"<!--[\s\S]*?-->|<!\[CDATA\[[\s\S]*?\]\]>|<\?[\s\S]*?\?>|<(?:[^<>"']|"[^"]*"|'[^']*')*>"#)
        let value = try NSRegularExpression(pattern: #"^<VALUE(?:[ \t\r\n]+(?:name|val)[ \t\r\n]*=[ \t\r\n]*(?:"[^"<]*"|'[^'<]*')){2}[ \t\r\n]*/?>$"#)
        let attribute = try NSRegularExpression(pattern: #"(name|val)[ \t\r\n]*=[ \t\r\n]*(["'])([\s\S]*?)\2"#)
        let reference = try NSRegularExpression(pattern: #"&#(x[0-9a-fA-F]+|[0-9]+);"#)
        var cursor = 0
        var replacements: [NSRange] = []
        while cursor < source.length {
            let start = source.range(of: "<", range: NSRange(location: cursor, length: source.length - cursor))
            if start.location == NSNotFound { break }
            guard let token = markup.firstMatch(in: text, options: .anchored,
                range: NSRange(location: start.location, length: source.length - start.location)) else {
                throw RekordboxITunesSelection.ParseError.invalidFile
            }
            cursor = NSMaxRange(token.range)
            let tag = source.substring(with: token.range)
            if tag.hasPrefix("<!--") || tag.hasPrefix("<![CDATA[") || tag.hasPrefix("<?") { continue }
            // 설정에 DTD는 필요 없으며, 내부·외부 엔티티 선언으로 키 해석이 달라지는 것도 막는다.
            guard !tag.hasPrefix("<!") else { throw RekordboxITunesSelection.ParseError.invalidFile }
            let tagRange = NSRange(location: 0, length: (tag as NSString).length)
            guard value.firstMatch(in: tag, range: tagRange) != nil else { continue }
            let attributes = attribute.matches(in: tag, range: tagRange)
            guard let key = attributes.first(where: { (tag as NSString).substring(with: $0.range(at: 1)) == "name" }),
                  let val = attributes.first(where: { (tag as NSString).substring(with: $0.range(at: 1)) == "val" }) else { continue }
            let name = (tag as NSString).substring(with: key.range(at: 3))
            let forbidden = reference.matches(in: tag, range: tagRange).filter { match in
                let number = (tag as NSString).substring(with: match.range(at: 1))
                let hex = number.hasPrefix("x")
                guard let scalar = UInt32(hex ? String(number.dropFirst()) : number, radix: hex ? 16 : 10) else { return false }
                // XML 1.0 §2.2 Char에 없는 숫자 참조만 다룬다.
                return !(scalar == 9 || scalar == 10 || scalar == 13 || (0x20...0xD7FF).contains(scalar)
                    || (0xE000...0xFFFD).contains(scalar) || (0x10000...0x10FFFF).contains(scalar))
            }
            let nameReferences = forbidden.filter { NSLocationInRange($0.range.location, key.range(at: 3)) }
            if !nameReferences.isEmpty {
                // 금지 참조를 뺀 이름도 필수 키라면 거부한다. 정상 엔티티 표기도 같은 파서로 판별한다.
                let candidate = NSMutableString(string: (tag as NSString).substring(with: key.range))
                for match in nameReferences.reversed() {
                    candidate.replaceCharacters(in: NSRange(location: match.range.location - key.range.location,
                                                            length: match.range.length), with: "")
                }
                let reader = SettingsReader()
                let parser = XMLParser(data: Data("<PROPERTIES><VALUE \(candidate) val=''/></PROPERTIES>".utf8))
                parser.shouldResolveExternalEntities = false
                parser.delegate = reader
                guard parser.parse(), reader.values.isEmpty else { throw RekordboxITunesSelection.ParseError.invalidFile }
            } else {
                // 그 밖의 참조 이름은 필수 키일 수 있으므로 원문 그대로 엄격하게 파싱한다.
                guard !name.contains("&"), !["MusicAppLoadingType", "itunesLibraryFile"].contains(name) else { continue }
            }
            for match in forbidden where NSLocationInRange(match.range.location, key.range(at: 3))
                || NSLocationInRange(match.range.location, val.range(at: 3)) {
                replacements.append(NSRange(location: token.range.location + match.range.location, length: match.range.length))
            }
        }
        // 삭제하면 &am&#2;p;처럼 깨진 참조가 합쳐질 수 있어 공백으로 경계를 남긴다.
        for range in replacements.reversed() { result.replaceCharacters(in: range, with: " ") }
        return Data((result as String).utf8)
    }

    private final class SettingsReader: NSObject, XMLParserDelegate {
        var depth = 0
        var hasRoot = false
        var values: [String: String] = [:]
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            defer { depth += 1 }
            if depth == 0 { hasRoot = name == "PROPERTIES" }
            if depth == 1, name == "VALUE", let key = attributes["name"], ["MusicAppLoadingType", "itunesLibraryFile"].contains(key) {
                values[key] = attributes["val"]
            }
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) { depth -= 1 }
    }
}
