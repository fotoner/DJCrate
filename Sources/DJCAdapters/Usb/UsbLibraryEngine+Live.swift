import DJCApplication
import DJCDomain
import Foundation
import RekordboxKit

extension UsbLibraryEngine {
    /// RekordboxKit/Usb를 감싼 실제 엔진. USB에 쓰는 일은 `Writer.live`(`UsbLibraryEngine+Writer.swift`) 한 곳만 한다.
    /// - fileSystem: USB 파일 연산. 앱·CLI는 `PosixUsbFileSystem()`, 자가 테스트·시험은 기록하거나 마운트를 흉내 내는 것을 넘긴다
    public static func live(fileSystem: any UsbFileSystem) -> UsbLibraryEngine {
        UsbLibraryEngine(
            openLocal: { UsbLocalCopyDatabase(try CipherDatabase.diagnostic(path: $0.path, key: RekordboxKey.derive())) },
            read: Read(
                rekordboxFileNames: { try UsbReadFiles.rekordboxFileNames(UsbRoot($0)) },
                exists: { UsbReadFiles.exists(UsbRoot($0), $1) },
                isRegularFile: { UsbReadFiles.isRegularFile(UsbRoot($0), $1) },
                copyDatabases: { UsbDatabaseCopy(try UsbSnapshot.take(root: UsbRoot($0), into: $1)) },
                copyPdb: { try UsbReadFiles.copyPdb(UsbRoot($0), into: $1).map { (export: $0.0, ext: $0.1) } },
                oneLibrary: { try OneLibraryReader.read(copyAt: $0) },
                deviceLibrary: { export, ext in
                    let (library, report) = try PdbReader.read(export: Data(contentsOf: export), exportExt: ext.map { try Data(contentsOf: $0) })
                    return UsbDeviceLibraryRead(library: library, report: report)
                },
                roundTrip: { export, ext in
                    try PdbRoundTrip.check(export: Data(contentsOf: export), exportExt: ext.map { try Data(contentsOf: $0) })
                },
                analysisTrackPath: { UsbReadFiles.analysisTrackPath(UsbRoot($0), datRelative: $1) },
                settings: { UsbReadFiles.settings(UsbRoot($0)) }),
            export: Export(
                hasLibrary: { try hasLibrary(UsbRoot($0), fileSystem: fileSystem) },
                leftoverBlock: { UsbEmptyVolumeInspector.pioneerNames(UsbRoot($0)) > 0 ? UsbEmptyVolumeInspector.leftoverBlock : nil },
                existingContents: { try UsbExportAssembly.existingContents(root: UsbRoot($0)) },
                layoutTree: { try UsbExportCandidates.playlistTree(layout: $0, rootIDs: $1) },
                playlistTree: { try UsbExportCandidates.playlistTree(database: database($0), rootIDs: $1) },
                candidates: { try UsbExportCandidates.load(database: database($0), share: $1, contentIDs: $2) },
                sameContent: { UsbExportCandidates.sameContent(sourcePath: $0, usbFile: $1) },
                build: { request, local, share, createdDate in
                    let build = try UsbExportAssembly.planAndBuild(request, local: UsbLocalSource(database: database(local)), share: share,
                                                                   myTagMasterDBID: UsbLibraryBuilder.randomMyTagMasterDBID(), createdDate: createdDate)
                    return UsbExportBuilt(plan: build.plan, blocks: build.blocks, model: build.model)
                },
                assemble: { input in
                    try UsbExportAssembly.assembled(
                        model: engineValue(input.built.model, as: UsbExportModel.self), plan: input.built.plan, localDatabase: database(input.local),
                        share: input.share, staging: input.staging, formats: input.formats, session: input.session,
                        settingsFolder: input.settingsFolder, syncSelection: input.syncSelection, progress: input.progress,
                        isCancelled: input.isCancelled)
                }),
            edit: Edit(
                load: { root, into in
                    let source = try UsbEditEngine.load(root: UsbRoot(root), into: into)
                    return UsbEditSourceRead(blocks: source.blocks, source: source)
                },
                plan: { input in
                    try UsbEditEngine.plan(
                        source: engineValue(input.source.source, as: UsbEditSource.self), edits: input.edits,
                        localDatabase: try input.local.map(database), share: input.share, volume: input.volume,
                        existingFiles: UsbRoot(input.root), fileSystem: fileSystem, staging: input.staging, session: input.session,
                        highWater: input.highWater, snapshotTakenAt: input.snapshotTakenAt, localAppVersion: input.appVersion,
                        progress: input.progress, isCancelled: input.isCancelled)
                }),
            migration: Migration(
                oneLibraryExistsBlock: UsbMigration.Blocks.oneLibraryExists,
                plan: { root, copyInto, staging, session in
                    let snapshot = try UsbSnapshot.take(root: UsbRoot(root), into: copyInto)
                    return try UsbMigration.plan(snapshot: snapshot, root: UsbRoot(root), fileSystem: fileSystem, staging: staging, session: session)
                }),
            cueGrid: CueGrid(
                localKeys: { try UsbCueGridReader.localKeys(snapshot: $0) },
                deviceCueContentIDs: { try UsbCueGridReader.deviceCueContentIDs(oneLibraryCopy: $0) },
                readTrack: { try UsbCueGridReader.read(root: UsbRoot($0), track: $1) },
                analysisURL: { RekordboxShare.analysisURL($0, root: $1) },
                localGrid: { try BeatGrid.load(anlz: $0) },
                databasesUnchanged: { try UsbCueGridReader.databasesUnchanged(since: $0, root: UsbRoot($1)) },
                newCueID: { UUID() }),
            writer: .live(fileSystem: fileSystem),
            syncGate: .live,
            syncSelectionFiles: { try UsbSyncSelectionBundle.read(root: UsbRoot($0), formats: $1).baseFiles })
    }

    /// `PIONEER/rekordbox/`(철자 무관) 바로 아래에 DB 파일 이름이 하나라도 있는지. 이름만 본다
    static func hasLibrary(_ usb: UsbRoot, fileSystem: any UsbFileSystem) throws -> Bool {
        func child(_ url: URL, _ name: String) throws -> URL? {
            guard let info = try fileSystem.stat(url), info.kind == .directory else { return nil }
            return try fileSystem.list(url).first { UsbLayout.collisionKey($0) == UsbLayout.collisionKey(name) }.map { url.appending(path: $0) }
        }
        guard let pioneer = try child(usb.url, "PIONEER"), let folder = try child(pioneer, "rekordbox"),
              let info = try fileSystem.stat(folder), info.kind == .directory else { return false }
        let databases = Set([UsbLayout.oneLibrary, UsbLayout.exportPdb, UsbLayout.exportExtPdb]
            .map { UsbLayout.collisionKey(($0 as NSString).lastPathComponent) })
        return try fileSystem.list(folder).contains { databases.contains(UsbLayout.collisionKey($0)) }
    }

    /// 세션이 돌려준 엔진 값(이 엔진이 만든 것만 받는다)
    static func engineValue<T>(_ value: any Sendable, as type: T.Type) throws -> T {
        guard let value = value as? T else { throw UsbError.readFailed(detail: "engine value \(T.self)") }
        return value
    }

    static func database(_ local: any UsbOpenedLibrary) throws -> CipherDatabase {
        guard let local = local as? UsbLocalCopyDatabase else { throw UsbError.readFailed(detail: "engine value CipherDatabase") }
        return local.database
    }
}

/// 엔진이 연 세션 사본 연결
final class UsbLocalCopyDatabase: UsbOpenedLibrary {
    let database: CipherDatabase

    init(_ database: CipherDatabase) { self.database = database }

    func close() { database.close() }
}

extension UsbDatabaseCopy {
    init(_ snapshot: UsbSnapshot) {
        self.init(oneLibrary: snapshot.oneLibrary, exportPdb: snapshot.exportPdb, exportExtPdb: snapshot.exportExtPdb,
                  fingerprint: snapshot.fingerprint, rollbackHeader: snapshot.flags.headerMode == .rollback,
                  walPresent: snapshot.flags.walPresent, journalPresent: snapshot.flags.journalPresent)
    }
}

extension UsbSyncSelectionGate {
    /// 확인한 계약(`UsbSyncXMLWriteContract.production`)을 보는 실제 규칙(`UsbSyncSelectionStage`)
    public static let live = UsbSyncSelectionGate(gateBlock: { UsbSyncSelectionStage.gateBlock(baseFiles: $0, formats: $1) },
                                                  productionBlock: { UsbSyncSelectionStage.productionBlock },
                                                  draftBlock: { UsbSyncSelectionStage.draftBlock($0) })
}
