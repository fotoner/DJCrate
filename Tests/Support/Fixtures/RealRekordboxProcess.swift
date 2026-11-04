import Foundation
import RekordboxKit

/// 이 Mac에서 실제 rekordbox(또는 rekordboxAgent)가 켜져 있는지(#292). 프로세스를 띄우지 않고 앱·CLI가 쓰는 실제 감지(`pgrep -x`)를 한 번 부른다.
/// 라이브 폴더로 본 사본에 쓰는 `djc`처럼 실제 감지를 그대로 따라 rekordbox가 켜져 있으면 막히는 시험이 `.enabled(if: !RealRekordboxProcess.isRunning)`로 쓴다.
/// 확인하지 못해도 켜진 것으로 본다(#323). 가짜 `rekordbox` 이름 프로세스를 띄워 이 값을 바꾸지 않는다(다른 시험과 켜져 있는 앱이 실제로 본다).
public enum RealRekordboxProcess {
    public static let isRunning: Bool = RekordboxProcessCheck.system.isRunning()
}
