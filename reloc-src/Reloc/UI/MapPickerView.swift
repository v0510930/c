import CoreLocation
import MapKit
import SwiftUI

struct MapPickerView: View {
    @ObservedObject var viewModel: RelocViewModel
    let switchToConfig: () -> Void

    @State private var searchText = ""
    @State private var searchResults: [MKMapItem] = []
    @State private var isSearching = false
    @State private var cameraTarget: CLLocationCoordinate2D?
    @State private var showManualCoordinate = false
    @State private var showPlacesSheet = false
    @State private var showStopConfirm = false
    @State private var copiedAddressToast = false

    var body: some View {
        ZStack(alignment: .top) {
            InteractiveMKMapView(
                activeCoordinate: viewModel.activeMapCoordinate,
                isSessionRunning: viewModel.snapshot.isRunning,
                pendingCoordinate: viewModel.pendingMapCoordinate,
                mapStyle: viewModel.mapStyle,
                cameraTarget: $cameraTarget,
                onTapCoordinate: { coord in
                    RelocTheme.hapticLight()
                    viewModel.selectLocationFromMap(coord)
                }
            )
            .ignoresSafeArea()

            VStack(spacing: 10) {
                searchBar
                if !searchResults.isEmpty {
                    searchResultsList
                }
                topStatusRow

                if let interrupted = viewModel.interruptedSession, !viewModel.snapshot.isRunning {
                    interruptedRecoveryBanner(interrupted)
                }

                Spacer()

                HStack {
                    Spacer()
                    rightControlDock
                }

                fixedLocationCard
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .padding(.top, 8)
        }
        .toolbarBackground(.hidden, for: .tabBar)
        .sheet(isPresented: $showManualCoordinate) {
            ManualCoordinateSheet(viewModel: viewModel) { coord in
                cameraTarget = coord
            }
        }
        .sheet(isPresented: $showPlacesSheet) {
            PlacesSheet(viewModel: viewModel) { coord in
                cameraTarget = coord
            }
        }
        .confirmationDialog("停止定位并恢复真实位置？", isPresented: $showStopConfirm, titleVisibility: .visible) {
            Button("停止并恢复", role: .destructive) {
                RelocTheme.hapticMedium()
                viewModel.stopAndRestore()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("停止后系统将逐步切回本机真实 GPS 位置。")
        }
    }

    // MARK: - Top Search Bar & Status Row

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(RelocTheme.accent)

            TextField("搜索地点或输入 纬度, 经度", text: $searchText)
                .font(.subheadline)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { performSearch() }

            if isSearching {
                ProgressView().controlSize(.small)
            } else if !searchText.isEmpty {
                Button {
                    searchText = ""
                    searchResults = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    RelocTheme.hapticLight()
                    showManualCoordinate = true
                } label: {
                    Image(systemName: "number.circle.fill")
                        .font(.system(size: 19))
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("手动输入坐标")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.regularMaterial, in: Capsule())
        .overlay(
            Capsule().strokeBorder(Color.white.opacity(0.28), lineWidth: 0.7)
        )
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }

    private var topStatusRow: some View {
        HStack(spacing: 8) {
            Button(action: switchToConfig) {
                HStack(spacing: 7) {
                    PulsingStatusDot(
                        color: statusDotColor,
                        isPulsing: viewModel.snapshot.isRunning
                    )
                    Text(statusPillTitle)
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.primary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
                .overlay(
                    Capsule().strokeBorder(Color.white.opacity(0.24), lineWidth: 0.7)
                )
                .shadow(color: .black.opacity(0.10), radius: 8, y: 3)
            }

            Spacer()

            if viewModel.snapshot.isRunning {
                HStack(spacing: 5) {
                    Image(systemName: "location.fill")
                        .font(.caption2)
                        .foregroundStyle(RelocTheme.emerald)
                    Text(String(format: "%.4f, %.4f", viewModel.targetLocation.latitude, viewModel.targetLocation.longitude))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.7))
            }
        }
    }

    private var rightControlDock: some View {
        VStack(spacing: 10) {
            MapHUDIconButton(systemName: "bookmark.fill") {
                showPlacesSheet = true
            }

            Menu {
                Section("地图样式") {
                    ForEach(MapDisplayStyle.allCases) { style in
                        Button {
                            viewModel.mapStyle = style
                        } label: {
                            Label(style.title, systemImage: viewModel.mapStyle == style ? "checkmark" : "map")
                        }
                    }
                }
                Section("坐标") {
                    Button { showManualCoordinate = true } label: {
                        Label("手动输入经纬度", systemImage: "number")
                    }
                }
            } label: {
                Image(systemName: "map.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 42, height: 42)
                    .background(.regularMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.7))
                    .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
            }

            MapHUDIconButton(systemName: viewModel.snapshot.isRunning ? "scope" : "location.fill") {
                if !viewModel.snapshot.isRunning, let real = viewModel.coreLocation.latest {
                    cameraTarget = viewModel.toMapCoordinate(CLLocationCoordinate2D(latitude: real.latitude, longitude: real.longitude))
                } else {
                    viewModel.coreLocation.requestOneShot()
                    cameraTarget = viewModel.pendingMapCoordinate ?? viewModel.activeMapCoordinate
                }
            }
        }
    }

    private var statusDotColor: Color {
        if viewModel.snapshot.isRunning {
            return viewModel.snapshot.packetsAcknowledged > 0 ? RelocTheme.emerald : RelocTheme.accent
        }
        if viewModel.connectionVerified { return RelocTheme.emerald }
        return viewModel.pairingStatus.isLoaded ? RelocTheme.amber : RelocTheme.crimson
    }

    private var statusPillTitle: String {
        if viewModel.snapshot.isRunning {
            if viewModel.snapshot.packetsAcknowledged > 0 {
                return "定位注入中 · ACK \(viewModel.snapshot.packetsAcknowledged)"
            }
            if viewModel.snapshot.authenticated {
                return "已认证 · 等待订阅"
            }
            return "建立连接中…"
        }
        if viewModel.connectionVerified { return "回环已就绪" }
        return viewModel.pairingStatus.isLoaded ? "已配对 · 待验证" : "未配对设备"
    }

    private var searchResultsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(searchResults.prefix(6).enumerated()), id: \.offset) { _, item in
                    Button {
                        RelocTheme.hapticLight()
                        let coord = item.placemark.coordinate
                        viewModel.selectLocationFromMap(coord, name: item.name, address: item.placemark.title)
                        cameraTarget = coord
                        searchResults = []
                        searchText = ""
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "mappin.circle.fill")
                                .foregroundStyle(RelocTheme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name ?? "未知地点")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                if let title = item.placemark.title {
                                    Text(title)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                    Divider().padding(.leading, 40)
                }
            }
        }
        .frame(maxHeight: 230)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.24), lineWidth: 0.7))
        .shadow(color: .black.opacity(0.14), radius: 12, y: 6)
    }

    private func interruptedRecoveryBanner(_ record: InterruptedSessionRecord) -> some View {
        HStack(spacing: 10) {
            SettingsIconBadge(systemName: "arrow.counterclockwise", color: RelocTheme.amber)
            VStack(alignment: .leading, spacing: 1) {
                Text("上次定位会话意外中断")
                    .font(.caption.weight(.bold))
                Text("恢复上次位置：\(record.placeName)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("恢复") {
                RelocTheme.hapticMedium()
                viewModel.resumeInterruptedSession()
                cameraTarget = viewModel.activeMapCoordinate
            }
            .font(.caption.weight(.bold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(RelocTheme.amber, in: Capsule())
            .foregroundStyle(.white)

            Button {
                viewModel.dismissInterruptedSession()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(RelocTheme.amber.opacity(0.35), lineWidth: 0.8))
    }

    // MARK: - Bottom Fixed Location Card

    private var sheetGrabber: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.3))
            .frame(width: 36, height: 4)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 2)
    }

    private var fixedLocationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sheetGrabber

            HStack(alignment: .center, spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill((viewModel.pendingLocation != nil ? RelocTheme.amber : (viewModel.snapshot.isRunning ? RelocTheme.emerald : RelocTheme.accent)).opacity(0.16))
                        .frame(width: 42, height: 42)
                    Image(systemName: viewModel.pendingLocation != nil ? "mappin.and.ellipse" : (viewModel.snapshot.isRunning ? "location.fill" : "mappin.circle.fill"))
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(viewModel.pendingLocation != nil ? RelocTheme.amber : (viewModel.snapshot.isRunning ? RelocTheme.emerald : RelocTheme.accent))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.selectedPlaceName)
                        .font(.headline)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text(viewModel.selectedPlaceAddress.isEmpty
                             ? String(format: "%.5f, %.5f", viewModel.inspectedLocation.latitude, viewModel.inspectedLocation.longitude)
                             : viewModel.selectedPlaceAddress)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Button {
                            let text = "\(viewModel.selectedPlaceName) (\(String(format: "%.6f, %.6f", viewModel.inspectedLocation.latitude, viewModel.inspectedLocation.longitude)))"
                            UIPasteboard.general.string = text
                            RelocTheme.hapticLight()
                            copiedAddressToast = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copiedAddressToast = false }
                        } label: {
                            Image(systemName: copiedAddressToast ? "checkmark.circle.fill" : "doc.on.doc")
                                .font(.caption)
                                .foregroundStyle(copiedAddressToast ? RelocTheme.emerald : RelocTheme.accent)
                        }
                    }
                }

                Spacer()

                Button {
                    RelocTheme.hapticLight()
                    viewModel.toggleFavoriteForInspected()
                } label: {
                    Image(systemName: viewModel.isCurrentInspectedFavorite ? "heart.fill" : "heart")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(viewModel.isCurrentInspectedFavorite ? .pink : .secondary)
                        .frame(width: 34, height: 34)
                        .background(Color.secondary.opacity(0.12), in: Circle())
                }

                if viewModel.pendingLocation != nil {
                    Button {
                        viewModel.clearPendingSelection()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 34, height: 34)
                            .background(Color.secondary.opacity(0.12), in: Circle())
                    }
                }
            }

            if !viewModel.pairingStatus.isLoaded {
                Button(action: switchToConfig) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(RelocTheme.amber)
                        Text("尚未配对这台 iPhone，前往「设备连接」一键配对").font(.caption.weight(.semibold))
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                    }
                    .padding(10)
                    .background(RelocTheme.amber.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .foregroundStyle(.primary)
            } else if viewModel.snapshot.isRunning && viewModel.snapshot.authenticated && viewModel.snapshot.activeSentences.isEmpty {
                HStack(spacing: 7) {
                    Image(systemName: "info.circle.fill").foregroundStyle(RelocTheme.accent)
                    Text("已连接就绪，打开「地图」即可触发订阅；若位置未立刻切换，关闭定位服务约 5 秒再打开。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(9)
                .background(RelocTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            } else if let err = viewModel.snapshot.lastError, !viewModel.snapshot.isRunning {
                Text("上次错误：\(err)")
                    .font(.caption)
                    .foregroundStyle(RelocTheme.crimson)
                    .lineLimit(2)
            }

            HStack(spacing: 10) {
                if viewModel.snapshot.isRunning {
                    if viewModel.pendingLocation != nil {
                        RelocPrimaryButton(
                            title: "更新到此位置",
                            systemImage: "paperplane.fill",
                            gradient: RelocTheme.accentGradient
                        ) {
                            viewModel.applyPendingLocationUpdate()
                        }
                    }
                    RelocPrimaryButton(
                        title: "停止并恢复",
                        systemImage: "stop.fill",
                        gradient: RelocTheme.crimsonGradient
                    ) {
                        showStopConfirm = true
                    }
                } else {
                    RelocPrimaryButton(
                        title: "开始定位",
                        systemImage: "paperplane.fill",
                        gradient: RelocTheme.accentGradient,
                        disabled: !viewModel.canStartSession
                    ) {
                        viewModel.start(mode: .send)
                    }
                }
            }
        }
        .relocGlassCard(cornerRadius: 24, padding: 15)
    }

    // MARK: - Search Action

    private func performSearch() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let parts = trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]),
           (-90.0...90.0).contains(lat), (-180.0...180.0).contains(lon) {
            viewModel.selectWGSLocation(TargetLocation(latitude: lat, longitude: lon, altitude: viewModel.targetLocation.altitude))
            cameraTarget = viewModel.pendingMapCoordinate ?? viewModel.activeMapCoordinate
            searchResults = []
            searchText = ""
            return
        }

        isSearching = true
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = trimmed
        let search = MKLocalSearch(request: req)
        search.start { response, _ in
            Task { @MainActor in
                isSearching = false
                searchResults = response?.mapItems ?? []
            }
        }
    }
}

// MARK: - Interactive MKMapView Wrapper

private struct InteractiveMKMapView: UIViewRepresentable {
    let activeCoordinate: CLLocationCoordinate2D
    let isSessionRunning: Bool
    let pendingCoordinate: CLLocationCoordinate2D?
    let mapStyle: MapDisplayStyle
    @Binding var cameraTarget: CLLocationCoordinate2D?
    let onTapCoordinate: (CLLocationCoordinate2D) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTapCoordinate: onTapCoordinate)
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.showsCompass = true
        mapView.showsScale = true

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        mapView.addGestureRecognizer(tap)

        let activeAnn = TaggedAnnotation(kind: .active)
        activeAnn.coordinate = activeCoordinate
        activeAnn.title = "当前位置"
        mapView.addAnnotation(activeAnn)
        context.coordinator.activeAnnotation = activeAnn

        let region = MKCoordinateRegion(
            center: activeCoordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
        )
        mapView.setRegion(region, animated: false)
        return mapView
    }

    func updateUIView(_ uiView: MKMapView, context: Context) {
        context.coordinator.onTapCoordinate = onTapCoordinate
        context.coordinator.isSessionRunning = isSessionRunning

        switch mapStyle {
        case .standard: uiView.mapType = .standard
        case .satellite: uiView.mapType = .satellite
        case .hybrid: uiView.mapType = .hybrid
        }

        if let activeAnn = context.coordinator.activeAnnotation {
            if abs(activeAnn.coordinate.latitude - activeCoordinate.latitude) > 1e-9 ||
               abs(activeAnn.coordinate.longitude - activeCoordinate.longitude) > 1e-9 {
                activeAnn.coordinate = activeCoordinate
            }
            if let markerView = uiView.view(for: activeAnn) as? MKMarkerAnnotationView {
                markerView.markerTintColor = isSessionRunning ? UIColor(RelocTheme.emerald) : UIColor(RelocTheme.accent)
            }
        }

        if let pending = pendingCoordinate {
            if let existing = context.coordinator.pendingAnnotation {
                existing.coordinate = pending
            } else {
                let ann = TaggedAnnotation(kind: .pending)
                ann.coordinate = pending
                ann.title = "待更新位置"
                uiView.addAnnotation(ann)
                context.coordinator.pendingAnnotation = ann
            }
        } else if let existing = context.coordinator.pendingAnnotation {
            uiView.removeAnnotation(existing)
            context.coordinator.pendingAnnotation = nil
        }

        if let target = cameraTarget {
            let region = MKCoordinateRegion(
                center: target,
                span: uiView.region.span.latitudeDelta > 0.25
                    ? MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
                    : uiView.region.span
            )
            uiView.setRegion(region, animated: true)
            DispatchQueue.main.async {
                cameraTarget = nil
            }
        }
    }

    final class TaggedAnnotation: MKPointAnnotation {
        enum Kind { case active, pending }
        let kind: Kind
        init(kind: Kind) {
            self.kind = kind
            super.init()
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var onTapCoordinate: (CLLocationCoordinate2D) -> Void
        var isSessionRunning = false
        var activeAnnotation: TaggedAnnotation?
        var pendingAnnotation: TaggedAnnotation?

        init(onTapCoordinate: @escaping (CLLocationCoordinate2D) -> Void) {
            self.onTapCoordinate = onTapCoordinate
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let mapView = gesture.view as? MKMapView else { return }
            let point = gesture.location(in: mapView)
            let coord = mapView.convert(point, toCoordinateFrom: mapView)
            onTapCoordinate(coord)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let tagged = annotation as? TaggedAnnotation else { return nil }
            let id = tagged.kind == .active ? "reloc.active" : "reloc.pending"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
            view.annotation = annotation
            view.displayPriority = .required
            if tagged.kind == .active {
                view.markerTintColor = isSessionRunning ? UIColor(RelocTheme.emerald) : UIColor(RelocTheme.accent)
                view.glyphImage = UIImage(systemName: "location.fill")
            } else {
                view.markerTintColor = UIColor(RelocTheme.amber)
                view.glyphImage = UIImage(systemName: "mappin")
            }
            return view
        }
    }
}

// MARK: - Places Sheet (Favorites + Recent 30 History + Rename)

private struct PlacesSheet: View {
    @ObservedObject var viewModel: RelocViewModel
    let onSelect: (CLLocationCoordinate2D) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var tab = 0
    @State private var newFavoriteName = ""
    @State private var renamingFavorite: FavoriteLocation?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("分类", selection: $tab) {
                    Text("收藏 (\(viewModel.favorites.count))").tag(0)
                    Text("最近记录 (\(viewModel.recents.count))").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                List {
                    if tab == 0 {
                        Section("收藏当前选中位置") {
                            HStack {
                                TextField("输入名称", text: $newFavoriteName)
                                Button("保存") {
                                    viewModel.saveCurrentAsFavorite(name: newFavoriteName)
                                    newFavoriteName = ""
                                }
                                .disabled(newFavoriteName.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                        }

                        Section("已保存收藏") {
                            if viewModel.favorites.isEmpty {
                                Text("暂无收藏地点").foregroundStyle(.secondary)
                            } else {
                                ForEach(viewModel.favorites) { fav in
                                    Button {
                                        viewModel.selectWGSLocation(
                                            TargetLocation(latitude: fav.latitude, longitude: fav.longitude, altitude: fav.altitude),
                                            name: fav.name,
                                            address: fav.subtitle
                                        )
                                        onSelect(viewModel.pendingMapCoordinate ?? viewModel.activeMapCoordinate)
                                        dismiss()
                                    } label: {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(fav.name).foregroundStyle(.primary)
                                            Text(fav.subtitle ?? String(format: "%.5f, %.5f", fav.latitude, fav.longitude))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) {
                                            viewModel.deleteFavorite(id: fav.id)
                                        } label: {
                                            Label("删除", systemImage: "trash")
                                        }
                                        Button {
                                            renameText = fav.name
                                            renamingFavorite = fav
                                        } label: {
                                            Label("重命名", systemImage: "pencil")
                                        }
                                        .tint(.orange)
                                    }
                                }
                            }
                        }
                    } else {
                        Section {
                            if viewModel.recents.isEmpty {
                                Text("暂无最近使用记录").foregroundStyle(.secondary)
                            } else {
                                ForEach(viewModel.recents) { item in
                                    Button {
                                        viewModel.selectWGSLocation(
                                            TargetLocation(latitude: item.latitude, longitude: item.longitude, altitude: item.altitude),
                                            name: item.name,
                                            address: item.subtitle
                                        )
                                        onSelect(viewModel.pendingMapCoordinate ?? viewModel.activeMapCoordinate)
                                        dismiss()
                                    } label: {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.name).foregroundStyle(.primary)
                                            Text(item.subtitle ?? String(format: "%.5f, %.5f", item.latitude, item.longitude))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) {
                                            viewModel.deleteRecent(id: item.id)
                                        } label: {
                                            Label("删除", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        } header: {
                            HStack {
                                Text("最近使用（最多 30 条）")
                                Spacer()
                                if !viewModel.recents.isEmpty {
                                    Button("清空") { viewModel.clearRecents() }
                                        .font(.caption)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("收藏与历史")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .alert("重命名收藏", isPresented: Binding(
                get: { renamingFavorite != nil },
                set: { if !$0 { renamingFavorite = nil } }
            )) {
                TextField("新名称", text: $renameText)
                Button("取消", role: .cancel) { renamingFavorite = nil }
                Button("保存") {
                    if let fav = renamingFavorite {
                        viewModel.renameFavorite(id: fav.id, newName: renameText)
                    }
                    renamingFavorite = nil
                }
            }
        }
    }
}

private struct ManualCoordinateSheet: View {
    @ObservedObject var viewModel: RelocViewModel
    let onApply: (CLLocationCoordinate2D) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var latText = ""
    @State private var lonText = ""
    @State private var altText = ""
    @State private var favoriteName = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("WGS-84 坐标") {
                    TextField("纬度 (-90 ~ 90)", text: $latText)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("经度 (-180 ~ 180)", text: $lonText)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("海拔 (米)", text: $altText)
                        .keyboardType(.numbersAndPunctuation)
                }

                Section("保存到收藏（可选）") {
                    TextField("地点名称", text: $favoriteName)
                }
            }
            .navigationTitle("手动输入坐标")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") {
                        if let lat = Double(latText), let lon = Double(lonText),
                           (-90.0...90.0).contains(lat), (-180.0...180.0).contains(lon) {
                            let alt = Double(altText) ?? viewModel.inspectedLocation.altitude
                            viewModel.selectWGSLocation(
                                TargetLocation(latitude: lat, longitude: lon, altitude: alt),
                                name: favoriteName.trimmingCharacters(in: .whitespaces).isEmpty ? nil : favoriteName
                            )
                            if !favoriteName.trimmingCharacters(in: .whitespaces).isEmpty {
                                viewModel.saveCurrentAsFavorite(name: favoriteName)
                            }
                            onApply(viewModel.pendingMapCoordinate ?? viewModel.activeMapCoordinate)
                            dismiss()
                        }
                    }
                }
            }
            .onAppear {
                let loc = viewModel.inspectedLocation
                latText = String(format: "%.6f", loc.latitude)
                lonText = String(format: "%.6f", loc.longitude)
                altText = String(format: "%.1f", loc.altitude)
            }
        }
    }
}
