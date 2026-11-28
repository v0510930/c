import AppIntents
import SwiftUI

@main
struct RelocApp: App {
    @ObservedObject private var viewModel = RelocViewModel.shared
    @StateObject private var activation = ActivationManager()

    init() {
        RelocAppShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            if activation.isActivated {
                ContentView(viewModel: viewModel)
                    .tint(RelocTheme.accent)
                    .preferredColorScheme(viewModel.appearanceMode.colorScheme)
                    .environment(\.locale, viewModel.appLanguage.locale)
                    .onOpenURL { url in
                        viewModel.handleIncomingURL(url)
                    }
            } else {
                ActivationGateView(manager: activation)
            }
        }
    }
}

struct ContentView: View {
    @ObservedObject var viewModel: RelocViewModel
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            MapPickerView(viewModel: viewModel, switchToConfig: { selectedTab = 1 })
                .tabItem {
                    Label(L10n.tr("tab.location"), systemImage: "location.north.circle.fill")
                }
                .tag(0)

            ConfigurationView(viewModel: viewModel)
                .tabItem {
                    Label(L10n.tr("tab.settings"), systemImage: "gearshape.fill")
                }
                .tag(1)

            ProtocolLogsView(viewModel: viewModel)
                .tabItem {
                    Label(L10n.tr("tab.logs"), systemImage: "waveform.path.ecg")
                }
                .tag(2)
        }
        .alert(L10n.tr("common.alert.title"), isPresented: Binding(
            get: { viewModel.alertMessage != nil },
            set: { if !$0 { viewModel.alertMessage = nil } }
        )) {
            Button(L10n.tr("common.ok"), role: .cancel) {
                viewModel.alertMessage = nil
            }
        } message: {
            Text(viewModel.alertMessage ?? "")
        }
    }
}
