import DJCApplication
import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit

extension XMLFiles {
    /// rekordbox XML 형식(RekordboxKit)과 이 Mac의 파일
    public static let live = XMLFiles(
        read: { try RekordboxXMLReader.read(url: $0) },
        library: { try RekordboxXMLImport.library(snapshot: $0, shareRoot: $1, gridsFor: $2) },
        checkOutput: { try RekordboxLibraryXML.checkOutput($0) },
        exportLibrary: { snapshot, shareRoot, out, progress in
            let collection = try RekordboxLibraryXML.load(snapshot: snapshot, shareRoot: shareRoot, progress: progress)
            if let out { try RekordboxLibraryXML.write(collection, to: out, progress: progress) }
            return collection.summary
        },
        item: { url in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return .none }
            return isDirectory.boolValue ? .directory : .file
        },
        reflectionPlan: { Reflection.plan(track: $0, rawCues: $1, cueDraft: $2, gridDraft: $3) },
        verifyReflection: { Reflection.verify($0, track: $1, cues: $2, grid: $3) },
        writeReflection: { plans, name, out in
            try Reflection.document(plans: plans, playlistName: name).write(to: out, atomically: true, encoding: .utf8)
        },
        writeStaged: { entries, name, out in
            let document = RekordboxXML.document(entries: entries.map { RekordboxXML.Entry(track: $0.track, tempos: $0.tempos, cues: $0.cues) },
                                                 playlistName: name)
            try document.write(to: out, atomically: true, encoding: .utf8)
        })
}

extension DraftFiles {
    /// 초안 폴더 `home`의 곡별 초안 파일(큐·그리드·태그·재생 목록)을 바로 읽고 쓴다(저장 큐를 거치지 않는다)
    public static func live(home: URL) -> DraftFiles {
        let places = DraftLocations(home: home)
        @Sendable func directory(_ kind: XMLImportDrafts.Kind) -> URL? {
            switch kind {
            case .cue: places.cue
            case .grid: places.grid
            case .tag: places.tags
            case .playlist: nil
            }
        }
        return DraftFiles(
            exists: { kind, uuid in
                guard let directory = directory(kind) else { return false }
                return FileManager.default.fileExists(atPath: directory.appending(path: "\(uuid).json").path)
            },
            saveCue: { try CueDraftStore.save($0, directory: places.cue) },
            saveGrid: { try GridDraftStore.save($0, directory: places.grid) },
            saveTag: { try TagDraftStore.save($0, directory: places.tags) },
            playlist: { PlaylistDraftStore.load(url: places.playlist) },
            savePlaylist: { try PlaylistDraftStore.save($0, url: places.playlist) },
            cue: { try existing(places.cue.appending(path: "\($0).json")) },
            tag: { try existing(places.tags.appending(path: "\($0).json")) },
            removeCue: { try CueDraftStore.remove(trackUUID: $0, directory: places.cue) },
            removeTag: { try TagDraftStore.remove(trackUUID: $0, directory: places.tags) },
            isPlainPath: { kind, uuid in
                guard let directory = directory(kind) else { return false }
                let file = directory.appending(path: "\(uuid).json")
                return directory.resolvingSymlinksInPath().standardizedFileURL == directory.standardizedFileURL
                    && file.resolvingSymlinksInPath().standardizedFileURL == file.standardizedFileURL
            },
            newCueID: { UUID() })
    }

    /// 초안 파일 하나: 없으면 nil, 읽지 못하면 던진다
    private static func existing<T: Decodable>(_ file: URL) throws -> T? {
        do { return try JSONDecoder().decode(T.self, from: Data(contentsOf: file)) }
        catch CocoaError.fileReadNoSuchFile { return nil }
    }
}
