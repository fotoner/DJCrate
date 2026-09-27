// swift-tools-version: 6.2
import PackageDescription

// 의존 방향(위가 아래를 모른다):
//   DJCrate(앱)·djc(CLI) → DJCStorage → RekordboxKit → DJCDomain
//                         → DJCAnalysis ──────────────→ DJCDomain
let package = Package(
    name: "DJCrate",
    // 문구 원문(String Catalog 키)은 한국어. 앱·CLI가 카탈로그를 공유한다(docs/i18n.md).
    defaultLocalization: "ko",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "DJCDomain", targets: ["DJCDomain"]),
        .library(name: "RekordboxKit", targets: ["RekordboxKit"]),
        .library(name: "DJCStorage", targets: ["DJCStorage"]),
        .library(name: "DJCAnalysis", targets: ["DJCAnalysis"]),
        .executable(name: "djc", targets: ["djcExecutable"]),
        .executable(name: "DJCrate", targets: ["DJCrateExecutable"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sqlcipher/SQLCipher.swift", exact: "4.19.0"),
    ],
    targets: [
        // 순수 규칙·모델(입출력 없음)
        .target(name: "DJCDomain"),
        // rekordbox 형식: SQLCipher DB·ANLZ·XML 읽기/쓰기, 스냅샷, 백업
        .target(
            name: "RekordboxKit",
            dependencies: ["DJCDomain", .product(name: "SQLCipher", package: "SQLCipher.swift")]
        ),
        // DJCrate 자신의 파일: 초안·추가한 곡·반영 묶음
        .target(name: "DJCStorage", dependencies: ["DJCDomain", "RekordboxKit"]),
        // 소리 분석: 파형·그리드 추정·조성·음량·섹션
        .target(name: "DJCAnalysis", dependencies: ["DJCDomain"]),
        // 본체를 라이브러리로 공유해 실행용·테스트용 중복 컴파일을 피한다.
        .target(
            name: "djc",
            dependencies: ["DJCDomain", "RekordboxKit", "DJCStorage", "DJCAnalysis"],
            resources: [.process("Resources")]
        ),
        // macOS 앱. 문구 카탈로그는 Resources/에 있다.
        .target(
            name: "DJCrate",
            dependencies: ["DJCDomain", "RekordboxKit", "DJCStorage", "DJCAnalysis"],
            exclude: ["Info.plist"],
            resources: [.process("Resources")]
        ),
        .executableTarget(name: "djcExecutable", dependencies: ["djc"]),
        // 번들 없이 도는 개발 빌드도 macOS 언어를 따르게 실행 파일에 언어 목록(Info.plist)을 넣는다.
        // 넣지 않으면 메인 번들 언어가 영어뿐이라 카탈로그 번들도 늘 영어를 고른다.
        .executableTarget(
            name: "DJCrateExecutable",
            dependencies: ["DJCrate"],
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                "-Xlinker", Context.packageDirectory + "/Sources/DJCrate/Info.plist",
            ])]
        ),
        // 테스트 재료: 구조만 있는 rekordbox DB, 합성 분석 파일·음원(실데이터 없음)
        .target(
            name: "DJCTestSupport",
            dependencies: ["DJCDomain", "RekordboxKit", .product(name: "SQLCipher", package: "SQLCipher.swift")],
            path: "Tests/Support",
            resources: [.copy("Resources")]
        ),
        .testTarget(name: "DJCDomainTests", dependencies: ["DJCDomain"]),
        .testTarget(name: "RekordboxKitTests", dependencies: ["RekordboxKit", "DJCDomain", "DJCTestSupport"]),
        .testTarget(name: "DJCAnalysisTests", dependencies: ["DJCAnalysis", "DJCDomain", "DJCTestSupport"]),
        .testTarget(name: "djcTests", dependencies: ["djc", "DJCAnalysis", "RekordboxKit", "DJCTestSupport"]),
        // 앱 화면 모델(덱·목록·반영 흐름)을 가짜 오디오·저장소로 시험한다.
        .testTarget(name: "DJCrateTests", dependencies: ["DJCrate", "DJCDomain", "DJCStorage", "DJCTestSupport"]),
    ]
)
