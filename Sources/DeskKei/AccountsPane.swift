import DeskKeiCore
import SwiftUI

/// 증권사 계정 목록 / 추가 / 편집 / 삭제 / 전환 (설정 화면의 계정 탭)
struct AccountsPane: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    /// nil = 목록, "" = 신규, 그 외 = 편집 중인 계정 이름
    @State private var editing: String?
    @Binding var isEditing: Bool
    @State private var form = BrokerAccount()
    @State private var formError: String?
    @State private var deleting: String?
    @State private var verifyState: VerifyState = .idle

    private enum VerifyState: Equatable {
        case idle, checking, ok, failed(String)
    }

    var body: some View {
        Group { if editing == nil { list } else { editor } }
            .onChange(of: editing) { isEditing = $0 != nil }
            .alert("계정 삭제", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("삭제", role: .destructive) { if let d = deleting { model.deleteAccount(d) } }
                Button("취소", role: .cancel) {}
            } message: {
                Text("\"\(deleting ?? "")\" 계정을 삭제할까요?")
            }
    }

    // MARK: 목록

    private var list: some View {
        VStack(spacing: 0) {
            if model.accounts.isEmpty {
                Text("등록된 계정이 없습니다.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.accounts) { acc in
                    let active = acc.name == model.account.name
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(acc.name).fontWeight(.medium)
                                Badge(text: acc.broker.displayName, color: .gray)
                                if active { Badge(text: "사용 중", color: .accentColor) }
                            }
                            Text(subtitle(acc)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { open(acc) } label: { Image(systemName: "pencil") }.buttonStyle(.borderless)
                        Button { deleting = acc.name } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).foregroundStyle(Color.up)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.activateAccount(acc.name)
                        dismiss()
                    }
                }
            }
            marketAccountRow
            Divider()
            HStack {
                Text("계정을 클릭하면 해당 계정으로 전환됩니다.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("닫기") { dismiss() }
                Button("+ 계정 추가") { open(nil) }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
    }

    /// 사용 중인 계정이 KIS 가 아니면 시세를 받을 KIS 계정을 알려 주고, 둘 이상이면 고르게 한다.
    @ViewBuilder private var marketAccountRow: some View {
        if model.needsMarketAccount {
            Text("시세·호가를 보려면 한국투자증권 계정을 등록해 주세요. \(model.account.broker.displayName) 계정은 시세를 받지 못합니다.")
                .font(.caption).foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.bottom, 8)
        } else if model.usesSeparateMarketAccount, let market = model.marketAccount {
            HStack {
                Text("시세 계정").font(.caption).foregroundStyle(.secondary)
                if model.kisAccounts.count > 1 {
                    Picker("", selection: Binding(get: { market.name }, set: { model.setMarketAccount($0) })) {
                        ForEach(model.kisAccounts) { Text($0.name).tag($0.name) }
                    }
                    .labelsHidden().frame(width: 160)
                } else {
                    Text(market.name).font(.caption)
                }
                Text("시세·호가·차트는 이 한국투자증권 계정의 키로 받습니다.").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.bottom, 8)
        }
    }

    private func subtitle(_ acc: BrokerAccount) -> String {
        if !acc.accountNo.isEmpty { return acc.accountNo }
        if !acc.userId.isEmpty { return acc.userId }
        return String(acc.appKey.prefix(8)) + "…"
    }

    // MARK: 편집

    private var editor: some View {
        VStack(spacing: 0) {
            Form {
                Text("입력한 정보는 이 Mac에만 저장되며, \(form.broker.apiHostNote) 외에는 전송되지 않습니다.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("증권사 *", selection: $form.broker) {
                    ForEach(Broker.allCases) { Text($0.displayName).tag($0) }
                }
                // 이미 있는 계정의 증권사는 바꿀 수 없다: 입력한 키가 그 증권사 것이다.
                .disabled(editing?.isEmpty == false)
                if !form.broker.supportsTrading {
                    Text("\(form.broker.displayName) 계정은 지금 자산 조회만 지원합니다.")
                        .font(.caption).foregroundStyle(.orange)
                }
                TextField("계정 이름 *", text: $form.name, prompt: Text("예) 내 계좌"))
                TextField(form.broker.requiresAccountNo ? "계좌번호 *" : "계좌번호", text: $form.accountNo, prompt: Text("예) 00000000-01"))
                if form.broker.usesUserId {
                    TextField("사용자 ID", text: $form.userId, prompt: Text("KIS 사용자 ID (HTS ID)"))
                }
                TextField("App Key *", text: $form.appKey)
                SecureField("\(form.broker.secretLabel) *", text: $form.appSecret)
                if form.broker.requiresPassword {
                    SecureField("계좌 비밀번호 *", text: $form.password)
                }
                if let formError { Text(formError).foregroundStyle(Color.up).font(.callout) }
            }
            .formStyle(.grouped)
            // 입력값이 바뀌면 이전 확인 결과는 무효다.
            .onChange(of: form) { _ in verifyState = .idle }
            Divider()
            HStack {
                verifyStatus
                Spacer()
                Button("연결 확인", action: verify).disabled(verifyState == .checking)
                Button("취소") { editing = nil }.keyboardShortcut(.cancelAction)
                Button("저장", action: save).keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
    }

    @ViewBuilder private var verifyStatus: some View {
        switch verifyState {
        case .idle: EmptyView()
        case .checking: ProgressView().controlSize(.small)
        case .ok: Label("연결됨", systemImage: "checkmark.circle.fill").foregroundStyle(Color.green).font(.callout)
        case .failed(let message):
            Text(message).foregroundStyle(Color.up).font(.caption).lineLimit(2)
                .frame(maxWidth: 220, alignment: .leading)
        }
    }

    private func verify() {
        let acc = form
        verifyState = .checking
        Task {
            do {
                try await model.verifyAccount(acc)
                if acc == form { verifyState = .ok }
            } catch {
                if acc == form { verifyState = .failed(error.localizedDescription) }
            }
        }
    }

    private func open(_ acc: BrokerAccount?) {
        form = acc ?? BrokerAccount()
        formError = nil
        verifyState = .idle
        editing = acc?.name ?? ""
    }

    private func save() {
        do {
            try model.saveAccount(form, replacing: editing?.isEmpty == false ? editing : nil)
            editing = nil
            // 사용 중인 계정을 새로 만들거나 고쳤으면 자격 증명이 바뀌었으므로 세션을 다시 시작한다.
            let saved = form.name.trimmingCharacters(in: .whitespaces)
            if saved == model.account.name { model.activateAccount(saved) }
        } catch {
            formError = error.localizedDescription
        }
    }
}
