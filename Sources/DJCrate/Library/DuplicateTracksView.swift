import DJCDomain
import SwiftUI

/// 기존 곡 표의 열·정렬 설정을 바꾸지 않고 후보끼리 비교한다.
struct DuplicateTracksView: View {
    @Bindable var store: LibraryStore
    @State private var model: DuplicateTracksModel

    init(store: LibraryStore) {
        self.store = store
        _model = State(initialValue: DuplicateTracksModel(store: store))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(.ui("제목·아티스트 같음 · 길이 차이 2초 이내 · 버전 표기 구분"))
                .font(.callout).padding(.horizontal, 12).padding(.top, 8)
            Text(.ui("스냅샷 기준 · 후보가 같은 음원인지는 직접 확인하세요 · 한 곡이 여러 묶음에 나올 수 있습니다"))
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 8)
            ForEach(store.mergeDrafts) { draft in
                HStack {
                    Text(.ui("합치기 쓰기 대기 · \(draft.keeping.title) 유지 · \(draft.removing.count)곡 빼기"))
                    Spacer()
                    Button(.ui("초안 버리기")) {
                        do { try store.setMergeDrafts(store.mergeDrafts.filter { $0.id != draft.id }) }
                        catch { store.reflectionMessage = AppMessage(kind: .warning, text: error.localizedDescription) }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 4)
            }
            if store.displayDuplicateGroups.isEmpty {
                ContentUnavailableView(.ui("중복 후보가 없습니다"), systemImage: "square.on.square",
                                       description: store.search.isEmpty ? Text(.ui("현재 스냅샷에서 조건이 맞는 곡이 없습니다")) : Text(.ui("검색어를 지우고 다시 확인하세요")))
            } else {
                GeometryReader { geometry in
                    ScrollView(.horizontal) {
                        VStack(spacing: 0) {
                            HStack(spacing: Self.artworkSpacing) {
                                Image(systemName: "photo").frame(width: Self.artworkSide)
                                    .accessibilityLabel(Text(.ui("앨범아트")))
                                columns(title: String(ui: "곡 · 파일 경로"), length: String(ui: "길이"), cues: String(ui: "큐"), playlists: String(ui: "재생 목록"),
                                        plays: String(ui: "재생 횟수"), format: String(ui: "형식"), bitrate: String(ui: "비트레이트"))
                            }
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 16).padding(.vertical, 6)
                            List(selection: $store.selection) {
                                ForEach(store.displayDuplicateGroups) { group in
                                    Section {
                                        ForEach(group.tracks) { member in
                                            candidate(member, group: group).tag(member.id)
                                        }
                                    } header: {
                                        Text(.ui("\(group.tracks.first?.track.title ?? "") · \(group.tracks.count)곡"))
                                    }
                                }
                            }
                            .listStyle(.inset)
                            // 한 번 클릭은 고르기만, 더블클릭·Return·오른쪽 클릭 메뉴로 덱에 올린다(#93).
                            .contextMenu(forSelectionType: TrackRow.ID.self) { ids in
                                if loadTarget(ids) != nil {
                                    Button(.ui("덱에 불러오기")) { store.loadToDeck(loadTarget(ids)) }
                                }
                            } primaryAction: { ids in
                                store.loadToDeck(loadTarget(ids))
                            }
                        }
                        .frame(width: max(900, geometry.size.width), height: geometry.size.height)
                    }
                }
            }
        }
        .disabled(!store.writeLockPolicy.allowsLibraryInteraction)
        .navigationTitle(store.sidebarTitle)
        .navigationSubtitle(String(ui: "\(store.displayDuplicateGroups.count)묶음 · \(store.displayRows.count)곡"))
    }

    /// 고른 후보 중 화면 순서로 첫 곡
    private func loadTarget(_ ids: Set<TrackRow.ID>) -> TrackRow? {
        store.displayRows.first { ids.contains($0.id) }
    }

    /// 곡 목록의 앨범 아트 칸과 같은 크기
    private static let artworkSide: CGFloat = 22
    private static let artworkSpacing: CGFloat = 12

    private func candidate(_ member: LibraryRecords.DuplicateMember, group: LibraryRecords.DuplicateGroup) -> some View {
        HStack(alignment: .top, spacing: Self.artworkSpacing) {
            ArtworkThumbnail(imagePath: member.imagePath, id: member.id, shareRoot: store.shareRoot, thumbnails: store.thumbnails)
                .frame(width: Self.artworkSide, height: Self.artworkSide)
            details(member, group: group)
        }
        .padding(.vertical, 3)
    }

    private func details(_ member: LibraryRecords.DuplicateMember, group: LibraryRecords.DuplicateGroup) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            columns(title: member.track.title, length: String(ui: "\(member.track.lengthSeconds)초"), cues: "\(member.cueCount)",
                    playlists: "\(member.playlistCount)", plays: "\(member.playCount)", format: member.format,
                    bitrate: member.bitrateKbps.map { "\($0) kbps" } ?? String(ui: "알 수 없음"))
            HStack {
                Text(verbatim: member.track.artist ?? "").lineLimit(1)
                Text(.ui("수동 큐 \(member.manualCueCount) · 자동 큐 \(member.cueCount - member.manualCueCount)"))
            }
            .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(member.track.path).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(member.track.path)
                Spacer()
                Button(.ui("이 곡을 남기고 합치기…")) {
                    model.startMerge(keeping: member.id, removing: group.tracks.filter { $0.id != member.id }.map(\.id))
                }
                .buttonStyle(.borderless)
                .disabled(model.isPreparing || group.tracks.contains { store.pendingUUIDs.contains($0.track.uuid) })
            }
        }
    }

    private func columns(title: String, length: String, cues: String, playlists: String,
                         plays: String, format: String, bitrate: String) -> some View {
        HStack(spacing: 12) {
            Text(title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text(length).frame(width: 60, alignment: .trailing)
            Text(cues).frame(width: 40, alignment: .trailing)
            Text(playlists).frame(width: 65, alignment: .trailing)
            Text(plays).frame(width: 65, alignment: .trailing)
            Text(format).frame(width: 60, alignment: .leading)
            Text(bitrate).frame(width: 100, alignment: .trailing)
        }
        .monospacedDigit()
    }
}

/// 곡 목록의 앨범 아트 칸(`ThumbnailCell`)과 같은 모양·같은 디코딩·같은 캐시 키(ContentID)를 쓴다.
/// 줄마다 AppKit 셀을 만들면 빠르게 훑을 때 한 번 처리가 늘어서 SwiftUI로 그린다.
private struct ArtworkThumbnail: View {
    let imagePath: String?
    let id: String
    let shareRoot: URL
    let thumbnails: Thumbnails
    @State private var loader = ArtworkThumbnailLoader()

    var body: some View {
        ZStack {
            if let artwork = loader.box {
                Image(decorative: artwork.image, scale: 1).resizable().scaledToFit()
            } else {
                Color(nsColor: .quaternarySystemFill)
                Image(systemName: "music.note").font(.system(size: 8)).foregroundStyle(Color(nsColor: .tertiaryLabelColor))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .accessibilityElement()
        .accessibilityLabel(loader.box == nil ? Text(.ui("앨범아트 없음")) : Text(.ui("앨범아트")))
        // 스크롤로 지나친 줄은 작업이 취소되어 디코딩하지 않는다(`Thumbnails`).
        .task(id: ArtworkRevisions.key(id)) { await loader.load(imagePath, root: shareRoot, key: ArtworkRevisions.key(id), from: thumbnails) }
    }
}
