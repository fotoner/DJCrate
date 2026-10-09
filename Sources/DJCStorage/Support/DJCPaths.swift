import DJCDomain
import DJCEnvironment
import Foundation

/// DJCrate가 쓰는 사용자 데이터(초안·추가한 곡) 위치.
/// `DJC_HOME`을 주면 그쪽을 쓴다(테스트가 사용자 초안을 건드리지 않게). 파형·분석·음량 캐시도 같은 뿌리를 따른다(`DJCCachePaths`, #195).
/// 스냅샷만 `DJC_HOME`을 따르지 않는다(`DJC_REKORDBOX_DIR`을 주면 그 안).
public enum DJCPaths {
    public static var userData: URL { DJCIdentity.dataDirectory }

    /// DJCrate가 rekordbox에 쓰기 직전에 뜬 백업
    public static var rekordboxBackups: URL { userData.appending(path: "rekordbox-backups") }

    /// 시점 스냅샷(#224): rekordbox 라이브러리에서 DJCrate가 쓰는 파일 전체를 한 시점으로 남긴 것. 쓰기 전 백업과 따로 둔다(#223)
    public static var pointSnapshots: URL { userData.appending(path: "point-snapshots") }

    public static var previewWaveforms: URL { userData.appending(path: "preview-waveforms.plist") }

    /// 곡 편집 창이 렌더한 편집본. rekordbox 컬렉션이 이 경로를 가리키게 되므로 숨은 데이터 폴더가 아니라 음악 폴더에 둔다.
    public static var editOutput: URL {
        editOutput(environment: ProcessInfo.processInfo.environment,
                   music: FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0])
    }

    /// `DJC_HOME`을 주면 그 아래 `edits`(테스트·자가 테스트가 사용자 음악 폴더에 파일을 만들지 않게).
    public static func editOutput(environment: [String: String], music: URL) -> URL {
        if let override = environment["DJC_HOME"], !override.isEmpty {
            return URL(filePath: override).appending(path: "edits")
        }
        return music.appending(path: "DJCrate 편집본")
    }
}
