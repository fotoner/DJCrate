import DJCDomain
import Foundation
import Testing

/// 라이브러리 읽기 실패를 원인별로 나눠 문구를 정한다(#299). 원인을 가를 수 없으면 "그 밖"이다.
@Suite("라이브러리 읽기 실패 원인")
struct LibraryReadFailureTests {
    // MARK: - 원인 가르기

    @Test(arguments: [CocoaError.Code.fileReadNoSuchFile, .fileNoSuchFile])
    func 파일이_없는_오류는_라이브러리_없음이다(_ code: CocoaError.Code) {
        #expect(LibraryReadFailure.cause(of: CocoaError(code)) == .libraryMissing)
    }

    @Test func 밑에_깔린_POSIX_파일_없음도_라이브러리_없음이다() {
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
        let error = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadUnknown.rawValue,
                            userInfo: [NSUnderlyingErrorKey: underlying])
        #expect(LibraryReadFailure.cause(of: error) == .libraryMissing)
    }

    @Test func 읽기_권한_오류는_권한이다() {
        #expect(LibraryReadFailure.cause(of: CocoaError(.fileReadNoPermission)) == .permissionDenied)
    }

    @Test(arguments: [EACCES, EPERM])
    func POSIX_접근_거부는_권한이다(_ code: Int32) {
        #expect(LibraryReadFailure.cause(of: NSError(domain: NSPOSIXErrorDomain, code: Int(code))) == .permissionDenied)
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadUnknown.rawValue,
                              userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(code))])
        #expect(LibraryReadFailure.cause(of: wrapped) == .permissionDenied)
    }

    @Test func 쓰기_권한_오류는_읽기_권한으로_보지_않는다() {
        // 읽기용 사본 폴더에 쓰지 못한 것은 rekordbox 라이브러리를 읽을 권한 문제가 아니다
        #expect(LibraryReadFailure.cause(of: CocoaError(.fileWriteNoPermission)) == .other)
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        let write = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteNoPermission.rawValue,
                            userInfo: [NSUnderlyingErrorKey: underlying])
        #expect(LibraryReadFailure.cause(of: write) == .other)
    }

    @Test func 복사하는_사이_바뀐_오류는_복사_중_바뀜이다() {
        #expect(LibraryReadFailure.cause(of: DJCError.sourceChangedDuringCopy(path: "/x/master.db")) == .changedWhileCopying)
    }

    @Test func 가를_수_없으면_그_밖이다() {
        #expect(LibraryReadFailure.cause(of: DJCError.databaseOpenFailed(path: "/x", message: "bad")) == .other)
        #expect(LibraryReadFailure.cause(of: DJCError.keyDerivationFailed) == .other)
        #expect(LibraryReadFailure.cause(of: CocoaError(.fileWriteOutOfSpace)) == .other)
    }

    @Test(arguments: [LibraryReadFailure.Stage.opening, .contents])
    func 사본을_읽는_단계의_오류는_원인을_가르지_않는다(_ stage: LibraryReadFailure.Stage) {
        // DJCrate가 만든 사본이 없거나 열리지 않는 것은 rekordbox 설치·권한 문제가 아니다
        for error in [CocoaError(.fileReadNoSuchFile), CocoaError(.fileReadNoPermission)] as [any Error] {
            #expect(LibraryReadFailure(stage: stage, keepsPreviousLibrary: false, error: error, home: "/Users/dj").cause == .other)
        }
        #expect(LibraryReadFailure(stage: .snapshotCreation, keepsPreviousLibrary: false, error: CocoaError(.fileReadNoSuchFile),
                                   home: "/Users/dj").cause == .libraryMissing)
    }

    // MARK: - 문구

    @Test func 이전_목록이_없을_때_원인별_문구는_할_일까지_한_문장으로_쓴다() {
        func message(_ cause: LibraryReadFailure.Cause) -> String {
            LibraryReadFailure(stage: .snapshotCreation, keepsPreviousLibrary: false, cause: cause).message
        }
        #expect(message(.libraryMissing) == "rekordbox 라이브러리를 찾지 못했습니다. rekordbox 7을 설치하고 한 번 실행한 뒤 다시 찾아 주세요")
        #expect(message(.permissionDenied)
            == "rekordbox 라이브러리를 읽을 권한이 없습니다. Finder에서 rekordbox 라이브러리 폴더의 읽기 권한을 확인하고, 그래도 안 되면 시스템 설정 › 개인정보 보호 및 보안 › 전체 디스크 접근 권한에서 DJCrate를 허용한 뒤 다시 시도하세요")
        #expect(message(.changedWhileCopying) == "rekordbox가 라이브러리를 쓰는 중입니다. 잠시 뒤 다시 읽습니다")
        #expect(message(.other) == "라이브러리를 읽지 못했습니다")
    }

    @Test(arguments: [LibraryReadFailure.Cause.libraryMissing, .permissionDenied, .other], [LibraryReadFailure.Stage.snapshotCreation, .opening, .contents])
    func 이전_목록이_있으면_이전_목록을_표시한다고_알린다(_ cause: LibraryReadFailure.Cause, _ stage: LibraryReadFailure.Stage) {
        let kept = LibraryReadFailure(stage: stage, keepsPreviousLibrary: true, cause: cause).message
        let none = LibraryReadFailure(stage: stage, keepsPreviousLibrary: false, cause: cause).message
        #expect(kept.contains("이전 목록"))
        #expect(!none.contains("이전 목록"))
        // 내부 용어(스냅샷·사본)를 화면 문구에 쓰지 않는다
        for text in [kept, none] { #expect(!text.contains("스냅샷") && !text.contains("사본")) }
    }

    @Test func 제목과_안내는_원인마다_다르고_그_밖에만_자세히_보기가_있다() {
        let causes: [LibraryReadFailure.Cause] = [.libraryMissing, .permissionDenied, .changedWhileCopying, .other]
        let titles = causes.map { LibraryReadFailure(stage: .contents, keepsPreviousLibrary: false, cause: $0).title }
        #expect(Set(titles).count == causes.count)
        #expect(LibraryReadFailure(stage: .contents, keepsPreviousLibrary: false, cause: .other).title == "라이브러리를 읽지 못했습니다")
        #expect(LibraryReadFailure(stage: .contents, keepsPreviousLibrary: false, cause: .other).offersDetail)
        #expect(!LibraryReadFailure(stage: .contents, keepsPreviousLibrary: false, cause: .libraryMissing).offersDetail)
    }

    @Test func 지원하지_않는_버전_안내는_앞_두_자리만_보인다() {
        #expect(UnsupportedRekordboxNotice.title(version: "7.3.1") == "이 rekordbox 버전(7.3)은 아직 지원하지 않습니다")
        #expect(UnsupportedRekordboxNotice.title(version: "6") == "이 rekordbox 버전(6)은 아직 지원하지 않습니다")
        #expect(UnsupportedRekordboxNotice.guidance == "읽기만 하고 rekordbox에 쓰기는 막혀 있습니다")
    }

    // MARK: - 자세히 보기

    @Test func 자세히_보기는_홈_폴더를_물결표로_줄이고_원문을_담는다() throws {
        let error = DJCError.databaseOpenFailed(path: "/Users/dj/Library/Application Support/DJCrate/snapshots/master.db", message: "file is not a database")
        let failure = LibraryReadFailure(stage: .opening, keepsPreviousLibrary: false, error: error, home: "/Users/dj")
        let detail = try #require(failure.detail)
        #expect(detail.contains("~/Library/Application Support/DJCrate/snapshots/master.db"))
        #expect(detail.contains("file is not a database"))
        #expect(!detail.contains("/Users/dj"))
    }

    @Test func 홈_폴더_이름이_다른_경로_앞부분과_겹쳐도_통째로_바꾸지_않는다() {
        #expect(LibraryReadFailure.redactingHome("/Users/dj2/x and /Users/dj/y", home: "/Users/dj") == "/Users/dj2/x and ~/y")
        #expect(LibraryReadFailure.redactingHome("그대로", home: "") == "그대로")
    }

    @Test func 원인과_단계가_같으면_원문이_달라도_같은_실패다() {
        let a = LibraryReadFailure(stage: .opening, keepsPreviousLibrary: false, cause: .other, detail: "a")
        let b = LibraryReadFailure(stage: .opening, keepsPreviousLibrary: false, cause: .other, detail: "b")
        #expect(a == b)
        #expect(a != LibraryReadFailure(stage: .opening, keepsPreviousLibrary: true, cause: .other))
    }
}
