import DeskKeiCore
import SwiftUI

struct SettingsSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var version: String {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String else { return "개발 빌드" }
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("설정").font(.headline)

            row("앱 버전") { Text(version) }

            row("화면 모드") {
                Picker("화면 모드", selection: $model.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }

            row("주문 확인") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("주문 전 확인 팝업 표시", isOn: $model.confirmOrders)
                    Text("끄면 주문 버튼을 누르는 즉시 주문이 전송됩니다. 정정은 항상 확인합니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            row("종목 마스터") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Text("\(fmt(model.stocks.count))종목")
                        if let at = model.masterUpdatedAt {
                            Text("· \(at.formatted(.dateTime.year().month().day().hour().minute())) 갱신")
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 8) {
                        Button("지금 갱신") { Task { await model.refreshMaster() } }
                            .disabled(model.masterRefreshing)
                        if model.masterRefreshing { ProgressView().controlSize(.small) }
                    }
                    HStack(spacing: 10) {
                        Text("선물/옵션 \(fmt(model.futures.instruments.count))종목")
                        if let at = model.futuresUpdatedAt {
                            Text("· \(at.formatted(.dateTime.year().month().day().hour().minute())) 갱신")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let error = model.masterError {
                        Text(error).font(.caption).foregroundStyle(Color.up)
                    }
                }
            }

            HStack {
                Spacer()
                Button("닫기") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func row<V: View>(_ title: String, @ViewBuilder content: () -> V) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }
}
