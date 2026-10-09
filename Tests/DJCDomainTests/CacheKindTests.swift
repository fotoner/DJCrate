import DJCDomain
import DJCEnvironment
import Foundation
import Testing

/// #215: 비울 수 있는 캐시 종류는 허용 목록 하나(`DJCCacheKind`)다. 사용자 작업·안전 상태는 어떤 종류의 자리에도 들어가지 않는다.
@Suite("캐시 종류")
struct CacheKindTests {
    /// 어떤 초기화에서도 지우지 않는 것(이슈 #215 범위표)
    static let protected = [
        "cue-drafts", "grid-drafts", "tag-drafts", "artwork-drafts", "gain-drafts.json", "playlist-drafts.json",
        "staged.json", "playlist-imports.json", "damaged-drafts", "usb-drafts", "usb-sessions", "usb-staging",
        "usb-physical-allow.json", "usb-physical-deny.json", "rekordbox-backups", "usb-backups", "edits",
        "merge-drafts.json", "reflection.json", "last-write-result.json",
    ]

    let root = URL(filePath: "/private/tmp/djc-cache-kind-\(UUID())")

    @Test func 종류마다_자리가_하나이고_데이터_폴더의_허용한_이름만_가리킨다() {
        let paths = DJCCachePaths(root: root)
        let expected: [DJCCacheKind: String] = [
            .waveforms: "waveforms", .analysis: "analysis", .loudness: "loudness.json",
            .previewWaveforms: "preview-waveforms.plist", .usbSnapshots: "usb-snapshots", .snapshots: "snapshots",
        ]
        #expect(Set(DJCCacheKind.allCases) == Set(expected.keys))
        for kind in DJCCacheKind.allCases {
            #expect(paths.location(of: kind) == root.appending(path: expected[kind]!), "\(kind)")
        }
    }

    @Test func 사용자_데이터는_어떤_종류의_자리에도_없다() {
        let paths = DJCCachePaths(root: root, snapshots: root.appending(path: "snapshots"))
        for kind in DJCCacheKind.allCases {
            let location = paths.location(of: kind).standardizedFileURL.path
            for name in Self.protected {
                let user = root.appending(path: name).standardizedFileURL.path
                #expect(location != user && !user.hasPrefix(location + "/") && !location.hasPrefix(user + "/"), "\(kind) ↔ \(name)")
            }
        }
    }

    @Test func 종류_이름은_CLI_인자로_쓰는_글자_그대로다() {
        #expect(DJCCacheKind.allCases.map(\.rawValue) == ["waveforms", "analysis", "loudness", "preview-waveforms", "usb-snapshots", "snapshots"])
        for kind in DJCCacheKind.allCases {
            #expect(!kind.title.isEmpty && !kind.detail.isEmpty)
        }
    }

    @Test func 스냅샷_폴더는_DJC_HOME이_아니라_rekordbox_폴더_사본이나_지원_폴더를_따른다() {
        let support = URL(filePath: "/private/tmp/support")
        #expect(DJCIdentity.snapshotsDirectory(environment: [:], support: support) == support.appending(path: "snapshots"))
        #expect(DJCIdentity.snapshotsDirectory(environment: ["DJC_HOME": "/private/tmp/home"], support: support) == support.appending(path: "snapshots"))
        #expect(DJCIdentity.snapshotsDirectory(environment: ["DJC_REKORDBOX_DIR": "/private/tmp/rb"], support: support)
                == URL(filePath: "/private/tmp/rb").appending(path: "djc-snapshots"))
    }
}
