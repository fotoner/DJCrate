import DJCApplication
import DJCDomain
import Foundation

/// 곡 편집 창의 재생·시킹(창 전용 재생기 `EditAudio`)과 보기(확대·가로 스크롤)
extension TrackEditModel {
    // MARK: - 재생·시킹

    /// 줄의 길이(초). 결과가 없으면 0.
    func length(_ lane: Lane) -> Double {
        lane == .source ? duration : edit?.duration ?? 0
    }

    /// 지금 재생선 위치(재생 중이면 들리는 자리)
    func position(_ lane: Lane) -> Double {
        if playing == lane { return min(playStart + audio.elapsed, playLimit) }
        return lane == .source ? sourcePlayhead : outputPlayhead
    }

    func canPlay(_ lane: Lane) -> Bool {
        isAudioReady && blockedReason == nil && length(lane) > 0
    }

    /// 스페이스바: 재생 중이면 멈추고, 아니면 마지막으로 누른 줄을 재생한다.
    func togglePlay() {
        if playing != nil { pause() } else { play(focus) }
    }

    /// 재생선에서 재생한다. 끝에 있으면 처음부터. `until`(초)에 닿으면 멈춘다(이음새 듣기).
    func play(_ lane: Lane, until: Double? = nil) {
        guard canPlay(lane) else { return }
        focus = lane
        var from = position(lane)
        if from >= length(lane) - 0.01 { from = 0 }
        start(lane, at: from, until: until)
    }

    private func start(_ lane: Lane, at time: Double, until: Double?) {
        stopAudio()
        // 덱과 겹쳐 들리지 않게 덱을 멈춘다.
        deck.pause()
        let rate = audio.sampleRate
        let items: [EditPlaybackItem]
        switch lane {
        case .source:
            items = [EditPlaybackItem(outputFrame: 0, frameCount: Int64((duration * rate).rounded()),
                                      sourceFrame: -Int64((timelineOffset * rate).rounded()))]
        case .output:
            guard let edit else { return }
            items = TrackEdit.playbackItems(edit.frames(sampleRate: rate, sourceOffset: timelineOffset))
        }
        setPlayhead(lane, time)
        guard audio.play(items, from: Int64((time * rate).rounded()), volume: Float(deck.volume())) else {
            message = AppMessage(kind: .failure, text: String(ui: "재생하지 못했습니다. 소리 출력 장치를 확인하세요"))
            return
        }
        // 끝(또는 이음새 듣기 끝)에 닿으면 멈춘다. 확대해 보는 중에 재생선이 보이는 자리 오른쪽 끝을 넘으면 다음 쪽으로 넘긴다
        // (다른 곳을 보고 있으면 끌어오지 않는다).
        let watch = Task { [weak self] in
            var last = time
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(40))
                guard let self, self.playing == lane else { return }
                if !self.audio.isPlaying || self.playStart + self.audio.elapsed >= self.playLimit {
                    self.pause()
                    return
                }
                let now = self.position(lane), end = self.viewport(lane).visible(length: self.extent(lane)).upperBound
                if last <= end, now > end { self.reveal(lane, now) }
                last = now
            }
        }
        markPlaying(lane, from: time, limit: min(until ?? length(lane), length(lane)), watch: watch)
    }

    /// 멈추고 들리던 자리에 재생선을 둔다.
    func pause() {
        guard let lane = playing else { return }
        let time = position(lane)
        stopAudio()
        setPlayhead(lane, time)
    }

    /// 재생선을 옮긴다(누른 자리·←→·Home·End). 재생 중이면 그 자리에서 잇는다. 보이지 않는 자리면 따라 넘긴다.
    func seek(_ lane: Lane, to time: Double) {
        focus = lane
        if playing == lane {
            start(lane, at: min(max(time, 0), length(lane)), until: nil)
        } else {
            setPlayhead(lane, time)
        }
        reveal(lane, position(lane))
    }

    /// 재생선을 끄는 동안: 소리를 멈췄다가 `endScrub`에서 그 자리부터 잇는다(덱 휠 이동과 같다).
    func scrub(_ lane: Lane, to time: Double) {
        focus = lane
        if playing == lane {
            stopAudio()
            holdScrub(lane)
        }
        setPlayhead(lane, time)
    }

    func endScrub() {
        guard let lane = scrubbing else { return }
        holdScrub(nil)
        play(lane)
    }

    /// ←→: 마지막으로 누른 줄의 재생선을 앞뒤 마디 줄로(⇧는 4마디).
    func step(bars: Int) {
        guard let layout = focus == .source ? layout : outputLayout else { return }
        seek(focus, to: layout.step(from: position(focus), by: bars))
    }

    /// Home·End
    func jump(toEnd: Bool) {
        seek(focus, to: toEnd ? length(focus) : 0)
    }

    /// 이음새(`edit.pieces[piece]`의 시작) 앞 2마디부터 뒤 2마디까지 결과를 들어 본다(조각이 짧으면 그 조각 안에서).
    func auditionSeam(_ piece: Int) {
        guard let range = edit?.seamAudition(piece), canPlay(.output) else { return }
        focus = .output
        start(.output, at: range.lowerBound, until: range.upperBound)
        reveal(.output, range.lowerBound)
        markAuditioning(piece)
    }

    // MARK: - 보기(확대·가로 스크롤)

    func viewport(_ lane: Lane) -> EditViewport {
        lane == .source ? sourceView : outputView
    }

    /// 줄에 그리는 길이(초). 결과는 규칙에 맞지 않아 재생할 수 없는 목록도 클립 자리만큼 그린다.
    func extent(_ lane: Lane) -> Double {
        lane == .source ? duration : clipLayout.last?.outputEnd ?? 0
    }

    /// 가장 가깝게 보는 길이: 2마디(마디 하나를 정확히 고를 만큼)
    var minimumSpan: Double { 2 * (layout?.barLength ?? 2) }

    /// `factor`배 확대한다(1보다 작으면 축소). 기준 자리는 `anchor`(휠·핀치는 포인터 자리),
    /// 없으면 보이는 재생선, 재생선이 보이지 않으면 보이는 구간 가운데.
    func zoom(_ lane: Lane, by factor: Double, around anchor: Double? = nil) {
        let length = extent(lane), visible = viewport(lane).visible(length: length)
        let playhead = position(lane)
        let anchor = anchor ?? (visible.contains(playhead) ? playhead : (visible.lowerBound + visible.upperBound) / 2)
        update(lane) { $0.zoom(by: factor, around: anchor, length: length, minimumSpan: minimumSpan) }
    }

    /// 줄 전체를 폭에 맞춘다.
    func fit(_ lane: Lane) {
        update(lane) { $0.fit() }
    }

    func scroll(_ lane: Lane, by seconds: Double) {
        let length = extent(lane)
        update(lane) { $0.scroll(by: seconds, length: length) }
    }

    func scroll(_ lane: Lane, to time: Double) {
        let length = extent(lane)
        update(lane) { $0.scroll(to: time, length: length) }
    }

    private func reveal(_ lane: Lane, _ time: Double) {
        let length = extent(lane)
        update(lane) { $0.reveal(time, length: length) }
    }

    /// 바뀔 때만 쓴다(보이는 자리를 읽는 줄만 다시 그린다).
    private func update(_ lane: Lane, _ body: (inout EditViewport) -> Void) {
        var view = viewport(lane)
        body(&view)
        guard view != viewport(lane) else { return }
        setViewport(view, for: lane)
    }
}
