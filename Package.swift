// swift-tools-version: 6.2
import PackageDescription

// 의존 방향(헥사고날, #167. 바깥이 안쪽을 알고 안쪽은 바깥을 모른다):
//   핵심부       DJCApplication(유스케이스·포트 정의) → DJCDomain(엔티티·값·순수 규칙)
//   피동 어댑터  DJCAdapters(포트의 실제 구현 .live) → DJCApplication·DJCDomain와 인프라 RekordboxKit·DJCStorage·DJCAnalysis·DJCEnvironment
//                인프라는 포트를 모른다(DJCApplication·DJCAdapters·앱을 import하지 않는다)
//   주도 어댑터  DJCrate(앱)·djc(CLI) → DJCApplication. 실제 구현은 조립 지점(AppComposition·CLI 조립 파일)만 고른다
// 규칙과 아직 남은 예외(빚 목록)는 scripts/check-imports.py·scripts/import-debt.txt가 검사한다.
// 실행 파일은 얇은 진입점(DJCrateExecutable·djcExecutable)이다.
// 모든 Swift 타깃: 직접 import한 모듈의 확장 멤버만 보인다(SE-0444). 전이 의존으로 새어 들어오는 확장 멤버를 컴파일러가 막아
// scripts/check-imports.py의 import 줄 검사가 실제 사용과 맞게 한다(#167).
let swiftSettings: [SwiftSetting] = [.enableUpcomingFeature("MemberImportVisibility")]
// SQLCipher는 외부 패키지 제품이다(아래 dependencies). 타깃마다 같은 이름을 쓴다.
let sqlCipher: Target.Dependency = .product(name: "SQLCipher", package: "SQLCipher.swift")

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
        .library(name: "DJCEnvironment", targets: ["DJCEnvironment"]),
        .library(name: "DJCLink", targets: ["DJCLink"]),
        .library(name: "DJCApplication", targets: ["DJCApplication"]),
        .library(name: "DJCAdapters", targets: ["DJCAdapters"]),
        // 실행 파일 이름(.build/debug/djc·DJCrate)은 제품 이름을 따른다. 본체는 같은 이름의 라이브러리 타깃이다.
        .executable(name: "djc", targets: ["djcExecutable"]),
        .executable(name: "DJCrate", targets: ["DJCrateExecutable"]),
    ],
    dependencies: [
        // rekordbox DB 열기(SQLCipher 4.19.0, BSD 계열). 공식 SwiftPM 패키지가 고정 URL·체크섬의 xcframework를 바이너리 타깃으로 낸다.
        // DJLinkKit도 같은 패키지를 의존하므로 이 저장소도 그 제품을 써야 그래프에 SQLCipher가 하나만 있다. 바이너리 타깃을
        // 따로 두면 SwiftPM이 같은 이름 'SQLCipher'를 두 패키지가 선언했다며 그래프를 거부한다(#268).
        // 그 manifest의 폐기된 watchOS 4 선언 경고가 manifest를 읽을 때마다 보인다(2026-10-01에는 이것을 없애려고 바이너리 타깃으로 두었다).
        .package(url: "https://github.com/sqlcipher/SQLCipher.swift", exact: "4.19.0"),
        // Pro DJ Link(CDJ·DJM 네트워크). alphatheta-connect의 Swift 포트, GPL-2.0-or-later(#268). DJCLink만 import한다.
        .package(url: "https://github.com/ImBada/DJLinkKit", exact: "0.1.6"),
    ],
    targets: [
        // 앱 자동 업데이트(#59, MIT). Sparkle 2.10.0 공식 SwiftPM 바이너리·체크섬(그 태그의 Package.swift와 같다).
        // 업데이트 검증 코드를 확인한 버전으로 고정한다. 올리면 docs/releasing.md "자동 업데이트"의 확인을 다시 한다.
        // 이 패키지의 바이너리 타깃으로 둔다. 앱 시험 번들(DJCrateTests)이 Sparkle.framework를 찾는 조건은 아래 DJCrateTests에 있다.
        // 외부 패키지 제품도 Products/Debug에 놓인다: SQLCipher를 외부 제품으로 바꾼 뒤 처음부터 빌드한
        // `swift build --build-tests`가 SQLCipher.framework를 두었고, DJLinkKit을 거쳐서만 닿는 DJCLinkTests도 열렸다(2026-10-16, Swift 6.4, #268).
        .binaryTarget(
            name: "Sparkle",
            url: "https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-for-Swift-Package-Manager.zip",
            checksum: "17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959"
        ),
        // 순수 규칙·모델(입출력 없음)
        .target(name: "DJCDomain", swiftSettings: swiftSettings),
        // 이 프로세스의 환경 읽기: 시험 프로세스 여부(#182)·데이터·로그·스냅샷 위치(DJC_HOME·DJC_REKORDBOX_DIR)
        .target(name: "DJCEnvironment", dependencies: ["DJCDomain"], swiftSettings: swiftSettings),
        // rekordbox 형식: SQLCipher DB·ANLZ·XML 읽기/쓰기, 스냅샷, 백업
        .target(
            name: "RekordboxKit",
            dependencies: ["DJCDomain", "DJCEnvironment", sqlCipher],
            swiftSettings: swiftSettings
        ),
        // DJCrate 자신의 파일: 초안·추가한 곡·반영 묶음
        .target(name: "DJCStorage", dependencies: ["DJCDomain", "DJCEnvironment", "RekordboxKit"], swiftSettings: swiftSettings),
        // 소리 분석: 파형·그리드 추정·조성·음량·섹션
        .target(name: "DJCAnalysis", dependencies: ["DJCDomain", "DJCEnvironment"], swiftSettings: swiftSettings),
        // Pro DJ Link(CDJ·DJM 네트워크): DJLinkKit을 import하는 유일한 모듈(scripts/check-imports.py). DJLinkKit 타입을 공개 API에 내지 않는다.
        // 어댑터(DJCAdapters/Link)만 부른다.
        .target(
            name: "DJCLink",
            dependencies: [.product(name: "DJLinkKit", package: "DJLinkKit"), .product(name: "DJLinkExport", package: "DJLinkKit")],
            swiftSettings: swiftSettings
        ),
        // 기능별(Library·Deck·Edit·Reflection·Usb) 유스케이스와 포트. DJCStorage는 모르고, 환경(DJCEnvironment)·Mac 파일 시스템은 포트로 받는다(남은 예외는 docs/architecture.md 경계 규칙).
        .target(name: "DJCApplication", dependencies: ["DJCDomain"], swiftSettings: swiftSettings),
        // 피동 어댑터: DJCApplication 포트의 실제 구현(.live) 한 벌. 인프라를 부르기만 하고 쓰기 관문의 위치·동작은 그대로 둔다.
        .target(
            name: "DJCAdapters",
            dependencies: ["DJCApplication", "DJCDomain", "RekordboxKit", "DJCStorage", "DJCAnalysis", "DJCEnvironment", "DJCLink"],
            swiftSettings: swiftSettings
        ),
        // 명령줄 도구 본체. 라이브러리로 두어 실행 파일과 테스트가 컴파일 결과를 함께 쓴다.
        .target(
            name: "djc",
            dependencies: ["DJCDomain", "DJCEnvironment", "RekordboxKit", "DJCStorage", "DJCAnalysis", "DJCApplication", "DJCAdapters"],
            resources: [.process("Resources")],
            swiftSettings: swiftSettings
        ),
        // macOS 앱 본체. 문구 카탈로그는 Resources/에 있다. Sparkle은 업데이트 연결 파일 한 곳만 import한다(scripts/check-imports.py).
        .target(
            name: "DJCrate",
            dependencies: ["DJCDomain", "DJCEnvironment", "RekordboxKit", "DJCStorage", "DJCAnalysis", "DJCApplication", "DJCAdapters",
                           "Sparkle"],
            exclude: ["Info.plist"],
            resources: [.process("Resources")],
            swiftSettings: swiftSettings
        ),
        .executableTarget(name: "djcExecutable", dependencies: ["djc"], swiftSettings: swiftSettings),
        // 번들 없이 도는 개발 빌드도 macOS 언어를 따르게 실행 파일에 언어 목록(Info.plist)을 넣는다.
        // 넣지 않으면 메인 번들 언어가 영어뿐이라 카탈로그 번들도 늘 영어를 고른다.
        .executableTarget(
            name: "DJCrateExecutable",
            dependencies: ["DJCrate"],
            swiftSettings: swiftSettings,
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                "-Xlinker", Context.packageDirectory + "/Sources/DJCrate/Info.plist",
            ])]
        ),
        // 시험 재료(DJCDomain만): 가짜 볼륨·DiskArbitration 사전, 합성 음원·그림, 임시 폴더. SQLCipher를 빌드하지 않는다.
        .target(name: "DJCTestKit", dependencies: ["DJCDomain"], path: "Tests/Support/Kit", swiftSettings: swiftSettings),
        // rekordbox 시험 재료: 구조만 있는 rekordbox DB, 합성 분석 파일·pdb·USB 트리(실데이터 없음)
        .target(
            name: "RekordboxFixtures",
            dependencies: ["DJCDomain", "RekordboxKit", sqlCipher, "DJCTestKit"],
            path: "Tests/Support/Fixtures",
            resources: [.copy("Resources")],
            swiftSettings: swiftSettings
        ),
        // 시험 전용 SQLCipher 키 유도 반복 수(docs/ci.md "테스트 준비 비용"). 프로세스가 올라올 때 constructor가 기본 반복 수를 낮춘다.
        // 제품 연결이 많은 시험 타깃만 의존한다. 제품 타깃·실행 파일과 djc를 띄우는 djcTests는 의존하지 않아 SQLCipher 4 기본값 그대로다.
        .target(name: "CipherTestKDF", dependencies: [sqlCipher], path: "Tests/Support/CipherKDF"),
        // 포트 시험 재료(실제 구현·인프라를 모른다): 피동 포트의 가짜(메모리 구현)와 공용 계약 함수. 유스케이스 시험은 가짜에,
        // 어댑터 시험은 실제 구현에 같은 계약 함수를 돌린다(adv4 T7: 가짜와 실제가 갈라져도 모르고 통과했다).
        .target(name: "PortTestKit", dependencies: ["DJCApplication", "DJCDomain", "DJCTestKit"], path: "Tests/Support/Ports", swiftSettings: swiftSettings),
        // 시험 타깃은 시험하는 층과 그 아래 층, 필요한 재료만 의존한다.
        .testTarget(name: "DJCDomainTests", dependencies: ["DJCDomain", "DJCEnvironment", "DJCTestKit"], swiftSettings: swiftSettings),
        .testTarget(name: "RekordboxKitTests", dependencies: ["RekordboxKit", "DJCDomain", "DJCEnvironment", "RekordboxFixtures", "DJCTestKit", "CipherTestKDF"], swiftSettings: swiftSettings),
        .testTarget(name: "DJCAnalysisTests", dependencies: ["DJCAnalysis", "DJCDomain", "DJCEnvironment", "DJCTestKit"], swiftSettings: swiftSettings),
        // Pro DJ Link 패킷 읽기. 실기 캡처 바이트만 쓰고 소켓을 열지 않는다.
        .testTarget(name: "DJCLinkTests", dependencies: ["DJCLink"], swiftSettings: swiftSettings),
        // DJCrate 자신의 파일(초안·USB 세션·볼륨·도구 실행·iTunes 읽기). 가짜 도구 실행기(FakeToolRunner)는 이 타깃 안에 있다.
        .testTarget(
            name: "DJCStorageTests",
            dependencies: ["DJCStorage", "DJCApplication", "DJCAnalysis", "RekordboxKit", "DJCDomain", "RekordboxFixtures", "DJCTestKit", "CipherTestKDF"],
            swiftSettings: swiftSettings
        ),
        // CLI 인자·출력과 `.build/debug/djc`를 띄우는 프로세스 시험. djc에 넘길 픽스처를 djc와 같은 키 유도(256,000번)로 만들게 CipherTestKDF에 의존하지 않는다.
        .testTarget(
            name: "djcTests",
            dependencies: ["djc", "DJCStorage", "DJCApplication", "DJCAdapters", "DJCAnalysis", "RekordboxKit", "DJCDomain", "DJCEnvironment", "RekordboxFixtures", "DJCTestKit"],
            swiftSettings: swiftSettings
        ),
        // 앱 화면 모델(덱·목록·반영 흐름)을 가짜 오디오·저장소로 시험한다.
        .testTarget(
            name: "DJCrateTests",
            // Sparkle은 import하지 않는다. 시험 타깃이 바이너리 타깃에 직접 의존해야 `swift build --build-tests`가 Sparkle.framework를
            // Products/Debug에 둔다(앱 제품을 거친 의존만으로는 두지 않아 DJCrateTests.xctest를 열지 못한다).
            dependencies: ["DJCrate", "DJCStorage", "DJCApplication", "DJCAdapters", "DJCAnalysis", "RekordboxKit", "DJCDomain", "DJCEnvironment", "RekordboxFixtures", "DJCTestKit",
                           "CipherTestKDF", "Sparkle"],
            swiftSettings: swiftSettings
        ),
        // 유스케이스 시험: 가짜 포트(PortTestKit)와 DJCTestKit만 쓴다(DB·인프라 없이). 포트 계약 함수를 가짜에 돌린다.
        .testTarget(name: "DJCApplicationTests", dependencies: ["DJCApplication", "DJCDomain", "DJCTestKit", "PortTestKit"],
                    swiftSettings: swiftSettings),
        // 어댑터 시험: 실제 구현(.live)을 합성 픽스처·임시 폴더로 시험한다(실제 rekordbox·사용자 폴더 없이). 포트 계약 함수를 실제 구현에 돌린다.
        .testTarget(name: "DJCAdaptersTests", dependencies: ["DJCAdapters", "DJCApplication", "DJCDomain", "DJCEnvironment", "DJCStorage", "RekordboxKit",
                                                     "RekordboxFixtures", "DJCTestKit", "PortTestKit", "CipherTestKDF"], swiftSettings: swiftSettings),
    ]
)
