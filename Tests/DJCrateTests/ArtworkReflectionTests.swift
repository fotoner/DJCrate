@testable import DJCrate
import DJCApplication
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing
import UniformTypeIdentifiers

/// 곡 그림 초안(#66)의 앱 흐름: 그림을 고르면 초안·쓰기 대기, 미리 보기·확인 창 줄, 쓰기 뒤 초안 정리·썸네일 열쇠, 되돌리면 초안과 옛 그림이 돌아온다.
@MainActor
@Suite("그림 반영", .serialized)
struct ArtworkReflectionTests {
    /// 크기를 판정하지 않으므로 같은 비율의 작은 그림을 쓴다(디버그 JPEG 인코딩 비용, 크기 골든은 RekordboxKit이 본다).
    let image = ImageFixture.image(width: 64, height: 48)

    @Test func 사용자에게_보이는_아트워크_문구는_앨범아트다() {
        #expect(ArtworkWriteKind.add.label == "앨범아트 넣기")
        #expect(ArtworkWriteKind.replace.label == "앨범아트 바꾸기")
        #expect(ArtworkWriteKind.delete.label == "앨범아트 지우기")
        #expect(WritePart.artwork.summary(2) == "앨범아트 2곡")
        #expect(WritePart.artwork.written == "앨범아트 쓰기 완료")
        #expect(ReflectionSession.artworkRestoreFailureText(2).contains("앨범아트 초안 2곡"))
    }

    func makeStore(_ fixture: RekordboxFixture) async -> LibraryStore {
        let store = LibraryStore.test(settings: SettingsStore(defaults: TestDefaults.make("artwork"), persist: false),
                                 resultHistory: WriteResultHistory(url: nil), feedback: AppFeedback(announce: { _ in }),
                                 saveTagDrafts: { _ in }, backupDirectory: fixture.backups,
                                 playlistDraftSaver: { _ in }, mergeDraftSaver: { _ in }, playlistImportURL: nil, stagingSaver: { _ in },
                                 draftHome: fixture.root.appending(path: "drafts"), rekordboxDatabase: fixture.database,
                                 rekordboxShareRoot: fixture.shareRoot, arguments: ["test"], environment: [:],
                                 takeLiveSnapshot: { [database = fixture.database] _ in database })
        await store.load(snapshot: fixture.database)
        return store
    }

    /// 분석한 곡 하나(그림 없음)
    func library() throws -> (RekordboxFixture, TrackSpec) {
        let fixture = try RekordboxFixture()
        var spec = TrackSpec()
        spec.analysisDataPath = "/PIONEER/USBANLZ/\(spec.uuid.prefix(3))/\(spec.uuid.dropFirst(3))/ANLZ0000.DAT"
        spec.imagePath = ""
        try fixture.add(spec)
        return (fixture, spec)
    }

    func folder(_ fixture: RekordboxFixture, _ spec: TrackSpec) -> URL {
        fixture.shareRoot.appending(path: "PIONEER/Artwork/\(spec.uuid.prefix(3))/\(spec.uuid.dropFirst(3))")
    }

    // MARK: - 그림 칸(#244: 뷰의 .task에서 옮긴 읽기)

    @Test func 그림_칸은_초안과_rekordbox_그림을_읽고_취소된_읽기는_그림을_바꾸지_않는다() async throws {
        let (fixture, spec) = try library()
        let store = await makeStore(fixture)
        let row = try #require(store.rowsByUUID[spec.uuid])
        // 인스펙터 그림 칸: 초안이 있으면 초안 그림, 없으면 rekordbox 그림(이 곡은 없음)
        let well = ArtworkInspectorModel(store: store)
        well.setArtwork(image, name: "표지.jpg", rows: [row])
        await well.loadImage(row)
        #expect(well.image != nil)
        well.discardDrafts(rows: [row])
        let cancelled = Task { await well.loadImage(row) }
        cancelled.cancel()
        await cancelled.value
        #expect(well.image != nil, "취소된 읽기는 그림을 바꾸지 않는다")
        await well.loadImage(row)
        #expect(well.image == nil)

        // 중복 후보 줄의 썸네일: rekordbox 그림(작은 그림)
        let path = "/PIONEER/Artwork/00001/a.jpg"
        let small = try #require(RekordboxShare.artworkURL(path, size: .small, root: fixture.shareRoot))
        try FileManager.default.createDirectory(at: small.deletingLastPathComponent(), withIntermediateDirectories: true)
        try image.write(to: small)
        let thumbnail = ArtworkThumbnailLoader()
        await thumbnail.load(path, root: fixture.shareRoot, key: "a", from: store.thumbnails)
        #expect(thumbnail.box != nil)
        let skipped = Task { await thumbnail.load(nil, root: fixture.shareRoot, key: "b", from: store.thumbnails) }
        skipped.cancel()
        await skipped.value
        #expect(thumbnail.box != nil, "스크롤로 지나쳐 취소된 줄은 그림을 바꾸지 않는다")
        await thumbnail.load(nil, root: fixture.shareRoot, key: "b", from: store.thumbnails)
        #expect(thumbnail.box == nil)
    }

    @Test func 그림을_고르면_사본과_초안을_두고_쓰기_대기가_된다() async throws {
        let (fixture, spec) = try library()
        let store = await makeStore(fixture)
        let row = try #require(store.rowsByUUID[spec.uuid])
        #expect(store.writeTargets([row]).isEmpty && !store.artworkBase(for: row).hasArtwork)
        let artwork = ArtworkInspectorModel(store: store)
        artwork.setArtwork(image, name: "표지.jpg", rows: [row])
        let draft = try #require(store.artworkDrafts[spec.uuid])
        #expect(draft.kind == .add && draft.imageName == "표지.jpg" && draft.base == ArtworkBase(imagePath: ""))
        #expect(store.pendingUUIDs.contains(spec.uuid) && store.editedUUIDs.contains(spec.uuid))
        #expect(store.writeTargets([row]).map(\.track.uuid) == [spec.uuid])
        #expect(artwork.draftImage(trackUUID: spec.uuid) == image, "원본을 옮겨도 사본이 남는다")
        // 그림이 없는 곡의 지우기는 남은 초안만 버린다
        artwork.deleteArtwork(rows: [row])
        #expect(store.artworkDrafts.isEmpty && !store.pendingUUIDs.contains(spec.uuid))
        #expect(ArtworkDraftStore.uuids(directory: store.artworkDirectory).isEmpty)
    }

    @Test func 확인하지_않은_그림은_초안을_만들지_않고_이유를_알린다() async throws {
        let (fixture, spec) = try library()
        let store = await makeStore(fixture)
        let row = try #require(store.rowsByUUID[spec.uuid])
        let artwork = ArtworkInspectorModel(store: store)
        artwork.setArtwork(ImageFixture.image(width: 40, height: 40, type: .gif), name: "움짤.gif", rows: [row])
        #expect(store.artworkDrafts.isEmpty && artwork.message?.text.contains("JPEG") == true)
        artwork.setArtwork(fileAt: fixture.root.appending(path: "없는 그림.jpg"), rows: [row])
        #expect(store.artworkDrafts.isEmpty && artwork.message?.text.contains("다시 고르세요") == true)
    }

    @Test(.enabled(if: LiveDraftHome.isIsolated))
    func 넣기와_지우기를_쓰고_되돌리면_초안과_옛_그림이_돌아온다() async throws {
        let (fixture, spec) = try library()
        let store = await makeStore(fixture)
        var row = try #require(store.rowsByUUID[spec.uuid])
        let artwork = ArtworkInspectorModel(store: store)
        artwork.setArtwork(image, name: "표지.jpg", rows: [row])

        // 미리 보기: 넣기만 있고 막힘이 없으니 묻지 않고 쓴다(#210)
        let preview = try await store.session.previewWrite(rows: [row], playlists: false)
        #expect(preview.report.artworkWritten.map(\.artwork) == [.add] && preview.batch.artworks.map(\.trackUUID) == [spec.uuid])
        #expect(WriteConfirmPolicy.reasons(preview.report, exclusions: preview.exclusions, canBackUp: store.session.ports.backups.canWrite(store.backupDirectory)).isEmpty)
        #expect(ReflectionPrompts.confirmation(preview.report).title.contains(WritePart.artwork.summary(1)))
        #expect(!FileManager.default.fileExists(atPath: folder(fixture, spec).path), "미리 보기는 사본에만")

        let before = ArtworkRevisions.key(spec.id)
        let added = try await store.session.writeToRekordbox([], artworks: preview.batch.artworks)
        #expect(added.artworkWritten.count == 1 && store.artworkDrafts.isEmpty && !store.pendingUUIDs.contains(spec.uuid))
        #expect(ArtworkRevisions.key(spec.id) != before, "같은 ContentID라도 목록 썸네일을 새로 읽는다")
        #expect(["artwork.jpg", "artwork_m.jpg", "artwork_s.jpg"].allSatisfy { FileManager.default.fileExists(atPath: folder(fixture, spec).appending(path: $0).path) })
        let result = WriteResult.written(added, preview: preview.report)
        #expect(result.title.contains(WritePart.artwork.summary(1)) && result.text.contains(ArtworkWriteKind.add.label))

        // 다시 읽은 곡은 그림이 있다 → 지우기 초안
        row = try #require(store.rowsByUUID[spec.uuid])
        #expect(store.artworkBase(for: row).hasArtwork && store.artworkBase(for: row).files.count == 1)
        artwork.deleteArtwork(rows: [row])
        #expect(store.artworkDrafts[spec.uuid]?.kind == .delete)
        let deletion = try await store.session.previewWrite(rows: [row], playlists: false)
        let removed = try await store.session.writeToRekordbox([], artworks: deletion.batch.artworks)
        #expect(removed.artworkWritten.map(\.artwork) == [.delete])
        #expect(!FileManager.default.fileExists(atPath: folder(fixture, spec).appending(path: "artwork.jpg").path))

        // 지우기 쓰기를 되돌리면 그림 셋과 지우기 초안이 돌아온다
        let backup = try #require(RekordboxWriter.backups(in: fixture.backups).first(where: { $0.isWrite }))
        #expect(store.session.restoreConflicts(backup).isEmpty)
        try await store.session.restoreRekordbox(backup, keepingCurrentDrafts: true)
        #expect(FileManager.default.fileExists(atPath: folder(fixture, spec).appending(path: "artwork.jpg").path))
        #expect(store.artworkDrafts[spec.uuid]?.kind == .delete)
        row = try #require(store.rowsByUUID[spec.uuid])
        #expect(store.artworkBase(for: row).hasArtwork)

        // 그 뒤 다른 초안(넣기·바꾸기)을 만들면 같은 백업의 복원은 충돌로 알린다
        artwork.setArtwork(image, name: "다른 표지.jpg", rows: [row])
        #expect(store.session.restoreConflicts(backup).map(\.kind) == [.artwork])
        #expect(store.session.restoreConflictDetails(backup).first?.contains(RestoreDraftConflict(kind: .artwork, uuid: spec.uuid).label) == true)
    }

    @Test func 연결되지_않은_그림_초안도_목록에_보이고_버린다() async throws {
        let (fixture, _) = try library()
        let store = await makeStore(fixture)
        let edit = ArtworkDraftStore.edit(trackUUID: "없는-곡", base: ArtworkBase(imagePath: ""), image: image, imageName: nil)
        try ArtworkDraftStore.save(edit, directory: store.artworkDirectory)
        store.refreshUnlinkedDrafts()
        let sheet = UnlinkedDraftsModel(store: store)
        sheet.reload()
        #expect(sheet.drafts.first { $0.uuid == "없는-곡" }?.kinds == [.artwork])
        sheet.setSelected("없는-곡", true)
        sheet.discard()
        #expect(sheet.failure == nil)
        #expect(ArtworkDraftStore.uuids(directory: store.artworkDirectory).isEmpty)
    }

    // MARK: 리뷰 4·5

    @Test func 그림_초안_저장_실패는_같은_동작의_나머지가_지우지_않는다() async throws {
        // 그림 있는 곡의 지우기 초안은 저장에 실패하고 그림 없는 곡은 버릴 초안이 없다. 실패 안내가 남아야 한다.
        let (fixture, spec) = try library()
        var art = TrackSpec()
        art.analysisDataPath = "/PIONEER/USBANLZ/\(art.uuid.prefix(3))/\(art.uuid.dropFirst(3))/ANLZ0000.DAT"
        art.imagePath = TrackArtwork.imagePath(uuid: art.uuid)
        try fixture.add(art)
        let store = await makeStore(fixture)
        try FileManager.default.createDirectory(at: store.artworkDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("폴더 자리의 파일".utf8).write(to: store.artworkDirectory)
        let rows = try [spec.uuid, art.uuid].map { try #require(store.rowsByUUID[$0]) }
        let artwork = ArtworkInspectorModel(store: store)
        artwork.deleteArtwork(rows: rows)
        #expect(store.artworkDrafts.isEmpty && artwork.message?.text.contains("저장하지 못했으니") == true)
        artwork.setArtwork(image, name: nil, rows: rows)
        #expect(artwork.message?.text.contains("2곡") == true)
    }

    @Test func 되살리지_못한_그림_초안은_알리고_복원_확인_창은_그림도_적는다() async throws {
        let (fixture, spec) = try library()
        let store = await makeStore(fixture)
        // 백업 모양: artwork-drafts/<UUID>.json·.image
        let backupURL = fixture.root.appending(path: "backup")
        let folder = backupURL.appending(path: "artwork-drafts")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let edit = ArtworkDraftStore.edit(trackUUID: spec.uuid, base: ArtworkBase(imagePath: ""), image: image, imageName: nil)
        try JSONEncoder().encode(edit.draft).write(to: folder.appending(path: "\(spec.uuid).json"))
        try image.write(to: folder.appending(path: "\(spec.uuid).image"))
        let backup = RekordboxWriter.Backup(url: backupURL, createdAt: .now, isWrite: true, report: nil, trackReport: nil)
        try FileManager.default.createDirectory(at: store.artworkDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("폴더 자리의 파일".utf8).write(to: store.artworkDirectory)
        // 백업 폴더로 되돌리는 관문만 가짜로 두고(DB는 그대로) 되살리기는 반영 세션이 실제 초안 폴더에 한다.
        store.testReflection.gate = .restoringOnly
        try await store.session.restoreRekordbox(backup, keepingCurrentDrafts: false)
        #expect(store.writeFollowUp.contains(ReflectionSession.artworkRestoreFailureText(1)) && store.artworkDrafts.isEmpty)
        #expect(ReflectionSession.artworkRestoreFailureText(1).contains("1곡"))
        try FileManager.default.removeItem(at: store.artworkDirectory)
        try await store.session.restoreRekordbox(backup, keepingCurrentDrafts: false)
        #expect(!store.writeFollowUp.contains(ReflectionSession.artworkRestoreFailureText(1)) && store.artworkDrafts[spec.uuid] == edit.draft)
        #expect(ReflectionPrompts.restoreConfirmation(backup, changedSince: false).text.contains("앨범아트"))
    }
}
