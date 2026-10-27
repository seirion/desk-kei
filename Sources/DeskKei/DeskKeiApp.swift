import SwiftUI

@main
struct DeskKeiApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Desk Kei") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 560)
                .onAppear { model.start() }
        }
        .defaultSize(width: 980, height: 700)
        .commands {
            CommandGroup(after: .newItem) {
                Button("종목 검색") { model.showSearch = true }
                    .keyboardShortcut("f", modifiers: .command)
                Button("계정 관리") { model.showAccounts = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("화면") {
                ForEach(Array(AppTab.allCases.enumerated()), id: \.element) { i, tab in
                    Button(tab.title) { model.tab = tab }
                        .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: .command)
                }
            }
        }
    }
}
