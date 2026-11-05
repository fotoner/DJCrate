import DJCApplication
import DJCDomain
import Foundation
import RekordboxKit

extension UsbLibraryEngine.PointSnapshot {
    /// USB 시점 스냅샷의 실제 구현: 뜨기·목록·고정·지우기는 `UsbPointSnapshot`, 되돌리기 계획은 `UsbPointRestore`(USB는 읽기만).
    /// 되돌리기 쓰기는 이 포트에 없다. 유스케이스가 계획을 `writer.write`(`UsbWriter.write` 한 곳)로 넘긴다
    /// - fileSystem: USB 파일 연산(앱·CLI는 `PosixUsbFileSystem()`, 시험은 마운트를 흉내 내는 것)
    public static func live(fileSystem: any UsbFileSystem) -> Self {
        Self(
            create: { request in
                try UsbPointSnapshot.create(name: request.name, root: UsbRoot(request.root), in: request.directory, paths: request.paths,
                                            guard: request.writeGuard, fileSystem: fileSystem, now: request.now)
            },
            list: { UsbPointSnapshot.list(in: $0, volumeKey: $1) },
            setPinned: { try UsbPointSnapshot.setPinned($0, $1, in: $2) },
            delete: { try UsbPointSnapshot.delete($0, in: $1) },
            planRestore: { input in
                try UsbPointRestore.plan(input.entry, root: UsbRoot(input.root), fileSystem: fileSystem, base: input.base, staging: input.staging,
                                         session: input.session, highWater: input.highWater)
            },
            volumeEvents: { UsbPointSnapshot.volumeEvents(in: $0, paths: $1, volumeKey: $2) })
    }
}
