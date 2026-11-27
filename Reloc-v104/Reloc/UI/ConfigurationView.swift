import SwiftUI

struct ConfigurationView: View {
    @ObservedObject var viewModel: RelocViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.tr("settings.section.location")) {
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

                    Toggle(isOn: $viewModel.backgroundKeepAliveEnabled) {
                        Label {
                            Text(L10n.tr("settings.keep_alive"))
                        } icon: {
                            SettingsIconBadge(systemName: "bolt.shield.fill", color: .teal)
                        }
                    }
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
