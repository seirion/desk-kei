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
    /// 검색 결과를 직접 만들 때(기본은 주식 종목 마스터 검색)
    var source: ((_ query: String) -> [(code: String, name: String)])?
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
        let results = source?(query) ?? StockSearch.search(model.stocks, query: query, limit: 8).map { (code: $0.code, name: $0.name) }
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

/// 지금 보는 종목을 뺀 최근 종목 5개 바로가기. 누르면 그 종목으로 이동한다.
struct RecentStockChips: View {
    static let count = 5

    let selectedCode: String
    let recent: [RecentStock]
    /// 버튼 하나의 최대 너비. 이름이 길면 이 폭에서 말줄임으로 줄어든다.
    var maxChipWidth: CGFloat = 90
    let onSelect: (_ code: String, _ name: String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(recent.filter { $0.code != selectedCode }.prefix(Self.count), id: \.code) { stock in
                Button { onSelect(stock.code, stock.name) } label: {
                    Text(stock.name)
                        .font(.callout)
                        .lineLimit(1)
                        .frame(maxWidth: maxChipWidth)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("\(stock.name) \(stock.code)")
            }
        }
        // 자리가 모자라면 버튼 이름이 말줄임으로 줄어든다.
        .fixedSize(horizontal: false, vertical: true)
    }
}
