import SwiftUI
import UIKit

struct ConfigurationView: View {
    @ObservedObject var viewModel: RelocViewModel
    @Environment(\.openURL) private var openURL
    @State private var copiedPrefsURL = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $viewModel.intervalSeconds, in: 1.0...10.0, step: 0.5) {
                        Label {
                            Text(L10n.format("settings.nmea_interval", viewModel.intervalSeconds))
                                .monospacedDigit()
                        } icon: {
                            SettingsIconBadge(systemName: "timer", color: RelocTheme.accent)
                        }
                    }

                    Picker(selection: $viewModel.durationSeconds) {
                        Text(L10n.tr("settings.duration.continuous")).tag(0.0)
                        Text(L10n.format("settings.duration.seconds", 60)).tag(60.0)
                        Text(L10n.format("settings.duration.seconds", 180)).tag(180.0)
                        Text(L10n.format("settings.duration.seconds", 600)).tag(600.0)
                        Text(L10n.format("settings.duration.seconds", 1800)).tag(1800.0)
                        Text(L10n.format("settings.duration.hours", 1)).tag(3600.0)
                        Text(L10n.format("settings.duration.hours", 2)).tag(7200.0)
                        Text(L10n.format("settings.duration.hours", 4)).tag(14400.0)
                        Text(L10n.format("settings.duration.hours", 8)).tag(28800.0)
                    } label: {
                        Label {
                            Text(L10n.tr("settings.duration"))
                        } icon: {
                            SettingsIconBadge(systemName: "hourglass", color: .purple)
                        }
                    }

                    Toggle(isOn: $viewModel.gcj02CorrectionEnabled) {
                        Label {
                            Text(L10n.tr("settings.gcj02"))
                        } icon: {
                            SettingsIconBadge(systemName: "globe.asia.australia.fill", color: RelocTheme.emerald)
                        }
                    }

                    Toggle(isOn: $viewModel.microJitterEnabled) {
                        Label {
                            Text(L10n.tr("settings.micro_jitter"))
                        } icon: {
                            SettingsIconBadge(systemName: "dot.radiowaves.left.and.right", color: RelocTheme.amber)
                        }
                    }

                    HStack(spacing: 10) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L10n.tr("settings.background_mode.title"))
                                Text(
                                    viewModel.isAlwaysLocationAuthorized
                                        ? L10n.tr("settings.background_mode.always")
                                        : L10n.tr("settings.background_mode.upgrade_hint")
                                )
                                .font(.caption)
                                .foregroundStyle(viewModel.isAlwaysLocationAuthorized ? .secondary : RelocTheme.amber)
                            }
                        } icon: {
                            SettingsIconBadge(
                                systemName: "bolt.shield.fill",
                                color: viewModel.isAlwaysLocationAuthorized ? RelocTheme.emerald : RelocTheme.amber
                            )
                        }
                        Spacer()
                        if !viewModel.isAlwaysLocationAuthorized {
                            Button(L10n.tr("settings.background_mode.action")) {
                                viewModel.openAppSettings()
                            }
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.borderless)
                            .foregroundStyle(RelocTheme.accent)
                        }
                    }
                } header: {
                    Text(L10n.tr("settings.section.location"))
                } footer: {
                    Text(L10n.tr("settings.background_mode.footer"))
                }

                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.tr("intent.start_favorite.title"))
                                .font(.subheadline.weight(.semibold))
                            Text(L10n.tr("settings.shortcuts.start_summary"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        SettingsIconBadge(systemName: "location.north.circle.fill", color: RelocTheme.accent)
                    }

                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.tr("intent.stop.title"))
                                .font(.subheadline.weight(.semibold))
                            Text(L10n.tr("settings.shortcuts.stop_summary"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        SettingsIconBadge(systemName: "stop.circle.fill", color: RelocTheme.crimson)
                    }

                    Button {
                        if let url = URL(string: "shortcuts://") {
                            openURL(url)
                        }
                    } label: {
                        HStack {
                            Label {
                                Text(L10n.tr("settings.shortcuts.open_app"))
                                    .foregroundStyle(.primary)
                            } icon: {
                                SettingsIconBadge(systemName: "square.stack.3d.up.fill", color: .indigo)
                            }
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Button {
                        UIPasteboard.general.string = "prefs:root=Privacy&path=LOCATION"
                        RelocTheme.hapticLight()
                        copiedPrefsURL = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                            copiedPrefsURL = false
                        }
                    } label: {
                        HStack {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(L10n.tr("settings.shortcuts.copy_prefs_title"))
                                        .foregroundStyle(.primary)
                                    Text("prefs:root=Privacy&path=LOCATION")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                SettingsIconBadge(systemName: "link", color: .gray)
                            }
                            Spacer()
                            if copiedPrefsURL {
                                Text(L10n.tr("settings.shortcuts.copied"))
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(RelocTheme.emerald)
                            } else {
                                Image(systemName: "doc.on.doc")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                } header: {
                    Text(L10n.tr("settings.section.shortcuts"))
                } footer: {
                    Text(L10n.tr("settings.shortcuts.footer"))
                }

                Section {
                    Picker(selection: $viewModel.appLanguage) {
                        ForEach(AppLanguage.allCases) { lang in
                            Text(lang.title).tag(lang)
                        }
                    } label: {
                        Label {
                            Text(L10n.tr("settings.language"))
                        } icon: {
                            SettingsIconBadge(systemName: "character.bubble.fill", color: .indigo)
                        }
                    }

                    Picker(selection: $viewModel.appearanceMode) {
                        ForEach(AppAppearanceMode.allCases) { m in
                            Text(m.title).tag(m)
                        }
                    } label: {
                        Label {
                            Text(L10n.tr("settings.appearance"))
                        } icon: {
                            SettingsIconBadge(systemName: "circle.lefthalf.filled", color: .gray)
                        }
                    }

                    Picker(selection: $viewModel.mapSource) {
                        ForEach(MapSource.allCases) { src in
                            Text(src.title).tag(src)
                        }
                    } label: {
                        Label {
                            Text(L10n.tr("settings.map_source"))
                        } icon: {
                            SettingsIconBadge(systemName: "globe.americas.fill", color: RelocTheme.accent)
                        }
                    }

                    if viewModel.mapSource == .appleNative {
                        Picker(selection: $viewModel.mapStyle) {
                            ForEach(MapDisplayStyle.allCases) { s in
                                Text(s.title).tag(s)
                            }
                        } label: {
                            Label {
                                Text(L10n.tr("settings.apple_map_style"))
                            } icon: {
                                SettingsIconBadge(systemName: "map.fill", color: RelocTheme.accent)
                            }
                        }
                    }
                } header: {
                    Text(L10n.tr("settings.section.appearance"))
                } footer: {
                    Text(L10n.tr("settings.appearance.footer"))
                }
            }
            .navigationTitle(L10n.tr("settings.title"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
