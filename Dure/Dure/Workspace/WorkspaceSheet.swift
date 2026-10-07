import SwiftUI

/// 새 워크스페이스 / 이름 바꾸기. 둘 다 이름 한 칸이라 시트 하나로 쓴다.
struct WorkspaceSheet: View {

    enum Mode: Identifiable {
        case create
        case rename(Workspace)

        var id: String {
            switch self {
            case .create: "create"
            case .rename(let w): "rename-\(w.id)"
            }
        }
    }

    let mode: Mode
    let onDone: (String, AgentKind) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var kind: AgentKind = .claude

    init(mode: Mode, onDone: @escaping (String, AgentKind) -> Void) {
        self.mode = mode
        self.onDone = onDone
        if case .rename(let w) = mode {
            _name = State(initialValue: w.name)
        } else {
            _name = State(initialValue: "")
        }
    }

    private var isCreate: Bool {
        if case .create = mode { return true } else { return false }
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isCreate ? "새 워크스페이스" : "이름 바꾸기").font(.headline)
            TextField("이름 (예: 모바일 로그인 개편)", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            if isCreate {
                // 기본 CLI 는 만들 때 정한다 (설계문서 8절). 나중에 사이드바에서도 바꿀 수 있다.
                Picker("기본 CLI", selection: $kind) {
                    ForEach(AgentKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
            }
            HStack {
                Spacer()
                Button("취소", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isCreate ? "만들기" : "저장", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private func submit() {
        guard !trimmed.isEmpty else { return }
        onDone(trimmed, kind)
        dismiss()
    }
}
