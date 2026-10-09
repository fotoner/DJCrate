import DJCApplication
import DJCDomain
import AppKit
import Foundation

/// 게인: rekordbox 오토게인·DJCrate 측정·곡 초안·트림 (계산 규칙은 `GainPolicy`)
extension DeckModel {
    // MARK: 게인 (볼륨 페이더 앞)

    /// 지금 설정(오토게인·rekordbox 값 사용·트림)으로 만든 계산 규칙
    var gainPolicy: GainPolicy {
        var policy = GainPolicy()
        policy.enabled = autoGain
        policy.useRekordbox = useRekordboxGain
        policy.trim = gainTrim
        return policy
    }

    /// 이 곡의 rekordbox 오토게인(dB)
    var rekordboxGainDB: Double? { row?.autoGain?.gainDB }

    /// DJCrate 측정으로 계산한 오토게인(dB)
    var measuredGainDB: Double? {
        loudness.map { $0.autoGain(target: gainTarget, peakProtection: peakProtection) }
    }

    /// rekordbox 오토게인과 DJCrate 계산(같은 −10 LUFS 기준)의 차이. 1.5dB 넘으면 이상한 값으로 본다.
    var gainMismatchDB: Double? { GainPolicy.mismatch(rekordbox: rekordboxGainDB, integratedLoudness: loudness?.integrated) }

    var isGainSuspicious: Bool { GainPolicy.isSuspicious(mismatch: gainMismatchDB) }

    var autoGainDB: Double { gainPolicy.autoGainDB(rekordbox: rekordboxGainDB, measured: measuredGainDB, draft: gainDraft) }

    // MARK: 곡 오토게인 초안(rekordbox에 반영한다)

    /// 지금 이 곡에 쓰는 오토게인 값(초안 > rekordbox)
    var trackGainDB: Double? { gainDraft ?? rekordboxGainDB }

    /// 제안할 게인(dB): rekordbox 오토게인이 DJCrate 측정과 1.5dB 넘게 다를 때 DJCrate 계산값.
    /// 무시 여부와 관계없다(무시한 곡은 덱 제안 줄이 "무시한 제안 다시 보기"로 남긴다).
    var gainSuggestionCandidate: Double? {
        guard autoGain, useRekordboxGain, isGainSuspicious, gainDraft == nil, row != nil else { return nil }
        return measuredGainDB
    }

    var isGainSuggestionDismissed: Bool {
        guard let uuid = row?.track.uuid else { return false }
        return dismissedGainSuggestions.contains(uuid)
    }

    func acceptGainSuggestion() {
        guard let value = measuredGainDB else { return }
        setTrackGain((value * 10).rounded() / 10)
    }

    func dismissGainSuggestion() {
        guard let uuid = row?.track.uuid else { return }
        dismissedGainSuggestions.insert(uuid)
    }

    func restoreGainSuggestion() {
        guard let uuid = row?.track.uuid, dismissedGainSuggestions.contains(uuid) else { return }
        dismissedGainSuggestions.remove(uuid)
    }

    /// 곡 오토게인을 정한다(초안). rekordbox 값과 같으면 초안을 지운다.
    func setTrackGain(_ value: Double) {
        guard !isWriteLocked, let uuid = row?.track.uuid, let rekordbox = rekordboxGainDB else { return }
        let before = draftSnapshot
        gainDraft = GainPolicy.draft(for: value, rekordbox: rekordbox)
        persistGain(gainDraft, uuid: uuid)
        onDraftChange?(uuid, .gain, gainDraft != nil)
        applyGain()
        registerDraftUndo(from: before, name: String(ui: "게인 변경"))
    }

    func adjustTrackGain(by delta: Double) {
        guard let current = trackGainDB else { return }
        setTrackGain(((current + delta) * 10).rounded() / 10)
    }

    /// 초안을 지우고 rekordbox 오토게인으로 돌아간다.
    func clearGainDraft() {
        guard !isWriteLocked, let uuid = row?.track.uuid else { return }
        let before = draftSnapshot
        gainDraft = nil
        dismissedGainSuggestions.remove(uuid)
        persistGain(nil, uuid: uuid)
        onDraftChange?(uuid, .gain, false)
        applyGain()
        registerDraftUndo(from: before, name: String(ui: "게인 초안 버리기"))
    }

    var hasGainOverride: Bool { gainDraft != nil }

    /// 실제로 걸린 게인(dB)
    var appliedGain: Double { gainPolicy.applied(autoGainDB: autoGainDB) }

    /// 게인 뒤·볼륨 앞 레벨
    var meter: LevelMeter { audio.meter }

    func applyGain() { audio.gainDB = Float(appliedGain) }
}
