import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Redesigned loopback & on-device pairing configuration (preserving the Reukix/retools 3-step structure
/// without any MFi identity UI) + PiP floating pairing guide + Roam-Control-style preferences.
struct ConfigurationView: View {
    @ObservedObject var viewModel: RelocViewModel
    @ObservedObject private var pairing = DevicePairingCoordinator.shared
    @ObservedObject private var pip = PairingPiPPresenter.shared
    @Environment(\.scenePhase) private var scenePhase

    @State private var showImporter = false
    @State private var copiedPinToast = false

    private var serviceStateText: String {
        if viewModel.connectionVerified { return "已连接" }
        if viewModel.isVerifyingConnection { return "验证中" }
        return viewModel.connectionCheckFailed ? "连接失败" : "待验证"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    heroHeaderCard
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                        .listRowBackground(Color.clear)
                }

                Section {
                    HStack(spacing: 12) {
                        SettingsIconBadge(systemName: "network", color: RelocTheme.accent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("外部代理提供本地回环")
                                .font(.subheadline.weight(.semibold))
                            Text("请先在代理软件中启用 \(viewModel.host) 的回环映射，再完成下方配对与验证。Reloc 不创建 VPN。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                } header: {
                    stepSectionHeader(number: "01", title: "回环通路")
                }

                Section {
                    HStack {
                        SettingsIconBadge(
                            systemName: viewModel.pairingStatus.isLoaded ? "checkmark.seal.fill" : "iphone.radiowaves.left.and.right",
                            color: viewModel.pairingStatus.isLoaded ? RelocTheme.emerald : RelocTheme.amber
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text("配对记录")
                                .font(.subheadline.weight(.medium))
                            Text(viewModel.pairingStatus.isLoaded
                                 ? "已保存（\(viewModel.pairingStatus.kind?.rawValue ?? "")）"
                                 : "尚未配置这台 iPhone")
                                .font(.caption)
                                .foregroundStyle(viewModel.pairingStatus.isLoaded ? RelocTheme.emerald : .secondary)
                        }
                        Spacer()
                    }

                    if #available(iOS 27.0, *) {
                        if !pairing.isRunning {
                            Button {
                                RelocTheme.hapticMedium()
                                viewModel.startDevicePairing()
                            } label: {
                                HStack {
                                    Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                                        .font(.subheadline.weight(.semibold))
                                    Text(viewModel.pairingStatus.isLoaded ? "重新配对这台 iPhone" : "一键配对这台 iPhone")
                                        .font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Text("悬浮窗指引")
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(RelocTheme.accent.opacity(0.14), in: Capsule())
                                }
                            }
                            .disabled(viewModel.isVerifyingConnection || viewModel.snapshot.isRunning)
                        }
                    } else {
                        Text("此系统版本请导入已有的配对文件。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if pairing.isRunning || pairing.error != nil {
                        activePairingGuideCard
                    }

                    Button {
                        showImporter = true
                    } label: {
                        Label("导入已有配对文件", systemImage: "square.and.arrow.down")
                    }
                    .disabled(pairing.isRunning || viewModel.isVerifyingConnection || viewModel.snapshot.isRunning)

                    if viewModel.pairingStatus.isLoaded {
                        Button("移除已保存配对记录", role: .destructive) {
                            viewModel.removePairingFile()
                        }
                        .disabled(pairing.isRunning || viewModel.isVerifyingConnection || viewModel.snapshot.isRunning)
                    }
                } header: {
                    stepSectionHeader(number: "02", title: "设备配对")
                } footer: {
                    Text("开始配对后会自动启用画中画悬浮指引窗：切到「设置 → 隐私与安全性 → 开发者模式」点击「与 Reloc 配对」，即可在悬浮窗中实时查看 6 位配对码。")
                }

                Section {
                    HStack(spacing: 10) {
                        if viewModel.isVerifyingConnection {
                            ProgressView().controlSize(.small)
                        } else {
                            SettingsIconBadge(
                                systemName: viewModel.connectionVerified
                                    ? "checkmark"
                                    : (viewModel.connectionCheckFailed ? "exclamationmark" : "link"),
                                color: viewModel.connectionVerified
                                    ? RelocTheme.emerald
                                    : (viewModel.connectionCheckFailed ? RelocTheme.amber : .secondary)
                            )
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(viewModel.deviceConnectionStatus)
                                .font(.subheadline.weight(.medium))
                                .textSelection(.enabled)
                            if let port = viewModel.discoveredDevicePort {
                                Text("已连接回环端口：\(port)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Button {
                        RelocTheme.hapticLight()
                        viewModel.testConnection(silent: false)
                    } label: {
                        Label(
                            viewModel.connectionVerified ? "重新检测连接" : "检测设备连接",
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                    }
                    .disabled(!viewModel.pairingStatus.isLoaded || viewModel.isVerifyingConnection || pairing.isRunning || viewModel.snapshot.isRunning)

                    if !viewModel.deviceUDID.isEmpty {
                        LabeledContent("设备 UDID") {
                            Text(viewModel.deviceUDID)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                } header: {
                    stepSectionHeader(number: "03", title: "连接验证")
                } footer: {
                    Text("自动发现 Remote Pairing 服务并用配对记录验证广播身份，最终通过设备服务确认连接可用。")
                }

                Section("定位选项") {
                    Stepper(value: $viewModel.intervalSeconds, in: 1.0...10.0, step: 0.5) {
                        Label {
                            Text(String(format: "NMEA 发送间隔 · %.1f 秒", viewModel.intervalSeconds))
                                .monospacedDigit()
                        } icon: {
                            SettingsIconBadge(systemName: "timer", color: RelocTheme.accent)
                        }
                    }

                    Picker(selection: $viewModel.durationSeconds) {
                        Text("持续运行").tag(0.0)
                        Text("60 秒").tag(60.0)
                        Text("180 秒").tag(180.0)
                        Text("600 秒").tag(600.0)
                        Text("1800 秒").tag(1800.0)
                    } label: {
                        Label {
                            Text("会话时长")
                        } icon: {
                            SettingsIconBadge(systemName: "hourglass", color: .purple)
                        }
                    }

                    Toggle(isOn: $viewModel.gcj02CorrectionEnabled) {
                        Label {
                            Text("中国大陆地图 GCJ-02 纠偏")
                        } icon: {
                            SettingsIconBadge(systemName: "globe.asia.australia.fill", color: RelocTheme.emerald)
                        }
                    }

                    Toggle(isOn: $viewModel.microJitterEnabled) {
                        Label {
                            Text("自然微漂移（±0.6m GPS 抖动）")
                        } icon: {
                            SettingsIconBadge(systemName: "dot.radiowaves.left.and.right", color: RelocTheme.amber)
                        }
                    }

                    Toggle(isOn: $viewModel.backgroundKeepAliveEnabled) {
                        Label {
                            Text("后台保活（切换地图不断连）")
                        } icon: {
                            SettingsIconBadge(systemName: "bolt.shield.fill", color: .teal)
                        }
                    }
                }

                Section("地图与外观") {
                    Picker(selection: $viewModel.appearanceMode) {
                        ForEach(AppAppearanceMode.allCases) { m in
                            Text(m.title).tag(m)
                        }
                    } label: {
                        Label {
                            Text("外观主题")
                        } icon: {
                            SettingsIconBadge(systemName: "circle.lefthalf.filled", color: .gray)
                        }
                    }

                    Picker(selection: $viewModel.mapStyle) {
                        ForEach(MapDisplayStyle.allCases) { s in
                            Text(s.title).tag(s)
                        }
                    } label: {
                        Label {
                            Text("默认地图样式")
                        } icon: {
                            SettingsIconBadge(systemName: "map.fill", color: RelocTheme.accent)
                        }
                    }
                }
            }
            .navigationTitle("设备配对与连接")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                viewModel.importDiscoveredPairing()
                await viewModel.verifyConnectionIfNeeded()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    viewModel.importDiscoveredPairing()
                    Task {
                        await viewModel.verifyConnectionIfNeeded()
                    }
                }
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.data, .propertyList, .xml, .item],
                allowsMultipleSelection: false
            ) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                viewModel.importPairingFile(url: url)
            }
        }
    }

    private var heroHeaderCard: some View {
        let ready = viewModel.connectionVerified
        let accent: Color = ready ? RelocTheme.emerald : (viewModel.pairingStatus.isLoaded ? RelocTheme.amber : RelocTheme.accent)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(accent.opacity(0.18))
                        .frame(width: 48, height: 48)
                    Image(systemName: ready ? "checkmark.shield.fill" : "antenna.radiowaves.left.and.right")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(accent)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(ready ? "设备回环已就绪" : "配置本机回环连接")
                        .font(.headline)
                    Text(ready ? "可直接返回「定位」标签页开始定格定位" : "依次完成回环通路、本机配对与连接验证")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                MetricTile(
                    title: "配对状态",
                    value: viewModel.pairingStatus.isLoaded ? "已保存" : "未配置",
                    tint: viewModel.pairingStatus.isLoaded ? RelocTheme.emerald : .secondary
                )
                MetricTile(
                    title: "设备服务",
                    value: serviceStateText,
                    tint: ready ? RelocTheme.emerald : (viewModel.connectionCheckFailed ? RelocTheme.amber : .secondary)
                )
                MetricTile(
                    title: "回环主机",
                    value: viewModel.host,
                    tint: RelocTheme.accent
                )
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(accent.opacity(0.25), lineWidth: 1)
        )
    }

    private var activePairingGuideCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if pairing.isRunning {
                HStack(spacing: 6) {
                    pairingStepPill(num: 1, title: "广播就绪", active: pairing.stepIndex >= 1, current: pairing.stepIndex == 1)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    pairingStepPill(num: 2, title: "输入配对码", active: pairing.stepIndex >= 2, current: pairing.stepIndex == 2)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    pairingStepPill(num: 3, title: "保存完成", active: pairing.stepIndex >= 3, current: pairing.stepIndex == 3)
                }
            }

            Text(pairing.status)
                .font(.footnote.weight(.medium))
                .foregroundStyle(pairing.error != nil ? RelocTheme.crimson : .primary)
                .textSelection(.enabled)

            if let pin = pairing.pin {
                let chars = Array(pin)
                HStack(spacing: 6) {
                    ForEach(Array(chars.enumerated()), id: \.offset) { idx, ch in
                        Text(String(ch))
                            .font(.system(size: 26, weight: .bold, design: .monospaced))
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(RelocTheme.amber.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(RelocTheme.amber.opacity(0.45), lineWidth: 1)
                            )
                        if idx == 2 && chars.count == 6 {
                            Spacer().frame(width: 4)
                        }
                    }
                }

                Button {
                    UIPasteboard.general.string = pin
                    RelocTheme.hapticLight()
                    copiedPinToast = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedPinToast = false }
                } label: {
                    Label(copiedPinToast ? "已复制配对码" : "复制配对码", systemImage: copiedPinToast ? "checkmark" : "doc.on.doc")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(RelocTheme.amber.opacity(0.16), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)
                .foregroundStyle(RelocTheme.amber)
            }

            if pairing.isRunning {
                if pip.isSupported {
                    Button {
                        RelocTheme.hapticLight()
                        pairing.toggleFloatingGuide()
                    } label: {
                        Label(pip.isActive ? "收起悬浮指引窗" : "弹出悬浮指引窗", systemImage: pip.isActive ? "pip.exit" : "pip.enter")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(RelocTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(RelocTheme.accent)
                }

                Button("取消配对", role: .destructive) {
                    pairing.cancel()
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(RelocTheme.crimson)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 4)
    }

    private func pairingStepPill(num: Int, title: String, active: Bool, current: Bool) -> some View {
        HStack(spacing: 4) {
            Text("\(num)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .frame(width: 16, height: 16)
                .background(active ? RelocTheme.accent : Color.secondary.opacity(0.25), in: Circle())
                .foregroundStyle(active ? .white : .secondary)
            Text(title)
                .font(.system(size: 11, weight: current ? .bold : .medium))
                .foregroundStyle(active ? .primary : .secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(current ? RelocTheme.accent.opacity(0.14) : Color.clear, in: Capsule())
    }

    private func stepSectionHeader(number: String, title: String) -> some View {
        HStack(spacing: 6) {
            Text(number)
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RelocTheme.accent.opacity(0.15), in: Capsule())
                .foregroundStyle(RelocTheme.accent)
            Text(title)
                .font(.caption.weight(.bold))
        }
    }
}

private struct MetricTile: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit().weight(.bold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}
