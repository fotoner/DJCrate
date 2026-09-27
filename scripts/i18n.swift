// 앱 문구 카탈로그(Sources/DJCrate/Resources/*.xcstrings)를 코드와 맞추고 번역이 빠지지 않았는지 본다.
// 사용: swift scripts/i18n.swift sync    코드에서 뽑은 문구로 Localizable.xcstrings를 고친다(새 문구 더하기, 안 쓰는 문구 빼기)
//       swift scripts/i18n.swift check   카탈로그가 코드와 같고 en·ja 번역·자리표시자가 모두 맞는지(check.sh가 부른다)
// 문구는 디버그 빌드가 뽑은 .stringsdata(컴파일러가 타입을 보고 뽑음)에서 읽는다. 규칙은 docs/i18n.md.
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL
let resources = root.appending(path: "Sources/DJCrate/Resources")
let catalogURL = resources.appending(path: "Localizable.xcstrings")
let infoPlistCatalogURL = resources.appending(path: "InfoPlist.xcstrings")
/// 앱·CLI가 같은 카탈로그로 문구를 찾는다. CLI의 Lab은 개발자용이라 한국어를 유지한다.
let modules = ["DJCrate", "djc", "DJCDomain", "RekordboxKit", "DJCStorage", "DJCAnalysis"]
let languages = ["en", "ja"]

struct Extracted {
    var key: String
    /// 키를 따로 준 문구(`String(localized: "키", defaultValue: "원문", …)`)의 원문.
    var value: String?
    var table: String
    var file: String
    var line: Int
    var column: Int
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

@discardableResult
func run(_ arguments: [String], quiet: Bool = false) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    process.currentDirectoryURL = root
    if quiet {
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
    }
    do { try process.run() } catch { fail("실행하지 못했습니다: \(arguments.joined(separator: " "))") }
    process.waitUntilExit()
    return process.terminationStatus
}

/// 디버그 빌드가 남긴 .stringsdata 중 지금 있는 소스 파일의 것만(지운·옮긴 파일의 옛 결과는 뺀다).
/// 테스트 빌드(-testable-)는 따로 남아 옛 내용일 수 있어 빼고, 한 소스에 여럿이면 가장 새것을 쓴다.
func stringsdataFiles() -> [URL] {
    let intermediates = root.appending(path: ".build/out/Intermediates.noindex")
    guard let walker = FileManager.default.enumerator(at: intermediates, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
    let prefixes = modules.map { root.appending(path: "Sources/\($0)/").path }
    var newest: [String: (url: URL, date: Date)] = [:]
    for case let url as URL in walker
    where url.pathExtension == "stringsdata" && url.path.contains("/Debug/") && !url.path.contains("-testable-") {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let source = json["source"] as? String,
              prefixes.contains(where: { source.hasPrefix($0) }),
              FileManager.default.fileExists(atPath: source) else { continue }
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        if date > newest[source]?.date ?? .distantPast { newest[source] = (url, date) }
    }
    return newest.values.map(\.url).sorted { $0.path < $1.path }
}

func extracted(from files: [URL]) -> [Extracted] {
    var result: [Extracted] = []
    for url in files {
        let json = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]
        let source = json["source"] as? String ?? ""
        for (table, entries) in json["tables"] as? [String: [[String: Any]]] ?? [:] {
            for entry in entries {
                let location = entry["location"] as? [String: Int] ?? [:]
                result.append(Extracted(key: entry["key"] as? String ?? "", value: entry["value"] as? String, table: table, file: source,
                                        line: location["startingLine"] ?? 0, column: location["startingColumn"] ?? 0))
            }
        }
    }
    return result
}

/// 문구는 `String(ui:)`·`.ui(…)`로만 카탈로그를 찾는다. SwiftUI에 문자열을 그대로 주면(Text("…"))
/// 메인 번들을 찾아서 개발 빌드·테스트와 앱 번들이 다르게 보인다. 원문 그대로 보일 글은 verbatim으로 쓴다.
/// 같은 한국어를 뜻에 따라 달리 번역할 때만 키를 따로 주고 번들은 `UIStrings.bundle`로 준다.
func misplaced(_ entries: [Extracted]) -> [String] {
    var sources: [String: [Substring]] = [:]
    let allowed = try! Regex(#"(String\(ui:|\.ui\()\s*#*$"#)
    let explicitKey = try! Regex(#"(String\(localized:|LocalizedStringResource\()\s*#*$"#)
    var problems: [String] = []
    for entry in entries where !isTextless(entry.value ?? entry.key) {
        let relative = entry.file.replacingOccurrences(of: root.path + "/", with: "")
        guard entry.table == "Localizable" else {
            problems.append("\(relative):\(entry.line): 표 '\(entry.table)'는 쓰지 않습니다. String(ui:)·.ui(…)로 쓰세요")
            continue
        }
        if sources[entry.file] == nil {
            let text = (try? String(contentsOfFile: entry.file, encoding: .utf8)) ?? ""
            sources[entry.file] = text.split(separator: "\n", omittingEmptySubsequences: false)
        }
        let lines = sources[entry.file]!
        guard entry.line >= 1, entry.line <= lines.count else { continue }
        // 열은 UTF-8 바이트 기준(1부터). 여러 줄에 걸친 호출도 보게 앞 두 줄을 붙인다.
        let current = Array(lines[entry.line - 1].utf8)
        let head = String(decoding: current.prefix(max(entry.column - 1, 0)), as: UTF8.self)
        let before = lines[max(0, entry.line - 3)..<(entry.line - 1)].joined(separator: "\n") + "\n" + head
        let after = String(decoding: current.dropFirst(max(entry.column - 1, 0)), as: UTF8.self)
            + lines[entry.line..<min(lines.count, entry.line + 2)].joined(separator: "\n")
        let keyed = entry.value != nil && before.firstMatch(of: explicitKey) != nil && after.contains("bundle: UIStrings.bundle")
        if before.firstMatch(of: allowed) == nil && !keyed {
            problems.append("\(relative):\(entry.line): \"\(entry.key)\" — String(ui:)·.ui(…) 밖의 지역화 문구입니다. 번역할 문구면 .ui(…)로, 그대로 보일 글이면 Text(verbatim:)으로 쓰세요")
        }
    }
    return problems
}

func loadCatalog(_ url: URL) -> [String: Any] {
    guard let data = try? Data(contentsOf: url),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { fail("카탈로그를 읽지 못했습니다: \(url.path)") }
    return json
}

/// 카탈로그 사본을 코드 문구와 맞춘다. 사본 이름이 표 이름(Localizable)이어야 xcstringstool이 맞춘다.
func synced(stringsdata: [URL]) -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: "djc-i18n-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let copy = directory.appending(path: "Localizable.xcstrings")
    try? FileManager.default.copyItem(at: catalogURL, to: copy)
    let arguments = ["xcrun", "xcstringstool", "sync", copy.path] + stringsdata.flatMap { ["--stringsdata", $0.path] }
    guard run(arguments) == 0 else { fail("xcstringstool sync가 실패했습니다") }
    return copy
}

func strings(_ catalog: [String: Any]) -> [String: [String: Any]] {
    catalog["strings"] as? [String: [String: Any]] ?? [:]
}

func isStale(_ entry: [String: Any]) -> Bool { entry["extractionState"] as? String == "stale" }

/// 번역 값들. 복수형 변형이 있으면 변형마다 하나씩. 빠졌거나 번역 완료가 아니면 nil.
func translations(_ entry: [String: Any], language: String) -> [(value: String, isVariant: Bool)]? {
    guard let localization = (entry["localizations"] as? [String: Any])?[language] as? [String: Any] else { return nil }
    if let unit = localization["stringUnit"] as? [String: Any] {
        guard unit["state"] as? String == "translated", let value = unit["value"] as? String, !value.isEmpty else { return nil }
        return [(value, false)]
    }
    if let plural = (localization["variations"] as? [String: Any])?["plural"] as? [String: [String: Any]], plural["other"] != nil {
        var values: [(String, Bool)] = []
        for (_, variant) in plural {
            guard let unit = variant["stringUnit"] as? [String: Any], unit["state"] as? String == "translated",
                  let value = unit["value"] as? String, !value.isEmpty else { return nil }
            values.append((value, true))
        }
        return values
    }
    return nil
}

/// 자리표시자 종류(순서 무관). 위치 지정(%1$@)은 종류만 본다.
func placeholders(_ text: String) -> [String] {
    let pattern = try! Regex(#"%(?:\d+\$)?[-+ #0']*\d*(?:\.\d+)?(hh|h|ll|l|q|L|z|t|j)?([@dDiuUxXoOfeEgGcCsSpaA%])"#)
    return text.matches(of: pattern).compactMap { match in
        let length = match.output[1].substring.map(String.init) ?? ""
        let conversion = match.output[2].substring.map(String.init) ?? ""
        return conversion == "%" ? nil : length + conversion
    }.sorted()
}

/// 자리표시자와 빈칸만 있는 키(SF 심볼을 끼운 Text("\(letter)\(Image(…))")의 "%@%@" 등)는 번역할 것이 없다.
/// 따옴표·쌍점이 있는 키("‘%@’")는 언어마다 부호가 달라(「%@」) 번역한다.
func isTextless(_ key: String) -> Bool {
    let pattern = try! Regex(#"%(?:\d+\$)?[-+ #0']*\d*(?:\.\d+)?(hh|h|ll|l|q|L|z|t|j)?[@dDiuUxXoOfeEgGcCsSpaA%]"#)
    return key.replacing(pattern, with: "").allSatisfy(\.isWhitespace)
}

func isSubset(_ small: [String], of large: [String]) -> Bool {
    var remaining = large
    for item in small {
        guard let index = remaining.firstIndex(of: item) else { return false }
        remaining.remove(at: index)
    }
    return true
}

/// en·ja 번역이 모두 있고 자리표시자가 원문과 같은지. 복수형 변형은 원문의 일부만 써도 된다("1곡"의 1을 글로).
/// 키를 따로 준 문구는 한국어 원문 값(ko)과 비교한다.
func translationProblems(_ catalog: [String: Any], name: String, languages: [String] = languages) -> [String] {
    var problems: [String] = []
    for (key, entry) in strings(catalog).sorted(by: { $0.key < $1.key }) where entry["shouldTranslate"] as? Bool != false {
        let korean = (((entry["localizations"] as? [String: Any])?["ko"] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
        let source = placeholders(korean ?? key)
        for language in languages {
            guard let values = translations(entry, language: language) else {
                problems.append("\(name) \(language) 번역 없음: \(key)")
                continue
            }
            for (value, isVariant) in values {
                let found = placeholders(value)
                if isVariant ? !isSubset(found, of: source) : found != source {
                    problems.append("\(name) \(language) 자리표시자가 원문과 다름: \(key) → \(value)")
                }
            }
        }
    }
    return problems
}

// 전체 검사와 같은 계측 설정을 써서 번역 확인 때문에 디버그 빌드를 다시 하지 않는다.
let buildArguments = Array(CommandLine.arguments.dropFirst(2))
let coverageArguments = ["--enable-code-coverage"]
let hashingArguments = ["-Xswiftc", "-enable-incremental-file-hashing"]
guard [[], coverageArguments, hashingArguments, coverageArguments + hashingArguments].contains(buildArguments) else {
    fail("사용: swift scripts/i18n.swift sync|check [--enable-code-coverage] [-Xswiftc -enable-incremental-file-hashing]")
}

func buildDebug() {
    guard run(["swift", "build", "--product", "DJCrate"] + buildArguments, quiet: buildArguments.isEmpty) == 0 else { fail("swift build가 실패했습니다. 먼저 빌드 오류를 고치세요") }
    guard run(["swift", "build", "--product", "djc"] + buildArguments, quiet: buildArguments.isEmpty) == 0 else { fail("djc 빌드가 실패했습니다. 먼저 빌드 오류를 고치세요") }
}

func report(_ problems: [String], limit: Int = 40) {
    for problem in problems.prefix(limit) { print("    \(problem)") }
    if problems.count > limit { print("    … 외 \(problems.count - limit)개") }
}

let command = CommandLine.arguments.dropFirst().first ?? "check"
switch command {
case "sync":
    buildDebug()
    let files = stringsdataFiles()
    guard !files.isEmpty else { fail(".stringsdata가 없습니다. swift build(기본 빌드 시스템)로 빌드했는지 확인하세요") }
    let before = strings(loadCatalog(catalogURL))
    let copy = synced(stringsdata: files)
    var after = loadCatalog(copy)
    var entries = strings(after)
    let removed = entries.filter { isStale($0.value) }.map(\.key).sorted()
    for key in removed { entries[key] = nil }
    for key in entries.keys { entries[key]?["shouldTranslate"] = isTextless(key) ? false : nil }
    after["strings"] = entries
    // 빠진 문구만 빼고 다시 맞춰 xcstringstool 모양 그대로 저장한다.
    let data = try! JSONSerialization.data(withJSONObject: after, options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: copy)
    guard run(["xcrun", "xcstringstool", "sync", copy.path] + files.flatMap { ["--stringsdata", $0.path] }) == 0 else { fail("xcstringstool sync가 실패했습니다") }
    try! FileManager.default.removeItem(at: catalogURL)
    try! FileManager.default.copyItem(at: copy, to: catalogURL)
    let added = Set(entries.keys).subtracting(before.keys).sorted()
    print("카탈로그: 문구 \(entries.count)개, 새 문구 \(added.count)개, 뺀 문구 \(removed.count)개")
    for key in added { print("  + \(key)") }
    for key in removed {
        let old = languages.compactMap { language in translations(before[key] ?? [:], language: language)?.first.map { "\(language): \($0.value)" } }
        print("  - \(key)" + (old.isEmpty ? "" : "  (" + old.joined(separator: " / ") + ")"))
    }
    let untranslated = translationProblems(loadCatalog(catalogURL), name: "Localizable")
    if !untranslated.isEmpty { print("번역·자리표시자 확인이 필요한 문구 \(untranslated.count)개"); report(untranslated) }

case "check":
    buildDebug()
    let files = stringsdataFiles()
    guard !files.isEmpty else { fail(".stringsdata가 없습니다. swift build(기본 빌드 시스템)로 빌드했는지 확인하세요") }
    var problems = misplaced(extracted(from: files))
    let committed = loadCatalog(catalogURL)
    let current = strings(loadCatalog(synced(stringsdata: files)))
    let added = current.filter { strings(committed)[$0.key] == nil }.map(\.key).sorted()
    let stale = current.filter { isStale($0.value) }.map(\.key).sorted()
    problems += added.map { "카탈로그에 없는 문구(swift scripts/i18n.swift sync): \($0)" }
    problems += stale.map { "코드에서 안 쓰는 문구(swift scripts/i18n.swift sync): \($0)" }
    problems += translationProblems(committed, name: "Localizable")
    let infoPlist = loadCatalog(infoPlistCatalogURL)
    // Info.plist 문구는 원문도 카탈로그 값으로 쓴다(없으면 한국어 화면에 키 이름이 나온다).
    problems += translationProblems(infoPlist, name: "InfoPlist", languages: ["ko"] + languages)
    let count = strings(committed).count
    if problems.isEmpty {
        print("  ✔ 번역 문구 \(count)개 + Info.plist \(strings(infoPlist).count)개, en·ja 누락 0, stale 0")
    } else {
        print("  ✘ 번역 문제 \(problems.count)개(문구 \(count)개)")
        report(problems)
        exit(1)
    }

default:
    fail("사용: swift scripts/i18n.swift sync|check")
}
