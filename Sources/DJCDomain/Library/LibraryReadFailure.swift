import Foundation

/// 마지막 정상 목록의 유무, 실패한 읽기 단계, 실패 원인을 함께 보존한다.
/// 원인(`Cause`)은 사용자가 할 일이 갈리는 것만 나눈다. 가를 수 없으면 `.other`다(#299).
public struct LibraryReadFailure: Equatable, Sendable {
    public enum Stage: Sendable { case snapshotCreation, opening, contents }

    /// 실패 원인. 화면 문구와 할 일이 원인마다 다르다
    public enum Cause: Sendable, Equatable {
        /// 라이브러리 폴더·`master.db`가 없다(설치 안 됨, 설치만 하고 한 번도 실행 안 함)
        case libraryMissing
        /// 라이브러리를 읽을 권한이 없다
        case permissionDenied
        /// 복사하는 사이 rekordbox가 라이브러리를 바꿨다(잠시 뒤 다시 읽으면 된다)
        case changedWhileCopying
        /// 그 밖(원인을 가를 수 없다)
        case other
    }

    public let stage: Stage
    public let keepsPreviousLibrary: Bool
    public let cause: Cause
    /// 원문 오류(자세히 보기용, 홈 폴더는 `~`로 줄였다). 같은 실패인지 가를 때는 보지 않는다
    public let detail: String?

    public init(stage: Stage, keepsPreviousLibrary: Bool, cause: Cause = .other, detail: String? = nil) {
        self.stage = stage
        self.keepsPreviousLibrary = keepsPreviousLibrary
        self.cause = cause
        self.detail = detail
    }

    /// 던져진 오류에서 원인과 원문을 뽑는다. 원인은 rekordbox 라이브러리를 복사하는 단계(`.snapshotCreation`)에서만 가른다:
    /// 그 뒤에 읽는 것은 DJCrate가 만든 사본이라 파일이 없거나 열리지 않아도 rekordbox 설치·권한 문제가 아니다.
    /// - Parameter home: 원문에서 `~`로 줄일 홈 폴더 경로(개인 경로를 화면에 그대로 두지 않는다)
    public init(stage: Stage, keepsPreviousLibrary: Bool, error: any Error, home: String) {
        self.init(stage: stage, keepsPreviousLibrary: keepsPreviousLibrary,
                  cause: stage == .snapshotCreation ? Self.cause(of: error) : .other, detail: Self.detail(of: error, home: home))
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.stage == rhs.stage && lhs.keepsPreviousLibrary == rhs.keepsPreviousLibrary && lhs.cause == rhs.cause
    }

    // MARK: - 원인 가르기

    /// 오류가 가리키는 원인. 밑에 깔린 오류(`NSUnderlyingErrorKey`)까지 본다
    public static func cause(of error: any Error) -> Cause {
        if case DJCError.sourceChangedDuringCopy = error { return .changedWhileCopying }
        var current: NSError? = error as NSError
        var depth = 0
        while let ns = current, depth < 4 {
            switch (ns.domain, ns.code) {
            case (NSCocoaErrorDomain, CocoaError.fileNoSuchFile.rawValue), (NSCocoaErrorDomain, CocoaError.fileReadNoSuchFile.rawValue),
                 (NSPOSIXErrorDomain, Int(ENOENT)):
                return .libraryMissing
            case (NSCocoaErrorDomain, CocoaError.fileReadNoPermission.rawValue),
                 (NSPOSIXErrorDomain, Int(EACCES)), (NSPOSIXErrorDomain, Int(EPERM)):
                return .permissionDenied
            case (NSCocoaErrorDomain, CocoaError.fileWriteNoPermission.rawValue), (NSCocoaErrorDomain, CocoaError.fileWriteOutOfSpace.rawValue),
                 (NSCocoaErrorDomain, CocoaError.fileWriteVolumeReadOnly.rawValue), (NSCocoaErrorDomain, CocoaError.fileWriteFileExists.rawValue),
                 (NSCocoaErrorDomain, CocoaError.fileWriteUnknown.rawValue):
                // 읽기용 사본을 두는 쪽 문제는 rekordbox 라이브러리를 읽는 문제가 아니다
                return .other
            default:
                break
            }
            current = ns.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return .other
    }

    static func detail(of error: any Error, home: String) -> String {
        let text: String
        if let known = error as? DJCError {
            text = known.description
        } else {
            let ns = error as NSError
            text = "\(ns.localizedDescription) (\(ns.domain) \(ns.code))"
        }
        return redactingHome(text, home: home)
    }

    /// 글 안의 홈 폴더 경로를 `~`로 줄인다. 이름이 더 긴 다른 폴더(`/Users/dj2`)는 건드리지 않는다
    public static func redactingHome(_ text: String, home: String) -> String {
        guard !home.isEmpty else { return text }
        var result = "", rest = Substring(text)
        while let range = rest.range(of: home) {
            result += rest[..<range.lowerBound]
            let next = rest[range.upperBound...].first
            let continuesName = next.map { $0.isLetter || $0.isNumber || "._-".contains($0) } ?? false
            result += continuesName ? String(home) : "~"
            rest = rest[range.upperBound...]
        }
        return result + rest
    }

    // MARK: - 문구

    /// 실패 화면 제목(원인마다 다르다)
    public var title: String {
        switch cause {
        case .libraryMissing: String(ui: "rekordbox 라이브러리를 찾지 못했습니다")
        case .permissionDenied: String(ui: "rekordbox 라이브러리를 읽을 권한이 없습니다")
        case .changedWhileCopying: String(ui: "rekordbox가 라이브러리를 쓰는 중입니다")
        case .other: String(ui: "라이브러리를 읽지 못했습니다")
        }
    }

    /// 실패 화면에서 제목 밑에 보이는 할 일. 그 밖은 없다(단추와 자세히 보기가 안내한다)
    public var guidance: String? {
        switch cause {
        case .libraryMissing: String(ui: "rekordbox 7을 설치하고 한 번 실행한 뒤 다시 찾아 주세요")
        case .permissionDenied: String(ui: "Finder에서 rekordbox 라이브러리 폴더의 읽기 권한을 확인하고, 그래도 안 되면 시스템 설정 › 개인정보 보호 및 보안 › 전체 디스크 접근 권한에서 DJCrate를 허용한 뒤 다시 시도하세요")
        case .changedWhileCopying: String(ui: "잠시 뒤 다시 읽습니다")
        case .other: nil
        }
    }

    /// [자세히 보기]로 원문 오류를 보여 줄지(원인을 가른 실패는 할 일이 문구에 다 있다)
    public var offersDetail: Bool { cause == .other }

    /// 복사 중 바뀜을 자동으로 다시 읽는 동안 보이는 글
    public static var retryingMessage: String {
        LibraryReadFailure(stage: .snapshotCreation, keepsPreviousLibrary: false, cause: .changedWhileCopying).message
    }

    /// 한 문장(또는 두 문장)으로 합친 문구. 이전 목록이 있으면 목록 위 오류 줄에, 없으면 실패 화면 단계 값에 쓴다
    public var message: String {
        if keepsPreviousLibrary {
            switch cause {
            case .libraryMissing:
                String(ui: "rekordbox 라이브러리를 찾지 못해 이전 목록을 표시합니다. rekordbox 7을 설치하고 한 번 실행한 뒤 다시 찾아 주세요")
            case .permissionDenied:
                String(ui: "rekordbox 라이브러리를 읽을 권한이 없어 이전 목록을 표시합니다. Finder에서 rekordbox 라이브러리 폴더의 읽기 권한을 확인하고, 그래도 안 되면 시스템 설정 › 개인정보 보호 및 보안 › 전체 디스크 접근 권한에서 DJCrate를 허용한 뒤 다시 시도하세요")
            case .changedWhileCopying:
                String(ui: "rekordbox가 라이브러리를 쓰는 중이라 이전 목록을 표시합니다. 잠시 뒤 다시 읽습니다")
            case .other:
                String(ui: "라이브러리를 읽지 못해 이전 목록을 표시합니다. 최근 변경은 확인되지 않았으니 잠시 뒤 ‘rekordbox와 동기화’로 다시 읽으세요")
            }
        } else {
            switch cause {
            case .libraryMissing:
                String(ui: "rekordbox 라이브러리를 찾지 못했습니다. rekordbox 7을 설치하고 한 번 실행한 뒤 다시 찾아 주세요")
            case .permissionDenied:
                String(ui: "rekordbox 라이브러리를 읽을 권한이 없습니다. Finder에서 rekordbox 라이브러리 폴더의 읽기 권한을 확인하고, 그래도 안 되면 시스템 설정 › 개인정보 보호 및 보안 › 전체 디스크 접근 권한에서 DJCrate를 허용한 뒤 다시 시도하세요")
            case .changedWhileCopying:
                String(ui: "rekordbox가 라이브러리를 쓰는 중입니다. 잠시 뒤 다시 읽습니다")
            case .other:
                String(ui: "라이브러리를 읽지 못했습니다")
            }
        }
    }
}
