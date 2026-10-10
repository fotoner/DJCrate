import DJCDomain
import DJCEnvironment
import Foundation
import RekordboxKit

/// 사용자가 고른 폴더를 훑어 파일 없는 곡의 새 위치 후보를 맞춘다(#62). 폴더·음원·라이브러리는 읽기만 한다.
///
/// - 심볼릭 링크는 따라가지 않는다(파일도 폴더도 건너뜀). 숨은 파일·`._*`·USB의 `PIONEER` 폴더(대소문자 무시)·`djprofile.nxs`·rekordbox/DJCrate 데이터 폴더도 건너뛰고,
///   고른 폴더 자신이 `PIONEER`이거나 그 안이면 거부한다.
/// - 훑는 일은 호출한 쪽 액터(메인 스레드 등) 밖에서 하고, 폴더·파일마다 취소를 본다. 폴더 열거는 협력 풀 밖(`OffPoolIO`)에서 한다.
/// - 태그·길이는 이름이나 크기가 어느 곡과 맞는 파일만 읽는다(`RelocateTargetIndex`).
public enum RelocateScanner {
    public typealias Progress = RelocateProgress
    public typealias Summary = RelocateSummary
    public typealias Output = RelocateOutput

    /// 음원 파일에서 읽은 값. 읽지 못한 칸은 nil.
    public struct Tags: Sendable, Equatable {
        public var title: String?
        public var artist: String?
        public var duration: Double?

        public init(title: String? = nil, artist: String? = nil, duration: Double? = nil) {
            self.title = title; self.artist = artist; self.duration = duration
        }
    }

    public typealias TagReader = @Sendable (URL) async -> Tags

    public typealias ScanError = RelocateScanError

    /// 후보 폴더로 쓰지 않고 훑을 때도 들어가지 않는 폴더: rekordbox 라이브러리와 DJCrate 데이터(실제 위치와 `DJC_REKORDBOX_DIR`·`DJC_HOME`이 가리키는 곳).
    public static var protectedRoots: [String] {
        let real = LibrarySnapshot.realRekordboxDirectory
        let urls = [real.deletingLastPathComponent(), real, LibrarySnapshot.rekordboxDirectory,
                    DJCIdentity.userSupportDirectory, DJCIdentity.supportDirectory, DJCIdentity.dataDirectory]
        var seen = Set<String>()
        return urls.flatMap { [$0.path, $0.resolvingSymlinksInPath().path] }.filter { seen.insert($0).inserted }
    }

    /// 파일 태그에서 제목·아티스트·길이를 읽는다(아트워크는 읽지 않는다). 읽지 못하면 빈 값.
    public static let defaultTagReader: TagReader = { url in
        guard let tags = try? await AudioTags.read(url: url, includeArtwork: false) else { return Tags() }
        return Tags(title: tags.title, artist: tags.artist, duration: tags.duration > 0 ? tags.duration : nil)
    }

    /// 파일 없는 곡의 후보 맞추기에 쓸 곡 목록. 곡 행의 파일 크기는 스냅샷 사본에서 읽는다.
    public static func targets(for tracks: [Track], snapshot: URL) throws -> [RelocateTarget] {
        let sizes = try TrackFileSizes.load(snapshot: snapshot, trackIDs: Set(tracks.map(\.id)))
        return tracks.filter { !$0.isStreaming }.map { RelocateTarget(track: $0, fileSize: sizes[$0.id]) }
    }

    /// `folder` 아래를 훑어 `targets`의 후보를 맞춘다. 취소하면 `CancellationError`.
    @concurrent
    public static func scan(targets: [RelocateTarget], folder: URL, protectedRoots: [String] = RelocateScanner.protectedRoots,
                            readTags: @escaping TagReader = RelocateScanner.defaultTagReader, readWidth: Int = 4,
                            progress: @escaping @Sendable (Progress) -> Void = { _ in }) async throws -> Output {
        // 링크는 풀어서 본다(보호 폴더를 가리키는 링크로 보호를 피하지 못하게). 보호 폴더인지를 먼저 보고 폴더가 맞는지 본다.
        let root = folder.resolvingSymlinksInPath().standardizedFileURL
        guard !RelocateScanPolicy.isProtected(root.path, protectedRoots: protectedRoots) else { throw ScanError.protectedFolder }
        // USB의 PIONEER 안(`extracted`·`CDP` 포함)은 열거하지 않는다: 하위 이름 검사는 고른 폴더 자신에 걸리지 않으므로 경로 전체로 본다.
        guard !RelocateScanPolicy.isInsideUsbLibraryFolder(root.path),
              !RelocateScanPolicy.isInsideUsbLibraryFolder(folder.standardizedFileURL.path) else { throw ScanError.usbLibraryFolder }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ScanError.notAFolder
        }

        // 폴더 열거는 잠든 외장 볼륨에서 오래 막을 수 있어 협력 풀 밖에서 한다. 작업 취소는 폴더마다 신호로 본다(#247).
        let listed = try await OffPoolIO.run { cancellation in
            try listAudioFiles(in: root, protectedRoots: protectedRoots, cancellation: cancellation) { count in
                progress(Progress(phase: .listing, audioFiles: count, filesToRead: 0, filesRead: 0))
            }
        }
        try Task.checkCancellation()

        // 이름·줄기·크기가 어느 곡과도 안 맞는 파일은 태그를 읽지 않는다.
        let index = RelocateTargetIndex(targets: targets)
        let toRead = listed.filter { index.mayMatch(fileName: $0.url.lastPathComponent, size: $0.size) }
        progress(Progress(phase: .reading, audioFiles: listed.count, filesToRead: toRead.count, filesRead: 0))

        var files: [RelocateFile] = []
        files.reserveCapacity(toRead.count)
        try await withThrowingTaskGroup(of: RelocateFile.self) { group in
            let width = max(1, readWidth)
            var next = 0
            func launch(_ group: inout ThrowingTaskGroup<RelocateFile, Error>) {
                guard next < toRead.count else { return }
                let item = toRead[next]
                next += 1
                group.addTask {
                    let tags = await readTags(item.url)
                    return RelocateFile(path: item.url.path, size: item.size, durationSeconds: tags.duration,
                                        title: tags.title, artist: tags.artist)
                }
            }
            for _ in 0..<width { launch(&group) }
            while let file = try await group.next() {
                try Task.checkCancellation()
                files.append(file)
                // 파일마다 알리면 화면이 알림에 묻힌다: 여덟 개마다와 끝에서만.
                if files.count % 8 == 0 || files.count == toRead.count {
                    progress(Progress(phase: .reading, audioFiles: listed.count, filesToRead: toRead.count, filesRead: files.count))
                }
                launch(&group)
            }
        }
        try Task.checkCancellation()

        progress(Progress(phase: .matching, audioFiles: listed.count, filesToRead: toRead.count, filesRead: files.count))
        let report = RelocateMatcher.match(targets: targets, files: files)
        return Output(report: report, summary: Summary(audioFiles: listed.count, comparedFiles: files.count))
    }

    /// 폴더 아래 음원 파일(경로·크기). 취소를 폴더마다 본다. 읽을 수 없는 폴더는 건너뛴다.
    public static func listAudioFiles(in root: URL, protectedRoots: [String], cancellation: CancellationCheck = CancellationCheck(),
                                      onCount: (Int) -> Void) throws -> [(url: URL, size: Int64)] {
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .isPackageKey, .fileSizeKey]
        let keySet = Set(keys)
        let fm = FileManager.default
        var found: [(url: URL, size: Int64)] = []
        var pending = [root]
        while let directory = pending.popLast() {
            try cancellation.check()
            guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            else { continue }
            for entry in entries {
                let name = entry.lastPathComponent
                // `djprofile.nxs` 같은 열지 않는 파일은 속성도 읽지 않는다.
                guard !RelocateScanPolicy.skipsFile(named: name), let values = try? entry.resourceValues(forKeys: keySet) else { continue }
                // 링크는 파일이든 폴더든 따라가지 않는다(보호 폴더나 다른 디스크로 새는 길을 막는다).
                if values.isSymbolicLink == true { continue }
                if values.isDirectory == true {
                    guard values.isPackage != true, !RelocateScanPolicy.skipsDirectory(named: name),
                          !RelocateScanPolicy.isProtected(entry.path, protectedRoots: protectedRoots) else { continue }
                    pending.append(entry)
                } else if values.isRegularFile == true, RelocateScanPolicy.isAudio(fileName: name) {
                    found.append((entry, Int64(values.fileSize ?? 0)))
                    if found.count % 200 == 0 { onCount(found.count) }
                }
            }
        }
        onCount(found.count)
        return found
    }
}
