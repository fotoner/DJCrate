import SwiftUI

/// ⓘ 단추: 처음 한 번만 필요한 개념(보관 규칙, 스킬이란?)을 팝오버로 연다. 늘 보이는 설명 줄 대신 쓴다.
/// `label`은 화면 낭독 이름이자 툴팁이고 팝오버 제목이다. 본문은 줄(문단)마다 `lines`에 준다.
struct InfoPopoverButton: View {
    let label: String
    let lines: [String]
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: { Image(systemName: "info.circle") }
            .buttonStyle(.borderless)
            .help(label)
            .accessibilityLabel(label)
            .popover(isPresented: $isPresented, arrowEdge: .bottom) { InfoPopoverContent(title: label, lines: lines) }
    }
}

/// 팝오버 본문. 글자 배율을 따르고, 긴 줄은 접는다.
struct InfoPopoverContent: View {
    let title: String
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: title).font(.headline)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(verbatim: line).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
    }
}
