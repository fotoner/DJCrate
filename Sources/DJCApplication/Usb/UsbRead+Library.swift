import DJCDomain
import Foundation

extension UsbRead {
    /// 앱 사이드바: 사본을 떠서(`UsbSnapshot`) 두 형식을 읽고 합친다. USB에는 아무것도 쓰지 않는다.
    /// 볼륨 정보 없이 Mac 밖 볼륨을 넘기면 `info`처럼 읽지 않고, 그때는 사본 폴더도 만들지 않는다.
    /// 사본은 `snapshots/<볼륨키>/<시각>/`에 새로 떠서 남기고, 그 볼륨의 사본 폴더는 최근 `keep`개만 둔다.
    public func library(root: URL, snapshots: URL, volumeKey: String, volume: UsbVolumeInfo?,
                        now: Date, keep: Int = 5) throws -> (library: UsbLibrary, mismatches: [UsbFormatMismatch]) {
        // 볼륨키는 사본 폴더 이름 한 성분이다
        guard !volumeKey.isEmpty, volumeKey != ".", volumeKey != "..", !volumeKey.contains("/") else {
            throw UsbError.readFailed(detail: "bad volume key")
        }
        if volume == nil {
            guard let real = device.realPath(root.path), let mount = device.mountedOn(real), Self.startupMounts.contains(mount) else {
                throw UsbError.readFailed(detail: "volumeNotChecked")
            }
        }
        let names = try engine.read.rekordboxFileNames(root)
        let hasOneLibrary = names.contains((UsbLayout.oneLibrary as NSString).lastPathComponent)
        let hasPdb = names.contains((UsbLayout.exportPdb as NSString).lastPathComponent)
        guard hasOneLibrary || hasPdb else { throw UsbError.readFailed(detail: "noLibrary") }

        let base = snapshots.appending(path: volumeKey)
        let folder = snapshotFolder(in: base, now: now)
        var oneLibrary: UsbLibrary?, deviceLibrary: UsbLibrary?
        do {
            do {
                let snapshot = try engine.read.copyDatabases(root, folder)
                if let copy = snapshot.oneLibrary { oneLibrary = try readOneLibrary(copy) }
                deviceLibrary = try Self.readDeviceLibrary { try snapshot.exportPdb.map { try engine.read.deviceLibrary($0, snapshot.exportExtPdb).library } }
            } catch let error as UsbError where hasOneLibrary && Self.isOneLibraryFailure(error) {
                // OneLibrary 사본이 온전하지 않다(무결성·암호). Device Library만 따로 떠서 읽는다
                if let (export, ext) = try engine.read.copyPdb(root, folder.appending(path: "pdb")) {
                    deviceLibrary = try Self.readDeviceLibrary { try engine.read.deviceLibrary(export, ext).library }
                }
            }
            guard oneLibrary != nil || deviceLibrary != nil else { throw UsbError.readFailed(detail: "noReadableLibrary") }
        } catch {
            // 읽지 못한 사본은 남기지 않는다(이 호출이 만든 폴더만)
            device.remove(folder)
            throw error
        }
        pruneSnapshots(in: base, keep: keep)
        return UsbLibrary.merge(oneLibrary: oneLibrary, deviceLibrary: deviceLibrary)
    }

    /// 읽기 직전에 목록의 볼륨 자리(`mountPoint`)를 다시 보고 지금 그 자리의 볼륨 정보를 돌려준다.
    /// 목록을 훑은 뒤 볼륨이 빠지고 다른 볼륨이 같은 자리에 붙었으면(UUID·디스크 이미지 여부·이미지 파일·자리가 다름)
    /// `volumeChanged`를 던진다 — 옛 정보(디스크 이미지·다른 UUID)로 판정을 지나가지 않게.
    public func currentVolume(matching volume: UsbVolumeInfo) throws -> UsbVolumeInfo {
        guard let now = try self.volume(for: URL(filePath: volume.mountPoint)),
              now.mountPoint == volume.mountPoint,
              now.volumeUUID?.uppercased() == volume.volumeUUID?.uppercased(),
              now.isDiskImage == volume.isDiskImage,
              now.diskImagePath == volume.diskImagePath
        else { throw UsbError.readFailed(detail: "volumeChanged") }
        return now
    }

    /// 모르는 모양의 OneLibrary는 건너뛰고 Device Library만 쓴다(`info`의 경고와 같은 판정)
    func readOneLibrary(_ copy: URL) throws -> UsbLibrary? {
        do {
            return try engine.read.oneLibrary(copy)
        } catch let error as UsbError {
            guard case .formatUnsupported = error else { throw error }
            return nil
        }
    }

    /// 머리가 달라 읽지 못한 Device Library는 건너뛴다(`info`는 경고로 알린다)
    static func readDeviceLibrary(_ read: () throws -> UsbLibrary?) throws -> UsbLibrary? {
        do {
            return try read()
        } catch let error as UsbError {
            guard case .readFailed = error else { throw error }
            return nil
        }
    }

    /// `<시각>`(UTC, 초까지) 폴더. 같은 이름이 있으면 `-2`, `-3`…
    func snapshotFolder(in base: URL, now: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        let name = formatter.string(from: now)
        var candidate = base.appending(path: name)
        var index = 2
        while device.exists(candidate) {
            candidate = base.appending(path: "\(name)-\(index)")
            index += 1
        }
        return candidate
    }

    /// 이 볼륨의 사본 폴더 중 이름(시각) 순으로 최근 `keep`개만 남긴다. 시각 모양이 아닌 항목은 건드리지 않는다
    func pruneSnapshots(in base: URL, keep: Int) {
        let names = (device.names(base) ?? [])
            .filter { $0.range(of: #"^[0-9]{8}T[0-9]{6}(-[0-9]+)?$"#, options: .regularExpression) != nil }
            .sorted { lhs, rhs in
                // "-10"이 "-9"보다 앞서지 않게 번호는 수로 비교한다
                let (a, b) = (lhs.split(separator: "-"), rhs.split(separator: "-"))
                if a[0] != b[0] { return a[0] < b[0] }
                return (a.count > 1 ? Int(a[1]) ?? 0 : 1) < (b.count > 1 ? Int(b[1]) ?? 0 : 1)
            }
        for name in names.dropLast(max(keep, 0)) { device.remove(base.appending(path: name)) }
    }
}
