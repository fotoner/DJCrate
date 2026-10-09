import AppKit
import DJCApplication
import DJCDomain
import Foundation

/// 곡 불러오기: 상태를 비우고 → 음원 값만 메인 밖에서 읽어 음원을 열고 → 초안·그리드·그림을 메인 밖에서 읽어 한 번에 적용한다.
/// 같은 곡 가드는 `loadGeneration` 하나다(곡을 바꾸면 그 전 곡의 늦은 읽기·파형·분석을 버린다).
extension DeckModel {
    /// 지금 곡을 처음부터 다시 읽는다(분석 파일·초안이 밖에서 바뀌었을 때).
    func reload() {
        let current = row
        load(nil)
        load(current)
    }

    /// rekordbox에 쓰거나 되돌린 뒤: 소리·파형·분석은 그대로 두고 초안·그리드·게인만 새 rekordbox 값으로 맞춘다.
    func refreshAfterWrite(_ newRow: TrackRow?) {
        guard let current = row else { return }
        let target = newRow ?? current
        guard target.id == current.id else { return }
        softReload(target)
    }

    /// 백그라운드 읽기를 시작할 때의 곡이 아직 덱에 있는지(곡을 바꿀 때마다 `loadGeneration`이 오른다)
    func isCurrentLoad(_ generation: Int) -> Bool {
        !Task.isCancelled && generation == loadGeneration
    }

    /// 덱의 곡 행을 바꾼다. 곡(ID·UUID)이 달라지면 그 전 곡의 백그라운드 읽기를 버린다.
    func replaceRow(_ newRow: TrackRow?) {
        if newRow?.id != row?.id || newRow?.track.uuid != row?.track.uuid { loadGeneration += 1 }
        row = newRow
    }

    func loadRequest(_ row: TrackRow) -> DeckTrackRequest {
        let track = row.track
        return DeckTrackRequest(uuid: track.uuid, audioFile: track.isStreaming ? nil : URL(filePath: track.folderPath),
                                analysisPath: track.analysisDataPath, imagePath: track.imagePath,
                                shareRoot: shareRoot(), rekordboxCues: row.cues)
    }

    /// 같은 곡·같은 파일인데 내용(큐·그리드·게인·메타데이터)만 바뀌었을 때.
    func softReload(_ newRow: TrackRow) {
        clearDraftUndo()
        replaceRow(newRow)
        // rekordbox 키가 바뀌었을 수 있다(장·단 기준과 키 제안을 새 값으로 맞춘다).
        refreshKeySegments()
        let selected = cue(selectedCueID), engaged = cue(engagedLoopID)
        let request = loadRequest(newRow), generation = loadGeneration, length = duration, loader = loader
        softReloadTask?.cancel()
        softReloadTask = Task {
            let (content, gainDraft) = await loader.reloadContent(request, duration: length)
            guard self.isCurrentLoad(generation) else { return }
            self.clearDraftUndo()
            self.gainDraft = gainDraft
            self.applyGain()
            self.draft = content.draft
            self.applyGridGate(content.grid)
            self.applyAnalysisState(content.analysisState)
            self.refreshGrid()
            self.refreshSuggestionNote()
            // 고른 큐·걸린 루프는 같은 자리·종류의 새 큐로 잇는다(반영하면 rekordbox 큐로 바뀌어 ID가 새로 생긴다).
            func match(_ old: EditableCue?) -> EditableCue.ID? {
                old.flatMap { o in content.draft.cues.first { $0.kind == o.kind && abs($0.time - o.time) < 0.002 }?.id }
            }
            self.selectedCueID = match(selected)
            if self.engagedLoopID != nil { self.engagedLoopID = match(engaged) }
            // rekordbox 그림을 넣거나 바꾸거나 지웠을 수 있다(#66). 그림이 없어지면 처음 불러올 때처럼 음원 내장 그림을 보인다.
            if let artwork = content.artwork {
                self.artwork = Self.image(artwork)
            } else if let url = request.audioFile {
                let embedded = await loader.embeddedArtwork(url)
                guard self.isCurrentLoad(generation) else { return }
                self.artwork = embedded.map(Self.image)
            }
        }
    }

    /// 곡 ID가 같아도 내용(새 스냅샷의 큐·메타데이터)이 다르면 다시 불러온다.
    /// 같은 파일이고 이미 소리를 불러 둔 상태면 처음부터 다시 부르지 않고 초안·그리드만 맞춘다.
    func load(_ row: TrackRow?) {
        guard row != self.row else { return }
        clearDraftUndo()
        hasUncommittedCueEdits = false
        let sameTrack = row != nil && row?.id == self.row?.id
        if sameTrack, let row, let current = self.row, canPlay,
           row.track.folderPath == current.track.folderPath, row.track.imagePath == current.track.imagePath {
            softReload(row)
            return
        }
        stopPlayback()
        // 기록은 이 곡의 시각이라 다른 곡(다른 파일)으로 이어 가지 않는다.
        if isFlipRecording {
            cancelFlipRecording()
            if row != nil { showToast(String(ui: "곡을 바꿔 Flip 기록을 버렸습니다. 새 곡에서 Flip을 다시 누르세요")) }
        }
        loadTask?.cancel()
        softReloadTask?.cancel()
        waveformTask?.cancel()
        seekRestartTask?.cancel()
        audio.unload()
        // 같은 곡을 다시 부를 때도(파일이 바뀜·소리를 못 열었음) 그 전 읽기를 버린다.
        loadGeneration += 1
        self.row = row
        waveform = nil; waveformError = nil; analysis = nil; analysisError = nil; artwork = nil; applyAnalysisState(nil)
        isAnalyzingSections = row.map { !$0.track.isStreaming } ?? false
        suggestions = []; sectionEnergies = []; draft = nil; loudness = nil; keySegments = []; keyChroma = nil; keyEstimate = nil; gainDraft = nil
        engagedLoopID = nil; instantLoop = nil
        originalGrid = nil; gridDraft = nil; grid = nil; gridBPM = nil; gridEditBlockedReason = nil; gridSourceNotice = nil
        hasRekordboxGrid = false; timelineOffset = 0; gridSuggestion = nil; gridSuggestionItem = nil; suggestedGrid = nil
        suggestionTask?.cancel()
        gridDragBase = nil; tapBPM = nil; taps = []; resumeAfterScrub = false; scrubAnchor = nil; isCuePreviewing = false
        if !sameTrack { selectedCueID = nil; playhead = 0; cuePoint = 0; placeAtFirstMemoryCue = true }
        duration = Double(row?.track.lengthSeconds ?? 0)
        canPlay = false
        audioSourceState = row == nil ? .none : .preparing
        guard let row else { return }

        let request = loadRequest(row), generation = loadGeneration, key = row.track.uuid, loader = loader, analyzer = analyzer
        loadTask = Task {
            // 1) 음원을 열기 전에 필요한 값만 메인 밖에서 읽고, 음원은 바로 연다(초안·그리드를 기다리지 않고 재생할 수 있게).
            let prepared = await loader.prepareAudio(request)
            guard self.isCurrentLoad(generation) else { return }
            self.openAudio(row.track, prepared)

            // 2) 초안·그리드·그림은 백그라운드에서 읽고, 아직 이 곡일 때 한 번에 적용한다.
            let content = await loader.content(request, duration: self.duration)
            guard self.isCurrentLoad(generation) else { return }
            self.apply(content)
            if self.artwork == nil, prepared.fileExists, self.runsAnalysis, let url = request.audioFile {
                let embedded = await loader.embeddedArtwork(url)
                guard self.isCurrentLoad(generation), self.artwork == nil else { return }
                self.artwork = embedded.map(Self.image)
            }

            // 3) 파형: 곡을 넘기면 바로 취소된다(조각 단위로 취소를 확인한다).
            guard self.canPlay, self.runsAnalysis, let url = request.audioFile else { self.isAnalyzingSections = false; return }
            let job = Task.detached(priority: .userInitiated) { try analyzer.waveform(file: url, key: key) }
            self.waveformTask = job
            do {
                let waveform = try await job.value
                guard self.isCurrentLoad(generation) else { return }
                self.waveform = waveform
            } catch {
                guard self.isCurrentLoad(generation) else { return }
                self.waveformError = String(ui: "파형을 만들지 못했습니다: \(error.localizedDescription)")
            }
            #if DEBUG
            self.applyLaunchFlags()
            #endif

            // 4) 음악 분석(약 5초): 같은 곡에 1초 머문 뒤에만 시작하고, 곡을 넘기면 취소된다.
            try? await Task.sleep(for: .seconds(1))
            guard self.isCurrentLoad(generation) else { return }
            do {
                let sections = try await analyzer.sections(file: url, key: key, timelineOffset: self.timelineOffset)
                guard self.isCurrentLoad(generation) else { return }
                self.analysis = sections.shifted
                self.analysisError = nil
                self.isAnalyzingSections = false
                self.sectionEnergies = sections.energies
                self.refreshSuggestions()
                self.startGridSuggestion(sections, url: url, key: key, generation: generation)
            } catch {
                guard self.isCurrentLoad(generation) else { return }
                self.analysisError = String(describing: error)
                self.isAnalyzingSections = false
            }
        }
    }

    /// 음원을 연다(오디오 엔진은 메인 액터에서 동기로). 덱의 모든 시각은 rekordbox 시간축이다.
    private func openAudio(_ track: Track, _ prepared: DeckAudioPreparation) {
        if prepared.fileExists {
            timelineOffset = prepared.timelineOffset
            // 조성 크로마 캐시가 있으면 디코딩 때 다시 계산하지 않는다(불러오기 전에 정해야 한다).
            audio.needsChroma = prepared.cachedChroma == nil
            do {
                try audio.load(url: URL(filePath: track.folderPath), timelineOffset: timelineOffset)
                audioSourceState = audio.isLoaded ? .ready : .preparing
            } catch {
                audioSourceState = audio.failureState(for: error)
                waveformError = audioSourceState.unavailableReason
            }
            // 전에 잰 곡이면 디코딩을 기다리지 않고 바로 오토게인을 건다.
            loudness = prepared.loudness
            gainDraft = prepared.gainDraft
            applyGain()
            canPlay = audio.isLoaded
            if canPlay { duration = audio.duration }
            if let cachedChroma = prepared.cachedChroma {
                keyChroma = cachedChroma
                refreshKeySegments()
            }
        } else if !track.isStreaming {
            audioSourceState = .missing
            waveformError = audioSourceState.unavailableReason
        } else {
            audioSourceState = .streaming
        }
        playhead = min(playhead, duration)
    }

    /// 백그라운드에서 읽은 곡 내용을 한 번에 적용한다.
    func apply(_ content: DeckTrackContent) {
        draft = content.draft
        applyGridGate(content.grid)
        applyAnalysisState(content.analysisState)
        if let artwork = content.artwork { self.artwork = Self.image(artwork) }
        refreshGrid()
        // CDJ처럼 첫 메모리 큐에서 대기한다. 그사이 사용자가 위치를 옮겼으면 건드리지 않는다.
        if placeAtFirstMemoryCue {
            placeAtFirstMemoryCue = false
            if !isPlaying, playhead == cuePoint {
                cuePoint = DeckCuePoint.onLoad(cues: content.draft.cues, duration: duration)
                playhead = cuePoint
                audio.seekWhilePaused(cuePoint)
                updateGridBPM()
            }
        }
    }

    func applyGridGate(_ gate: DeckGridGate) {
        originalGrid = gate.originalGrid
        gridDraft = gate.gridDraft
        gridEditBlockedReason = gate.blockedReason
        gridSourceNotice = gate.sourceNotice
        hasRekordboxGrid = gate.originalGrid != nil
    }

    /// 같은 값이면 바꾸지 않는다(덱 머리 본문을 다시 계산하지 않게)
    func applyAnalysisState(_ state: RekordboxAnalysisState?) {
        if analysisState != state { analysisState = state }
    }

    static func image(_ artwork: DeckArtwork) -> NSImage {
        NSImage(cgImage: artwork.image, size: NSSize(width: artwork.image.width, height: artwork.image.height))
    }
}
