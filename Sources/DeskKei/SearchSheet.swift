import DeskKeiCore
import SwiftUI

/// 종목 검색 후 현재 관심종목 그룹에 추가/제거
struct SearchSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("종목명 또는 코드 검색…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Divider()

            let results = StockSearch.search(model.stocks, query: query, limit: 50)
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                hint("종목명 또는 코드를 입력하세요")
            } else if results.isEmpty {
                hint("검색 결과가 없습니다")
            } else {
                List(results, id: \.code) { r in
                    HStack {
                        Text(r.name)
                        Text(r.code).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { model.toggleWatch(r.code) } label: {
                            Image(systemName: model.isWatched(r.code) ? "star.fill" : "star")
                                .foregroundStyle(model.isWatched(r.code) ? Color.yellow : Color.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(model.isWatched(r.code) ? "관심 종목 제거" : "관심 종목 추가")
                    }
                }
                .listStyle(.plain)
            }
            Divider()
            Text("★ 는 현재 그룹(\(model.groupName(model.activeGroup)))에 추가됩니다")
                .font(.caption).foregroundStyle(.secondary).padding(8)
        }
        .frame(width: 460, height: 480)
        .onAppear { focused = true }
    }

    private func hint(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum StockSearch {
    struct Result { let code: String; let name: String }

    /// 이름/코드 부분 일치. 이름이 검색어로 시작하는 종목을 먼저 보여 준다.
    static func search(_ stocks: [String: StockInfo], query: String, limit: Int) -> [Result] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        var prefix: [Result] = []
        var rest: [Result] = []
        for (code, info) in stocks {
            let name = info.nameKr.lowercased()
            if name.hasPrefix(q) || code.hasPrefix(q) {
                prefix.append(Result(code: code, name: info.nameKr))
            } else if name.contains(q) || code.contains(q) {
                rest.append(Result(code: code, name: info.nameKr))
            }
        }
        let byName: (Result, Result) -> Bool = { $0.name == $1.name ? $0.code < $1.code : $0.name < $1.name }
        return Array((prefix.sorted(by: byName) + rest.sorted(by: byName)).prefix(limit))
    }
}
