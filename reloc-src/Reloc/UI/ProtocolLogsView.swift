import SwiftUI
import UIKit

struct ProtocolLogsView: View {
    @ObservedObject var viewModel: RelocViewModel
    @ObservedObject private var monitor: LiveCoreLocationMonitor
    @State private var filterText = ""
    @State private var categoryFilter: LogCategory = .all
    @State private var copiedBanner = false

    enum LogCategory: String, CaseIterable, Identifiable {
        case all = "全部"
        case nmea = "NMEA"
        case errors = "错误"
        var id: String { rawValue }
    }

    init(viewModel: RelocViewModel) {
        self.viewModel = viewModel
        self._monitor = ObservedObject(wrappedValue: viewModel.coreLocation)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private var filteredEvents: [ProtocolEvent] {
        let base: [ProtocolEvent]
        switch categoryFilter {
        case .all:
            base = viewModel.events
        case .nmea:
            base = viewModel.events.filter {
                $0.name.localizedCaseInsensitiveContains("location")
                    || $0.name.localizedCaseInsensitiveContains("nmea")
                    || $0.detail.localizedCaseInsensitiveContains("GP")
                    || $0.detail.localizedCaseInsensitiveContains("FFFA")
                    || $0.detail.localizedCaseInsensitiveContains("FFFB")
            }
        case .errors:
            base = viewModel.events.filter(\.isError)
        }

        let q = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return base }
        return base.filter {
            $0.name.lowercased().contains(q) || $0.detail.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                telemetryDashboard
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 10)

                HStack(spacing: 8) {
                    ForEach(LogCategory.allCases) { cat in
                        let selected = categoryFilter == cat
                        Button {
                            RelocTheme.hapticLight()
                            categoryFilter = cat
                        } label: {
                            Text(cat.rawValue)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(selected ? RelocTheme.accent : Color.secondary.opacity(0.12), in: Capsule())
                                .foregroundStyle(selected ? .white : .primary)
                        }
                    }
                    Spacer()
                    Text("\(filteredEvents.count) 条事件")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)

                Divider()

                if filteredEvents.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "waveform.path.ecg.rectangle")
                            .font(.system(size: 40))
                            .foregroundStyle(RelocTheme.accent.opacity(0.6))
                        Text("暂无协议事件")
                            .font(.headline)
                        Text("开始定位或连接验证后，这里会实时展示连接握手与 NMEA 数据流。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        List(filteredEvents) { event in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(event.isError ? RelocTheme.crimson : RelocTheme.accent)
                                        .frame(width: 6, height: 6)
                                    Text(event.name)
                                        .font(.caption.monospaced().weight(.semibold))
                                        .foregroundStyle(event.isError ? RelocTheme.crimson : RelocTheme.accent)
                                    Spacer()
                                    Text(Self.timeFormatter.string(from: event.timestamp))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                Text(event.detail)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(event.isError ? RelocTheme.crimson : .primary)
                                    .textSelection(.enabled)
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .id(event.id)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 5, leading: 14, bottom: 5, trailing: 14))
                        }
                        .listStyle(.plain)
                        .onChange(of: viewModel.events.count) { _, _ in
                            if let last = filteredEvents.last {
                                withAnimation {
                                    proxy.scrollTo(last.id, anchor: .bottom)
                                }
                            }
                        }
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("定位实测与日志")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $filterText, prompt: "筛选事件（如 FFFA / acknowledged）")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        UIPasteboard.general.string = viewModel.exportedLogsText()
                        RelocTheme.hapticLight()
                        copiedBanner = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            copiedBanner = false
                        }
                    } label: {
                        Image(systemName: copiedBanner ? "checkmark" : "doc.on.doc")
                    }
                    .disabled(viewModel.events.isEmpty)

                    Button(role: .destructive) {
                        viewModel.clearLogs()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(viewModel.events.isEmpty)
                }
            }
        }
    }

    private var telemetryDashboard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SettingsIconBadge(systemName: "sensor.tag.radiowaves.forward.fill", color: monitor.isMonitoring ? RelocTheme.emerald : RelocTheme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("CoreLocation 实时实测")
                        .font(.subheadline.weight(.semibold))
                    Text(monitor.isMonitoring ? "正在实时读取系统上报定位来源" : "验证系统是否识别为外设 GPS")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    RelocTheme.hapticLight()
                    if monitor.isMonitoring {
                        monitor.stop()
                    } else {
                        monitor.requestAndStart()
                    }
                } label: {
                    Text(monitor.isMonitoring ? "停止" : "开始实测")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            (monitor.isMonitoring ? RelocTheme.crimson : RelocTheme.accent).opacity(0.16),
                            in: Capsule()
                        )
                        .foregroundStyle(monitor.isMonitoring ? RelocTheme.crimson : RelocTheme.accent)
                }
            }

            if let t = monitor.latest {
                HStack(spacing: 8) {
                    telemetryMetric(label: "纬度 / 经度", value: String(format: "%.5f, %.5f", t.latitude, t.longitude))
                    telemetryMetric(label: "精度 / 海拔", value: String(format: "±%.1fm · %.0fm", t.horizontalAccuracy, t.altitude))
                }

                HStack(spacing: 8) {
                    flagBadge(
                        title: "软件模拟",
                        key: "isSimulatedBySoftware",
                        value: t.isSimulatedBySoftware,
                        goodWhen: false
                    )
                    flagBadge(
                        title: "外设来源",
                        key: "isProducedByAccessory",
                        value: t.isProducedByAccessory,
                        goodWhen: true
                    )
                }
            } else {
                Text("点击右上角「开始实测」，即可实时查看 iOS `sourceInformation` 中的软件模拟与外设定位标记。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.8)
        )
    }

    private func telemetryMetric(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func flagBadge(title: String, key: String, value: Bool?, goodWhen: Bool) -> some View {
        let text = value.map { $0 ? "true" : "false" } ?? "nil"
        let tint: Color = {
            guard let v = value else { return .secondary }
            return (v == goodWhen) ? RelocTheme.emerald : RelocTheme.crimson
        }()
        return HStack(spacing: 5) {
            Image(systemName: value == goodWhen ? "checkmark.circle.fill" : (value == nil ? "questionmark.circle" : "exclamationmark.triangle.fill"))
                .font(.caption2)
            VStack(alignment: .leading, spacing: 0) {
                Text("\(title): \(text)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                Text(key)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .foregroundStyle(tint)
    }
}
