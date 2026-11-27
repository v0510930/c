import SwiftUI
import UIKit

struct ContentView: View {
    @State private var deviceCode: String = ""
    @State private var resultCode: String? = nil
    @State private var showCopied: Bool = false
    @State private var showInvalid: Bool = false

    private let accent = LinearGradient(
        colors: [Color(hex: "5B7CFA"), Color(hex: "8A5BFA")],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [Color(hex: "0E1220"), Color(hex: "151B31"), Color(hex: "0E1220")],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 22) {
                        header
                        inputCard
                        if let code = resultCode { resultCard(code) }
                        hintCard
                        authorCard
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Reloc 注册机")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 20)
                    .fill(accent)
                    .frame(width: 72, height: 72)
                Image(systemName: "key.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundColor(.white)
            }
            Text("设备绑定激活码生成")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white.opacity(0.65))
        }
        .padding(.top, 8)
    }

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("设备码", systemImage: "iphone")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(0.8))

            TextField("RLC-XXXXXX-XXXXXX-XXXXXX-XXXXXX", text: $deviceCode)
                .font(.system(size: 16, weight: .medium, design: .monospaced))
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .padding(14)
                .background(Color.white.opacity(0.06))
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(showInvalid ? Color.red.opacity(0.8) : Color.white.opacity(0.12), lineWidth: 1)
                )
                .onChange(of: deviceCode) { _, _ in
                    showInvalid = false
                }

            if showInvalid {
                Text("请输入有效设备码（形如 RLC-XXXXXX-...）")
                    .font(.footnote)
                    .foregroundColor(.red.opacity(0.9))
            }

            Button {
                generate()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "wand.and.stars")
                    Text("生成激活码")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(14)
                .background(accent)
                .foregroundColor(.white)
                .cornerRadius(12)
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .background(Color.white.opacity(0.04))
        .cornerRadius(18)
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    private func resultCard(_ code: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("激活码", systemImage: "checkmark.seal.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.green)

            Text(code)
                .font(.system(size: 17, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color.black.opacity(0.3))
                .cornerRadius(12)

            Button {
                UIPasteboard.general.string = code
                showCopied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showCopied = false }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: showCopied ? "checkmark.circle.fill" : "doc.on.doc")
                    Text(showCopied ? "已复制" : "复制激活码")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(13)
                .background(showCopied ? Color.green.opacity(0.25) : Color.white.opacity(0.1))
                .foregroundColor(showCopied ? .green : .white)
                .cornerRadius(12)
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .background(Color.green.opacity(0.06))
        .cornerRadius(18)
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.green.opacity(0.25), lineWidth: 1))
    }

    private var hintCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("使用说明", systemImage: "info.circle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(0.8))
            Text("1. 让用户打开 Reloc，复制启动页显示的 RLC- 设备码。\n2. 粘贴到上方输入框，点「生成激活码」。\n3. 复制激活码发给用户，在 Reloc 激活页输入即可。\n4. 一机一码，只对生成它的那台设备有效。")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.55))
                .lineSpacing(4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.white.opacity(0.03))
        .cornerRadius(16)
    }

    private var authorCard: some View {
        VStack(spacing: 4) {
            Text("作者：洛巴牛")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(0.75))
            Button {
                UIPasteboard.general.string = "v0510930"
                showCopied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showCopied = false }
            } label: {
                HStack(spacing: 5) {
                    Text("微信：v0510930")
                        .font(.system(size: 13))
                    Image(systemName: showCopied ? "checkmark.circle.fill" : "doc.on.doc")
                        .font(.system(size: 12))
                }
                .foregroundColor(Color(hex: "8FA8FF"))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }

    private func generate() {
        guard !deviceCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showInvalid = true
            return
        }
        guard let code = KeygenEngine.generate(from: deviceCode), code.count == 26 else {
            showInvalid = true
            resultCode = nil
            return
        }
        resultCode = code
        showInvalid = false
        endEditing()
    }

    private func endEditing() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        (r, g, b) = ((int >> 16) & 0xff, (int >> 8) & 0xff, int & 0xff)
        self.init(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }
}
