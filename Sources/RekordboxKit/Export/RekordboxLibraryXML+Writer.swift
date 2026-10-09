import DJCDomain
import DJCEnvironment
import Foundation

extension RekordboxLibraryXML {
    // MARK: - 출력 경로

    /// 출력 파일을 쓸 수 없는 이유. 무엇을 하면 되는지까지 한 문장이다.
    public typealias OutputError = LibraryXMLOutputError

    /// 보호된 자리를 거부할 때의 이유
    public static var protectedOutputReason: String {
        String(ui: "rekordbox 폴더, USB의 PIONEER 폴더, DJCrate 데이터 폴더, 연동 XML 파일 자리에는 내보낼 수 없습니다. 다른 폴더를 고르세요")
    }

    /// 출력 파일을 써도 되는 자리인지 본다(아무것도 쓰지 않는다). 다음은 거부한다.
    /// - `.xml`이 아닌 파일(실수로 `master.db` 같은 파일을 덮지 않게)과 폴더
    /// - 상위 폴더가 없는 경로
    /// - rekordbox 폴더(`~/Library/Pioneer`, 시험·개발 때의 `DJC_REKORDBOX_DIR`) 안. 링크를 따라간 실제 경로와 대소문자만 다른 표기도 같다.
    /// - USB의 `PIONEER/` 아래(`/Volumes/<볼륨>/PIONEER/…`, 대소문자 무시)
    /// - DJCrate 데이터 폴더(`DJC_HOME`·지원 폴더) 안. 백업의 masterPlaylists6.xml을 덮으면 "쓰기 전으로 복원"이 그것을 라이브로 옮긴다.
    /// - rekordbox가 연동 파일로 읽는 DJCrate의 연동 XML 자리(`DJCIdentity.linkedXMLFile`)
    public static func checkOutput(_ url: URL, environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard url.isFileURL, url.pathExtension.lowercased() == "xml" else {
            throw OutputError(reason: String(ui: "내보낼 파일 이름은 .xml로 끝나야 합니다. 저장 위치와 이름을 다시 고르세요"))
        }
        // 적힌 경로로 먼저 본다(아직 없는 USB·백업 폴더도 이유를 바르게 알린다). 아래에서 링크를 따라간 실제 경로로 다시 본다.
        guard !isProtected(url.standardizedFileURL.path, environment: environment) else {
            throw OutputError(reason: protectedOutputReason)
        }
        let parent = url.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let parentReal = UsbScratchRoots.realPath(parent.path) else {
            throw OutputError(reason: String(ui: "저장할 폴더가 없습니다. 있는 폴더를 고르세요"))
        }
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw OutputError(reason: String(ui: "같은 이름의 폴더가 있습니다. 다른 이름을 고르세요"))
        }
        // 이미 있는 파일이 링크면 그 실제 자리를 본다.
        let target = UsbScratchRoots.realPath(url.path) ?? parentReal + "/" + url.lastPathComponent
        guard !isProtected(target, environment: environment) else {
            throw OutputError(reason: protectedOutputReason)
        }
    }

    /// `/Volumes/<볼륨>/PIONEER/` 아래인지(대소문자 무시). rekordbox·기기가 읽는 USB 라이브러리 자리다.
    static func isUsbPioneerPath(_ path: String) -> Bool {
        let parts = path.precomposedStringWithCanonicalMapping.lowercased().split(separator: "/", omittingEmptySubsequences: true)
        return parts.count >= 4 && parts[0] == "volumes" && parts[2] == "pioneer"
    }

    private static func isProtected(_ realPath: String, environment: [String: String]) -> Bool {
        func key(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased() }
        let path = key(realPath)
        if isUsbPioneerPath(realPath) { return true }
        func inside(_ candidate: String?) -> Bool {
            guard let candidate else { return false }
            let root = key(candidate)
            return path == root || path.hasPrefix(root + "/")
        }
        let pioneer = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Pioneer").path
        // DJCrate 데이터 폴더: 이 프로세스의 뿌리(`DJC_HOME` 포함)와 설치한 앱의 실제 사용자 폴더, 옛 이름 폴더
        let data = [DJCIdentity.dataDirectory(environment: environment, support: DJCIdentity.supportDirectory).path,
                    DJCIdentity.supportDirectory.path, DJCIdentity.userSupportDirectory.path,
                    URL.applicationSupportDirectory.appending(path: DJCIdentity.legacyName).path]
        let roots = [pioneer, LibrarySnapshot.realRekordboxDirectory.path, LibrarySnapshot.rekordboxDirectory(in: environment).path] + data
        if roots.contains(where: { inside($0) || inside(UsbScratchRoots.realPath($0)) }) { return true }
        let linked = DJCIdentity.linkedXMLFile
        let linkedReal = UsbScratchRoots.realPath(linked.deletingLastPathComponent().path).map { $0 + "/" + linked.lastPathComponent }
        return path == key(linked.path) || linkedReal.map { path == key($0) } == true
    }

    // MARK: - 쓰기

    /// 스냅샷을 읽어 `out` 한 파일에만 쓴다(옛 파일은 다 쓴 뒤에 바꿔 끼운다). 쓰기 전에 출력 자리를 확인한다.
    @discardableResult
    public static func export(snapshot: URL, shareRoot: URL, to out: URL, productVersion: String = "0.1",
                              progress: (@Sendable (Progress) -> Void)? = nil) throws -> Summary {
        try checkOutput(out)
        let collection = try load(snapshot: snapshot, shareRoot: shareRoot, productVersion: productVersion, progress: progress)
        try write(collection, to: out, progress: progress)
        return collection.summary
    }

    /// 컬렉션을 `out`에 쓴다. 같은 폴더의 임시 파일에 다 쓰고 바꿔 끼우므로, 도중에 실패해도 있던 파일은 그대로다.
    public static func write(_ collection: Collection, to out: URL, progress: (@Sendable (Progress) -> Void)? = nil) throws {
        try checkOutput(out)
        let fm = FileManager.default
        let temporary = out.deletingLastPathComponent().appending(path: ".\(out.lastPathComponent).\(UUID().uuidString).part")
        guard fm.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o644]) else {
            throw OutputError(reason: String(ui: "파일을 만들지 못했습니다. 저장 위치와 권한을 확인하세요"))
        }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            do {
                try write(collection, progress: progress) { chunk in try handle.write(contentsOf: Data(chunk.utf8)) }
                try handle.synchronize()
            } catch {
                try? handle.close()
                throw error
            }
            try handle.close()
            if fm.fileExists(atPath: out.path) {
                _ = try fm.replaceItemAt(out, withItemAt: temporary)
            } else {
                try fm.moveItem(at: temporary, to: out)
            }
        } catch {
            try? fm.removeItem(at: temporary)
            throw error
        }
    }

    /// 문서 전체(작은 라이브러리·시험용). 큰 라이브러리는 `write(_:to:)`가 덩어리로 흘려 쓴다.
    public static func document(_ collection: Collection) -> String {
        var text = ""
        // 메모리에 쌓기만 하므로 던지는 일은 작업 취소뿐이다. 그때는 쓴 데까지만 돌려준다.
        try? write(collection, progress: nil) { text += $0 }
        return text
    }

    /// 문서를 덩어리(약 256KB)로 `emit`에 넘긴다. 곡이 수만 개여도 문서 전체를 메모리에 들고 있지 않는다.
    public static func write(_ collection: Collection, progress: (@Sendable (Progress) -> Void)? = nil,
                             emit: (String) throws -> Void) throws {
        var buffer = ""
        func flush(force: Bool = false) throws {
            if force || buffer.utf8.count >= 256 * 1024 {
                try emit(buffer)
                buffer = ""
            }
        }
        buffer += #"<?xml version="1.0" encoding="UTF-8"?>"# + "\n"
        buffer += #"<DJ_PLAYLISTS Version="1.0.0">"# + "\n"
        buffer += #"  <PRODUCT Name="\#(attribute(DJCIdentity.name))" Version="\#(attribute(collection.productVersion))" Company=""/>"# + "\n"
        buffer += #"  <COLLECTION Entries="\#(collection.entries.count)">"# + "\n"
        for (index, entry) in collection.entries.enumerated() {
            if index % 100 == 0 {
                try Task.checkCancellation()
                progress?(Progress(phase: .writing, done: index, total: collection.entries.count))
            }
            for line in trackLines(entry) { buffer += line + "\n" }
            try flush()
        }
        buffer += "  </COLLECTION>\n"
        buffer += "  <PLAYLISTS>\n"
        if collection.lists.isEmpty {
            buffer += #"    <NODE Type="0" Name="ROOT" Count="0"/>"# + "\n"
        } else {
            buffer += #"    <NODE Type="0" Name="ROOT" Count="\#(collection.lists.count)">"# + "\n"
            for node in collection.lists {
                for line in nodeLines(node, depth: 3) { buffer += line + "\n" }
                try flush()
            }
            buffer += "    </NODE>\n"
        }
        buffer += "  </PLAYLISTS>\n"
        buffer += "</DJ_PLAYLISTS>\n"
        try flush(force: true)
        progress?(Progress(phase: .writing, done: collection.entries.count, total: collection.entries.count))
    }

    // MARK: - 줄 만들기

    /// TRACK 한 곡. 칸 순서는 rekordbox 형식 문서의 순서를 따르고, 넣지 않는 칸(Grouping·DateModified·LastPlayed·Mix 등)은 건너뛴다.
    static func trackLines(_ entry: Entry) -> [String] {
        let track = entry.track, extras = entry.extras
        var attributes: [(String, String)] = [
            ("TrackID", "\(entry.trackKey)"),
            ("Name", track.title),
            ("Artist", track.artist ?? ""),
            ("Composer", track.composer ?? ""),
            ("Album", track.album ?? ""),
            ("Genre", track.genre ?? ""),
            ("Kind", RekordboxXML.kind(forExtension: (track.folderPath as NSString).pathExtension)),
        ]
        if let size = extras.fileSize { attributes.append(("Size", "\(size)")) }
        attributes += [
            ("TotalTime", "\(track.lengthSeconds)"),
            ("DiscNumber", "\(extras.discNumber ?? 0)"),
            ("TrackNumber", "\(track.trackNumber ?? 0)"),
            ("Year", "\(track.releaseYear ?? 0)"),
        ]
        if let bpm = track.bpm, bpm > 0 { attributes.append(("AverageBpm", String(format: "%.2f", bpm))) }
        if let added = extras.dateAdded ?? track.importedOn { attributes.append(("DateAdded", added)) }
        if let bitrate = track.bitrateKbps { attributes.append(("BitRate", "\(bitrate)")) }
        if let rate = extras.sampleRate { attributes.append(("SampleRate", "\(rate)")) }
        attributes += [("Comments", track.comment), ("PlayCount", "\(extras.playCount)"),
                       ("Location", RekordboxXML.location(forPath: track.folderPath))]
        if let remixer = extras.remixer { attributes.append(("Remixer", remixer)) }
        if let key = track.key, !key.isEmpty { attributes.append(("Tonality", key)) }
        if let label = extras.label { attributes.append(("Label", label)) }
        attributes += entry.extraAttributes.map { ($0.name, $0.value) }

        let open = "    <TRACK " + attributes.map { "\($0.0)=\"\(attribute($0.1))\"" }.joined(separator: " ")
        var children: [String] = entry.tempos.filter { $0.bpm > 0 }.map { tempo in
            #"      <TEMPO Inizio="\#(String(format: "%.3f", tempo.start))" Bpm="\#(String(format: "%.2f", tempo.bpm))" Metro="4/4" Battito="\#(tempo.firstBeatNumber)"/>"#
        }
        for mark in entry.marks {
            var line = #"      <POSITION_MARK Name="\#(attribute(mark.name))" Type="\#(mark.type)" Start="\#(String(format: "%.3f", mark.start))""#
            if let end = mark.end { line += #" End="\#(String(format: "%.3f", end))""# }
            children.append(line + #" Num="\#(mark.num)"/>"#)
        }
        return children.isEmpty ? [open + "/>"] : [open + ">"] + children + ["    </TRACK>"]
    }

    static func nodeLines(_ node: ListNode, depth: Int) -> [String] {
        let indent = String(repeating: "  ", count: depth)
        let name = attribute(node.name)
        guard let children = node.children else {
            let open = #"\#(indent)<NODE Name="\#(name)" Type="1" KeyType="0" Entries="\#(node.keys.count)""#
            return node.keys.isEmpty ? [open + "/>"] : [open + ">"] + node.keys.map { #"\#(indent)  <TRACK Key="\#($0)"/>"# } + ["\(indent)</NODE>"]
        }
        let open = #"\#(indent)<NODE Name="\#(name)" Type="0" Count="\#(children.count)""#
        return children.isEmpty ? [open + "/>"]
            : [open + ">"] + children.flatMap { nodeLines($0, depth: depth + 1) } + ["\(indent)</NODE>"]
    }

    /// 속성 값: XML 1.0이 허용하지 않는 글자(U+FFFE·U+FFFF)를 버리고 이스케이프한다(제어 문자는 `RekordboxXML.escape`가 버린다).
    static func attribute(_ value: String) -> String {
        let clean = value.unicodeScalars.contains { $0.value == 0xFFFE || $0.value == 0xFFFF }
            ? String(String.UnicodeScalarView(value.unicodeScalars.filter { $0.value != 0xFFFE && $0.value != 0xFFFF }))
            : value
        return RekordboxXML.escape(clean)
    }
}
