import CoreLocation
import MapKit
import SwiftUI

struct MapPickerView: View {
    @ObservedObject var viewModel: RelocViewModel
    let switchToConfig: () -> Void

    @State private var searchText = ""
    @State private var searchResults: [MKMapItem] = []
    @State private var isSearching = false
    @State private var searchStatusMessage: String?
    @State private var activeSearch: MKLocalSearch?
    @StateObject private var searchCompleter = LocationSearchCompleter()
    @FocusState private var isSearchFocused: Bool
    @State private var cameraTarget: CLLocationCoordinate2D?
    @State private var visibleMapRegion: MKCoordinateRegion?
    @State private var showManualCoordinate = false
    @State private var showPlacesSheet = false
    @State private var showStopConfirm = false
    @State private var showSaveRouteAlert = false
    @State private var saveRouteName = ""
    @State private var copiedAddressToast = false
    @State private var airplaneHintDismissed = false

    private var isRouteMode: Bool {
        viewModel.controlMode == .route || viewModel.isRouteSessionActive
    }

    private var hasSearchDropdown: Bool {
        !searchResults.isEmpty
            || !searchCompleter.suggestions.isEmpty
            || searchStatusMessage != nil
    }

    private var currentSearchRegion: MKCoordinateRegion {
        if let region = visibleMapRegion {
            if viewModel.mapSource.isPureWGS84,
               viewModel.gcj02CorrectionEnabled,
               !CoordinateTransform.isOutsideChina(lat: region.center.latitude, lon: region.center.longitude) {
                let gcjCenter = CoordinateTransform.wgs84ToGCJ02(lat: region.center.latitude, lon: region.center.longitude)
                return MKCoordinateRegion(center: gcjCenter, span: region.span)
            }
            return region
        }
        return MKCoordinateRegion(
            center: viewModel.activeMapCoordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)
        )
    }

    init(viewModel: RelocViewModel, switchToConfig: @escaping () -> Void) {
        self.viewModel = viewModel
        self.switchToConfig = switchToConfig
    }

    var body: some View {
        ZStack(alignment: .top) {
            if viewModel.mapSource.isPureWGS84 {
                WebMercatorMapView(
                    activeCoordinate: viewModel.activeMapCoordinate,
                    isSessionRunning: viewModel.snapshot.isRunning,
                    pendingCoordinate: isRouteMode ? nil : viewModel.pendingMapCoordinate,
                    routePolyline: viewModel.routeMapPolylineCoordinates,
                    routeWaypoints: viewModel.routeMapWaypointCoordinates,
                    showActivePin: !isRouteMode || viewModel.isRouteSessionActive,
                    mapSource: viewModel.mapSource,
                    cameraTarget: $cameraTarget,
                    onTapCoordinate: { coord in
                        handleMapTap(coord)
                    },
                    onRegionChange: { region in
                        visibleMapRegion = region
                    }
                )
                .ignoresSafeArea()
            } else {
                InteractiveMKMapView(
                    activeCoordinate: viewModel.activeMapCoordinate,
                    isSessionRunning: viewModel.snapshot.isRunning,
                    pendingCoordinate: isRouteMode ? nil : viewModel.pendingMapCoordinate,
                    routePolyline: viewModel.routeMapPolylineCoordinates,
                    routeWaypoints: viewModel.routeMapWaypointCoordinates,
                    showActivePin: !isRouteMode || viewModel.isRouteSessionActive,
                    mapStyle: viewModel.mapStyle,
                    cameraTarget: $cameraTarget,
                    onTapCoordinate: { coord in
                        handleMapTap(coord)
                    },
                    onRegionChange: { region in
                        visibleMapRegion = region
                    }
                )
                .ignoresSafeArea()
            }

            VStack(spacing: 10) {
                Spacer(minLength: 0)

                HStack {
                    Spacer()
                    rightControlDock
                }

                if isRouteMode {
                    routeControlCard
                } else {
                    fixedLocationCard
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .ignoresSafeArea(.keyboard, edges: .bottom)

            VStack(spacing: 10) {
                searchBar
                if hasSearchDropdown {
                    searchDropdownCard
                } else {
                    topStatusRow

                    if let interrupted = viewModel.interruptedSession, !viewModel.snapshot.isRunning {
                        interruptedRecoveryBanner(interrupted)
                    }

                    airplaneModeHintBanner
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .toolbarBackground(.hidden, for: .tabBar)
        .relocOnChange(of: searchText) { newValue in
            handleSearchTextChange(newValue)
        }
        .relocOnChange(of: isSearchFocused) { focused in
            if focused {
                let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, searchCompleter.suggestions.isEmpty, searchResults.isEmpty {
                    handleSearchTextChange(trimmed)
                }
            }
        }
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
        .confirmationDialog(L10n.tr("map.stop_confirm.title"), isPresented: $showStopConfirm, titleVisibility: .visible) {
            Button(L10n.tr("map.stop_confirm.button"), role: .destructive) {
                RelocTheme.hapticMedium()
                viewModel.stopAndRestore()
            }
            Button(L10n.tr("common.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.tr("map.stop_confirm.message"))
        }
        .alert(L10n.tr("route.save.title"), isPresented: $showSaveRouteAlert) {
            TextField(L10n.tr("route.save.placeholder"), text: $saveRouteName)
            Button(L10n.tr("common.cancel"), role: .cancel) {
                saveRouteName = ""
            }
            Button(L10n.tr("common.save")) {
                viewModel.saveCurrentRoute(name: saveRouteName)
                saveRouteName = ""
                RelocTheme.hapticSuccess()
            }
        } message: {
            Text(L10n.tr("route.save.message"))
        }
    }

    // MARK: - Top Search Bar & Status Row

    private var searchBar: some View {
        HStack(spacing: 10) {
            Button {
                if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    performSearch()
                } else {
                    isSearchFocused = true
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(RelocTheme.accent)
                    .frame(width: 24, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            TextField(
                isRouteMode ? L10n.tr("route.search.placeholder") : L10n.tr("map.search.placeholder"),
                text: $searchText
            )
                .font(.subheadline)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($isSearchFocused)
                .onSubmit { performSearch() }
                .frame(maxWidth: .infinity, minHeight: 44)

            Group {
                if isSearching {
                    ProgressView().controlSize(.small)
                } else if !searchText.isEmpty {
                    Button {
                        clearSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(Color(uiColor: .secondaryLabel))
                            .frame(width: 28, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.tr("map.search.clear"))
                } else {
                    Button {
                        RelocTheme.hapticLight()
                        dismissSearchOverlay()
                        showManualCoordinate = true
                    } label: {
                        Image(systemName: "number.circle.fill")
                            .font(.system(size: 19))
                            .foregroundStyle(Color(uiColor: .secondaryLabel))
                            .frame(width: 28, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.tr("map.search.manual"))
                }
            }
            .frame(width: 28, height: 44)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .background {
            Capsule()
                .fill(.regularMaterial)
                .contentShape(Capsule())
                .onTapGesture {
                    isSearchFocused = true
                }
        }
        .overlay(
            Capsule()
                .strokeBorder(Color.white.opacity(0.28), lineWidth: 0.7)
                .allowsHitTesting(false)
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
                        .foregroundStyle(Color.primary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
                .overlay(
                    Capsule().strokeBorder(Color.white.opacity(0.24), lineWidth: 0.7)
                )
                .shadow(color: .black.opacity(0.10), radius: 8, y: 3)
            }
            .buttonStyle(.plain)

            Spacer()

            if viewModel.snapshot.isRunning {
                let live = viewModel.currentLiveCoordinateSummary
                HStack(spacing: 5) {
                    Image(systemName: viewModel.isRouteSessionActive ? viewModel.routePreset.systemImage : "location.fill")
                        .font(.caption2)
                        .foregroundStyle(RelocTheme.emerald)
                    if viewModel.isRouteSessionActive, let prog = viewModel.trajectoryProgress {
                        Text("\(RouteGeometry.formatSpeedKmh(prog.currentSpeedMps)) · \(Int((prog.progress * 100).rounded()))%")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    } else {
                        Text(String(format: "%.4f, %.4f · %.0fm", live.latitude, live.longitude, live.altitude))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.7))
            } else {
                modeTogglePill
            }
        }
    }

    private var modeTogglePill: some View {
        HStack(spacing: 2) {
            ForEach(LocationControlMode.allCases) { mode in
                let selected = viewModel.controlMode == mode
                Button {
                    guard viewModel.controlMode != mode else { return }
                    RelocTheme.hapticLight()
                    withAnimation(.easeInOut(duration: 0.18)) {
                        viewModel.controlMode = mode
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: mode == .fixed ? "mappin.circle.fill" : "point.filled.topleft.down.curvedto.point.bottomright.up")
                            .font(.system(size: 10, weight: .bold))
                        Text(mode.title)
                            .font(.caption.weight(.semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5.5)
                    .background(selected ? RelocTheme.accent : Color.clear, in: Capsule())
                    .foregroundStyle(selected ? .white : .primary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.24), lineWidth: 0.7))
        .shadow(color: .black.opacity(0.10), radius: 8, y: 3)
    }

    private var rightControlDock: some View {
        VStack(spacing: 10) {
            MapHUDIconButton(systemName: "bookmark.fill") {
                showPlacesSheet = true
            }

            Menu {
                Section(L10n.tr("map.menu.source")) {
                    ForEach(MapSource.allCases) { source in
                        Button {
                            viewModel.mapSource = source
                        } label: {
                            Label(source.shortTitle, systemImage: viewModel.mapSource == source ? "checkmark" : "globe")
                        }
                    }
                }
                if viewModel.mapSource == .appleNative {
                    Section(L10n.tr("map.menu.style")) {
                        ForEach(MapDisplayStyle.allCases) { style in
                            Button {
                                viewModel.mapStyle = style
                            } label: {
                                Label(style.title, systemImage: viewModel.mapStyle == style ? "checkmark" : "map")
                            }
                        }
                    }
                }
                Section(L10n.tr("map.menu.coordinates")) {
                    Button { showManualCoordinate = true } label: {
                        Label(L10n.tr("map.menu.manual_input"), systemImage: "number")
                    }
                }
            } label: {
                Image(systemName: "map.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .frame(width: 42, height: 42)
                    .background(.regularMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.7))
                    .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
            }
            .tint(.primary)

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

    @ViewBuilder
    private var airplaneModeHintBanner: some View {
        // iOS 27+ blocks accessory GPS for targets >15 km away unless Wi-Fi/Cell scanning is off.
        // Show a proactive hint once the user picks a distant point, before starting the session.
        // Pure UI guidance — does not touch the location pipeline.
        if !viewModel.snapshot.isRunning,
           viewModel.interruptedSession == nil,
           viewModel.isDistantFromRealLocation,
           !airplaneHintDismissed {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "airplane")
                        .foregroundStyle(RelocTheme.amber)
                    Text(L10n.tr("map.airplane.title"))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Button {
                        airplaneHintDismissed = true
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Text(L10n.tr("map.airplane.detail"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .background(RelocTheme.amber.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(RelocTheme.amber.opacity(0.35), lineWidth: 0.8))
            .transition(.opacity)
        }
    }

    private var statusDotColor: Color {
        switch viewModel.injectionPhase {
        case .activeConfirmed:
            return RelocTheme.emerald
        case .injectingPendingLock, .waitingSubscription:
            return viewModel.needsLocationServiceRefresh ? RelocTheme.amber : RelocTheme.accent
        case .connecting:
            return RelocTheme.amber
        case .idle:
            return RelocTheme.accent
        }
    }

    private var statusPillTitle: String {
        switch viewModel.injectionPhase {
        case .activeConfirmed:
            return L10n.tr("map.status.confirmed")
        case .injectingPendingLock:
            return viewModel.needsLocationServiceRefresh
                ? L10n.format("map.status.pending_refresh", viewModel.snapshot.packetsAcknowledged)
                : L10n.format("map.status.switching", viewModel.snapshot.packetsAcknowledged)
        case .waitingSubscription:
            return viewModel.needsLocationServiceRefresh ? L10n.tr("map.status.auth_refresh") : L10n.tr("map.status.auth_waking")
        case .connecting:
            return L10n.tr("map.status.connecting")
        case .idle:
            return L10n.tr("map.status.idle")
        }
    }

    private var searchCompletionsContent: some View {
        let items = Array(searchCompleter.suggestions.prefix(6).enumerated())
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(items, id: \.element.id) { index, suggestion in
                Button {
                    selectSuggestion(suggestion)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: suggestion.isDirectMapItem ? "mappin.circle.fill" : "magnifyingglass")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(suggestion.isDirectMapItem ? RelocTheme.accent : Color(uiColor: .secondaryLabel))
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color(uiColor: .label))
                                .lineLimit(1)
                            if let subtitle = suggestion.subtitle {
                                Text(subtitle)
                                    .font(.caption)
                                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        Image(systemName: "arrow.up.left")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color(uiColor: .tertiaryLabel))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if index < items.count - 1 {
                    Rectangle()
                        .fill(Color(uiColor: .separator).opacity(0.45))
                        .frame(height: 0.5)
                        .padding(.leading, 44)
                }
            }
        }
    }

    private var searchResultsContent: some View {
        let items = Array(searchResults.prefix(6).enumerated())
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(items, id: \.offset) { index, item in
                Button {
                    applyMapItemSelection(item)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "mappin.circle.fill")
                            .foregroundStyle(RelocTheme.accent)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name ?? L10n.tr("map.unknown_place"))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color(uiColor: .label))
                                .lineLimit(1)
                            if let subtitle = Self.formattedAddress(for: item) {
                                Text(subtitle)
                                    .font(.caption)
                                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if index < items.count - 1 {
                    Rectangle()
                        .fill(Color(uiColor: .separator).opacity(0.45))
                        .frame(height: 0.5)
                        .padding(.leading, 44)
                }
            }
        }
    }

    @ViewBuilder
    private var searchDropdownCard: some View {
        Group {
            if !searchResults.isEmpty {
                ViewThatFits(in: .vertical) {
                    searchResultsContent
                    ScrollView {
                        searchResultsContent
                    }
                }
                .frame(maxHeight: 240)
            } else if !searchCompleter.suggestions.isEmpty {
                ViewThatFits(in: .vertical) {
                    searchCompletionsContent
                    ScrollView {
                        searchCompletionsContent
                    }
                }
                .frame(maxHeight: 240)
            } else if let message = searchStatusMessage {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color(uiColor: .secondaryLabel))
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(Color(uiColor: .secondaryLabel))
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.regularMaterial)
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .onTapGesture {}
        }
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.24), lineWidth: 0.7)
                .allowsHitTesting(false)
        )
        .shadow(color: .black.opacity(0.14), radius: 12, y: 6)
    }

    private func interruptedRecoveryBanner(_ record: InterruptedSessionRecord) -> some View {
        HStack(spacing: 10) {
            SettingsIconBadge(systemName: "arrow.counterclockwise", color: RelocTheme.amber)
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.tr("map.interrupted.title"))
                    .font(.caption.weight(.bold))
                Text(L10n.format("map.interrupted.subtitle", record.placeName))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(L10n.tr("common.restore")) {
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
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
            }
            .buttonStyle(.plain)
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

                VStack(alignment: .leading, spacing: 3) {
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
                            let text = "\(viewModel.selectedPlaceName) (\(String(format: "%.6f, %.6f, %.1fm", viewModel.inspectedLocation.latitude, viewModel.inspectedLocation.longitude, viewModel.inspectedLocation.altitude)))"
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
                    HStack(spacing: 6) {
                        Button {
                            RelocTheme.hapticLight()
                            showManualCoordinate = true
                        } label: {
                            HStack(spacing: 3) {
                                if viewModel.isResolvingAltitude {
                                    ProgressView().controlSize(.mini)
                                    Text(L10n.tr("map.altitude.resolving"))
                                } else {
                                    Group {
                                        if #available(iOS 16.1, *) {
                                            Image(systemName: "mountain.2.fill")
                                        } else {
                                            Image(systemName: "arrow.up.and.down")
                                        }
                                    }
                                    .font(.system(size: 9, weight: .semibold))
                                    Text(L10n.format("map.altitude.value", viewModel.inspectedLocation.altitude))
                                        .monospacedDigit()
                                }
                            }
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(RelocTheme.accent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(RelocTheme.accent.opacity(0.12), in: Capsule())
                        }
                        .buttonStyle(.plain)

                        Text(String(format: "%.5f, %.5f", viewModel.inspectedLocation.latitude, viewModel.inspectedLocation.longitude))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
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

            if viewModel.locationAuthorizationStatus == .denied || viewModel.locationAuthorizationStatus == .restricted {
                HStack(spacing: 8) {
                    Image(systemName: "location.slash.fill").foregroundStyle(RelocTheme.crimson)
                    Text(L10n.tr("map.permission.denied")).font(.caption.weight(.semibold))
                    Spacer()
                    Button(L10n.tr("common.enable")) {
                        viewModel.openAppSettings()
                    }
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RelocTheme.crimson, in: Capsule())
                    .foregroundStyle(.white)
                }
                .padding(10)
                .background(RelocTheme.crimson.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if viewModel.isLocationReducedAccuracy {
                HStack(spacing: 8) {
                    Image(systemName: "scope").foregroundStyle(RelocTheme.amber)
                    Text(L10n.tr("map.permission.reduced")).font(.caption.weight(.semibold))
                    Spacer()
                    Button(L10n.tr("common.enable")) {
                        viewModel.openAppSettings()
                    }
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RelocTheme.amber, in: Capsule())
                    .foregroundStyle(.white)
                }
                .padding(10)
                .background(RelocTheme.amber.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if viewModel.snapshot.isRunning {
                liveTriggerStatusBanner
            } else if viewModel.isRestoringRealLocation {
                restoreLocationStatusBanner
            } else if viewModel.realLocationRestoredNotice {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(RelocTheme.emerald)
                    Text(L10n.tr("map.restored.notice"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(RelocTheme.emerald)
                    Spacer()
                }
                .padding(10)
                .background(RelocTheme.emerald.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if let err = viewModel.snapshot.lastError {
                Text(L10n.format("map.last_error", err))
                    .font(.caption)
                    .foregroundStyle(RelocTheme.crimson)
                    .lineLimit(2)
            }

            HStack(spacing: 10) {
                if viewModel.snapshot.isRunning {
                    if viewModel.pendingLocation != nil {
                        RelocPrimaryButton(
                            title: L10n.tr("map.button.update_location"),
                            systemImage: "paperplane.fill",
                            gradient: RelocTheme.accentGradient
                        ) {
                            viewModel.applyPendingLocationUpdate()
                        }
                    }
                    RelocPrimaryButton(
                        title: L10n.tr("map.button.stop_restore"),
                        systemImage: "stop.fill",
                        gradient: RelocTheme.crimsonGradient
                    ) {
                        showStopConfirm = true
                    }
                } else {
                    RelocPrimaryButton(
                        title: L10n.tr("map.button.start"),
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
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.clear)
                .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .onTapGesture {}
        }
    }

    // MARK: - Bottom Trajectory / Route Control Card

    private var routeControlCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sheetGrabber

            // Header: Route title, stats & quick edit buttons
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill((viewModel.isRouteSessionActive ? RelocTheme.emerald : RelocTheme.accent).opacity(0.16))
                        .frame(width: 40, height: 40)
                    if viewModel.isPlanningRoute {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: viewModel.isRouteSessionActive ? viewModel.routePreset.systemImage : "point.filled.topleft.down.curvedto.point.bottomright.up")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(viewModel.isRouteSessionActive ? RelocTheme.emerald : RelocTheme.accent)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(routeHeaderTitle)
                        .font(.subheadline.weight(.bold))
                        .lineLimit(1)
                    Text(routeHeaderSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if !viewModel.isRouteSessionActive && !viewModel.routeWaypoints.isEmpty {
                    HStack(spacing: 6) {
                        routeMiniIconButton("arrow.uturn.backward") {
                            viewModel.undoLastRouteWaypoint()
                        }
                        if viewModel.routeWaypoints.count >= 2 {
                            routeMiniIconButton("arrow.up.arrow.down") {
                                viewModel.reverseRouteWaypoints()
                            }
                        }
                        if viewModel.plannedRoutePoints.count >= 2 && !viewModel.isPlanningRoute {
                            routeMiniIconButton("bookmark") {
                                saveRouteName = defaultRouteSaveName
                                showSaveRouteAlert = true
                            }
                        }
                        routeMiniIconButton("trash", tint: RelocTheme.crimson) {
                            viewModel.clearRoute()
                        }
                    }
                }
            }

            if let notice = viewModel.routePlanningNotice, !viewModel.isRouteSessionActive {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(RelocTheme.amber)
                    Text(notice)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            if viewModel.isRouteSessionActive, let prog = viewModel.trajectoryProgress {
                // Live trajectory progress & speed control
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: prog.progress)
                        .tint(prog.isPaused ? RelocTheme.amber : RelocTheme.emerald)

                    HStack(spacing: 8) {
                        Image(systemName: "speedometer")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(RelocTheme.accent)
                        Text(liveSpeedLabel(prog.currentSpeedMps))
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.primary)
                        Slider(
                            value: $viewModel.routeSpeedMps,
                            in: viewModel.routePreset.speedRangeMps,
                            step: viewModel.routePreset.speedStepMps
                        )
                        .tint(RelocTheme.accent)
                    }
                }
            } else {
                // 4 Transport Presets
                HStack(spacing: 6) {
                    ForEach(RouteTransportPreset.allCases) { preset in
                        let selected = viewModel.routePreset == preset
                        Button {
                            RelocTheme.hapticLight()
                            viewModel.routePreset = preset
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: preset.systemImage)
                                    .font(.system(size: 11, weight: .semibold))
                                Text(preset.title)
                                    .font(.caption2.weight(.semibold))
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6.5)
                            .background(selected ? RelocTheme.accent : Color.secondary.opacity(0.12), in: Capsule())
                            .foregroundStyle(selected ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Speed Slider + Pace/km/h readout
                VStack(spacing: 2) {
                    HStack {
                        Text(L10n.tr("route.speed.label"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(configuredSpeedLabel)
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .foregroundStyle(RelocTheme.accent)
                    }
                    Slider(
                        value: $viewModel.routeSpeedMps,
                        in: viewModel.routePreset.speedRangeMps,
                        step: viewModel.routePreset.speedStepMps
                    )
                    .tint(RelocTheme.accent)
                }

                // Loop Mode + Realistic Motion toggle
                HStack(spacing: 6) {
                    ForEach(RouteLoopMode.allCases) { loop in
                        let selected = viewModel.routeLoopMode == loop
                        Button {
                            RelocTheme.hapticLight()
                            viewModel.routeLoopMode = loop
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: loop.systemImage)
                                    .font(.system(size: 10, weight: .semibold))
                                Text(loop.title)
                                    .font(.caption2.weight(.semibold))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5.5)
                            .background(selected ? RelocTheme.accent.opacity(0.16) : Color.secondary.opacity(0.10), in: Capsule())
                            .foregroundStyle(selected ? RelocTheme.accent : .secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer(minLength: 2)

                    Button {
                        RelocTheme.hapticLight()
                        viewModel.routeRealisticMotionEnabled.toggle()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "waveform.path")
                                .font(.system(size: 10, weight: .bold))
                            Text(L10n.tr("route.realistic.short"))
                                .font(.caption2.weight(.semibold))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5.5)
                        .background(
                            viewModel.routeRealisticMotionEnabled ? RelocTheme.emerald.opacity(0.16) : Color.secondary.opacity(0.10),
                            in: Capsule()
                        )
                        .foregroundStyle(viewModel.routeRealisticMotionEnabled ? RelocTheme.emerald : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Shared permission / live / restore / error banners
            if viewModel.locationAuthorizationStatus == .denied || viewModel.locationAuthorizationStatus == .restricted {
                HStack(spacing: 8) {
                    Image(systemName: "location.slash.fill").foregroundStyle(RelocTheme.crimson)
                    Text(L10n.tr("map.permission.denied")).font(.caption.weight(.semibold))
                    Spacer()
                    Button(L10n.tr("common.enable")) {
                        viewModel.openAppSettings()
                    }
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RelocTheme.crimson, in: Capsule())
                    .foregroundStyle(.white)
                }
                .padding(10)
                .background(RelocTheme.crimson.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if viewModel.isLocationReducedAccuracy {
                HStack(spacing: 8) {
                    Image(systemName: "scope").foregroundStyle(RelocTheme.amber)
                    Text(L10n.tr("map.permission.reduced")).font(.caption.weight(.semibold))
                    Spacer()
                    Button(L10n.tr("common.enable")) {
                        viewModel.openAppSettings()
                    }
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RelocTheme.amber, in: Capsule())
                    .foregroundStyle(.white)
                }
                .padding(10)
                .background(RelocTheme.amber.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if viewModel.snapshot.isRunning {
                liveTriggerStatusBanner
            } else if viewModel.isRestoringRealLocation {
                restoreLocationStatusBanner
            } else if viewModel.realLocationRestoredNotice {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(RelocTheme.emerald)
                    Text(L10n.tr("map.restored.notice"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(RelocTheme.emerald)
                    Spacer()
                }
                .padding(10)
                .background(RelocTheme.emerald.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if let err = viewModel.snapshot.lastError {
                Text(L10n.format("map.last_error", err))
                    .font(.caption)
                    .foregroundStyle(RelocTheme.crimson)
                    .lineLimit(2)
            }

            // Primary Action CTA
            HStack(spacing: 10) {
                if viewModel.isRouteSessionActive {
                    let isPaused = viewModel.trajectoryProgress?.isPaused ?? false
                    RelocPrimaryButton(
                        title: isPaused ? L10n.tr("route.button.resume") : L10n.tr("route.button.pause"),
                        systemImage: isPaused ? "play.fill" : "pause.fill",
                        gradient: isPaused ? RelocTheme.emeraldGradient : LinearGradient(colors: [RelocTheme.amber, Color(red: 0.85, green: 0.48, blue: 0.08)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    ) {
                        viewModel.toggleTrajectoryPause()
                    }
                    RelocPrimaryButton(
                        title: L10n.tr("map.button.stop_restore"),
                        systemImage: "stop.fill",
                        gradient: RelocTheme.crimsonGradient
                    ) {
                        showStopConfirm = true
                    }
                } else {
                    RelocPrimaryButton(
                        title: L10n.tr("route.button.start"),
                        systemImage: "play.fill",
                        gradient: RelocTheme.emeraldGradient,
                        disabled: !viewModel.canStartRouteSession
                    ) {
                        viewModel.startRouteSession()
                    }
                }
            }
        }
        .relocGlassCard(cornerRadius: 24, padding: 14)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.clear)
                .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .onTapGesture {}
        }
    }

    private func routeMiniIconButton(_ systemName: String, tint: Color = .secondary, action: @escaping () -> Void) -> some View {
        Button {
            RelocTheme.hapticLight()
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(Color.secondary.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
    }

    private var defaultRouteSaveName: String {
        if let first = viewModel.routeWaypoints.first?.name,
           let last = viewModel.routeWaypoints.last?.name,
           first != last {
            return "\(first) → \(last)"
        }
        return "\(viewModel.routePreset.title) \(RouteGeometry.formatDistance(viewModel.plannedRouteDistanceMeters))"
    }

    private var routeHeaderTitle: String {
        if viewModel.isRouteSessionActive, let prog = viewModel.trajectoryProgress {
            if prog.isCompleted {
                return L10n.tr("route.status.completed")
            } else if prog.isPaused {
                return L10n.tr("route.status.paused")
            } else if prog.isWaitingForStartLock {
                return prog.traveledMeters > 1.0
                    ? L10n.tr("route.status.waiting_relock")
                    : L10n.tr("route.status.waiting_lock")
            } else if viewModel.routeLoopMode != .once {
                return L10n.format("route.status.moving_lap", prog.lapCount)
            } else {
                return L10n.tr("route.status.moving")
            }
        }
        if viewModel.isPlanningRoute {
            return L10n.tr("route.planning.calculating")
        }
        switch viewModel.routeWaypoints.count {
        case 0:
            return L10n.tr("route.planning.empty_title")
        case 1:
            return L10n.tr("route.planning.need_end_title")
        default:
            return L10n.format("route.planning.ready_title", RouteGeometry.formatDistance(viewModel.plannedRouteDistanceMeters))
        }
    }

    private var routeHeaderSubtitle: String {
        if viewModel.isRouteSessionActive, let prog = viewModel.trajectoryProgress {
            let traveled = RouteGeometry.formatDistance(prog.traveledMeters)
            let total = RouteGeometry.formatDistance(prog.totalDistanceMeters)
            let pct = Int((prog.progress * 100).rounded())
            let remainingMeters = prog.isReversing ? prog.traveledMeters : max(0, prog.totalDistanceMeters - prog.traveledMeters)
            let speedForETA = max(prog.currentSpeedMps, viewModel.routeSpeedMps)
            let eta = prog.isCompleted ? L10n.tr("route.eta.done") : RouteGeometry.formatETA(seconds: remainingMeters / max(0.3, speedForETA))
            return "\(traveled) / \(total) · \(pct)% · ETA \(eta)"
        }
        switch viewModel.routeWaypoints.count {
        case 0:
            return L10n.tr("route.planning.empty_subtitle")
        case 1:
            return L10n.format("route.planning.start_selected", viewModel.routeWaypoints[0].name)
        default:
            let eta = RouteGeometry.formatETA(seconds: viewModel.plannedRouteDistanceMeters / max(0.3, viewModel.routeSpeedMps))
            return L10n.format("route.planning.ready_subtitle", viewModel.routeWaypoints.count, eta)
        }
    }

    private var configuredSpeedLabel: String {
        let mps = viewModel.routeSpeedMps
        let kmh = RouteGeometry.formatSpeedKmh(mps)
        if viewModel.routePreset == .running, let pace = RouteGeometry.formatPacePerKm(mps) {
            return "\(kmh) · \(pace)"
        }
        return String(format: "%@ (%.1f m/s)", kmh, mps)
    }

    private func liveSpeedLabel(_ mps: Double) -> String {
        let kmh = RouteGeometry.formatSpeedKmh(mps)
        if viewModel.routePreset == .running, let pace = RouteGeometry.formatPacePerKm(mps) {
            return "\(kmh) · \(pace)"
        }
        return kmh
    }

    @ViewBuilder
    private var restoreLocationStatusBanner: some View {
        if viewModel.needsRestoreLocationRefresh {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.triangle.2.circlepath.circle.fill").foregroundStyle(RelocTheme.amber)
                    Text(L10n.tr("map.restore.banner.stale"))
                        .font(.caption2)
                        .foregroundStyle(.primary)
                }
                Button {
                    RelocTheme.hapticMedium()
                    viewModel.launchOneTapRestoreRefresh()
                } label: {
                    Label(L10n.tr("map.restore.banner.button"), systemImage: "pip.enter")
                        .font(.caption.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(RelocTheme.amber, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .foregroundStyle(.white)
                }
            }
            .padding(10)
            .background(RelocTheme.amber.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L10n.tr("map.restore.banner.working"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L10n.tr("map.restore.banner.refresh_now")) {
                    RelocTheme.hapticLight()
                    viewModel.launchOneTapRestoreRefresh()
                }
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RelocTheme.accent.opacity(0.14), in: Capsule())
                .foregroundStyle(RelocTheme.accent)
            }
            .padding(9)
            .background(RelocTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
    }

    @ViewBuilder
    private var liveTriggerStatusBanner: some View {
        switch viewModel.injectionPhase {
        case .activeConfirmed:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(RelocTheme.emerald)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.tr("map.live.confirmed.title"))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(RelocTheme.emerald)
                    Text(L10n.tr("map.live.confirmed.subtitle"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(10)
            .background(RelocTheme.emerald.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

        case .injectingPendingLock where viewModel.needsLocationServiceRefresh,
             .waitingSubscription where viewModel.needsLocationServiceRefresh:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "bolt.circle.fill").foregroundStyle(RelocTheme.amber)
                    Text(
                        viewModel.injectionPhase == .waitingSubscription
                            ? L10n.tr("map.live.waiting_sub.detail")
                            : (viewModel.isDistantFromRealLocation
                                ? L10n.tr("map.live.pending_lock.distant_detail")
                                : L10n.tr("map.live.pending_lock.detail"))
                    )
                        .font(.caption2)
                        .foregroundStyle(.primary)
                }
                HStack(spacing: 8) {
                    Button {
                        RelocTheme.hapticMedium()
                        viewModel.launchOneTapLocationRefresh()
                    } label: {
                        Label(L10n.tr("map.live.refresh_button"), systemImage: "pip.enter")
                            .font(.caption.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(RelocTheme.amber, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .foregroundStyle(.white)
                    }
                    Button {
                        RelocTheme.hapticLight()
                        viewModel.retryAutoLock()
                    } label: {
                        Text(L10n.tr("common.retry"))
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .foregroundStyle(.primary)
                    }
                }
            }
            .padding(10)
            .background(RelocTheme.amber.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

        default:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(
                    viewModel.injectionPhase == .connecting
                        ? L10n.tr("map.live.connecting")
                        : (viewModel.injectionPhase == .waitingSubscription
                            ? L10n.tr("map.live.waking_sub")
                            : L10n.tr("map.live.injecting"))
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                Spacer()
                if viewModel.snapshot.authenticated {
                    Button(L10n.tr("map.live.force_refresh")) {
                        RelocTheme.hapticLight()
                        viewModel.launchOneTapLocationRefresh()
                    }
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RelocTheme.accent.opacity(0.14), in: Capsule())
                    .foregroundStyle(RelocTheme.accent)
                }
            }
            .padding(9)
            .background(RelocTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
    }

    // MARK: - Search Action

    private func handleMapTap(_ coord: CLLocationCoordinate2D) {
        if isSearchFocused || hasSearchDropdown {
            dismissSearchOverlay()
            return
        }
        RelocTheme.hapticLight()
        if isRouteMode {
            guard !viewModel.isRouteSessionActive else { return }
            viewModel.addRouteWaypoint(fromMapCoordinate: coord)
        } else {
            viewModel.selectLocationFromMap(coord)
        }
    }

    private func clearSearch() {
        activeSearch?.cancel()
        activeSearch = nil
        isSearching = false
        searchText = ""
        searchResults = []
        searchStatusMessage = nil
        searchCompleter.clear()
    }

    private func dismissSearchOverlay() {
        isSearchFocused = false
        searchStatusMessage = nil
        searchResults = []
        searchCompleter.clear()
    }

    static func formattedAddress(for item: MKMapItem) -> String? {
        if let title = item.placemark.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty, title != item.name {
            return title
        }
        let parts = [
            item.placemark.administrativeArea,
            item.placemark.locality,
            item.placemark.subLocality,
            item.placemark.thoroughfare,
            item.placemark.subThoroughfare
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        if !parts.isEmpty {
            return parts.joined(separator: " ")
        }
        let coord = item.placemark.coordinate
        return String(format: "%.5f, %.5f", coord.latitude, coord.longitude)
    }

    private func searchErrorDescription(for error: Error?) -> String {
        if let mkError = error as? MKError {
            switch mkError.code {
            case .placemarkNotFound:
                return L10n.tr("map.search.error.not_found")
            case .loadingThrottled:
                return L10n.tr("map.search.error.throttled")
            default:
                return L10n.tr("map.search.error.network")
            }
        }
        return error != nil ? L10n.tr("map.search.error.network") : L10n.tr("map.search.error.not_found")
    }

    private func parseCoordinateInput(_ input: String) -> (lat: Double, lon: Double, alt: Double?)? {
        let normalized = input.replacingOccurrences(of: "，", with: ",")
        let parts = normalized.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 || parts.count == 3,
              let lat = Double(parts[0]), let lon = Double(parts[1]),
              lat.isFinite, lon.isFinite,
              (-90.0...90.0).contains(lat), (-180.0...180.0).contains(lon) else {
            return nil
        }
        if parts.count == 3 {
            let altToken = parts[2].trimmingCharacters(in: CharacterSet(charactersIn: "mM "))
            guard let alt = Double(altToken), alt.isFinite, (-500.0...50_000.0).contains(alt) else {
                return nil
            }
            return (lat, lon, alt)
        }
        return (lat, lon, nil)
    }

    private func handleSearchTextChange(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        searchStatusMessage = nil
        if !searchResults.isEmpty {
            searchResults = []
        }
        guard !trimmed.isEmpty, parseCoordinateInput(trimmed) == nil else {
            searchCompleter.clear()
            return
        }
        searchCompleter.update(query: trimmed, region: currentSearchRegion)
    }

    private func applyMapItemSelection(_ item: MKMapItem) {
        RelocTheme.hapticLight()
        isSearchFocused = false
        activeSearch?.cancel()
        activeSearch = nil
        isSearching = false
        searchStatusMessage = nil
        searchCompleter.clear()
        let coord = item.placemark.coordinate
        if isRouteMode && !viewModel.isRouteSessionActive {
            viewModel.addRouteWaypoint(fromSearchCoordinate: coord, name: item.name)
            if let last = viewModel.routeMapWaypointCoordinates.last {
                cameraTarget = last
            }
        } else {
            viewModel.selectSearchResultCoordinate(coord, name: item.name, address: item.placemark.title)
            cameraTarget = viewModel.pendingMapCoordinate ?? viewModel.activeMapCoordinate
        }
        searchResults = []
        searchText = ""
    }

    private func selectSuggestion(_ suggestion: LocationSearchSuggestion) {
        switch suggestion {
        case .mapItem(let item, _):
            applyMapItemSelection(item)
        case .completion(let completion, _):
            selectCompletion(completion)
        }
    }

    private func selectCompletion(_ completion: MKLocalSearchCompletion) {
        RelocTheme.hapticLight()
        isSearchFocused = false
        activeSearch?.cancel()
        isSearching = true
        searchStatusMessage = nil
        searchResults = []
        searchCompleter.clear()

        let req = MKLocalSearch.Request(completion: completion)
        let search = MKLocalSearch(request: req)
        activeSearch = search
        search.start { response, error in
            Task { @MainActor in
                guard activeSearch === search else { return }
                activeSearch = nil
                isSearching = false
                let items = response?.mapItems ?? []
                if let first = items.first, items.count == 1 || !completion.subtitle.isEmpty {
                    applyMapItemSelection(first)
                } else if !items.isEmpty {
                    searchResults = items
                } else {
                    searchStatusMessage = searchErrorDescription(for: error)
                }
            }
        }
    }

    private func performSearch() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSearchFocused = false
        searchStatusMessage = nil
        searchCompleter.clear()

        if let coord = parseCoordinateInput(trimmed) {
            if isRouteMode && !viewModel.isRouteSessionActive {
                let pt = RoutePoint(
                    latitude: coord.lat,
                    longitude: coord.lon,
                    altitude: coord.alt ?? viewModel.inspectedLocation.altitude
                )
                viewModel.addRouteWaypointWGS(pt, name: String(format: "%.5f, %.5f", coord.lat, coord.lon))
                if let last = viewModel.routeMapWaypointCoordinates.last {
                    cameraTarget = last
                }
            } else {
                let loc = TargetLocation(
                    latitude: coord.lat,
                    longitude: coord.lon,
                    altitude: coord.alt ?? viewModel.inspectedLocation.altitude
                )
                viewModel.selectWGSLocation(loc, resolveAltitude: coord.alt == nil)
                cameraTarget = viewModel.pendingMapCoordinate ?? viewModel.activeMapCoordinate
            }
            searchResults = []
            searchText = ""
            return
        }

        activeSearch?.cancel()
        isSearching = true
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = trimmed
        req.region = currentSearchRegion
        let search = MKLocalSearch(request: req)
        activeSearch = search
        search.start { response, error in
            Task { @MainActor in
                guard activeSearch === search else { return }
                activeSearch = nil
                isSearching = false
                let items = response?.mapItems ?? []
                searchResults = items
                if items.isEmpty {
                    searchStatusMessage = searchErrorDescription(for: error)
                }
            }
        }
    }
}

// MARK: - Live Viewport-Scoped Location Search Completer

private enum LocationSearchSuggestion: Identifiable {
    case completion(MKLocalSearchCompletion, Int)
    case mapItem(MKMapItem, Int)

    var id: String {
        switch self {
        case .completion(let c, let idx):
            return "c-\(idx)-\(c.title)-\(c.subtitle)"
        case .mapItem(let m, let idx):
            let coord = m.placemark.coordinate
            return "m-\(idx)-\(m.name ?? "")-\(coord.latitude)-\(coord.longitude)"
        }
    }

    var isDirectMapItem: Bool {
        if case .mapItem = self { return true }
        return false
    }

    var title: String {
        switch self {
        case .completion(let c, _): return c.title
        case .mapItem(let m, _): return m.name ?? L10n.tr("map.unknown_place")
        }
    }

    var subtitle: String? {
        switch self {
        case .completion(let c, _):
            let trimmed = c.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .mapItem(let m, _):
            return MapPickerView.formattedAddress(for: m)
        }
    }
}

@MainActor
private final class LocationSearchCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published private(set) var suggestions: [LocationSearchSuggestion] = []

    private let completer = MKLocalSearchCompleter()
    private var debounceTask: Task<Void, Never>?
    private var fallbackTask: Task<Void, Never>?
    private var fallbackSearch: MKLocalSearch?
    private var activeQuery = ""
    private var activeRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.334606, longitude: -122.009102),
        span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)
    )
    private var completerRespondedForActiveQuery = false

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func update(query: String, region: MKCoordinateRegion) {
        debounceTask?.cancel()
        fallbackTask?.cancel()
        fallbackSearch?.cancel()
        fallbackSearch = nil

        activeQuery = query
        activeRegion = region
        completerRespondedForActiveQuery = false

        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, let self, self.activeQuery == query else { return }
            self.completer.region = region
            self.completer.queryFragment = query
            self.scheduleFallbackSearch(for: query, region: region, delayNanoseconds: 420_000_000)
        }
    }

    func clear() {
        debounceTask?.cancel()
        debounceTask = nil
        fallbackTask?.cancel()
        fallbackTask = nil
        fallbackSearch?.cancel()
        fallbackSearch = nil
        activeQuery = ""
        completerRespondedForActiveQuery = false
        if !completer.queryFragment.isEmpty {
            completer.queryFragment = ""
        }
        if !suggestions.isEmpty {
            suggestions = []
        }
    }

    private func scheduleFallbackSearch(for query: String, region: MKCoordinateRegion, delayNanoseconds: UInt64) {
        fallbackTask?.cancel()
        fallbackTask = Task { [weak self] in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled, let self, self.activeQuery == query else { return }
            if self.completerRespondedForActiveQuery && !self.suggestions.isEmpty {
                return
            }
            self.runFallbackLocalSearch(query: query, region: region)
        }
    }

    private func runFallbackLocalSearch(query: String, region: MKCoordinateRegion) {
        fallbackSearch?.cancel()
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = query
        req.region = region
        let search = MKLocalSearch(request: req)
        fallbackSearch = search
        search.start { [weak self] response, _ in
            Task { @MainActor [weak self] in
                guard let self,
                      self.fallbackSearch === search,
                      self.activeQuery == query else { return }
                self.fallbackSearch = nil
                guard !(self.completerRespondedForActiveQuery && !self.suggestions.isEmpty) else { return }
                let items = response?.mapItems ?? []
                self.suggestions = items.prefix(6).enumerated().map { .mapItem($1, $0) }
            }
        }
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results
        let fragment = completer.queryFragment
        Task { @MainActor [weak self] in
            guard let self, !self.activeQuery.isEmpty, fragment == self.activeQuery else { return }
            if !results.isEmpty {
                self.completerRespondedForActiveQuery = true
                self.fallbackTask?.cancel()
                self.fallbackSearch?.cancel()
                self.fallbackSearch = nil
                self.suggestions = results.prefix(6).enumerated().map { .completion($1, $0) }
            } else {
                self.scheduleFallbackSearch(for: self.activeQuery, region: self.activeRegion, delayNanoseconds: 0)
            }
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        let fragment = completer.queryFragment
        Task { @MainActor [weak self] in
            guard let self, !self.activeQuery.isEmpty, fragment == self.activeQuery else { return }
            self.scheduleFallbackSearch(for: self.activeQuery, region: self.activeRegion, delayNanoseconds: 0)
        }
    }
}

// MARK: - Interactive MKMapView Wrapper

private struct InteractiveMKMapView: UIViewRepresentable {
    let activeCoordinate: CLLocationCoordinate2D
    let isSessionRunning: Bool
    let pendingCoordinate: CLLocationCoordinate2D?
    var routePolyline: [CLLocationCoordinate2D] = []
    var routeWaypoints: [CLLocationCoordinate2D] = []
    var showActivePin: Bool = true
    let mapStyle: MapDisplayStyle
    @Binding var cameraTarget: CLLocationCoordinate2D?
    let onTapCoordinate: (CLLocationCoordinate2D) -> Void
    var onRegionChange: ((MKCoordinateRegion) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(onTapCoordinate: onTapCoordinate, onRegionChange: onRegionChange)
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.showsCompass = true
        mapView.showsScale = true

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        mapView.addGestureRecognizer(tap)

        applyMapStyle(to: mapView)

        if showActivePin {
            let activeAnn = TaggedAnnotation(kind: .active)
            activeAnn.coordinate = activeCoordinate
            activeAnn.title = L10n.tr("map.pin.active")
            mapView.addAnnotation(activeAnn)
            context.coordinator.activeAnnotation = activeAnn
        }

        context.coordinator.syncRoute(on: mapView, polyline: routePolyline, waypoints: routeWaypoints, isRunning: isSessionRunning)

        let region = MKCoordinateRegion(
            center: activeCoordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
        )
        mapView.setRegion(region, animated: false)
        if let onRegionChange {
            DispatchQueue.main.async {
                onRegionChange(region)
            }
        }
        return mapView
    }

    func updateUIView(_ uiView: MKMapView, context: Context) {
        context.coordinator.onTapCoordinate = onTapCoordinate
        context.coordinator.onRegionChange = onRegionChange
        context.coordinator.isSessionRunning = isSessionRunning

        applyMapStyle(to: uiView)

        if showActivePin {
            if let activeAnn = context.coordinator.activeAnnotation {
                let activeTitle = L10n.tr("map.pin.active")
                if activeAnn.title != activeTitle {
                    activeAnn.title = activeTitle
                }
                if abs(activeAnn.coordinate.latitude - activeCoordinate.latitude) > 1e-9 ||
                   abs(activeAnn.coordinate.longitude - activeCoordinate.longitude) > 1e-9 {
                    activeAnn.coordinate = activeCoordinate
                }
                if let markerView = uiView.view(for: activeAnn) as? MKMarkerAnnotationView {
                    markerView.markerTintColor = isSessionRunning ? UIColor(RelocTheme.emerald) : UIColor(RelocTheme.accent)
                }
            } else {
                let activeAnn = TaggedAnnotation(kind: .active)
                activeAnn.coordinate = activeCoordinate
                activeAnn.title = L10n.tr("map.pin.active")
                uiView.addAnnotation(activeAnn)
                context.coordinator.activeAnnotation = activeAnn
            }
        } else if let activeAnn = context.coordinator.activeAnnotation {
            uiView.removeAnnotation(activeAnn)
            context.coordinator.activeAnnotation = nil
        }

        if let pending = pendingCoordinate {
            let pendingTitle = L10n.tr("map.pin.pending")
            if let existing = context.coordinator.pendingAnnotation {
                if existing.title != pendingTitle {
                    existing.title = pendingTitle
                }
                existing.coordinate = pending
            } else {
                let ann = TaggedAnnotation(kind: .pending)
                ann.coordinate = pending
                ann.title = pendingTitle
                uiView.addAnnotation(ann)
                context.coordinator.pendingAnnotation = ann
            }
        } else if let existing = context.coordinator.pendingAnnotation {
            uiView.removeAnnotation(existing)
            context.coordinator.pendingAnnotation = nil
        }

        context.coordinator.syncRoute(on: uiView, polyline: routePolyline, waypoints: routeWaypoints, isRunning: isSessionRunning)

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

    private func applyMapStyle(to mapView: MKMapView) {
        switch mapStyle {
        case .standard: mapView.mapType = .standard
        case .satellite: mapView.mapType = .satellite
        case .hybrid: mapView.mapType = .hybrid
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

    final class RoutePinAnnotation: MKPointAnnotation {
        enum Role {
            case start
            case via(Int)
            case end
        }
        let role: Role
        init(role: Role) {
            self.role = role
            super.init()
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var onTapCoordinate: (CLLocationCoordinate2D) -> Void
        var onRegionChange: ((MKCoordinateRegion) -> Void)?
        var isSessionRunning = false
        var activeAnnotation: TaggedAnnotation?
        var pendingAnnotation: TaggedAnnotation?
        var routeOverlay: MKPolyline?
        var routeWaypointAnnotations: [RoutePinAnnotation] = []
        var lastPolylineSignature = ""
        var lastWaypointsSignature = ""
        var lastRunningColorState = false

        init(
            onTapCoordinate: @escaping (CLLocationCoordinate2D) -> Void,
            onRegionChange: ((MKCoordinateRegion) -> Void)?
        ) {
            self.onTapCoordinate = onTapCoordinate
            self.onRegionChange = onRegionChange
        }

        func syncRoute(
            on mapView: MKMapView,
            polyline: [CLLocationCoordinate2D],
            waypoints: [CLLocationCoordinate2D],
            isRunning: Bool
        ) {
            let polySig: String
            if let first = polyline.first, let last = polyline.last {
                polySig = "\(polyline.count):\(String(format: "%.5f,%.5f", first.latitude, first.longitude)):\(String(format: "%.5f,%.5f", last.latitude, last.longitude))"
            } else {
                polySig = ""
            }
            if polySig != lastPolylineSignature || lastRunningColorState != isRunning {
                lastPolylineSignature = polySig
                lastRunningColorState = isRunning
                if let existing = routeOverlay {
                    mapView.removeOverlay(existing)
                    routeOverlay = nil
                }
                if polyline.count >= 2 {
                    let overlay = MKPolyline(coordinates: polyline, count: polyline.count)
                    mapView.addOverlay(overlay, level: .aboveRoads)
                    routeOverlay = overlay
                }
            }

            let wpSig = waypoints.map { String(format: "%.5f,%.5f", $0.latitude, $0.longitude) }.joined(separator: ";")
            if wpSig != lastWaypointsSignature {
                lastWaypointsSignature = wpSig
                if !routeWaypointAnnotations.isEmpty {
                    mapView.removeAnnotations(routeWaypointAnnotations)
                    routeWaypointAnnotations.removeAll()
                }
                for (idx, coord) in waypoints.enumerated() {
                    let role: RoutePinAnnotation.Role
                    let title: String
                    if idx == 0 {
                        role = .start
                        title = L10n.tr("route.pin.start")
                    } else if idx == waypoints.count - 1 {
                        role = .end
                        title = L10n.tr("route.pin.end")
                    } else {
                        role = .via(idx)
                        title = L10n.format("route.pin.via", idx)
                    }
                    let ann = RoutePinAnnotation(role: role)
                    ann.coordinate = coord
                    ann.title = title
                    routeWaypointAnnotations.append(ann)
                }
                if !routeWaypointAnnotations.isEmpty {
                    mapView.addAnnotations(routeWaypointAnnotations)
                }
            }
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let mapView = gesture.view as? MKMapView else { return }
            let point = gesture.location(in: mapView)
            let coord = mapView.convert(point, toCoordinateFrom: mapView)
            onTapCoordinate(coord)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let region = mapView.region
            DispatchQueue.main.async { [weak self] in
                self?.onRegionChange?(region)
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = isSessionRunning ? UIColor(RelocTheme.emerald) : UIColor(RelocTheme.accent)
                renderer.lineWidth = 5.5
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let routePin = annotation as? RoutePinAnnotation {
                let id = "reloc.route.pin"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
                view.annotation = annotation
                view.displayPriority = .required
                switch routePin.role {
                case .start:
                    view.markerTintColor = UIColor(RelocTheme.emerald)
                    view.glyphText = nil
                    view.glyphImage = UIImage(systemName: "flag.fill")
                case .end:
                    view.markerTintColor = UIColor(RelocTheme.crimson)
                    view.glyphText = nil
                    view.glyphImage = UIImage(systemName: "flag.checkered")
                case .via(let number):
                    view.markerTintColor = UIColor(RelocTheme.accent)
                    view.glyphImage = nil
                    view.glyphText = "\(number)"
                }
                return view
            }
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
    @State private var newRouteName = ""
    @State private var renamingFavorite: FavoriteLocation?
    @State private var renamingRoute: SavedRoute?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker(L10n.tr("places.picker"), selection: $tab) {
                    Text(L10n.format("places.tab.favorites", viewModel.favorites.count)).tag(0)
                    Text(L10n.format("places.tab.routes", viewModel.savedRoutes.count)).tag(1)
                    Text(L10n.format("places.tab.recents", viewModel.recents.count)).tag(2)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                List {
                    if tab == 0 {
                        Section(L10n.tr("places.save_current.header")) {
                            HStack {
                                TextField(L10n.tr("places.name.placeholder"), text: $newFavoriteName)
                                Button(L10n.tr("common.save")) {
                                    viewModel.saveCurrentAsFavorite(name: newFavoriteName)
                                    newFavoriteName = ""
                                }
                                .disabled(newFavoriteName.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                        }

                        Section(L10n.tr("places.favorites.header")) {
                            if viewModel.favorites.isEmpty {
                                Text(L10n.tr("places.favorites.empty")).foregroundStyle(.secondary)
                            } else {
                                ForEach(viewModel.favorites) { fav in
                                    Button {
                                        if viewModel.controlMode == .route && !viewModel.isRouteSessionActive {
                                            viewModel.addRouteWaypointWGS(
                                                RoutePoint(latitude: fav.latitude, longitude: fav.longitude, altitude: fav.altitude),
                                                name: fav.name
                                            )
                                            if let last = viewModel.routeMapWaypointCoordinates.last {
                                                onSelect(last)
                                            }
                                        } else {
                                            viewModel.selectWGSLocation(
                                                TargetLocation(latitude: fav.latitude, longitude: fav.longitude, altitude: fav.altitude),
                                                name: fav.name,
                                                address: fav.subtitle
                                            )
                                            onSelect(viewModel.pendingMapCoordinate ?? viewModel.activeMapCoordinate)
                                        }
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
                                            Label(L10n.tr("common.delete"), systemImage: "trash")
                                        }
                                        Button {
                                            renameText = fav.name
                                            renamingFavorite = fav
                                        } label: {
                                            Label(L10n.tr("common.rename"), systemImage: "pencil")
                                        }
                                        .tint(.orange)
                                    }
                                }
                            }
                        }
                    } else if tab == 1 {
                        if viewModel.plannedRoutePoints.count >= 2 && !viewModel.isPlanningRoute {
                            Section(L10n.tr("places.routes.save_current")) {
                                HStack {
                                    TextField(L10n.tr("route.save.placeholder"), text: $newRouteName)
                                    Button(L10n.tr("common.save")) {
                                        viewModel.saveCurrentRoute(name: newRouteName)
                                        newRouteName = ""
                                    }
                                    .disabled(newRouteName.trimmingCharacters(in: .whitespaces).isEmpty)
                                }
                            }
                        }

                        Section(L10n.tr("places.routes.header")) {
                            if viewModel.savedRoutes.isEmpty {
                                Text(L10n.tr("places.routes.empty")).foregroundStyle(.secondary)
                            } else {
                                ForEach(viewModel.savedRoutes) { route in
                                    Button {
                                        viewModel.loadSavedRoute(route)
                                        if let first = viewModel.routeMapWaypointCoordinates.first {
                                            onSelect(first)
                                        }
                                        dismiss()
                                    } label: {
                                        HStack(spacing: 10) {
                                            SettingsIconBadge(systemName: route.preset.systemImage, color: RelocTheme.accent)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(route.name)
                                                    .foregroundStyle(.primary)
                                                    .lineLimit(1)
                                                Text("\(route.preset.title) · \(RouteGeometry.formatDistance(route.totalDistanceMeters)) · \(route.loopMode.title)")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }
                                        }
                                    }
                                    .disabled(viewModel.snapshot.isRunning)
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) {
                                            viewModel.deleteSavedRoute(id: route.id)
                                        } label: {
                                            Label(L10n.tr("common.delete"), systemImage: "trash")
                                        }
                                        Button {
                                            renameText = route.name
                                            renamingRoute = route
                                        } label: {
                                            Label(L10n.tr("common.rename"), systemImage: "pencil")
                                        }
                                        .tint(.orange)
                                    }
                                }
                            }
                        }
                    } else {
                        Section {
                            if viewModel.recents.isEmpty {
                                Text(L10n.tr("places.recents.empty")).foregroundStyle(.secondary)
                            } else {
                                ForEach(viewModel.recents) { item in
                                    Button {
                                        if viewModel.controlMode == .route && !viewModel.isRouteSessionActive {
                                            viewModel.addRouteWaypointWGS(
                                                RoutePoint(latitude: item.latitude, longitude: item.longitude, altitude: item.altitude),
                                                name: item.name
                                            )
                                            if let last = viewModel.routeMapWaypointCoordinates.last {
                                                onSelect(last)
                                            }
                                        } else {
                                            viewModel.selectWGSLocation(
                                                TargetLocation(latitude: item.latitude, longitude: item.longitude, altitude: item.altitude),
                                                name: item.name,
                                                address: item.subtitle
                                            )
                                            onSelect(viewModel.pendingMapCoordinate ?? viewModel.activeMapCoordinate)
                                        }
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
                                            Label(L10n.tr("common.delete"), systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        } header: {
                            HStack {
                                Text(L10n.tr("places.recents.header"))
                                Spacer()
                                if !viewModel.recents.isEmpty {
                                    Button(L10n.tr("common.clear")) { viewModel.clearRecents() }
                                        .font(.caption)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(L10n.tr("places.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("common.close")) { dismiss() }
                }
            }
            .onAppear {
                if viewModel.controlMode == .route {
                    tab = 1
                }
            }
            .alert(L10n.tr("places.rename.title"), isPresented: Binding(
                get: { renamingFavorite != nil || renamingRoute != nil },
                set: { if !$0 { renamingFavorite = nil; renamingRoute = nil } }
            )) {
                TextField(L10n.tr("places.rename.placeholder"), text: $renameText)
                Button(L10n.tr("common.cancel"), role: .cancel) {
                    renamingFavorite = nil
                    renamingRoute = nil
                }
                Button(L10n.tr("common.save")) {
                    if let fav = renamingFavorite {
                        viewModel.renameFavorite(id: fav.id, newName: renameText)
                    } else if let route = renamingRoute {
                        viewModel.renameSavedRoute(id: route.id, newName: renameText)
                    }
                    renamingFavorite = nil
                    renamingRoute = nil
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

    private var parsedCoordinate: (lat: Double, lon: Double, alt: Double, autoAltitude: Bool)? {
        guard let lat = Double(latText.trimmingCharacters(in: .whitespaces)),
              let lon = Double(lonText.trimmingCharacters(in: .whitespaces)),
              lat.isFinite, lon.isFinite,
              (-90.0...90.0).contains(lat),
              (-180.0...180.0).contains(lon) else {
            return nil
        }
        let trimmedAlt = altText.trimmingCharacters(in: .whitespaces)
        if trimmedAlt.isEmpty {
            return (lat, lon, viewModel.inspectedLocation.altitude, true)
        }
        guard let alt = Double(trimmedAlt), alt.isFinite, (-500.0...50_000.0).contains(alt) else {
            return nil
        }
        return (lat, lon, alt, false)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.tr("manual.lat.placeholder"), text: $latText)
                        .keyboardType(.numbersAndPunctuation)
                    TextField(L10n.tr("manual.lon.placeholder"), text: $lonText)
                        .keyboardType(.numbersAndPunctuation)
                    TextField(L10n.tr("manual.alt.placeholder"), text: $altText)
                        .keyboardType(.numbersAndPunctuation)
                } header: {
                    Text(L10n.tr("manual.section.header"))
                } footer: {
                    if parsedCoordinate == nil {
                        Text(L10n.tr("manual.footer.invalid"))
                            .foregroundStyle(RelocTheme.crimson)
                    } else {
                        Text(L10n.tr("manual.footer.hint"))
                    }
                }

                Section(L10n.tr("manual.favorite.header")) {
                    TextField(L10n.tr("manual.favorite.placeholder"), text: $favoriteName)
                }
            }
            .navigationTitle(L10n.tr("manual.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("common.apply")) {
                        guard let parsed = parsedCoordinate else { return }
                        let trimmedName = favoriteName.trimmingCharacters(in: .whitespaces)
                        viewModel.selectWGSLocation(
                            TargetLocation(latitude: parsed.lat, longitude: parsed.lon, altitude: parsed.alt),
                            name: trimmedName.isEmpty ? nil : trimmedName,
                            resolveAltitude: parsed.autoAltitude
                        )
                        if !trimmedName.isEmpty {
                            viewModel.saveCurrentAsFavorite(name: trimmedName)
                        }
                        onApply(viewModel.pendingMapCoordinate ?? viewModel.activeMapCoordinate)
                        dismiss()
                    }
                    .disabled(parsedCoordinate == nil)
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
