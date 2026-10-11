import Foundation

// 포트 계약 함수(`<포트>Contract`): 같은 피동 포트의 가짜(메모리 구현)와 실제 구현(DJCAdapters)이 유스케이스가 기대하는 성질을
// 똑같이 지키는지 본다. 유스케이스 시험(DJCApplicationTests)은 가짜에, 어댑터 시험(DJCAdaptersTests)은 실제 구현과 합성 픽스처에
// 같은 함수를 돌린다(adv4 T7: 가짜와 실제가 갈라져도 유스케이스 시험은 모르고 통과했다). 계약은 짧게 — 저장한 것을 같게 읽는지,
// 없는 것·지우기·거부처럼 유스케이스가 기대는 성질만 본다. 형식·파일 모양은 어댑터 시험이 따로 본다.

/// 같은 폴더인지(임시 폴더의 /var → /private/var 별칭과 끝의 / 표기를 맞춘다)
public func samePath(_ a: URL, _ b: URL) -> Bool {
    a.resolvingSymlinksInPath().standardizedFileURL.path == b.resolvingSymlinksInPath().standardizedFileURL.path
}
