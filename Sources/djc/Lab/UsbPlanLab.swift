import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit

/// USB 내보내기·고치기 계획 실험(쓰지 않는다). 출력은 수치·규칙 이름·막힘 code별 수만 — 곡 제목·경로를 찍지 않는다.
enum UsbPlanLab {
    static let all: [Command] = [
        Command("usb-plan",
                "--db <사본> --share <share> (--playlist <ID> | --tracks <ID,…> | --all) [--compare <골든 폴더>] [--summary] [--snapshot-time <ISO 8601>]",
                "로컬 사본의 곡·목록으로 빈 USB 내보내기 계획을 세워 수치만 찍는다(쓰지 않는다)", UsbPlanLab.plan),
    ]

    static let clusterSize = 32_768

    static func plan(_ args: [String]) async throws {
        guard let dbArgument = value(after: "--db", in: args), let shareArgument = value(after: "--share", in: args) else {
            throw UsageError()
        }
        // 임시 폴더 아래 사본만 연다(라이브 master.db·DJCrate 스냅샷 폴더는 거부된다).
        let databasePath = try UsbScratchPath.check(dbArgument, as: .existingFile)
        let golden = try value(after: "--compare", in: args).map { try UsbScratchPath.check($0, as: .existingDirectory) }
        let snapshot = try UsbSnapshotTime.resolve(explicit: value(after: "--snapshot-time", in: args), database: URL(filePath: databasePath))
        print("스냅샷 시각: \(snapshot.source.rawValue)")

        let database = try CipherDatabase.diagnostic(path: databasePath, key: RekordboxKey.derive())
        defer { database.close() }
        var playlists: [UsbPlaylistInput] = []
        var ids: [String]
        if let playlist = value(after: "--playlist", in: args) {
            playlists = try UsbExportCandidates.playlistTree(database: database, rootIDs: [playlist])
            var seen: Set<String> = []
            ids = playlists.flatMap(\.trackLocalIDs).filter { seen.insert($0).inserted }
        } else if let tracks = value(after: "--tracks", in: args) {
            ids = tracks.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        } else if args.contains("--all") {
            ids = []
            try database.query("SELECT ID FROM djmdContent WHERE rb_local_deleted = 0 ORDER BY CAST(ID AS INTEGER), ID") { row in
                if let id = row.string(0) { ids.append(id) }
            }
        } else {
            throw UsageError()
        }

        let candidates = try UsbExportCandidates.load(database: database, share: URL(filePath: shareArgument), contentIDs: ids)
        // 빈 USB 계획이라 USB에 있는 파일과 겹치지 않아 같은 내용 비교를 부르지 않는다(기본값을 쓴다).
        let plan = UsbExportPlanner.plan(UsbExportRequest(
            candidates: candidates, playlists: playlists, existing: nil, formats: UsbFormat.defaultSet, naming: RekordboxAnalysisNaming(),
            snapshotTakenAt: snapshot.date, clusterSize: clusterSize))

        print("후보 \(ids.count) · 읽은 곡 \(candidates.count) · 계획 \(plan.tracks.count)곡 · 목록 \(plan.playlists.count) · "
            + "막힘 \(plan.blocked.count) · 경고 \(plan.warnings.count)")
        print("확인 안 된 규칙: \(ruleList(plan.requiredRules))")
        print("아트워크 폴더: \(artworkRanges(plan))")
        let space = plan.space
        print("용량(바이트): 새 파일 \(space.newBytes) · 임시 \(space.tempBytes) · 여유 \(space.margin) · 합계 \(space.total)")
        if args.contains("--summary") {
            print("막힘 code별: \(counts(plan.blocked.map(\.code)))")
            print("경고 code별: \(counts(plan.warnings.map(\.code)))")
            print("규칙별 곡 수: " + (plan.ruleCounts.isEmpty ? "없음"
                : plan.ruleCounts.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue) \($0.value)" }.joined(separator: ", ")))
            print("분석 상태별: \(counts(candidates.map(\.analysis.rawValue)))")
        }
        if let golden {
            let root = UsbRoot(URL(filePath: golden))
            let contents = try Set(UsbTree.walk(root, under: UsbLayout.contents).filter { !$0.isDirectory }.map(\.relativePath))
            let artwork = try Set(UsbTree.walk(root, under: UsbLayout.artworkRoot).filter { !$0.isDirectory }.map(\.relativePath))
            let result = compare(plan, goldenContents: contents, goldenArtwork: artwork)
            print("경로 성분 \(result.components.0)/\(result.components.1), 파일 이름 \(result.files.0)/\(result.files.1), "
                + "아트워크 폴더 \(result.artwork.0)/\(result.artwork.1)(\(artworkRanges(plan))), 막힘 \(plan.blocked.count), "
                + "확인 안 된 규칙: \(ruleList(plan.requiredRules))")
        }
    }

    /// 골든 Contents/(NFC 상대 경로)와 계획 경로를 성분 단위로, 아트워크는 image ID별 폴더로 비교한다.
    /// 성분 = 곡마다 아티스트·앨범 폴더 둘, 파일 이름 = 곡마다 하나. (맞은 수, 전체)
    static func compare(_ plan: UsbExportPlan, goldenContents: Set<String>, goldenArtwork: Set<String>)
        -> (components: (Int, Int), files: (Int, Int), artwork: (Int, Int)) {
        let golden = Set(goldenContents.map(UsbLayout.nfc))
        let artists = Set(golden.compactMap { prefix($0, 2) })
        let albums = Set(golden.compactMap { prefix($0, 3) })
        var components = 0, files = 0
        for track in plan.tracks {
            let path = UsbLayout.nfc(String(track.contentsPath.drop { $0 == "/" }))
            if let artist = prefix(path, 2), artists.contains(artist) { components += 1 }
            if let album = prefix(path, 3), albums.contains(album) { components += 1 }
            if golden.contains(path) { files += 1 }
        }
        let placed = plan.tracks.compactMap { track in track.imageID.flatMap { id in track.artworkFolder.map { (id, $0) } } }
        let artwork = placed.filter { goldenArtwork.contains(UsbArtworkLayout.paths(imageID: $0.0, folder: $0.1).a) }.count
        return ((components, plan.tracks.count * 2), (files, plan.tracks.count), (artwork, placed.count))
    }

    /// "Contents/A/B/F"의 앞 n 성분
    static func prefix(_ path: String, _ count: Int) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count > count ? parts.prefix(count).joined(separator: "/") : nil
    }

    /// "00001: 1–19, 00002: 20–28". 폴더가 limit개를 넘으면 앞 둘과 마지막만 적는다.
    static func artworkRanges(_ plan: UsbExportPlan, limit: Int = 10) -> String {
        let byFolder = Dictionary(grouping: plan.tracks.compactMap { track in track.imageID.flatMap { id in track.artworkFolder.map { ($0, id) } } },
                                  by: \.0)
        guard !byFolder.isEmpty else { return "없음" }
        let ranges = byFolder.keys.sorted().map { folder in
            let ids = byFolder[folder]!.map(\.1)
            let low = ids.min()!, high = ids.max()!
            return String(format: "%05d", folder) + ": " + (low == high ? "\(low)" : "\(low)–\(high)")
        }
        guard ranges.count > limit else { return ranges.joined(separator: ", ") }
        return ranges.prefix(2).joined(separator: ", ") + ", …, " + ranges.last! + " (폴더 \(ranges.count)개)"
    }

    /// 규칙 이름(rawValue)을 알파벳 순으로
    static func ruleList(_ rules: Set<UsbProvisionalRule>) -> String {
        rules.isEmpty ? "없음" : rules.map(\.rawValue).sorted().joined(separator: "·")
    }

    static func counts(_ codes: [String]) -> String {
        guard !codes.isEmpty else { return "없음" }
        return Dictionary(codes.map { ($0, 1) }, uniquingKeysWith: +).sorted { $0.key < $1.key }
            .map { "\($0.key) \($0.value)" }.joined(separator: ", ")
    }
}
