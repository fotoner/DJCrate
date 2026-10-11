import CryptoKit
import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit

/// 외부 파서(rekordcrate·pyrekordbox) 대조용: 두 USB 리더가 읽은 모델을 표·행·칸마다 값 대신 해시로 JSON에 쓴다(#189).
/// Device Library는 쪽 사슬·행 수·산 행 오프셋 같은 구조 칸도 숫자로 함께 쓴다. 글자 값은 파일에도 출력에도 남기지 않는다.
/// 해시 = SHA-256(정규형 UTF-8) 앞 16자. 정규형: 글자 `s:<값>`(NFC로 바꾸지 않음), 정수 `i:<10진>`, 없음 `n`, 참거짓 `b:1|0`,
/// 목록 `l:<a,b,…>`, 형식 `e:<이름>`. 비교기(`scripts/usb-parser-compare.py`)가 같은 규칙으로 외부 파서 값을 해시한다.
enum UsbFieldsLab {
    static let all: [Command] = [
        Command("usb-fields", "<USB 폴더> --out <파일.json>",
                "두 USB 리더가 읽은 표·행·칸을 해시로, pdb 쪽 구조를 숫자로 JSON에 쓴다(외부 파서 대조용, 값은 쓰지 않음)",
                UsbFieldsLab.usbFields),
    ]

    static func usbFields(_ args: [String]) async throws {
        var positional: [String] = [], out: String?
        var index = 1
        while index < args.count {
            if args[index] == "--out" {
                guard index + 1 < args.count else { throw UsageError() }
                index += 1
                out = args[index]
            } else {
                positional.append(args[index])
            }
            index += 1
        }
        guard positional.count == 1, let path = positional.first, let out else { throw UsageError() }
        let root = UsbRoot(URL(filePath: try UsbScratchPath.check(path, as: .existingDirectory)))
        let target = URL(filePath: try UsbScratchPath.check(out, as: .newFile))
        let work = FileManager.default.temporaryDirectory.appending(path: "djc-usb-fields-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        let snapshot = try UsbSnapshot.take(root: root, into: work)
        var result: [String: Any] = ["hash": "sha256:16"]
        if let copy = snapshot.oneLibrary {
            let rows = tables(try OneLibraryReader.read(copyAt: copy))
            result["oneLibrary"] = ["tables": rows]
            print("OneLibrary " + summary(rows))
        }
        if let (library, report) = try PdbReader.read(snapshot: snapshot) {
            var files: [String: Any] = [:]
            for url in [snapshot.exportPdb, snapshot.exportExtPdb].compactMap({ $0 }) {
                let file = try PdbReader.inspect(Data(contentsOf: url))
                files[file.kind.fileName] = structure(file)
            }
            let issues = Dictionary(report.issueDetails.map { ($0.kind.rawValue, 1) }, uniquingKeysWith: +)
            let rows = tables(library)
            result["deviceLibrary"] = ["tables": rows, "files": files, "issues": issues]
            print("Device Library " + summary(rows) + ", 구조 문제 \(report.issueDetails.count)")
        }
        guard result.count > 1 else { print("USB 라이브러리(exportLibrary.db·export.pdb)가 없다"); return }
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        try data.write(to: target, options: .withoutOverwriting)
        print("썼다: \(target.lastPathComponent)")
    }

    // MARK: 칸 해시

    static func hash(_ canonical: String) -> String {
        SHA256.hash(data: Data(canonical.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// 값 하나의 정규형. 구조체·사전·Optional이면 nil(`flatten`이 펼친다)
    static func canonical(_ value: Any) -> String? {
        switch value {
        case let value as String: "s:" + value
        case let value as Bool: "b:" + (value ? "1" : "0")
        case let value as any BinaryInteger: "i:" + String(value)
        case let value as UsbFormat: "e:" + value.rawValue
        case let value as [Int]: "l:" + value.map(String.init).joined(separator: ",")
        case let value as Set<UsbFormat>: "l:" + value.map(\.rawValue).sorted().joined(separator: ",")
        case let value as Set<Int>: "l:" + value.sorted().map(String.init).joined(separator: ",")
        case let value as [PdbStringKind]: "l:" + value.map(\.rawValue).joined(separator: ",")
        default: nil
        }
    }

    /// 행 하나 → 칸 이름 → 해시. 중첩 칸은 `칸.하위`(사전은 `칸.키`, 형식 키는 형식 이름)로 펼친다
    static func fields(of row: Any) -> [String: String] {
        var result: [String: String] = [:]
        for child in Mirror(reflecting: row).children {
            if let label = child.label { flatten(child.value, key: label, into: &result) }
        }
        return result
    }

    private static func flatten(_ value: Any, key: String, into result: inout [String: String]) {
        if let canonical = canonical(value) {
            result[key] = hash(canonical)
            return
        }
        let mirror = Mirror(reflecting: value)
        switch mirror.displayStyle {
        case .optional:
            if let wrapped = mirror.children.first { flatten(wrapped.value, key: key, into: &result) } else { result[key] = hash("n") }
        case .dictionary:
            for entry in mirror.children {
                let pair = Mirror(reflecting: entry.value).children.map(\.value)
                guard pair.count == 2 else { continue }
                let name = (pair[0] as? UsbFormat)?.rawValue ?? "\(pair[0])"
                flatten(pair[1], key: key + "." + name, into: &result)
            }
        case .struct:
            for child in mirror.children {
                if let label = child.label { flatten(child.value, key: key + "." + label, into: &result) }
            }
        default:
            // 정규형이 없는 자료형은 비교기가 알아보게 표시만 한다(값은 넣지 않는다)
            result[key] = "?" + String(describing: type(of: value))
        }
    }

    /// 모델의 표마다 행 키 → 칸 해시
    static func tables(_ library: UsbLibrary) -> [String: [String: [String: String]]] {
        func keyed<Row>(_ rows: [Row], _ key: (Row) -> String) -> [String: [String: String]] {
            var result: [String: [String: String]] = [:]
            for row in rows {
                var name = key(row), copy = 2
                // 같은 키가 둘이면 뒤 행에 번호를 붙여 잃지 않는다
                while result[name] != nil {
                    name = key(row) + "#\(copy)"
                    copy += 1
                }
                result[name] = fields(of: row)
            }
            return result
        }
        var tables: [String: [String: [String: String]]] = [
            "tracks": keyed(library.tracks) { "\($0.id)" },
            "artists": keyed(library.artists) { "\($0.id)" },
            "albums": keyed(library.albums) { "\($0.id)" },
            "genres": keyed(library.genres) { "\($0.id)" },
            "keys": keyed(library.keys) { "\($0.id)" },
            "labels": keyed(library.labels) { "\($0.id)" },
            "colors": keyed(library.colors) { "\($0.id)" },
            "images": keyed(library.images) { "\($0.id)" },
            "playlists": keyed(library.playlists) { "\($0.id)" },
            "myTags": keyed(library.myTags) { "\($0.id)" },
            "myTagLinks": keyed(library.myTagLinks) { "\($0.myTagID):\($0.contentID)" },
            "menuItems": keyed(library.menuItems) { "\($0.id)" },
            "categories": keyed(library.categories) { "\($0.id)" },
            "sorts": keyed(library.sorts) { "\($0.id)" },
            "histories": keyed(library.histories) { "\($0.id)" },
            "property": ["0": fields(of: library.property)],
            "unknownRows": keyed(library.unknownRows) { "\($0.file):\($0.tableType)" },
            "deadIDs": library.deadIDs.mapValues { ["ids": canonical($0).map(hash) ?? "?"] },
        ]
        if !library.trackRowExtras.isEmpty {
            tables["trackRowExtras"] = Dictionary(uniqueKeysWithValues: library.trackRowExtras.map { ("\($0.key)", fields(of: $0.value)) })
        }
        return tables
    }

    static func summary(_ tables: [String: [String: [String: String]]]) -> String {
        let rows = tables.values.reduce(0) { $0 + $1.count }
        let fields = tables.values.reduce(0) { $0 + $1.values.reduce(0) { $0 + $1.count } }
        return "표 \(tables.count)개, 행 \(rows), 칸 \(fields)"
    }

    // MARK: pdb 구조

    /// 파일 머리·표 포인터와 표마다 사슬 쪽의 머리 칸·산 행 오프셋(힙 시작 0x28 기준). 모두 쪽·행 자리 숫자다
    static func structure(_ file: PdbFileReport) -> [String: Any] {
        let header = file.header
        return [
            "header": [
                "pageSize": header.pageSize, "numTables": header.numTables, "nextUnusedPage": header.nextUnusedPage,
                "flag10": header.flag10, "sequence": header.sequence, "gap": header.gap,
                "tables": header.tables.map {
                    ["type": $0.type, "emptyCandidate": $0.emptyCandidate, "firstPage": $0.firstPage, "lastPage": $0.lastPage]
                },
            ] as [String: Any],
            "tables": file.tables.map { table -> [String: Any] in
                [
                    "type": table.pointer.type, "name": table.name, "liveRows": table.liveRows, "slots": table.slotCount,
                    "pages": table.pages.map { page -> [String: Any] in
                        let header = page.header
                        return [
                            "index": header.pageIndex, "type": header.type, "next": header.nextPage, "sequence": header.sequence,
                            "u2": header.u2, "slots": header.rowSlots, "live": header.liveRows, "flags": header.flags,
                            "free": header.freeSize, "used": header.usedSize, "txRowCount": header.txRowCount,
                            "txRowIndex": header.txRowIndex, "u6": header.u6, "u7": header.u7, "isIndex": header.isIndex,
                            "liveOffsets": page.slots.filter(\.isLive).map(\.offset).sorted(),
                        ]
                    },
                ]
            },
            "issues": file.issues.count,
        ]
    }
}
