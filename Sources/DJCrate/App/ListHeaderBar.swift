import AppKit
import DJCDomain
import SwiftUI

/// 곡 목록·태그 시트·중복 후보 바로 위 머리 줄(#338·#339). 늘 한 줄이다.
/// 왼쪽은 검색칸 · 필터 단추 · 켜진 필터 칩, 오른쪽 끝은 목록 | 태그 시트 전환(태그 시트일 때는 ⓘ 초안 범례)이다. 작업 줄은 다음 이슈(#340)가 채운다.
/// 지금의 작업 줄·연결되지 않은 초안 줄은 이 줄 아래에 그대로 둔다.
/// 검색어·필터·보기 모드는 안쪽 잎(`ListSearchField`·`AttributeFilterMenu`·`ListFilterChips`·`ListViewModeControls`)만 읽는다:
/// 글자를 치거나 필터를 바꿀 때 `ContentView`·`LibraryDetail`·이 줄 본문을 다시 계산하지 않는다.
/// 이 본문이 읽는 것은 사이드바 대상뿐이다(검색칸·필터 단추가 걸리는 화면인지).
struct ListHeaderBar: View {
    /// 줄 높이. 덱·파형 높이 계산이 이 줄을 목록 위 높이로 센다(`LibraryLayoutMetrics`)
    static let height: CGFloat = 34

    let store: LibraryStore
    let window: LibraryWindowModel

    var body: some View {
        let _ = PerfProbe.body(Self.self)
        HStack(spacing: 10) {
            // 검색·필터가 걸리지 않는 화면(USB 쓰기 대기·중복 후보)에는 칸·단추를 두지 않는다. 줄 높이는 그대로다
            // 검색칸이 먼저 폭을 받고(폭이 모자라면 칩이 하나로 줄어든다), 칩 자리가 남는 폭을 받아 전환을 오른쪽 끝으로 민다
            if store.listIsSearchable { ListSearchField(store: store, window: window).layoutPriority(1) }
            if store.listIsFilterable {
                AttributeFilterMenu(store: store)
                ListFilterChips(store: store)
            } else {
                Spacer(minLength: 0)
            }
            ListViewModeControls(store: store)
        }
        .padding(.horizontal, Spacing.edge)
        .frame(height: Self.height)
    }
}

/// 머리 줄 왼쪽 끝 검색칸. 검색어와 포커스 요청은 이 뷰의 본문만 읽는다. 부모 본문에서 `Binding`을 만들어 넘기면 부모가
/// 검색어·표시 줄 변화에 걸려 다시 계산됐다(변경 추적으로 확인). 그래서 부모는 저장소와 화면 모델만 넘기고 읽지 않는다.
/// 검색 범위(제목·아티스트·코멘트)와 키 동작(Esc는 지우고 목록으로, Return은 목록으로, 한글 조합)은 툴바 검색칸 때와 같다.
struct ListSearchField: View {
    static let width: CGFloat = 240

    @Environment(\.isEnabled) private var isEnabled
    let store: LibraryStore
    let window: LibraryWindowModel

    var body: some View {
        let _ = PerfProbe.body(Self.self)
        SearchFieldRepresentable(text: store.search, focusRequest: window.searchFocusRequest,
                                 prompt: String(ui: "제목·아티스트·코멘트"), isEnabled: isEnabled) { store.search = $0 }
            .frame(minWidth: 160, idealWidth: Self.width, maxWidth: Self.width)
            .selfTestFrame("listHeader.search")
    }
}

/// 지움 단추·Esc·한글 조합을 AppKit 검색칸(`NSSearchField`)에 맡긴다. `KeyRouter`와 키 전달 시험이 이 타입으로 검색칸을 찾는다.
private struct SearchFieldRepresentable: NSViewRepresentable {
    let text: String
    let focusRequest: Int
    let prompt: String
    let isEnabled: Bool
    let onChange: (String) -> Void

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.changed(_:))
        field.stringValue = text
        // 이미 지나간 요청으로 칸이 만들어지자마자 포커스를 가져가지 않는다
        context.coordinator.handledFocusRequest = focusRequest
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        let coordinator = context.coordinator
        coordinator.onChange = onChange
        field.isEnabled = isEnabled
        // 입력 중인 글자(한글 조합 포함)는 칸이 이미 들고 있다. 다른 곳에서 바뀐 검색어(검색 지우기 단추 등)만 칸에 싣는다
        let composing = (field.currentEditor() as? NSTextView)?.hasMarkedText() == true
        if field.stringValue != text, !composing { field.stringValue = text }
        if coordinator.handledFocusRequest != focusRequest {
            coordinator.handledFocusRequest = focusRequest
            // 갱신 도중에 포커스를 옮기면 AppKit이 레이아웃 중 응답자를 바꾼다고 경고하므로 한 박자 뒤에 옮긴다
            DispatchQueue.main.async { [weak field] in
                guard let field, field.window != nil, field.isEnabled else { return }
                field.selectText(nil)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var onChange: (String) -> Void
        var handledFocusRequest = 0

        init(onChange: @escaping (String) -> Void) { self.onChange = onChange }

        /// 지움 단추와 Return
        @objc func changed(_ sender: NSSearchField) { onChange(sender.stringValue) }

        /// 글자를 칠 때마다(한글은 조합 중인 글자까지). 조합 중에는 칸이 글자를 들고 있어 되돌려 쓰지 않는다
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            onChange(field.stringValue)
        }

        /// Esc는 검색어를 지운다. 목록으로 포커스를 옮기는 일은 `KeyRouter`가 이어서 한다
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)), !textView.hasMarkedText(),
                  let field = control as? NSSearchField, !field.stringValue.isEmpty else { return false }
            field.stringValue = ""
            onChange("")
            return true
        }
    }
}
