/// 편집본 렌더가 쓴 비율(0~1)을 알린다. 렌더하는 스레드에서 부른다(`EditRenderer.Progress`, #167).
public typealias EditRenderProgress = @Sendable (Double) -> Void
