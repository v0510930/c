import SwiftUI

@main
struct RelocApp: App {
    @StateObject private var viewModel = RelocViewModel()
    @StateObject private var activation = ActivationManager()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .tint(RelocTheme.accent)
                .preferredColorScheme(viewModel.appearanceMode.colorScheme)
                .fullScreenCover(
                    isPresented: Binding(
                        get: { !activation.isActivated },
                        set: { _ in }
                    )
                ) {
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
                    Label("定位", systemImage: "location.north.circle.fill")
                }
                .tag(0)

            ConfigurationView(viewModel: viewModel)
                .tabItem {
                    Label("设备连接", systemImage: "antenna.radiowaves.left.and.right")
                }
                .tag(1)

            ProtocolLogsView(viewModel: viewModel)
                .tabItem {
                    Label("实测与日志", systemImage: "waveform.path.ecg")
                }
                .tag(2)
        }
        .alert("提示", isPresented: Binding(
            get: { viewModel.alertMessage != nil },
            set: { if !$0 { viewModel.alertMessage = nil } }
        )) {
            Button("确定", role: .cancel) {
                viewModel.alertMessage = nil
            }
        } message: {
            Text(viewModel.alertMessage ?? "")
        }
    }
}
