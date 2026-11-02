import DeskKeiCore
import SwiftUI

/// 종목명/코드 검색 입력과 추천 목록. 입력이 비어 있고 포커스가 있으면 최근 종목을 보여 준다.
struct StockSearchField: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    @FocusState private var focused: Bool

    /// 현재 선택된 종목. 바뀌면(다른 경로로 선택돼도) 입력을 비운다.
    let selectedCode: String
    let recent: [RecentStock]
    /// 최근 종목 항목의 x 버튼을 눌렀을 때.
    let onRemoveRecent: (_ code: String) -> Void
    /// true 면 목록을 입력창 아래에 겹쳐 그린다(아래 내용을 밀지 않는다).
    var floating = false
    let onSelect: (_ code: String, _ name: String) -> Void

    private static let maxListHeight: CGFloat = 280

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            field
            if floating {
                // 높이 0 인 기준점 아래로 목록을 겹쳐 그려, 입력창 아래쪽으로만 열리게 한다.
                Color.clear.frame(height: 0)
                    .overlay(alignment: .topLeading) { suggestionList }
            } else {
                suggestionList
            }
        }
        .zIndex(1)
        .onChange(of: selectedCode) { _ in clear() }
    }

    private var field: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TextField("종목명 또는 코드 검색", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit {
                        if let first = suggestions.first { choose(first) }
                    }
                    .onExitCommand { clear() }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
        }
    }

    private struct Suggestion {
        let code: String
        let name: String
        let isRecent: Bool
    }

    private var suggestions: [Suggestion] {
        let results = StockSearch.search(model.stocks, query: query, limit: 8)
        if !results.isEmpty { return results.map { Suggestion(code: $0.code, name: $0.name, isRecent: false) } }
        guard focused, query.isEmpty else { return [] }
        return recent.map { Suggestion(code: $0.code, name: $0.name, isRecent: true) }
    }

    @ViewBuilder
    private var suggestionList: some View {
        let items = floating && !focused ? [] : suggestions
        if !items.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if items.first?.isRecent == true {
                        Text("최근 종목").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.top, 6)
                    }
                    ForEach(items, id: \.code) { row($0) }
                }
            }
            // 항목이 적으면 내용 높이만큼, 많으면 maxListHeight 까지만 열고 스크롤한다.
            .frame(maxHeight: Self.maxListHeight)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            .padding(.top, 4)
        }
    }

    private func row(_ s: Suggestion) -> some View {
        HStack(spacing: 0) {
            Button { choose(s) } label: {
                HStack {
                    Text(s.name)
                    Text(s.code).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if s.isRecent {
                Button { onRemoveRecent(s.code) } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("최근 종목에서 삭제")
            }
        }
    }

    private func choose(_ s: Suggestion) {
        onSelect(s.code, s.name)
        clear()
    }

    private func clear() {
        query = ""
        focused = false
    }
}
