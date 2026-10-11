import Foundation

/// 파형·분석(섹션·그리드 추정·크로마)·음량 캐시의 위치. 뿌리 하나(`DJCIdentity.dataDirectory`)에서만 파생한다.
/// `DJC_HOME`이 없을 때의 이름·배치는 설치한 앱이 쓰던 그대로다(바꾸면 쌓아 둔 캐시를 잃는다).
public struct DJCCachePaths: Sendable, Equatable {
    public var root: URL
    /// 라이브 DB 읽기 스냅샷 폴더. `DJC_HOME`을 따르지 않는다(`DJCIdentity.snapshotsDirectory`)
    public var snapshots: URL

    public init(root: URL, snapshots: URL? = nil) {
        self.root = root
        self.snapshots = snapshots ?? root.appending(path: "snapshots")
    }

    public var waveforms: URL { root.appending(path: "waveforms") }
    /// 섹션 분석 JSON과 하위 `grid-estimates/`·`chroma/`
    public var analysis: URL { root.appending(path: "analysis") }
    public var loudness: URL { root.appending(path: "loudness.json") }
    public var previewWaveforms: URL { root.appending(path: "preview-waveforms.plist") }
    /// USB DB를 Mac에서 읽으려고 뜬 사본(`<볼륨키>/<시각>/`)과 쓰기 세션 사본(`local-`·`usb-`·`info-`)
    public var usbSnapshots: URL { root.appending(path: "usb-snapshots") }

    /// 비울 수 있는 종류의 자리. 여기 없는 것(초안·추가 목록·백업·USB 저널·준비 폴더)은 어떤 초기화에서도 지우지 않는다(#215).
    public func location(of kind: DJCCacheKind) -> URL {
        switch kind {
        case .waveforms: waveforms
        case .analysis: analysis
        case .loudness: loudness
        case .previewWaveforms: previewWaveforms
        case .usbSnapshots: usbSnapshots
        case .snapshots: snapshots
        }
    }
}

/// 비울 수 있는 캐시 종류(허용 목록). 모두 다시 만들어진다. 이름(rawValue)은 `djc cache --clear`의 인자다.
public enum DJCCacheKind: String, CaseIterable, Sendable, Codable {
    case waveforms
    case analysis
    case loudness
    case previewWaveforms = "preview-waveforms"
    case usbSnapshots = "usb-snapshots"
    case snapshots

    public var title: String {
        switch self {
        case .waveforms: String(ui: "파형")
        case .analysis: String(ui: "분석(섹션·그리드 추정·키)")
        case .loudness: String(ui: "음량(오토게인)")
        case .previewWaveforms: String(ui: "목록 미리 보기 파형")
        case .usbSnapshots: String(ui: "USB 읽기 사본")
        case .snapshots: String(ui: "라이브러리 읽기 사본")
        }
    }

    /// 비운 뒤 언제 다시 만들어지는지
    public var detail: String {
        switch self {
        case .waveforms: String(ui: "곡을 덱에 불러올 때 다시 만듭니다")
        case .analysis: String(ui: "곡을 덱에 불러오거나 분석할 때 다시 만듭니다")
        case .loudness: String(ui: "곡을 덱에 불러올 때 다시 잽니다")
        case .previewWaveforms: String(ui: "곡 목록을 그릴 때 다시 만듭니다")
        case .usbSnapshots: String(ui: "USB를 열 때 다시 뜹니다. 볼륨마다 가장 새 사본은 남깁니다")
        case .snapshots: String(ui: "rekordbox와 동기화할 때 다시 뜹니다. 가장 새 사본과 지금 연 사본은 남깁니다")
        }
    }
}

/// 캐시 종류 하나의 용량(`DJCCache.Usage`, 논리 크기 합)
public struct DJCCacheUsage: Sendable, Equatable {
    public var kind: DJCCacheKind
    public var bytes: Int64
    public var files: Int

    public init(kind: DJCCacheKind, bytes: Int64, files: Int) {
        self.kind = kind
        self.bytes = bytes
        self.files = files
    }
}

/// 캐시 종류 하나를 비운 결과(`DJCCache.Outcome`)
public struct DJCCacheOutcome: Sendable, Equatable {
    public var kind: DJCCacheKind
    /// 지운(미리 보기면 지울) 파일의 논리 크기 합
    public var freedBytes: Int64 = 0
    public var removedFiles = 0
    /// 일부러 남긴 사본 수(라이브러리·USB 읽기 사본)
    public var keptItems = 0
    /// 이 종류를 건너뛴 이유(무엇을 하면 되는지까지)
    public var skipped: String?

    public init(kind: DJCCacheKind, freedBytes: Int64 = 0, removedFiles: Int = 0, keptItems: Int = 0, skipped: String? = nil) {
        self.kind = kind
        self.freedBytes = freedBytes
        self.removedFiles = removedFiles
        self.keptItems = keptItems
        self.skipped = skipped
    }
}

/// 비우기 대상이 아닌 백업(`DJCCache.BackupUsage`, 용량만 보인다). 개수는 백업 폴더 수다(#227)
public struct DJCBackupUsage: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case rekordboxBackups, pointSnapshots, usbBackups }
    public var kind: Kind
    public var count: Int
    public var bytes: Int64
    public init(kind: Kind, count: Int, bytes: Int64) { self.kind = kind; self.count = count; self.bytes = bytes }
}
