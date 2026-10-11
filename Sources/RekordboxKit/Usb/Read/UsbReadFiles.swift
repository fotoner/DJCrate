import DJCDomain
import Darwin
import Foundation

/// USB 읽기 점검(`UsbRead`, DJCApplication)이 USB 위에서 하는 파일 일: 이름 나열·lstat·분석 파일 PPTH·기기 설정 파일·pdb 사본.
/// USB에는 아무것도 쓰지 않고 열지 않는 경로(`UsbLayout.neverRead`)는 열지 않는다. 유스케이스는 포트(`UsbLibraryEngine.Read`)로 부른다(#167)
public enum UsbReadFiles {
    /// PIONEER/rekordbox 바로 아래 일반 파일 이름(없으면 빈 집합). 다른 폴더는 열지 않는다
    public static func rekordboxFileNames(_ usb: UsbRoot) throws -> Set<String> {
        guard exists(usb, UsbLayout.rekordboxDir) else { return [] }
        let depth = UsbLayout.rekordboxDir.split(separator: "/").count + 1
        return Set(try UsbTree.walk(usb, under: UsbLayout.rekordboxDir)
            .filter { !$0.isDirectory && !$0.isSymlink && $0.relativePath.split(separator: "/").count == depth }
            .compactMap { $0.relativePath.split(separator: "/").last.map(String.init) })
    }

    /// lstat으로 있는지(링크도 있음으로 본다). 열지 않는 경로는 없음
    public static func exists(_ usb: UsbRoot, _ relative: String) -> Bool {
        guard let url = try? usb.url(for: relative) else { return false }
        var info = Darwin.stat()
        return lstat(url.path, &info) == 0
    }

    /// 링크가 아닌 일반 파일. 열지 않는 경로·링크를 거쳐 가는 경로는 없음으로 센다
    public static func isRegularFile(_ usb: UsbRoot, _ relative: String) -> Bool {
        guard let url = try? usb.url(for: relative) else { return false }
        var info = Darwin.stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
    }

    /// OneLibrary 사본이 온전하지 않을 때 pdb 둘만 사본으로 뜬다(복사 전후 크기·시각이 같아야 한다)
    public static func copyPdb(_ usb: UsbRoot, into directory: URL, fileSystem: SnapshotFileAccess = .posix) throws -> (URL, URL?)? {
        try UsbSnapshotFolders.createPrivate(directory)
        var copies: [String: URL] = [:]
        for relative in [UsbLayout.exportPdb, UsbLayout.exportExtPdb] {
            let source = try usb.url(for: relative)
            guard let before = try fileSystem.stat(source) else { continue }
            guard before.isRegularFile else { throw UsbError.readFailed(detail: "not a regular file: \(relative)") }
            let target = directory.appending(path: source.lastPathComponent)
            try fileSystem.copyData(source, target)
            guard let after = try fileSystem.stat(source), after.size == before.size, after.modificationDate == before.modificationDate else {
                throw DJCError.sourceChangedDuringCopy(path: source.path)
            }
            copies[relative] = target
        }
        return copies[UsbLayout.exportPdb].map { ($0, copies[UsbLayout.exportExtPdb]) }
    }

    /// 분석 파일(.DAT)의 PPTH에 적힌 곡 경로. 열지 못하거나 PPTH가 없으면 nil
    public static func analysisTrackPath(_ usb: UsbRoot, datRelative: String) -> String? {
        (try? usb.url(for: datRelative)).flatMap { try? AnlzFile(data: Data(contentsOf: $0)) }?.tag("PPTH")
            .flatMap { try? AnlzPathTag.decode($0.bytes) }
    }

    /// 기기 설정 파일 셋. 고정 이름만 연다. 파일 크기가 확인한 소형 파일과 다르면 내용을 읽지 않는다
    public static func settings(_ usb: UsbRoot) -> [UsbInfo.Setting] {
        DeviceSettingFile.Kind.allCases.map { setting(usb, kind: $0) }
    }

    private static func setting(_ usb: UsbRoot, kind: DeviceSettingFile.Kind) -> UsbInfo.Setting {
        func result(_ status: UsbInfo.Setting.Status, _ issue: String? = nil, crcOK: Bool? = nil) -> UsbInfo.Setting {
            UsbInfo.Setting(fileName: kind.fileName, status: status, issue: issue, crcOK: crcOK)
        }
        guard let url = try? usb.url(for: "PIONEER/" + kind.fileName) else { return result(.unreadable, "unsafePath") }
        // 링크로 바뀌어도 따라가지 않으며 FIFO로 바뀌어도 열기에서 멈추지 않는다
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return errno == ENOENT ? result(.missing) : result(.unreadable, "readFailed") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = Darwin.stat()
        guard fstat(descriptor, &info) == 0 else { return result(.unreadable, "readFailed") }
        guard info.st_mode & S_IFMT == S_IFREG else { return result(.unreadable, "notRegularFile") }
        guard info.st_size == kind.size else { return result(.invalid, "wrongSize") }
        let bytes: Data
        do {
            // 검사 뒤 커져도 읽는 양을 제한하고, 크기 변경은 파서가 거부한다
            bytes = try handle.read(upToCount: kind.size + 1) ?? Data()
        } catch {
            return result(.unreadable, "readFailed")
        }
        let pair = bytes.count == kind.size ? DeviceSettingFile.crcPair(kind: kind, bytes: bytes) : nil
        let crcOK = pair.map { $0.stored == $0.computed }
        do {
            _ = try DeviceSettingFile(kind: kind, bytes: bytes)
            return result(.valid, crcOK: crcOK)
        } catch let error as DeviceSettingError {
            let issue: String
            switch error {
            case .wrongSize: issue = "wrongSize"
            case .wrongStringsLength: issue = "wrongStringsLength"
            case .wrongDataLength: issue = "wrongDataLength"
            case .crcMismatch: issue = "crcMismatch"
            case .trailerNotZero: issue = "trailerNotZero"
            default: issue = "readFailed"
            }
            return result(.invalid, issue, crcOK: crcOK)
        } catch {
            return result(.unreadable, "readFailed")
        }
    }
}
