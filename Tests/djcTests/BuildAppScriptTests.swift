import Foundation
import Testing

@Suite("앱 빌드 스크립트")
struct BuildAppScriptTests {
    @Test(arguments: ["none", "found", "override"])
    func 서명_인증서_유무와_관계없이_설치까지_진행한다(_ identity: String) throws {
        let result = try run(identity: identity, install: true)
        #expect(result.status == 0, "\(result.output)")
        #expect(result.installed)
        #expect(result.output.contains("설치:"))
        #expect(result.signatures.contains(identity == "none" ? "--sign - " : "--sign TEST_IDENTITY "))
    }

    @Test func 설치_인자가_없으면_번들만_만든다() throws {
        let result = try run(identity: "none", install: false)
        #expect(result.status == 0, "\(result.output)")
        #expect(!result.installed)
        #expect(result.output.contains("만듦:"))
    }

    @Test func 서명_실패시_설치하지_않는다() throws {
        let result = try run(identity: "override", install: true, signingFails: true)
        #expect(result.status != 0)
        #expect(!result.installed)
        #expect(result.signatures.contains("--sign TEST_IDENTITY "))
    }

    @Test func 번들에도_덱_드래그_형식을_선언한다() throws {
        let result = try run(identity: "none", install: false)
        #expect(result.status == 0, "\(result.output)")
        #expect(result.exportedTypes.contains("com.djcrate.deck-track"))
        // 곡 목록 → 사이드바 재생 목록·USB 줄 끌어 놓기 형식(#240)
        #expect(result.exportedTypes.contains("com.djcrate.track-ids"))
        #expect(result.exportedTypes.contains("com.djcrate.usb-track-ids"))
    }

    @Test func 레이어_아이콘을_컴파일하고_번들에_연결한다() throws {
        let result = try run(identity: "none")
        #expect(result.status == 0, "\(result.output)")
        #expect(result.iconName == "AppIcon")
        #expect(result.hasIconAssets)
        #expect(result.iconCompilation.contains("AppIcon.icon"))
        #expect(result.iconCompilation.contains("--platform macosx"))
        #expect(result.iconCompilation.contains("--minimum-deployment-target 27.0"))
    }

    @Test func 아이콘_컴파일_실패시_서명과_설치를_막는다() throws {
        let result = try run(identity: "none", install: true, iconCompilationFails: true)
        #expect(result.status != 0)
        #expect(!result.installed)
        #expect(result.signatures.isEmpty)
    }

    @Test(arguments: [["--version", "1.2.3"], ["--tag", "v1.2.3"]])
    func 명시한_버전으로_패키지를_만들고_개발_인증서는_쓰지_않는다(_ arguments: [String]) throws {
        let result = try run(identity: "override", arguments: arguments + ["--package"])
        #expect(result.status == 0, "\(result.output)")
        #expect(result.version == "1.2.3")
        #expect(!result.installed)
        #expect(result.signatures.contains("--sign - "))
        #expect(!result.signatures.contains("TEST_IDENTITY"))
        #expect(result.packageFiles.contains("DJCrate-1.2.3-macOS-arm64.zip"))
        #expect(result.packageFiles.contains("DJCrate-1.2.3-macOS-arm64.zip.sha256"))
    }

    @Test func 현재_태그에서_패키지_버전을_읽는다() throws {
        let result = try run(identity: "none", arguments: ["--package"], tag: "v2.3.4")
        #expect(result.status == 0, "\(result.output)")
        #expect(result.version == "2.3.4")
        #expect(result.packageFiles.contains("DJCrate-2.3.4-macOS-arm64.zip"))
    }

    @Test(arguments: [
        ["--version"], ["--version", ""], ["--version", "1.2"], ["--version", "01.2.3"],
        ["--version", "1.2.3-beta"], ["--version", "1.2.3/foo"], ["--tag", "1.2.3"],
        ["--tag", "v1.2.3.4"], ["--unknown"], ["--version", "1.2.3", "--tag", "v1.2.3"],
        ["--package"], ["--package", "--install", "--version", "1.2.3"],
    ])
    func 잘못된_버전과_옵션은_빌드_전에_막는다(_ arguments: [String]) throws {
        let result = try run(identity: "none", arguments: arguments)
        #expect(result.status != 0)
        #expect(!result.buildStarted)
        #expect(!result.installed)
        #expect(result.signatures.isEmpty)
    }

    @Test func 잘못된_현재_태그는_빌드_전에_막는다() throws {
        let result = try run(identity: "none", tag: "v1.2.3-beta")
        #expect(result.status != 0)
        #expect(!result.buildStarted)
    }

    @Test func 태그가_없는_일반_빌드는_기존_버전을_유지한다() throws {
        let result = try run(identity: "none")
        #expect(result.status == 0, "\(result.output)")
        #expect(result.version == "0.1")
    }

    private func run(identity: String, install: Bool = false, signingFails: Bool = false,
                     arguments: [String]? = nil, tag: String = "", iconCompilationFails: Bool = false) throws
        -> (status: Int32, output: String, installed: Bool, signatures: String, exportedTypes: [String],
            version: String, packageFiles: [String], buildStarted: Bool,
            iconName: String, hasIconAssets: Bool, iconCompilation: String) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "djc-build-script-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func file(_ path: String, _ text: String = "합성 파일") throws {
            let url = root.appending(path: path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let source = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "scripts/build-app.sh")
        try file("scripts/build-app.sh", String(contentsOf: source, encoding: .utf8))
        let info = source.deletingLastPathComponent().deletingLastPathComponent().appending(path: "Sources/DJCrate/Info.plist")
        try file("Sources/DJCrate/Info.plist", String(contentsOf: info, encoding: .utf8))
        for path in [".build/release/DJCrate", ".build/release/SQLCipher.framework/SQLCipher",
                     ".build/release/DJCrate_DJCrate.bundle/Contents/Resources/ko.lproj/InfoPlist.strings",
                     "LICENSE", "THIRD_PARTY_NOTICES.md"] { try file(path) }
        // 빌드·키체인·서명은 가짜 도구로 실행하고 설치 대상도 임시 폴더로 돌린다.
        try file("bin/tool", #"""
        #!/bin/zsh
        set -e
        case "${0:t}" in
          swift) /usr/bin/touch "$DJC_TEST_ROOT/build-started"; exit 0 ;;
          install_name_tool) exit 0 ;;
          git)
            case "$1" in
              rev-list) echo 17 ;;
              describe) [[ -n "$DJC_TEST_TAG" ]] || exit 1; print -r -- "$DJC_TEST_TAG" ;;
              *) exit 99 ;;
            esac ;;
          lipo) echo arm64 ;;
          security)
            if [[ "$DJC_TEST_IDENTITY" == found ]]; then
              echo '  1) TEST_IDENTITY "Apple Development: Synthetic"'
            else
              echo '     0 valid identities found'
            fi ;;
          codesign)
            print -r -- "$*" >> "$DJC_TEST_ROOT/signatures"
            [[ "$DJC_TEST_SIGN_FAIL" != 1 ]] ;;
          plutil) /usr/bin/plutil "$@" ;;
          mktemp) /bin/mkdir -p "$DJC_TEST_ROOT/icon-temp"; echo "$DJC_TEST_ROOT/icon-temp" ;;
          iconutil) /usr/bin/touch "$5" ;;
          xcrun)
            [[ "$1" == actool ]] || exit 99
            print -r -- "$*" >> "$DJC_TEST_ROOT/icon-compilation"
            [[ "$DJC_TEST_ICON_FAIL" != 1 ]] || exit 1
            while (( $# )); do
              case "$1" in
                --compile) destination="$2"; shift 2 ;;
                --output-partial-info-plist) partial="$2"; shift 2 ;;
                *) shift ;;
              esac
            done
            /usr/bin/touch "$destination/Assets.car" "$destination/AppIcon.icns"
            /usr/bin/plutil -create xml1 "$partial"
            /usr/bin/plutil -insert CFBundleIconName -string AppIcon "$partial"
            /usr/bin/plutil -insert CFBundleIconFile -string AppIcon "$partial" ;;
          cp|rm|mkdir)
            args=()
            for arg in "$@"; do
              case "$arg" in
                /Applications|"$HOME/Applications") arg="$DJC_TEST_ROOT/installed" ;;
                /Applications/DJCrate.app|"$HOME/Applications/DJCrate.app") arg="$DJC_TEST_ROOT/installed/DJCrate.app" ;;
              esac
              args+=("$arg")
            done
            "/bin/${0:t}" "${args[@]}" ;;
          *) exit 99 ;;
        esac
        """#)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appending(path: "bin/tool").path)
        for tool in ["swift", "git", "lipo", "security", "codesign", "plutil", "mktemp", "iconutil", "xcrun", "install_name_tool", "cp", "rm", "mkdir"] {
            try fm.createSymbolicLink(atPath: root.appending(path: "bin/\(tool)").path, withDestinationPath: "tool")
        }
        let process = Process(), output = Pipe()
        process.executableURL = URL(filePath: "/bin/zsh")
        process.arguments = [root.appending(path: "scripts/build-app.sh").path] + (arguments ?? (install ? ["--install"] : []))
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = root.appending(path: "bin").path + ":/usr/bin:/bin"
        environment["DJC_TEST_ROOT"] = root.path
        environment["DJC_TEST_IDENTITY"] = identity
        environment["DJC_TEST_SIGN_FAIL"] = signingFails ? "1" : "0"
        environment["DJC_TEST_ICON_FAIL"] = iconCompilationFails ? "1" : "0"
        environment["DJC_TEST_TAG"] = tag
        environment["DJC_SIGN_IDENTITY"] = identity == "override" ? "TEST_IDENTITY" : nil
        process.environment = environment
        process.standardOutput = output; process.standardError = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let signatures = (try? String(contentsOf: root.appending(path: "signatures"), encoding: .utf8)) ?? ""
        let bundleInfo = NSDictionary(contentsOf: root.appending(path: "dist/DJCrate.app/Contents/Info.plist"))
        let declarations = bundleInfo?["UTExportedTypeDeclarations"] as? [[String: Any]] ?? []
        return (process.terminationStatus, text,
                fm.fileExists(atPath: root.appending(path: "installed/DJCrate.app/Contents/MacOS/DJCrate").path), signatures,
                declarations.compactMap { $0["UTTypeIdentifier"] as? String },
                bundleInfo?["CFBundleShortVersionString"] as? String ?? "",
                (try? fm.contentsOfDirectory(atPath: root.appending(path: "dist").path)) ?? [],
                fm.fileExists(atPath: root.appending(path: "build-started").path),
                bundleInfo?["CFBundleIconName"] as? String ?? "",
                fm.fileExists(atPath: root.appending(path: "dist/DJCrate.app/Contents/Resources/Assets.car").path),
                (try? String(contentsOf: root.appending(path: "icon-compilation"), encoding: .utf8)) ?? "")
    }
}
