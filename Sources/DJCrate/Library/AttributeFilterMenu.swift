import DJCDomain
import SwiftUI

/// 머리 줄의 필터 단추(#65, 화면 이름은 #299에서 '거르기' → '필터', 자리는 #339에서 툴바 → 머리 줄, 조건은 #351에서 BPM·키·장르·곡 색 여러 개로).
/// 누르면 필터 창(팝오버)이 열린다: BPM 범위, 키(같은 키·어울리는 키), 장르, 평점, 곡 색(여러 개). 조건끼리는 AND이고, 판정은 `TrackFilter` 한 곳이다.
/// rekordbox 값(초안 전)으로 거른다: 정렬·사이드바 항목과 같다. 켜져 있으면 아이콘을 채우고 VoiceOver 값에 조건을 읽는다.
/// 켜진 조건은 단추 옆 칩(`ListFilterChips`)이 글로 보인다. 필터가 걸리지 않는 목록(`LibraryStore.listIsFilterable`)에서는 머리 줄이 이 단추를 두지 않는다.
struct AttributeFilterMenu: View {
    @Bindable var store: LibraryStore
    @State private var isPresented = false

    var body: some View {
        let active = store.isAttributeFiltered
        Button { isPresented.toggle() } label: {
            Label(.ui("필터"), systemImage: active ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .fixedSize()
        .popover(isPresented: $isPresented, arrowEdge: .bottom) { AttributeFilterEditor(store: store) }
        // 아이콘만 있는 단추라 이름을 알리고, 거르는 기준(초안 전 값)을 함께 적는다. 켠 조건은 칩이 말한다
        .help(.ui("필터: rekordbox에 들어 있는 값으로 목록을 거릅니다"))
        .selfTestFrame("listHeader.filter", clearsOnDisappear: true)
        .accessibilityValue(active ? summary : String(ui: "꺼짐"))
    }

    /// 켠 조건을 한 줄로(VoiceOver)
    private var summary: String {
        String(ui: "필터 켜짐: \(store.attributeFilterChips.chips.map(\.title).joined(separator: " · "))")
    }

    /// "★★★ 이상"(별 다섯은 그것만)
    static func ratingTitle(_ count: Int) -> String {
        let stars = String(repeating: "★", count: count)
        return count == 5 ? stars : String(ui: "\(stars) 이상")
    }

    static func ratingSpoken(_ count: Int) -> String {
        count == 5 ? String(ui: "별 5개") : String(ui: "별 \(count)개 이상")
    }
}

/// BPM 칸에 친 글자. 비면 그쪽은 열려 있고, 숫자가 아니거나 0 이하면 받지 않는다(조건은 마지막으로 받은 값 그대로).
enum FilterBPMText {
    enum Parsed: Equatable {
        case empty
        case value(Double)
        case invalid
    }

    static func parse(_ text: String) -> Parsed {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        if trimmed.isEmpty { return .empty }
        guard let value = Double(trimmed), value.isFinite, value > 0 else { return .invalid }
        return .value(value)
    }

    /// 조건의 한쪽 값을 칸에 보일 글자로(없으면 빈칸)
    static func text(_ value: Double?) -> String { value.map(BPMRange.format) ?? "" }

    /// 칸의 글자를 조건 한쪽 값으로 옮긴다. 이 칸이 지금 조건을 그대로 보이고 있으면 건드리지 않는다
    /// (소수 셋째 자리 이하는 칸이 둘째 자리까지만 보이므로, 창을 다시 열 때 칸을 채우는 글자가 조건을 덮어쓰지 않게).
    /// 비면 그쪽을 열고, 숫자가 아니면 그 칸만 받지 않고 지금 값을 둔다(다른 칸의 값은 그대로 받는다)
    static func resolve(_ text: String, current: Double?) -> Double? {
        if text == Self.text(current) { return current }
        switch parse(text) {
        case .empty: return nil
        case let .value(number): return number
        case .invalid: return current
        }
    }
}

/// 필터 창 본문. 조건마다 한 줄이고 바꾸는 즉시 목록에 걸린다(적용 단추가 없다).
/// 값 바꾸기는 모두 `store.filter`의 한 곳을 고친다: 그래서 칩·목록·접근성 값이 같은 값을 본다.
private struct AttributeFilterEditor: View {
    @Bindable var store: LibraryStore
    @State private var lowerText = ""
    @State private var upperText = ""
    /// 창을 열 때 한 번 만든다(곡 수만큼 훑으므로 본문을 다시 계산할 때마다 만들지 않는다)
    @State private var genres: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text(verbatim: "BPM").gridColumnAlignment(.leading)
                    HStack(spacing: 6) {
                        bpmField(.ui("최소"), text: $lowerText)
                        Text(verbatim: "–").foregroundStyle(.secondary)
                        bpmField(.ui("최대"), text: $upperText)
                    }
                }
                GridRow {
                    Text(.ui("키"))
                    Picker(.ui("키"), selection: keyName) {
                        Text(.ui("모든 키")).tag(String?.none)
                        ForEach(KeyNotation.camelotNames, id: \.self) { Text(verbatim: $0).tag(String?.some($0)) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                GridRow {
                    Color.clear.frame(width: 0, height: 0)
                    Picker(.ui("키 비교"), selection: keyMode) {
                        Text(.ui("같은 키")).tag(KeyCondition.Mode.same)
                        Text(.ui("어울리는 키")).tag(KeyCondition.Mode.compatible)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .disabled(store.filter.key == nil)
                }
                GridRow {
                    Text(.ui("장르"))
                    Picker(.ui("장르"), selection: genre) {
                        Text(.ui("모든 장르")).tag(String?.none)
                        ForEach(genreChoices, id: \.self) { Text(verbatim: $0).tag(String?.some($0)) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                GridRow {
                    Text(.ui("평점"))
                    Picker(.ui("평점"), selection: $store.minimumRating) {
                        Text(.ui("모든 평점")).tag(0)
                        ForEach(1...5, id: \.self) { count in
                            Text(verbatim: AttributeFilterMenu.ratingTitle(count)).tag(count)
                                .accessibilityLabel(AttributeFilterMenu.ratingSpoken(count))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                GridRow(alignment: .top) {
                    Text(.ui("곡 색"))
                    colorGrid
                }
            }
            if store.isAttributeFiltered {
                Divider()
                Button(.ui("모든 필터 끄기")) { store.clearAttributeFilters() }
            }
        }
        .padding(14)
        .onAppear {
            genres = store.genreChoices
            lowerText = FilterBPMText.text(store.filter.bpm?.lower)
            upperText = FilterBPMText.text(store.filter.bpm?.upper)
        }
        .onChange(of: store.filter.bpm) { _, range in
            // 바깥(모든 필터 끄기)에서 바뀐 값만 칸에 싣는다. 치는 중인 글자는 같은 값이면 그대로 둔다
            if FilterBPMText.parse(lowerText) != parsed(range?.lower) { lowerText = FilterBPMText.text(range?.lower) }
            if FilterBPMText.parse(upperText) != parsed(range?.upper) { upperText = FilterBPMText.text(range?.upper) }
        }
        .onChange(of: lowerText) { commitBPM() }
        .onChange(of: upperText) { commitBPM() }
    }

    // MARK: BPM

    private func bpmField(_ prompt: LocalizedStringResource, text: Binding<String>) -> some View {
        TextField(text: text, prompt: Text(prompt)) { Text(prompt) }
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: 64)
    }

    private func parsed(_ value: Double?) -> FilterBPMText.Parsed { value.map(FilterBPMText.Parsed.value) ?? .empty }

    /// 두 칸의 글자를 조건으로 옮긴다(칸마다 `FilterBPMText.resolve`)
    private func commitBPM() {
        let current = store.filter.bpm
        let range = BPMRange(lower: FilterBPMText.resolve(lowerText, current: current?.lower),
                             upper: FilterBPMText.resolve(upperText, current: current?.upper))
        let next = range.isEmpty ? nil : range
        if store.filter.bpm != next { store.filter.bpm = next }
    }

    // MARK: 키·장르

    private var keyName: Binding<String?> {
        Binding(get: { store.filter.key?.camelot },
                set: { name in store.filter.key = name.map { KeyCondition($0, mode: store.filter.key?.mode ?? .same) } })
    }

    private var keyMode: Binding<KeyCondition.Mode> {
        Binding(get: { store.filter.key?.mode ?? .same },
                set: { mode in if let key = store.filter.key { store.filter.key = KeyCondition(key.text, mode: mode) } })
    }

    /// 고르기 목록(창을 열 때의 장르)에 지금 고른 장르가 없으면(다른 목록에서 켠 조건) 맨 앞에 더해 보인다
    private var genreChoices: [String] {
        guard let current = store.filter.genre,
              !genres.contains(where: { TrackFilter.genreKey($0) == TrackFilter.genreKey(current) }) else { return genres }
        return [current] + genres
    }

    /// 고르기 값은 목록의 표기로 맞춘다(대소문자·NFC가 달라도 같은 장르다)
    private var genre: Binding<String?> {
        Binding(get: {
            guard let current = store.filter.genre else { return nil }
            return genreChoices.first { TrackFilter.genreKey($0) == TrackFilter.genreKey(current) } ?? current
        }, set: { store.filter.genre = $0 })
    }

    // MARK: 곡 색

    private var colorGrid: some View {
        LazyVGrid(columns: [GridItem(.fixed(104), alignment: .leading), GridItem(.fixed(104), alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(store.trackColors.filter { TrackColor.ids.contains($0.id) }) { color in
                Toggle(isOn: colorBinding(color.id)) {
                    Label {
                        Text(verbatim: color.name)
                    } icon: {
                        if let image = TagChoice.swatchImage(color.id) { Image(nsImage: image) }
                    }
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    private func colorBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { store.filter.colorIDs.contains(id) },
                set: { isOn in
                    if isOn { store.filter.colorIDs.insert(id) } else { store.filter.colorIDs.remove(id) }
                })
    }
}
