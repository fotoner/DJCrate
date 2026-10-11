import DJCDomain
import SwiftUI

/// 반영 대기가 없어도 마지막 쓰기 결과와 되돌리기를 열 수 있다.
struct ReflectionMenu: View {
    let store: LibraryStore
    /// 주 창 화면 모델(메뉴 항목은 이 모델로 보고 부른다)
    let window: LibraryWindowModel
    @Environment(\.reflection) private var reflection

    var body: some View {
        if store.pendingLibraryCount > 0 {
            menu.buttonStyle(.borderedProminent)
        } else {
            menu.buttonStyle(.bordered)
        }
    }

    private var menu: some View {
        Menu {
            Button(LibraryMenuAction.restore.title) { LibraryMenuAction.restore.perform(in: window, reflection: reflection) }
                .disabled(!LibraryMenuAction.restore.isEnabled(in: window))
            Button(LibraryMenuAction.writeResult.title) { LibraryMenuAction.writeResult.perform(in: window, reflection: reflection) }
                .disabled(!LibraryMenuAction.writeResult.isEnabled(in: window))
        } label: {
            Label(.ui("rekordbox에 쓰기"), systemImage: "square.and.arrow.up.on.square")
        } primaryAction: {
            LibraryMenuAction.reflect.perform(in: window, reflection: reflection)
        }
        .labelStyle(.titleAndIcon)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(.ui("rekordbox에 쓰기"))
        .disabled(!store.writeLockPolicy.allowsLibraryInteraction)
        // ⇧⌘E는 AppCommands가 맡아 툴바·사이드바를 숨겨도 한 번만 실행한다.
        .help(LibraryMenuAction.reflect.disabledReason(in: window)
              ?? (!store.writeTargets(store.selectedRows).isEmpty
                  ? String(ui: "선택한 곡과 재생 목록의 초안을 확인한 뒤 rekordbox에 씁니다(⇧⌘E)")
                  : String(ui: "선택한 곡에 쓸 초안이 없어 쓰기 대기 전체와 재생 목록 초안을 확인하니 미리 보기에서 대상을 확인하세요")))
    }
}
