import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import Testing

/// 빈 USB 내보내기 세션의 순서·판정(가짜 포트, DB·디스크 없이). 실제 엔진을 묶은 끝까지 쓰기는 DJCAdaptersTests `UsbExportSessionTests`
@Suite("USB 내보내기 세션 흐름")
struct UsbExportSessionFlowTests {
    static func options(_ configure: (inout UsbExportOptions) -> Void = { _ in }) -> UsbExportOptions {
        var options = UsbExportOptions()
        options.snapshotTime = "2100-01-01T00:00:00Z"
        configure(&options)
        return options
    }

    @Test("라이브 master.db면 스냅샷 시각·볼륨·사본을 보기 전에 거부한다")
    func liveDatabaseRefusedFirst() {
        let ports = FakeUsbPorts { $0.liveDatabases = [FakeUsbPorts.database] }
        #expect(thrownUsbError {
            _ = try ports.exportSession().preview(selection: .tracks(["101"]), options: Self.options())
        }?.shape == "writeRefused liveDatabase")
        #expect(ports.calls == ["isLive"])
    }

    @Test("관문에 막힌 볼륨(동의 없는 실물)은 라이브러리·PIONEER를 보지 않고 사본도 뜨지 않는다")
    func gatedVolumeNotListed() throws {
        let ports = FakeUsbPorts {
            $0.volume = FakeUsbVolume.physicalFAT32()
            $0.underScratch = false
        }
        let preview = try ports.exportSession().preview(selection: .tracks(["101"]), options: Self.options())
        #expect(preview.blocks.contains { $0.code == "physicalDisabled" })
        #expect(!ports.calls.contains("hasLibrary") && !ports.calls.contains("leftover"))
        #expect(!ports.calls.contains("copyLocal") && !ports.calls.contains("openLocal"))
        #expect(preview.changes == nil)
    }

    @Test("확인하지 않은 로컬 rekordbox 버전·이미 있는 라이브러리·PIONEER 찌꺼기는 사본을 뜨기 전에 막는다")
    func volumeBlocksBeforeCopy() throws {
        let unverified = FakeUsbPorts { $0.appVersion = "7.1.0" }
        #expect(try unverified.exportSession().preview(selection: .tracks(["101"]), options: Self.options()).blocks.map(\.code)
            == ["localVersionUnverified"])
        let library = FakeUsbPorts { $0.hasLibrary = true }
        #expect(try library.exportSession().preview(selection: .tracks(["101"]), options: Self.options()).blocks.map(\.code) == ["libraryExists"])
        let leftover = FakeUsbPorts { $0.leftover = UsbBlock(code: "leftoverPioneer", scope: .volume, message: "남은 것") }
        #expect(try leftover.exportSession().preview(selection: .tracks(["101"]), options: Self.options()).blocks.map(\.code) == ["leftoverPioneer"])
        for ports in [unverified, library, leftover] { #expect(!ports.calls.contains("copyLocal")) }
    }

    @Test("요청한 곡이 후보에 없으면 그 곡만 막고, 세션 사본은 연 뒤 닫고 지운다")
    func missingCandidateBlocksAndCopyRemoved() throws {
        let ports = FakeUsbPorts { $0.candidates = [FakeUsbPorts.candidate("101")] }
        let preview = try ports.exportSession().preview(selection: .tracks(["101", "102"]), options: Self.options())
        #expect(preview.blocks.contains { $0.code == "localTrackMissing" && $0.scope == .track("102") })
        #expect(!preview.blocks.contains { $0.scope == .track("101") })
        #expect(preview.stopping.isEmpty && preview.changes != nil)
        // 사본: 원본에서 세션 전용 폴더로 뜨고, 연 연결은 닫고, 폴더는 끝나면 지운다
        let copy = try #require(ports.current.copied.first)
        #expect(copy.database == FakeUsbPorts.database && FakeUsbPorts.isChild(copy.into, of: FakeUsbPorts.copies))
        #expect(ports.calls.contains("openLocal") && ports.calls.contains("close"))
        #expect(ports.removedCopies(prefix: "local-") == [copy.into])
        // 미리 보기는 준비 폴더도 지운다
        #expect(ports.removedStaging().count == 1)
    }

    @Test("동기화 선택이 생산 관문에 막히면 빌더를 부르지 않고 막힘만 돌려준다")
    func syncGateStopsBeforeBuild() throws {
        let gate = UsbBlock(code: "syncSelectionPartialFiles", scope: .volume, message: "한 형식만")
        let ports = FakeUsbPorts {
            $0.candidates = [FakeUsbPorts.candidate("101")]
            $0.syncGateBlock = gate
        }
        let draft = UsbSyncSelectionDraft.enabledOnly(localDBID: 1, enabled: true, baseFiles: [:])
        let preview = try ports.exportSession().preview(selection: .tracks(["101"]), options: Self.options { $0.syncSelection = draft })
        #expect(preview.blocks == [gate])
        #expect(!ports.calls.contains("build") && !ports.calls.contains("assemble"))
    }

    @Test("계획한 곡이 없으면 noTracks, 빌더의 볼륨 막힘이면 조립하지 않는다")
    func noTracksOrVolumeBlockSkipsAssembly() throws {
        let empty = FakeUsbPorts()
        #expect(try empty.exportSession().preview(selection: .tracks([]), options: Self.options()).blocks.map(\.code) == ["noTracks"])
        let volume = FakeUsbPorts {
            $0.candidates = [FakeUsbPorts.candidate("101")]
            $0.buildBlocks = [UsbBlock(code: "myTagRow", scope: .volume, message: "My Tag 행")]
        }
        let preview = try volume.exportSession().preview(selection: .tracks(["101"]), options: Self.options())
        #expect(preview.blocks.contains { $0.code == "myTagRow" })
        for ports in [empty, volume] { #expect(!ports.calls.contains("assemble")) }
    }

    @Test("준비 뒤 공간이 모자라면 변경 묶음을 버리고 준비 폴더를 지운다")
    func spaceBlockDropsChanges() throws {
        let ports = FakeUsbPorts {
            $0.candidates = [FakeUsbPorts.candidate("101")]
            $0.volume.available = 10
        }
        let preview = try ports.exportSession().preview(selection: .tracks(["101"]), options: Self.options())
        #expect(preview.blocks.contains { $0.code == "insufficientSpace" })
        #expect(preview.changes == nil)
        #expect(ports.removedStaging().count == 1)
    }

    @Test("쓰기: 엔진 쓰기에 조립 결과·옵션·쓰기 직전 ._ 목록을 넘기고 곡 막힘을 보고서에 붙이며, 끝나면 준비 폴더를 지운다")
    func writePassesAssemblyAndCleans() throws {
        let ports = FakeUsbPorts {
            $0.candidates = [FakeUsbPorts.candidate("101")]
            $0.preexisting = ["._.Trashes"]
        }
        let options = Self.options {
            $0.dryRun = true
            $0.confirmName = "DJCTEST"
            $0.expectedVolumeUUID = "UUID-1"
        }
        let report = try ports.exportSession().write(selection: .tracks(["101", "102"]), options: options, progress: { _ in }, isCancelled: { false })
        let write = try #require(ports.current.writes.first)
        #expect(write.verification == "export" && write.root == FakeUsbPorts.root && write.preexisting == ["._.Trashes"])
        #expect(write.options.dryRun && write.options.confirmName == "DJCTEST" && write.options.expectedVolumeUUID == "UUID-1")
        #expect(report.blocks.contains { $0.code == "localTrackMissing" })
        // ._ 목록은 쓰기 직전에 본다
        #expect(ports.calls.firstIndex(of: "appleDoubles")! < ports.calls.firstIndex(of: "write")!)
        #expect(ports.removedStaging().count == 1)
    }

    @Test("쓰는 도중 볼륨이 사라지면 회복이 쓸 준비 폴더를 남기고 세션 사본은 지운다")
    func volumeLostKeepsStaging() {
        let ports = FakeUsbPorts {
            $0.candidates = [FakeUsbPorts.candidate("101")]
            $0.writeResult = .failure(.volumeLost(volumeName: "DJCTEST"))
        }
        #expect(thrownUsbError {
            _ = try ports.exportSession().write(selection: .tracks(["101"]), options: Self.options(), progress: { _ in }, isCancelled: { false })
        }?.shape == "volumeLost")
        #expect(ports.removedStaging().isEmpty)
        #expect(ports.removedCopies(prefix: "local-").count == 1)
    }

    @Test("멈추는 막힘이 있으면 엔진 쓰기를 부르지 않고 writeRefused")
    func stoppingBlocksRefuseWrite() {
        let ports = FakeUsbPorts { $0.hasLibrary = true }
        #expect(throws: UsbError.self) {
            _ = try ports.exportSession().write(selection: .tracks(["101"]), options: Self.options(), progress: { _ in }, isCancelled: { false })
        }
        #expect(!ports.calls.contains("write"))
    }
}
