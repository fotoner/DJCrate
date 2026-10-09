import Testing

extension Tag {
    /// 성능 계약: 뷰 본문 다시 계산 횟수·관찰 범위·경로 캐시·창 크기 측정 기록(#129·#137·#138). 동작이 아니라 비용을 지킨다.
    /// 관찰 범위를 좁혀 둔 곳을 고치면 이 태그의 시험을 다시 본다(실행 명령은 `docs/ci.md` "선택 실행 장치", `LayoutRecomputeTests`는 `DJC_LAYOUT_RECOMPUTE_TESTS=1`이 있어야 돈다).
    @Tag static var perfContract: Self
}
