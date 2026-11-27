import SwiftUI

/// 启动时的授权码门禁。只负责校验码，不参与任何定位/会话逻辑。
struct ActivationGateView: View {
    @ObservedObject var manager: ActivationManager
    @State private var code = ""
    @State private var errorMessage = ""

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.96, green: 0.97, blue: 1.0),
                    Color(red: 0.89, green: 0.93, blue: 1.0)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 22) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 54, weight: .semibold))
                    .foregroundStyle(RelocTheme.accentGradient)
                    .padding(.bottom, 4)

                Text("Reloc 授权验证")
                    .font(.title2.bold())
                    .foregroundStyle(.primary)

                Text("请输入授权码以继续使用。授权状态仅保存在本机，不影响定位功能。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                SecureField("授权码", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .onSubmit { verify() }
                    .padding(.horizontal, 8)

                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(RelocTheme.crimson)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                }

                RelocPrimaryButton(
                    title: "激活",
                    systemImage: "checkmark.seal.fill",
                    gradient: RelocTheme.accentGradient
                ) {
                    verify()
                }
                .padding(.horizontal, 8)

                Text("授权码由提供者发放。如需更换，可在源码中修改有效码列表。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(30)
            .relocGlassCard(cornerRadius: 28, padding: 20)
            .padding(.horizontal, 24)
        }
        .interactiveDismissDisabled(true)
    }

    private func verify() {
        if manager.activate(with: code) {
            RelocTheme.hapticSuccess()
        } else {
            errorMessage = "授权码无效，请检查后重试。"
            RelocTheme.hapticMedium()
        }
    }
}
