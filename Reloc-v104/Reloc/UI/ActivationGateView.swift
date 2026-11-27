import SwiftUI
import UIKit

/// 启动时的设备授权门禁。展示设备码、接收注册机签发的激活码。
/// 只负责授权校验，不参与任何定位 / 回环 / 配对逻辑。
struct ActivationGateView: View {
    @ObservedObject var manager: ActivationManager
    @State private var code = ""
    @State private var errorMessage = ""
    @State private var copied = false

    private let deviceCode: String

    init(manager: ActivationManager) {
        self.manager = manager
        self.deviceCode = manager.deviceCode
    }

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

            ScrollView {
                VStack(spacing: 18) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 46, weight: .semibold))
                        .foregroundStyle(RelocTheme.accentGradient)

                    Text("怪咖定位 · 设备授权")
                        .font(.title2.bold())

                    Text("把下方设备码发给管理员，用注册机生成激活码后粘贴到下面。一个激活码只对本机有效。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    deviceCodeCard

                    VStack(alignment: .leading, spacing: 6) {
                        Text("激活码").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $code)
                            .font(.system(.footnote, design: .monospaced))
                            .frame(height: 70)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                            )
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    if !errorMessage.isEmpty {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(RelocTheme.crimson)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    RelocPrimaryButton(
                        title: "激活",
                        systemImage: "checkmark.seal.fill",
                        gradient: RelocTheme.accentGradient
                    ) {
                        verify()
                    }

                    Text("激活状态保存在本机，不影响定位功能。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(22)
                .relocGlassCard(cornerRadius: 28, padding: 12)
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }
        }
        .interactiveDismissDisabled(true)
    }

    private var deviceCodeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("本机设备码")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = deviceCode
                    copied = true
                    RelocTheme.hapticLight()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        copied = false
                    }
                } label: {
                    Label(
                        copied ? "已复制" : "复制",
                        systemImage: copied ? "checkmark" : "doc.on.doc"
                    )
                    .font(.caption.weight(.semibold))
                }
            }

            Text(deviceCode)
                .font(.system(.subheadline, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(10)
        }
    }

    private func verify() {
        if manager.activate(with: code) {
            RelocTheme.hapticSuccess()
        } else {
            errorMessage = "激活码无效，或不是为本机设备码生成。"
            RelocTheme.hapticMedium()
        }
    }
}
