import CoreLocation
import Foundation
import MapKit
import SwiftUI

@MainActor
public final class RelocViewModel: ObservableObject {
    public let store = CredentialStore()
    public let coreLocation = LiveCoreLocationMonitor()
    private let keepAlive = BackgroundKeepAlive()
    private let geocoder = CLGeocoder()

    // MARK: - Loopback & Connection Settings
    @Published public var host: String {
        didSet {
            store.host = host
            invalidateDeviceConnection()
        }
    }
    @Published public var remotePort: UInt16 {
        didSet {
            store.remotePort = remotePort
            invalidateDeviceConnection()
        }
    }
    @Published public var lockdownPort: UInt16 {
        didSet {
            store.lockdownPort = lockdownPort
            invalidateDeviceConnection()
        }
    }
    @Published public var serviceName: String {
        didSet { store.serviceName = serviceName }
    }
    @Published public var intervalSeconds: Double {
        didSet { store.intervalSeconds = intervalSeconds }
    }
    @Published public var durationSeconds: Double {
        didSet { store.durationSeconds = durationSeconds }
    }
    @Published public var gcj02CorrectionEnabled: Bool {
        didSet { store.gcj02CorrectionEnabled = gcj02CorrectionEnabled }
    }
    @Published public var backgroundKeepAliveEnabled: Bool {
        didSet {
            store.backgroundKeepAliveEnabled = backgroundKeepAliveEnabled
            if snapshot.isRunning {
                keepAlive.start(useSilentAudio: backgroundKeepAliveEnabled)
            }
        }
    }
    @Published public var microJitterEnabled: Bool {
        didSet {
            store.microJitterEnabled = microJitterEnabled
            if snapshot.isRunning {
                if microJitterEnabled {
                    startJitterTimer()
                } else {
                    stopJitterTimer()
                    pushLocationToSession()
                }
            }
        }
    }
    @Published public var appearanceMode: AppAppearanceMode {
        didSet { store.appearanceMode = appearanceMode }
    }
    @Published public var mapStyle: MapDisplayStyle {
        didSet { store.mapStyle = mapStyle }
    }

    // MARK: - Target & Selected Location (WGS-84)
    /// The location currently being sent to the iPhone (or ready to send).
    @Published public var targetLocation: TargetLocation {
        didSet {
            store.lastTargetLocation = targetLocation
            pushLocationToSession()
        }
    }
    /// Candidate pin dropped on the map while a session is already active (allows browsing before tapping "更新到此位置").
    @Published public var pendingLocation: TargetLocation?
    @Published public var selectedPlaceName: String = "选中位置"
    @Published public var selectedPlaceAddress: String = ""

    // MARK: - Favorites, Recents (30), & Recovery
    @Published public var favorites: [FavoriteLocation] = []
    @Published public var recents: [RecentLocation] = []
    @Published public var interruptedSession: InterruptedSessionRecord?

    // MARK: - Device Pairing & Verification State
    @Published public var pairingStatus: PairingStatus
    @Published public var deviceUDID: String
    @Published public var connectionVerified = false
    @Published public var isVerifyingConnection = false
    @Published public var connectionCheckFailed = false
    @Published public var deviceConnectionStatus = "请先配对这台 iPhone"
    @Published public var discoveredDevicePort: UInt16?

    // MARK: - Session & Diagnostics
    @Published public var snapshot = SessionSnapshot()
    @Published public var events: [ProtocolEvent] = []
    @Published public var alertMessage: String?

    private var savedPairing: SavedPairing?
    private var mfiSigner: RLMFiSigner?
    private var session: AccessoryLocationSession?
    private var jitterTimer: Timer?

    public init() {
        self.host = store.host
        self.remotePort = store.remotePort
        self.lockdownPort = store.lockdownPort
        self.serviceName = store.serviceName
        self.intervalSeconds = store.intervalSeconds
        self.durationSeconds = store.durationSeconds
        self.gcj02CorrectionEnabled = store.gcj02CorrectionEnabled
        self.backgroundKeepAliveEnabled = store.backgroundKeepAliveEnabled
        self.microJitterEnabled = store.microJitterEnabled
        self.appearanceMode = store.appearanceMode
        self.mapStyle = store.mapStyle
        self.targetLocation = store.lastTargetLocation
        self.favorites = store.loadFavorites()
        self.recents = store.loadRecents()
        self.interruptedSession = store.loadInterruptedSession()
        self.deviceUDID = store.deviceUDID

        self.mfiSigner = store.loadBundledMFiSigner()

        let (pairing, pairStat) = store.loadPairing()
        self.savedPairing = pairing
        self.pairingStatus = pairStat
        self.deviceConnectionStatus = pairStat.isLoaded ? "配对记录已保存，等待连接验证" : "请先配对这台 iPhone"

        self.keepAlive.onDiagnostic = { [weak self] event, details in
            guard let self else { return }
            var payload = details
            payload["event"] = event
            let detailText: String
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
               let str = String(data: data, encoding: .utf8) {
                detailText = str
            } else {
                detailText = "{\"event\":\"\(event)\"}"
            }
            self.events.append(ProtocolEvent(name: event, detail: detailText))
            if self.events.count > 500 {
                self.events.removeFirst(self.events.count - 500)
            }
        }

        reverseGeocode(wgsLocation: targetLocation)
    }

    // MARK: - Coordinate Mapping Helpers

    public func toMapCoordinate(_ wgs: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        if gcj02CorrectionEnabled {
            return CoordinateTransform.wgs84ToGCJ02(lat: wgs.latitude, lon: wgs.longitude)
        }
        return wgs
    }

    public func fromMapCoordinate(_ mapCoord: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        if gcj02CorrectionEnabled {
            return CoordinateTransform.gcj02ToWGS84(lat: mapCoord.latitude, lon: mapCoord.longitude)
        }
        return mapCoord
    }

    public var activeMapCoordinate: CLLocationCoordinate2D {
        toMapCoordinate(CLLocationCoordinate2D(latitude: targetLocation.latitude, longitude: targetLocation.longitude))
    }

    public var pendingMapCoordinate: CLLocationCoordinate2D? {
        guard let pending = pendingLocation else { return nil }
        return toMapCoordinate(CLLocationCoordinate2D(latitude: pending.latitude, longitude: pending.longitude))
    }

    /// Coordinate currently highlighted in the bottom card (pending selection if browsing, else active target).
    public var inspectedLocation: TargetLocation {
        pendingLocation ?? targetLocation
    }

    public var isCurrentInspectedFavorite: Bool {
        let loc = inspectedLocation
        return favorites.contains {
            abs($0.latitude - loc.latitude) < 1e-4 && abs($0.longitude - loc.longitude) < 1e-4
        }
    }

    public func selectLocationFromMap(_ mapCoord: CLLocationCoordinate2D, name: String? = nil, address: String? = nil) {
        let wgs = fromMapCoordinate(mapCoord)
        selectWGSLocation(
            TargetLocation(latitude: wgs.latitude, longitude: wgs.longitude, altitude: inspectedLocation.altitude),
            name: name,
            address: address
        )
    }

    public func selectWGSLocation(_ wgsLoc: TargetLocation, name: String? = nil, address: String? = nil) {
        if snapshot.isRunning {
            // Keep active reported location unchanged until user taps "更新到此位置".
            pendingLocation = wgsLoc
        } else {
            pendingLocation = nil
            targetLocation = wgsLoc
        }

        if let name, !name.isEmpty {
            selectedPlaceName = name
            selectedPlaceAddress = address ?? String(format: "%.5f, %.5f", wgsLoc.latitude, wgsLoc.longitude)
        } else {
            selectedPlaceName = String(format: "%.5f, %.5f", wgsLoc.latitude, wgsLoc.longitude)
            selectedPlaceAddress = "正在解析地名…"
            reverseGeocode(wgsLocation: wgsLoc)
        }
    }

    public func clearPendingSelection() {
        pendingLocation = nil
        reverseGeocode(wgsLocation: targetLocation)
    }

    public func applyPendingLocationUpdate() {
        guard let pending = pendingLocation else { return }
        targetLocation = pending
        pendingLocation = nil
        recordRecent(name: selectedPlaceName, subtitle: selectedPlaceAddress, location: targetLocation)
        persistRecoveryRecord()
    }

    private func reverseGeocode(wgsLocation: TargetLocation) {
        geocoder.cancelGeocode()
        let displayCoord = toMapCoordinate(CLLocationCoordinate2D(latitude: wgsLocation.latitude, longitude: wgsLocation.longitude))
        let clLoc = CLLocation(latitude: displayCoord.latitude, longitude: displayCoord.longitude)
        geocoder.reverseGeocodeLocation(clLoc) { [weak self] placemarks, _ in
            Task { @MainActor in
                guard let self, let pm = placemarks?.first else { return }
                let title = pm.name ?? pm.locality ?? pm.administrativeArea ?? String(format: "%.5f, %.5f", wgsLocation.latitude, wgsLocation.longitude)
                let parts = [pm.administrativeArea, pm.locality, pm.subLocality, pm.thoroughfare, pm.subThoroughfare]
                    .compactMap { $0 }
                    .reduce(into: [String]()) { acc, item in
                        if !acc.contains(item) { acc.append(item) }
                    }
                self.selectedPlaceName = title
                self.selectedPlaceAddress = parts.isEmpty
                    ? String(format: "%.5f, %.5f", wgsLocation.latitude, wgsLocation.longitude)
                    : parts.joined(separator: " ")
            }
        }
    }

    // MARK: - Optional Stationary Micro-Jitter

    private func startJitterTimer() {
        stopJitterTimer()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.microJitterEnabled, self.snapshot.isRunning else { return }
                self.pushLocationToSession()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        jitterTimer = timer
    }

    private func stopJitterTimer() {
        jitterTimer?.invalidate()
        jitterTimer = nil
    }

    private func pushLocationToSession() {
        let outgoing = microJitterEnabled
            ? CoordinateTransform.applyMicroJitter(to: targetLocation)
            : targetLocation
        session?.locationBox.set(outgoing)
    }

    // MARK: - Interrupted Session Recovery

    public func resumeInterruptedSession() {
        guard let record = interruptedSession else { return }
        interruptedSession = nil
        store.saveInterruptedSession(nil)

        targetLocation = TargetLocation(latitude: record.latitude, longitude: record.longitude, altitude: record.altitude)
        selectedPlaceName = record.placeName
        pendingLocation = nil
        start(mode: .send)
    }

    public func dismissInterruptedSession() {
        interruptedSession = nil
        store.saveInterruptedSession(nil)
    }

    private func persistRecoveryRecord() {
        let rec = InterruptedSessionRecord(
            placeName: selectedPlaceName,
            latitude: targetLocation.latitude,
            longitude: targetLocation.longitude,
            altitude: targetLocation.altitude
        )
        store.saveInterruptedSession(rec)
    }

    // MARK: - Device Pairing & Loopback Verification

    public var canStartSession: Bool {
        savedPairing != nil && mfiSigner != nil && !snapshot.isRunning
    }

    public func invalidateDeviceConnection() {
        connectionVerified = false
        discoveredDevicePort = nil
        connectionCheckFailed = false
        deviceConnectionStatus = pairingStatus.isLoaded ? "配对记录已保存，等待连接验证" : "请先配对这台 iPhone"
    }

    public func startDevicePairing() {
        guard !snapshot.isRunning, !isVerifyingConnection else { return }
        DevicePairingCoordinator.shared.start { [weak self] rawRecord, hostIRK, udid in
            guard let self else { return }
            _ = try self.store.saveOnDevicePairedIdentity(rawRecord, hostIRK: hostIRK, udid: udid)
            self.reloadPairing()
            self.invalidateDeviceConnection()
            self.testConnection(silent: true)
        }
    }

    public func importDiscoveredPairing() {
        guard !snapshot.isRunning, !DevicePairingCoordinator.shared.isRunning else { return }
        if store.importDiscoveredPairingInDocuments() != nil {
            reloadPairing()
            invalidateDeviceConnection()
            events.append(ProtocolEvent(name: "pairing_auto_imported", detail: "{\"event\":\"pairing_auto_imported\"}"))
        }
    }

    public func verifyConnectionIfNeeded() async {
        guard pairingStatus.isLoaded,
              !connectionVerified,
              !isVerifyingConnection,
              !snapshot.isRunning,
              !DevicePairingCoordinator.shared.isRunning else {
            return
        }
        testConnection(silent: true)
    }

    public func testConnection(silent: Bool = false) {
        guard !isVerifyingConnection, !snapshot.isRunning else { return }
        guard let pairing = savedPairing else {
            deviceConnectionStatus = "请先配对这台 iPhone 或导入配对文件"
            return
        }

        let currentHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentRemotePort = remotePort
        let currentLockdownPort = lockdownPort

        isVerifyingConnection = true
        connectionVerified = false
        connectionCheckFailed = false
        deviceConnectionStatus = "正在发现服务并验证配对身份…"

        Task {
            defer { isVerifyingConnection = false }
            do {
                let result = try await AccessoryLocationSession.verifyConnection(
                    host: currentHost,
                    remotePort: currentRemotePort,
                    lockdownPort: currentLockdownPort,
                    pairing: pairing
                )
                guard self.host.trimmingCharacters(in: .whitespacesAndNewlines) == currentHost,
                      self.remotePort == currentRemotePort,
                      self.lockdownPort == currentLockdownPort else {
                    self.invalidateDeviceConnection()
                    return
                }
                if !result.udid.isEmpty {
                    self.deviceUDID = result.udid
                    self.store.deviceUDID = result.udid
                }
                self.discoveredDevicePort = result.port
                self.connectionVerified = true
                self.deviceConnectionStatus = "设备身份与回环连接已验证"
                self.events.append(ProtocolEvent(
                    name: "connection_verified",
                    detail: "{\"event\":\"connection_verified\",\"port\":\(result.port),\"service\":\"\(result.carkitService ?? "lockdown")\"}"
                ))
            } catch {
                self.connectionVerified = false
                self.connectionCheckFailed = true
                self.deviceConnectionStatus = error.localizedDescription
                self.events.append(ProtocolEvent(
                    name: "connection_check_failed",
                    detail: "{\"event\":\"connection_check_failed\",\"detail\":\"\(error.localizedDescription)\"}",
                    isError: true
                ))
                if !silent {
                    self.alertMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Location Injection Session

    public func start(mode: SessionMode) {
        guard !snapshot.isRunning else { return }
        guard let pairing = savedPairing else {
            alertMessage = "请先在「设备连接」页面完成本机配对或导入配对文件，并确保外部代理已启用 10.7.0.1 回环映射。"
            return
        }
        guard let mfiSigner else {
            alertMessage = "内置配件认证组件不可用，请重新安装应用。"
            return
        }

        if let pending = pendingLocation {
            targetLocation = pending
            pendingLocation = nil
        }

        recordRecent(name: selectedPlaceName, subtitle: selectedPlaceAddress, location: targetLocation)
        persistRecoveryRecord()
        if microJitterEnabled {
            startJitterTimer()
        }

        let config = SessionConfiguration(
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            remotePort: remotePort,
            lockdownPort: lockdownPort,
            serviceName: serviceName.trimmingCharacters(in: .whitespacesAndNewlines),
            mode: mode,
            intervalSeconds: intervalSeconds,
            durationSeconds: mode == .probe ? max(20.0, durationSeconds) : durationSeconds
        )

        keepAlive.start(useSilentAudio: backgroundKeepAliveEnabled)
        coreLocation.requestAndStart()

        let newSession = AccessoryLocationSession(
            initialLocation: targetLocation,
            onEvent: { [weak self] event in
                Task { @MainActor in
                    guard let self else { return }
                    self.events.append(event)
                    if self.events.count > 500 {
                        self.events.removeFirst(self.events.count - 500)
                    }
                }
            },
            onSnapshot: { [weak self] snap in
                Task { @MainActor in
                    guard let self else { return }
                    self.snapshot = snap
                    if !snap.isRunning {
                        self.stopJitterTimer()
                        self.keepAlive.stop()
                        self.coreLocation.stop()
                    }
                }
            },
            onSubscriptionRestarted: { [weak self] in
                Task { @MainActor in
                    self?.keepAlive.refreshAfterLocationToggle()
                }
            }
        )
        self.session = newSession
        newSession.start(
            configuration: config,
            pairing: pairing,
            discoveredRemotePort: discoveredDevicePort,
            mfiSigner: mfiSigner
        )
    }

    public func stopAndRestore() {
        stopJitterTimer()
        session?.stop()
        keepAlive.stop()
        coreLocation.stop()
        store.saveInterruptedSession(nil)
        interruptedSession = nil
    }

    // MARK: - Pairing & Places Management

    public func reloadPairing() {
        let (pairing, pairStat) = store.loadPairing()
        self.savedPairing = pairing
        self.pairingStatus = pairStat
        self.deviceUDID = store.deviceUDID
    }

    public func importPairingFile(url: URL) {
        do {
            _ = try store.importPairingFile(from: url)
            reloadPairing()
            invalidateDeviceConnection()
            events.append(ProtocolEvent(name: "pairing_imported", detail: "{\"event\":\"pairing_imported\"}"))
            testConnection(silent: true)
        } catch {
            alertMessage = "配对文件导入失败：\(error.localizedDescription)"
        }
    }

    public func removePairingFile() {
        store.removePairingFile()
        reloadPairing()
        invalidateDeviceConnection()
    }

    public func toggleFavoriteForInspected() {
        let loc = inspectedLocation
        if let idx = favorites.firstIndex(where: { abs($0.latitude - loc.latitude) < 1e-4 && abs($0.longitude - loc.longitude) < 1e-4 }) {
            favorites.remove(at: idx)
        } else {
            favorites.insert(
                FavoriteLocation(
                    name: selectedPlaceName,
                    subtitle: selectedPlaceAddress,
                    latitude: loc.latitude,
                    longitude: loc.longitude,
                    altitude: loc.altitude
                ),
                at: 0
            )
        }
        store.saveFavorites(favorites)
    }

    public func saveCurrentAsFavorite(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let loc = inspectedLocation
        favorites.insert(
            FavoriteLocation(
                name: trimmed,
                subtitle: selectedPlaceAddress,
                latitude: loc.latitude,
                longitude: loc.longitude,
                altitude: loc.altitude
            ),
            at: 0
        )
        store.saveFavorites(favorites)
    }

    public func renameFavorite(id: UUID, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = favorites.firstIndex(where: { $0.id == id }) else { return }
        favorites[idx].name = trimmed
        store.saveFavorites(favorites)
    }

    public func deleteFavorite(at offsets: IndexSet) {
        favorites.remove(atOffsets: offsets)
        store.saveFavorites(favorites)
    }

    public func deleteFavorite(id: UUID) {
        favorites.removeAll { $0.id == id }
        store.saveFavorites(favorites)
    }

    public func recordRecent(name: String, subtitle: String?, location: TargetLocation) {
        recents.removeAll {
            abs($0.latitude - location.latitude) < 1e-4 && abs($0.longitude - location.longitude) < 1e-4
        }
        recents.insert(
            RecentLocation(
                name: name.isEmpty ? String(format: "%.5f, %.5f", location.latitude, location.longitude) : name,
                subtitle: subtitle,
                latitude: location.latitude,
                longitude: location.longitude,
                altitude: location.altitude
            ),
            at: 0
        )
        if recents.count > 30 {
            recents = Array(recents.prefix(30))
        }
        store.saveRecents(recents)
    }

    public func deleteRecent(id: UUID) {
        recents.removeAll { $0.id == id }
        store.saveRecents(recents)
    }

    public func clearRecents() {
        recents.removeAll()
        store.saveRecents([])
    }

    public func clearLogs() {
        events.removeAll()
    }

    public func exportedLogsText() -> String {
        let formatter = ISO8601DateFormatter()
        return events.map { "[\(formatter.string(from: $0.timestamp))] \($0.detail)" }.joined(separator: "\n")
    }
}
