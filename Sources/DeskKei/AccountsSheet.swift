import DeskKeiCore
import SwiftUI

/// KIS 계정 목록 / 추가 / 편집 / 삭제 / 전환
struct AccountsSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    /// nil = 목록, "" = 신규, 그 외 = 편집 중인 계정 이름
    @State private var editing: String?
    @State private var form = KisAccount()
    @State private var formError: String?
    @State private var deleting: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button { editing == nil ? dismiss() : (editing = nil) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Divider()

            if editing == nil { list } else { editor }
        }
        .frame(width: 440, height: 420)
        .alert("계정 삭제", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("삭제", role: .destructive) { if let d = deleting { model.deleteAccount(d) } }
            Button("취소", role: .cancel) {}
        } message: {
            Text("\"\(deleting ?? "")\" 계정을 삭제할까요?")
        }
    }

    private var title: String {
        switch editing {
        case nil: return "KIS 계정 관리"
        case "": return "계정 추가"
        default: return "계정 편집"
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

    private func subtitle(_ acc: KisAccount) -> String {
        if !acc.accountNo.isEmpty { return acc.accountNo }
        if !acc.userId.isEmpty { return acc.userId }
        return String(acc.appKey.prefix(8)) + "…"
    }

    // MARK: 편집

    private var editor: some View {
        VStack(spacing: 0) {
            Form {
                Text("입력한 정보는 이 Mac에만 저장되며, 한국투자증권 API 외에는 전송되지 않습니다.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("계정 이름 *", text: $form.name, prompt: Text("예) 내 계좌"))
                TextField("계좌번호", text: $form.accountNo, prompt: Text("예) 00000000-01"))
                TextField("사용자 ID", text: $form.userId, prompt: Text("KIS 사용자 ID (HTS ID)"))
                TextField("App Key *", text: $form.appKey)
                SecureField("App Secret *", text: $form.appSecret)
                if let formError { Text(formError).foregroundStyle(Color.up).font(.callout) }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("취소") { editing = nil }
                Button("저장", action: save).keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
    }

    private func open(_ acc: KisAccount?) {
        form = acc ?? KisAccount()
        formError = nil
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
