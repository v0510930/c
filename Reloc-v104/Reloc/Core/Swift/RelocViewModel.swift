import Combine
import CoreLocation
import Foundation
import MapKit
import SwiftUI
import UIKit

public enum InjectionPhase: Equatable, Sendable {
    case idle
    case connecting
    case waitingSubscription
    case injectingPendingLock
    case activeConfirmed
}

@MainActor
public final class RelocViewModel: ObservableObject {
    public let store = CredentialStore()
    public let coreLocation = LiveCoreLocationMonitor()
    private let keepAlive = BackgroundKeepAlive()
    private let geocoder = CLGeocoder()
    private var cancellables = Set<AnyCancellable>()

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
            keepAlive.setAudioKeepAliveEnabled(backgroundKeepAliveEnabled)
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
    @Published public var appLanguage: AppLanguage {
        didSet {
            store.appLanguage = appLanguage
            reverseGeocode(wgsLocation: inspectedLocation)
        }
    }
    @Published public var mapStyle: MapDisplayStyle {
        didSet { store.mapStyle = mapStyle }
    }
    @Published public var mapSource: MapSource {
        didSet { store.mapSource = mapSource }
    }

    // MARK: - Target & Selected Location (WGS-84)
    /// The location currently being sent to the iPhone (or ready to send).
    @Published public var targetLocation: TargetLocation {
        didSet {
            store.lastTargetLocation = targetLocation
            pushLocationToSession()
        }
    }
    /// Candidate pin dropped on the map while a session is already active (allows browsing before tapping Update).
    @Published public var pendingLocation: TargetLocation?
    @Published public var selectedPlaceName: String = L10n.tr("map.selected_place")
    @Published public var selectedPlaceAddress: String = ""

    // MARK: - Favorites, Recents (30), & Recovery
    @Published public var favorites: [FavoriteLocation] = []
    @Published public var recents: [RecentLocation] = []
    @Published public var interruptedSession: InterruptedSessionRecord?

    // MARK: - Altitude Resolution
    @Published public var isResolvingAltitude = false

    // MARK: - Session & Diagnostics
    @Published public var snapshot = SessionSnapshot()
    @Published public var injectionPhase: InjectionPhase = .idle
    @Published public var isAccessoryLocationConfirmed = false
    @Published public var needsLocationServiceRefresh = false
    @Published public var isLocationRefreshGuideActive = false
    @Published public var isRestoringRealLocation = false
    @Published public var needsRestoreLocationRefresh = false
    @Published public var realLocationRestoredNotice = false
    @Published public private(set) var locationAuthorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published public private(set) var isLocationReducedAccuracy = false
    @Published public var events: [ProtocolEvent] = []
    @Published public var alertMessage: String?

    private var mfiSigner: RLMFiSigner?
    private var session: AccessoryLocationSession?
    private var lastKnownRealLocation: TargetLocation?
    private var jitterTimer: Timer?
    private var subscriptionPulseTask: Task<Void, Never>?
    private var lockWatchdogTask: Task<Void, Never>?
    private var refreshCountdownTask: Task<Void, Never>?
    private var locationStopDebounceTask: Task<Void, Never>?
    private var locationRefreshSawDisabled = false
    private var didAutoReconnectForSubscription = false
    private var didAutoSoftReconnectForCurrentTarget = false
    private var loggedReducedAccuracyForSession = false
    private var restoreTask: Task<Void, Never>?
    private var isRestoreRefreshGuideActive = false
    private var lastRestoreAuthStatus: CLAuthorizationStatus = .notDetermined
    private var geocodeTask: Task<Void, Never>?
    private var geocodeGeneration: Int = 0
    private var elevationTask: Task<Void, Never>?
    private var elevationGeneration: Int = 0

    public init() {
        self.intervalSeconds = store.intervalSeconds
        self.durationSeconds = store.durationSeconds
        self.gcj02CorrectionEnabled = store.gcj02CorrectionEnabled
        self.backgroundKeepAliveEnabled = store.backgroundKeepAliveEnabled
        self.microJitterEnabled = store.microJitterEnabled
        self.appearanceMode = store.appearanceMode
        self.appLanguage = store.appLanguage
        self.mapStyle = store.mapStyle
        self.mapSource = store.mapSource
        self.targetLocation = store.lastTargetLocation
        self.favorites = store.loadFavorites()
        self.recents = store.loadRecents()
        self.interruptedSession = store.loadInterruptedSession()
        self.locationAuthorizationStatus = coreLocation.authorizationStatus
        self.isLocationReducedAccuracy = coreLocation.isReducedAccuracy

        self.mfiSigner = store.loadBundledMFiSigner()

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

        self.coreLocation.$latest
            .receive(on: RunLoop.main)
            .sink { [weak self] telemetry in
                self?.evaluateCoreLocationConfirmation(telemetry)
            }
            .store(in: &cancellables)

        self.coreLocation.$authorizationStatus
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                guard let self else { return }
                if self.locationAuthorizationStatus != status {
                    self.locationAuthorizationStatus = status
                }
                self.isLocationReducedAccuracy = self.coreLocation.isReducedAccuracy
                self.handleCoreLocationAuthChangeForRestore(status)
            }
            .store(in: &cancellables)

        self.coreLocation.$accuracyAuthorization
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.isLocationReducedAccuracy = self.coreLocation.isReducedAccuracy
            }
            .store(in: &cancellables)

        reverseGeocode(wgsLocation: targetLocation)
    }

    // MARK: - Coordinate Mapping Helpers

    /// True only when displaying Apple's native MapKit with Mainland China GCJ-02 correction enabled.
    /// Pure WGS-84 tile sources (CARTO / OSM / Esri) never apply GCJ-02 display shift.
    public var usesGCJ02MapCoordinates: Bool {
        !mapSource.isPureWGS84 && gcj02CorrectionEnabled
    }

    public func toMapCoordinate(_ wgs: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        if usesGCJ02MapCoordinates {
            return CoordinateTransform.wgs84ToGCJ02(lat: wgs.latitude, lon: wgs.longitude)
        }
        return wgs
    }

    public func fromMapCoordinate(_ mapCoord: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        if usesGCJ02MapCoordinates {
            return CoordinateTransform.gcj02ToWGS84(lat: mapCoord.latitude, lon: mapCoord.longitude)
        }
        return mapCoord
    }

    /// Converts an `MKLocalSearch` result coordinate into canonical WGS-84.
    /// Apple's `MKLocalSearch` returns GCJ-02 for Mainland China POIs regardless of custom tile overlays.
    public func selectSearchResultCoordinate(_ searchCoord: CLLocationCoordinate2D, name: String? = nil, address: String? = nil) {
        let wgs: CLLocationCoordinate2D
        if gcj02CorrectionEnabled && !CoordinateTransform.isOutsideChina(lat: searchCoord.latitude, lon: searchCoord.longitude) {
            wgs = CoordinateTransform.gcj02ToWGS84(lat: searchCoord.latitude, lon: searchCoord.longitude)
        } else {
            wgs = searchCoord
        }
        selectWGSLocation(
            TargetLocation(latitude: wgs.latitude, longitude: wgs.longitude, altitude: inspectedLocation.altitude),
            name: name,
            address: address,
            resolveAltitude: true
        )
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
            address: address,
            resolveAltitude: true
        )
    }

    public func selectWGSLocation(
        _ wgsLoc: TargetLocation,
        name: String? = nil,
        address: String? = nil,
        resolveAltitude: Bool = false
    ) {
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
            selectedPlaceAddress = L10n.tr("map.geocoding")
            reverseGeocode(wgsLocation: wgsLoc)
        }

        if resolveAltitude {
            resolveElevation(for: wgsLoc)
        } else {
            cancelElevationResolution()
        }
    }

    public func clearPendingSelection() {
        pendingLocation = nil
        cancelElevationResolution()
        reverseGeocode(wgsLocation: targetLocation)
    }

    public func applyPendingLocationUpdate() {
        guard let pending = pendingLocation else { return }
        targetLocation = pending
        pendingLocation = nil
        isAccessoryLocationConfirmed = false
        needsLocationServiceRefresh = false
        didAutoSoftReconnectForCurrentTarget = false
        session?.notifyLocationUpdated(resetKalman: true, burstSeconds: 10.0)
        recordRecent(name: selectedPlaceName, subtitle: selectedPlaceAddress, location: targetLocation)
        persistRecoveryRecord()
        if snapshot.isRunning {
            updateInjectionPhase()
            scheduleLockWatchdog()
        }
    }

    // MARK: - Automatic Terrain Elevation Lookup

    private func cancelElevationResolution() {
        elevationTask?.cancel()
        elevationTask = nil
        elevationGeneration += 1
        isResolvingAltitude = false
    }

    private func resolveElevation(for wgsLocation: TargetLocation) {
        elevationTask?.cancel()
        elevationGeneration += 1
        let gen = elevationGeneration
        let lat = wgsLocation.latitude
        let lon = wgsLocation.longitude
        isResolvingAltitude = true

        elevationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.elevationGeneration == gen {
                    self.isResolvingAltitude = false
                }
            }

            var resolved = await self.fetchElevationWithOpenMeteo(latitude: lat, longitude: lon)
            if resolved == nil && !Task.isCancelled {
                resolved = await self.fetchElevationWithOpenTopoData(latitude: lat, longitude: lon)
            }
            guard !Task.isCancelled, self.elevationGeneration == gen, let altitude = resolved else { return }
            let rounded = (min(50_000.0, max(-500.0, altitude)) * 10.0).rounded() / 10.0
            self.applyResolvedAltitude(rounded, forLatitude: lat, longitude: lon)
        }
    }

    private func applyResolvedAltitude(_ altitude: Double, forLatitude lat: Double, longitude lon: Double) {
        if var pending = pendingLocation,
           abs(pending.latitude - lat) < 1e-6,
           abs(pending.longitude - lon) < 1e-6 {
            pending.altitude = altitude
            pendingLocation = pending
            return
        }
        if abs(targetLocation.latitude - lat) < 1e-6,
           abs(targetLocation.longitude - lon) < 1e-6 {
            var updated = targetLocation
            updated.altitude = altitude
            targetLocation = updated
            if snapshot.isRunning {
                persistRecoveryRecord()
            }
        }
    }

    private func fetchElevationWithOpenMeteo(latitude: Double, longitude: Double) async -> Double? {
        let latStr = String(format: "%.6f", latitude)
        let lonStr = String(format: "%.6f", longitude)
        guard let url = URL(string: "https://api.open-meteo.com/v1/elevation?latitude=\(latStr)&longitude=\(lonStr)") else {
            return nil
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 3.0
        req.setValue("Reloc/1.0 (iOS)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let values = json["elevation"] as? [NSNumber],
                  let first = values.first else {
                return nil
            }
            let alt = first.doubleValue
            return alt.isFinite ? alt : nil
        } catch {
            return nil
        }
    }

    private func fetchElevationWithOpenTopoData(latitude: Double, longitude: Double) async -> Double? {
        let latStr = String(format: "%.6f", latitude)
        let lonStr = String(format: "%.6f", longitude)
        guard let url = URL(string: "https://api.opentopodata.org/v1/aster30m?locations=\(latStr),\(lonStr)") else {
            return nil
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 3.0
        req.setValue("Reloc/1.0 (iOS)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]],
                  let first = results.first,
                  let elev = first["elevation"] as? NSNumber else {
                return nil
            }
            let alt = elev.doubleValue
            return alt.isFinite ? alt : nil
        } catch {
            return nil
        }
    }

    private func reverseGeocode(wgsLocation: TargetLocation) {
        geocoder.cancelGeocode()
        geocodeTask?.cancel()
        geocodeGeneration += 1
        let gen = geocodeGeneration
        let coordText = String(format: "%.5f, %.5f", wgsLocation.latitude, wgsLocation.longitude)

        geocodeTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // 1. Try system CLGeocoder first (strict 2.0s non-blocking timeout so China GeoServices never hangs on overseas coords).
            if let resolved = await self.reverseGeocodeWithCLGeocoder(wgsLocation: wgsLocation, timeoutSeconds: 2.0) {
                guard !Task.isCancelled, self.geocodeGeneration == gen else { return }
                self.selectedPlaceName = resolved.title
                self.selectedPlaceAddress = resolved.address
                return
            }
            guard !Task.isCancelled, self.geocodeGeneration == gen else { return }

            // 2. Fallback to free keyless OpenStreetMap Nominatim (pure WGS-84, street-level detail).
            if let resolved = await self.reverseGeocodeWithNominatim(wgsLocation: wgsLocation) {
                guard !Task.isCancelled, self.geocodeGeneration == gen else { return }
                self.selectedPlaceName = resolved.title
                self.selectedPlaceAddress = resolved.address
                return
            }
            guard !Task.isCancelled, self.geocodeGeneration == gen else { return }

            // 3. Fallback to free keyless BigDataCloud reverse geocoder (CDN-backed, works reliably in China & globally).
            if let resolved = await self.reverseGeocodeWithBigDataCloud(wgsLocation: wgsLocation) {
                guard !Task.isCancelled, self.geocodeGeneration == gen else { return }
                self.selectedPlaceName = resolved.title
                self.selectedPlaceAddress = resolved.address
                return
            }
            guard !Task.isCancelled, self.geocodeGeneration == gen else { return }

            // 4. Final fallback: never leave geocoding placeholder stuck on screen.
            self.selectedPlaceName = coordText
            self.selectedPlaceAddress = L10n.tr("map.wgs84_coord")
        }
    }

    private func reverseGeocodeWithCLGeocoder(
        wgsLocation: TargetLocation,
        timeoutSeconds: TimeInterval
    ) async -> (title: String, address: String)? {
        let clLoc = CLLocation(latitude: wgsLocation.latitude, longitude: wgsLocation.longitude)
        let geocoder = self.geocoder
        return await withCheckedContinuation { continuation in
            let lock = NSLock()
            var resumed = false
            func finish(_ value: (String, String)?) {
                lock.lock()
                let shouldResume = !resumed
                resumed = true
                lock.unlock()
                if shouldResume {
                    continuation.resume(returning: value)
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds) {
                lock.lock()
                let stillPending = !resumed
                lock.unlock()
                if stillPending {
                    geocoder.cancelGeocode()
                    finish(nil)
                }
            }

            geocoder.reverseGeocodeLocation(clLoc) { placemarks, _ in
                guard let pm = placemarks?.first else {
                    finish(nil)
                    return
                }
                let title = pm.name ?? pm.locality ?? pm.administrativeArea
                    ?? String(format: "%.5f, %.5f", wgsLocation.latitude, wgsLocation.longitude)
                let parts = [pm.country, pm.administrativeArea, pm.locality, pm.subLocality, pm.thoroughfare, pm.subThoroughfare]
                    .compactMap { $0 }
                    .reduce(into: [String]()) { acc, item in
                        if !acc.contains(item) { acc.append(item) }
                    }
                let addr = parts.isEmpty
                    ? String(format: "%.5f, %.5f", wgsLocation.latitude, wgsLocation.longitude)
                    : parts.joined(separator: " ")
                finish((title, addr))
            }
        }
    }

    private func reverseGeocodeWithNominatim(
        wgsLocation: TargetLocation
    ) async -> (title: String, address: String)? {
        let latStr = String(format: "%.6f", wgsLocation.latitude)
        let lonStr = String(format: "%.6f", wgsLocation.longitude)
        let acceptLang = L10n.isChinese ? "zh-CN,en" : "en,zh-CN"
        guard let url = URL(string: "https://nominatim.openstreetmap.org/reverse?format=jsonv2&lat=\(latStr)&lon=\(lonStr)&zoom=18&addressdetails=1&accept-language=\(acceptLang)") else {
            return nil
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 3.0
        req.setValue("Reloc/1.0 (iOS)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            let addrDict = json["address"] as? [String: Any] ?? [:]
            let name = (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (addrDict["road"] as? String)
                ?? (addrDict["neighbourhood"] as? String)
                ?? (addrDict["suburb"] as? String)
                ?? (addrDict["city"] as? String)
                ?? (addrDict["town"] as? String)
                ?? (addrDict["county"] as? String)
                ?? (addrDict["state"] as? String)

            let displayName = (json["display_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = [
                addrDict["country"] as? String,
                addrDict["state"] as? String,
                (addrDict["city"] as? String) ?? (addrDict["town"] as? String) ?? (addrDict["county"] as? String),
                (addrDict["suburb"] as? String) ?? (addrDict["neighbourhood"] as? String),
                addrDict["road"] as? String,
                addrDict["house_number"] as? String,
            ].compactMap { $0 }.reduce(into: [String]()) { acc, item in
                if !item.isEmpty && !acc.contains(item) { acc.append(item) }
            }

            let resolvedTitle = name ?? displayName ?? String(format: "%.5f, %.5f", wgsLocation.latitude, wgsLocation.longitude)
            let resolvedAddress = !parts.isEmpty
                ? parts.joined(separator: " ")
                : (displayName ?? String(format: "%.5f, %.5f", wgsLocation.latitude, wgsLocation.longitude))
            return (resolvedTitle, resolvedAddress)
        } catch {
            return nil
        }
    }

    private func reverseGeocodeWithBigDataCloud(
        wgsLocation: TargetLocation
    ) async -> (title: String, address: String)? {
        let latStr = String(format: "%.6f", wgsLocation.latitude)
        let lonStr = String(format: "%.6f", wgsLocation.longitude)
        let lang = L10n.isChinese ? "zh" : "en"
        guard let url = URL(string: "https://api.bigdatacloud.net/data/reverse-geocode-client?latitude=\(latStr)&longitude=\(lonStr)&localityLanguage=\(lang)") else {
            return nil
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 3.0

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            let country = json["countryName"] as? String
            let subdivision = json["principalSubdivision"] as? String
            let city = json["city"] as? String
            let locality = json["locality"] as? String

            let parts = [country, subdivision, city, locality]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .reduce(into: [String]()) { acc, item in
                    if !item.isEmpty && !acc.contains(item) { acc.append(item) }
                }
            guard !parts.isEmpty else { return nil }
            let title = locality.flatMap { $0.isEmpty ? nil : $0 }
                ?? city.flatMap { $0.isEmpty ? nil : $0 }
                ?? subdivision.flatMap { $0.isEmpty ? nil : $0 }
                ?? parts.last!
            return (title, parts.joined(separator: " "))
        } catch {
            return nil
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
        guard let record = interruptedSession, !snapshot.isRunning else { return }
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

    // MARK: - Session Readiness

    public var canStartSession: Bool {
        mfiSigner != nil && !snapshot.isRunning
    }

    // MARK: - Location Injection Session

    public func start(mode: SessionMode) {
        guard !snapshot.isRunning else { return }
        guard let mfiSigner else {
            alertMessage = L10n.tr("error.mfi_unavailable")
            return
        }

        if let pending = pendingLocation {
            targetLocation = pending
            pendingLocation = nil
        }

        recordRecent(name: selectedPlaceName, subtitle: selectedPlaceAddress, location: targetLocation)
        persistRecoveryRecord()
        interruptedSession = nil
        if microJitterEnabled {
            startJitterTimer()
        }

        let config = SessionConfiguration(
            mode: mode,
            intervalSeconds: intervalSeconds,
            durationSeconds: mode == .probe ? max(20.0, durationSeconds) : durationSeconds
        )

        isAccessoryLocationConfirmed = false
        needsLocationServiceRefresh = false
        isLocationRefreshGuideActive = false
        didAutoReconnectForSubscription = false
        didAutoSoftReconnectForCurrentTarget = false
        loggedReducedAccuracyForSession = false
        cancelRestoreRecovery()
        injectionPhase = .connecting
        cancelTriggerTasks()

        // Start audio keep-alive ONLY before iAP2 auth completes so we don't wake internal GPS early
        // and poison `locationd`'s fusion cache with a fresh real location.
        keepAlive.prepareForSession(useSilentAudio: backgroundKeepAliveEnabled)

        let sessionID = UUID()
        let newSession = AccessoryLocationSession(
            id: sessionID,
            initialLocation: targetLocation,
            onEvent: { [weak self] event in
                Task { @MainActor in
                    guard let self, self.session?.id == sessionID else { return }
                    self.events.append(event)
                    if self.events.count > 500 {
                        self.events.removeFirst(self.events.count - 500)
                    }
                }
            },
            onSnapshot: { [weak self] snap in
                Task { @MainActor in
                    guard let self, self.session?.id == sessionID else { return }
                    self.snapshot = snap
                    self.updateInjectionPhase()
                    if !snap.isRunning {
                        self.session = nil
                        self.cancelTriggerTasks()
                        self.stopJitterTimer()
                        self.keepAlive.stop()
                        self.interruptedSession = self.store.loadInterruptedSession()
                        if !self.isRestoringRealLocation {
                            self.coreLocation.stop()
                        }
                        self.isAccessoryLocationConfirmed = false
                        self.needsLocationServiceRefresh = false
                        self.injectionPhase = .idle
                        if self.isLocationRefreshGuideActive {
                            self.isLocationRefreshGuideActive = false
                            LocationRefreshPresenter.shared.finishLocationRefresh(succeeded: false, message: L10n.tr("pip.finish.stopped.message"))
                        }
                    }
                }
            },
            onAuthenticated: { [weak self] in
                Task { @MainActor in
                    guard let self, self.session?.id == sessionID else { return }
                    self.handleSessionAuthenticated()
                }
            },
            onLocationRequested: { [weak self] in
                Task { @MainActor in
                    guard let self, self.session?.id == sessionID else { return }
                    self.handleLocationSubscribed()
                }
            },
            onLocationStopped: { [weak self] in
                Task { @MainActor in
                    guard let self, self.session?.id == sessionID else { return }
                    self.handleLocationStoppedBySystem()
                }
            },
            onSubscriptionRestarted: { [weak self] in
                Task { @MainActor in
                    guard let self, self.session?.id == sessionID else { return }
                    self.keepAlive.refreshAfterLocationToggle()
                }
            }
        )
        newSession.setFallbackRealLocation(lastKnownRealLocation)
        self.session = newSession
        snapshot.isRunning = true
        newSession.start(configuration: config, mfiSigner: mfiSigner)
    }

    public func stopAndRestore() {
        cancelTriggerTasks()
        stopJitterTimer()
        let activeSession = session
        session = nil
        activeSession?.stop()
        keepAlive.stop()
        snapshot.isRunning = false
        snapshot.activeSentences = []
        isAccessoryLocationConfirmed = false
        needsLocationServiceRefresh = false
        injectionPhase = .idle
        if isLocationRefreshGuideActive {
            isLocationRefreshGuideActive = false
            LocationRefreshPresenter.shared.teardown()
        }
        store.saveInterruptedSession(nil)
        interruptedSession = nil
        beginRealLocationRecovery()
    }

    // MARK: - Post-Stop Real GPS Recovery

    private func cancelRestoreRecovery() {
        restoreTask?.cancel()
        restoreTask = nil
        isRestoringRealLocation = false
        needsRestoreLocationRefresh = false
        realLocationRestoredNotice = false
        if isRestoreRefreshGuideActive {
            isRestoreRefreshGuideActive = false
            LocationRefreshPresenter.shared.teardown()
        }
    }

    private func beginRealLocationRecovery() {
        restoreTask?.cancel()
        isRestoringRealLocation = true
        needsRestoreLocationRefresh = false
        realLocationRestoredNotice = false
        lastRestoreAuthStatus = coreLocation.authorizationStatus

        restoreTask = Task { @MainActor [weak self] in
            // Wait briefly for Void NMEA (GGA quality=0 / RMC status=V) + iAP2 RST + tunnel close to flush.
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled, let self, !self.snapshot.isRunning else { return }

            // Actively request fresh internal GNSS/Wi-Fi/Cell fix so `locationd` flushes the cached accessory fix.
            self.coreLocation.requestAndStart()
            self.coreLocation.pulseForAccessoryLock(requestSingleFix: true)
            self.events.append(ProtocolEvent(
                name: "real_location_recovery_started",
                detail: "{\"event\":\"real_location_recovery_started\"}"
            ))

            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled, self.isRestoringRealLocation, !self.snapshot.isRunning else { return }
            self.coreLocation.pulseForAccessoryLock(requestSingleFix: true)

            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled, self.isRestoringRealLocation, !self.snapshot.isRunning else { return }
            // Indoors / weak GNSS: offer 1-tap PiP Location Services flush to guarantee instant restoration.
            self.needsRestoreLocationRefresh = true

            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled, self.isRestoringRealLocation, !self.snapshot.isRunning else { return }
            if !self.isRestoreRefreshGuideActive {
                self.coreLocation.stop()
                self.isRestoringRealLocation = false
            }
        }
    }

    private func handleCoreLocationAuthChangeForRestore(_ status: CLAuthorizationStatus) {
        let prev = lastRestoreAuthStatus
        lastRestoreAuthStatus = status

        // Active injection refresh guide: react directly to real system Location Services OFF/ON transitions.
        if isLocationRefreshGuideActive && snapshot.isRunning {
            if status == .denied || status == .restricted {
                locationStopDebounceTask?.cancel()
                locationStopDebounceTask = nil
                if !locationRefreshSawDisabled {
                    locationRefreshSawDisabled = true
                    startLocationRefreshCountdown()
                }
            } else if locationRefreshSawDisabled,
                      (prev == .denied || prev == .restricted),
                      (status == .authorizedAlways || status == .authorizedWhenInUse) {
                refreshCountdownTask?.cancel()
                refreshCountdownTask = nil
                LocationRefreshPresenter.shared.updateLocationRefresh(
                    step: 3,
                    headline: L10n.tr("pip.step3.reopened.headline"),
                    subtitle: L10n.tr("pip.step3.reopened.subtitle")
                )
            }
            return
        }

        guard isRestoreRefreshGuideActive else { return }

        if status == .denied || status == .restricted {
            // User just toggled Location Services OFF -> start 5s countdown in PiP!
            startRestoreRefreshCountdown()
        } else if (prev == .denied || prev == .restricted)
            && (status == .authorizedAlways || status == .authorizedWhenInUse) {
            refreshCountdownTask?.cancel()
            refreshCountdownTask = nil
            LocationRefreshPresenter.shared.updateLocationRefresh(
                step: 3,
                headline: L10n.tr("pip.step3.restoring.headline"),
                subtitle: L10n.tr("pip.step3.restoring.subtitle")
            )
            coreLocation.requestAndStart()
            coreLocation.pulseForAccessoryLock(requestSingleFix: true)
        }
    }

    public func launchOneTapRestoreRefresh() {
        restoreTask?.cancel()
        restoreTask = nil
        refreshCountdownTask?.cancel()
        refreshCountdownTask = nil
        isRestoreRefreshGuideActive = true
        isRestoringRealLocation = true
        lastRestoreAuthStatus = coreLocation.authorizationStatus
        LocationRefreshPresenter.shared.startLocationRefreshGuide()
        LocationRefreshPresenter.shared.updateLocationRefresh(
            step: 1,
            headline: L10n.tr("pip.step1.headline"),
            subtitle: L10n.tr("pip.step1.restore.subtitle")
        )
        // Let PiP enter smoothly before switching apps to Settings (avoids transition stutter).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, self.isRestoreRefreshGuideActive else { return }
            self.openLocationServicesSettings()
        }
    }

    private func startRestoreRefreshCountdown() {
        refreshCountdownTask?.cancel()
        refreshCountdownTask = Task { @MainActor [weak self] in
            for remaining in stride(from: 7, through: 1, by: -1) {
                guard !Task.isCancelled, let self, self.isRestoreRefreshGuideActive else { return }
                LocationRefreshPresenter.shared.updateLocationRefresh(
                    step: 2,
                    headline: L10n.tr("pip.step2.restore.headline"),
                    subtitle: L10n.tr("pip.step2.subtitle"),
                    countdown: remaining
                )
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard !Task.isCancelled, let self, self.isRestoreRefreshGuideActive else { return }
            RelocTheme.hapticMedium()
            LocationRefreshPresenter.shared.updateLocationRefresh(
                step: 3,
                headline: L10n.tr("pip.step3.enable.headline"),
                subtitle: L10n.tr("pip.step3.restore.subtitle"),
                countdown: 0
            )
        }
    }

    // MARK: - Fast-Lock Auto-Trigger & One-Tap PiP Location Refresh

    private func cancelTriggerTasks() {
        subscriptionPulseTask?.cancel()
        subscriptionPulseTask = nil
        lockWatchdogTask?.cancel()
        lockWatchdogTask = nil
        refreshCountdownTask?.cancel()
        refreshCountdownTask = nil
        locationStopDebounceTask?.cancel()
        locationStopDebounceTask = nil
        locationRefreshSawDisabled = false
    }

    private func handleSessionAuthenticated() {
        guard snapshot.isRunning else { return }
        // Activate navigation-grade CoreLocation right AFTER iAP2 auth succeeds so `locationd`
        // immediately pairs this fresh request with our authenticated external MFi GPS accessory.
        keepAlive.activateLocationSubscription(forceRestart: true)
        coreLocation.requestAndStart()
        updateInjectionPhase()

        // Escalating wake-up strategy if `locationd` doesn't dispatch 0xFFFA promptly:
        // 1–2: non-destructive accuracy-tier nudge (avoids dropping active consumers to 0)
        // 3: hard CoreLocation pulse
        // 4: one automatic iAP2 link reconnect to clear stale `iap2d` state, then surface 1-tap refresh.
        subscriptionPulseTask?.cancel()
        subscriptionPulseTask = Task { @MainActor [weak self] in
            for attempt in 1...3 {
                let delayNs: UInt64 = attempt == 1 ? 1_500_000_000 : 2_000_000_000
                try? await Task.sleep(nanoseconds: delayNs)
                guard !Task.isCancelled, let self, self.snapshot.isRunning else { return }
                if !self.snapshot.activeSentences.isEmpty { return }
                self.events.append(ProtocolEvent(
                    name: "auto_subscription_pulse",
                    detail: "{\"event\":\"auto_subscription_pulse\",\"attempt\":\(attempt),\"mode\":\"\(attempt < 3 ? "nudge" : "pulse")\"}"
                ))
                if attempt < 3 {
                    self.keepAlive.nudgeLocationSubscription()
                    self.coreLocation.nudgeForAccessoryLock()
                } else {
                    self.keepAlive.pulseLocationSubscription()
                    self.coreLocation.pulseForAccessoryLock()
                }
            }

            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled, let self, self.snapshot.isRunning else { return }
            if !self.snapshot.activeSentences.isEmpty { return }

            if !self.didAutoReconnectForSubscription {
                self.didAutoReconnectForSubscription = true
                self.events.append(ProtocolEvent(
                    name: "auto_subscription_reconnect",
                    detail: "{\"event\":\"auto_subscription_reconnect\"}"
                ))
                self.session?.requestLinkReconnect(reason: "waiting_subscription_timeout")
            } else {
                self.needsLocationServiceRefresh = true
            }
        }
    }

    private func handleLocationSubscribed() {
        subscriptionPulseTask?.cancel()
        subscriptionPulseTask = nil
        locationStopDebounceTask?.cancel()
        locationStopDebounceTask = nil
        updateInjectionPhase()

        if isLocationRefreshGuideActive {
            if locationRefreshSawDisabled {
                refreshCountdownTask?.cancel()
                refreshCountdownTask = nil
                LocationRefreshPresenter.shared.updateLocationRefresh(
                    step: 3,
                    headline: L10n.tr("pip.step3.subscribed.headline"),
                    subtitle: L10n.tr("pip.step3.subscribed.subtitle")
                )
            }
            // Do not schedule CoreLocation pulses while the PiP refresh guide is active.
            return
        }
        scheduleLockWatchdog()
    }

    private func handleLocationStoppedBySystem() {
        isAccessoryLocationConfirmed = false
        session?.markCoreLocationConfirmed(false)
        updateInjectionPhase()

        // Debounce 0xFFFC by 0.9s so transient app-switch hiccups never falsely flash "5 秒"
        // when the user hasn't actually turned off Location Services yet.
        if isLocationRefreshGuideActive && !locationRefreshSawDisabled {
            locationStopDebounceTask?.cancel()
            locationStopDebounceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 900_000_000)
                guard !Task.isCancelled,
                      let self,
                      self.isLocationRefreshGuideActive,
                      !self.locationRefreshSawDisabled,
                      self.snapshot.isRunning,
                      self.snapshot.activeSentences.isEmpty else { return }
                self.locationRefreshSawDisabled = true
                self.startLocationRefreshCountdown()
            }
        }
    }

    private func scheduleLockWatchdog() {
        lockWatchdogTask?.cancel()
        lockWatchdogTask = Task { @MainActor [weak self] in
            // Stage 1 (2.0s): zero-click Kalman reset + 5Hz burst + non-destructive CoreLocation nudge.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self, self.snapshot.isRunning else { return }
            if !self.isAccessoryLocationConfirmed {
                self.events.append(ProtocolEvent(
                    name: "auto_lock_nudge",
                    detail: "{\"event\":\"auto_lock_nudge\"}"
                ))
                self.session?.notifyLocationUpdated(resetKalman: true, burstSeconds: 10.0)
                self.keepAlive.nudgeLocationSubscription()
                self.coreLocation.nudgeForAccessoryLock()
            }

            // Stage 2 (4.5s): at most ONE automatic zero-click iAP2 RST soft-reconnect per target.
            // Without this guard, re-subscribing after reconnect would loop soft-reconnect every 4.5s forever.
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled, self.snapshot.isRunning else { return }
            if !self.isAccessoryLocationConfirmed {
                if !self.didAutoSoftReconnectForCurrentTarget {
                    self.didAutoSoftReconnectForCurrentTarget = true
                    self.events.append(ProtocolEvent(
                        name: "auto_soft_reconnect",
                        detail: "{\"event\":\"auto_soft_reconnect\"}"
                    ))
                    self.session?.requestLinkReconnect(reason: "auto_soft_reconnect")
                    self.keepAlive.nudgeLocationSubscription()
                    self.coreLocation.nudgeForAccessoryLock()
                } else {
                    self.needsLocationServiceRefresh = true
                    return
                }
            }

            // Stage 3 (8.5s): surface manual 1-tap refresh banner only if zero-click recovery still hasn't locked.
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, self.snapshot.isRunning else { return }
            if !self.isAccessoryLocationConfirmed {
                self.needsLocationServiceRefresh = true
            }
        }
    }

    private func evaluateCoreLocationConfirmation(_ telemetry: LiveLocationTelemetry?) {
        if let telemetry, telemetry.isProducedByAccessory == false {
            let real = TargetLocation(latitude: telemetry.latitude, longitude: telemetry.longitude, altitude: telemetry.altitude)
            lastKnownRealLocation = real
            session?.setFallbackRealLocation(real)
        }
        // Post-stop recovery check: wait until `locationd` delivers a fresh internal (non-accessory) fix.
        if isRestoringRealLocation && !snapshot.isRunning {
            guard let telemetry else { return }
            let isFresh = abs(telemetry.timestamp.timeIntervalSinceNow) < 15.0
            if isFresh && telemetry.isProducedByAccessory == false {
                restoreTask?.cancel()
                restoreTask = nil
                isRestoringRealLocation = false
                needsRestoreLocationRefresh = false
                realLocationRestoredNotice = true
                coreLocation.stop()
                RelocTheme.hapticSuccess()
                events.append(ProtocolEvent(
                    name: "real_location_restored",
                    detail: String(format: "{\"event\":\"real_location_restored\",\"lat\":%.5f,\"lon\":%.5f,\"accuracy_m\":%.1f}", telemetry.latitude, telemetry.longitude, telemetry.horizontalAccuracy)
                ))
                if isRestoreRefreshGuideActive {
                    isRestoreRefreshGuideActive = false
                    refreshCountdownTask?.cancel()
                    refreshCountdownTask = nil
                    LocationRefreshPresenter.shared.finishLocationRefresh(
                        succeeded: true,
                        message: L10n.tr("pip.finish.restored.message"),
                        headline: L10n.tr("pip.finish.restored.headline")
                    )
                }
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    self?.realLocationRestoredNotice = false
                }
            }
            return
        }

        guard snapshot.isRunning, let telemetry else {
            if !snapshot.isRunning {
                isAccessoryLocationConfirmed = false
            }
            return
        }
        if coreLocation.isReducedAccuracy && !loggedReducedAccuracyForSession {
            loggedReducedAccuracyForSession = true
            events.append(ProtocolEvent(
                name: "reduced_accuracy_detected",
                detail: "{\"event\":\"reduced_accuracy_detected\"}",
                isError: true
            ))
        }
        let targetCL = CLLocation(latitude: targetLocation.latitude, longitude: targetLocation.longitude)
        let reportedCL = CLLocation(latitude: telemetry.latitude, longitude: telemetry.longitude)
        let distance = targetCL.distance(from: reportedCL)
        let confirmed = (telemetry.isProducedByAccessory == true) && distance < 500.0

        if confirmed != isAccessoryLocationConfirmed {
            let wasConfirmed = isAccessoryLocationConfirmed
            isAccessoryLocationConfirmed = confirmed
            session?.markCoreLocationConfirmed(confirmed)
            if confirmed {
                needsLocationServiceRefresh = false
                lockWatchdogTask?.cancel()
                lockWatchdogTask = nil
                RelocTheme.hapticSuccess()
                events.append(ProtocolEvent(
                    name: "accessory_location_confirmed",
                    detail: String(format: "{\"event\":\"accessory_location_confirmed\",\"distance_m\":%.1f,\"accuracy_m\":%.1f,\"alt_m\":%.1f}", distance, telemetry.horizontalAccuracy, telemetry.altitude)
                ))
                if isLocationRefreshGuideActive {
                    isLocationRefreshGuideActive = false
                    refreshCountdownTask?.cancel()
                    refreshCountdownTask = nil
                    keepAlive.restoreAudioPreferenceAfterSettingsToggle()
                    LocationRefreshPresenter.shared.finishLocationRefresh(
                        succeeded: true,
                        message: L10n.format("pip.finish.succeeded.message", selectedPlaceName)
                    )
                }
            } else if wasConfirmed && !isLocationRefreshGuideActive && !snapshot.activeSentences.isEmpty {
                // Mid-session lock drift: actively re-burst and nudge so `locationd` re-locks promptly.
                events.append(ProtocolEvent(
                    name: "accessory_lock_lost",
                    detail: String(format: "{\"event\":\"accessory_lock_lost\",\"distance_m\":%.1f}", distance)
                ))
                session?.triggerFastBurst(seconds: 12.0)
                keepAlive.nudgeLocationSubscription()
                coreLocation.nudgeForAccessoryLock()
                scheduleLockWatchdog()
            }
            updateInjectionPhase()
        }
    }

    private func updateInjectionPhase() {
        guard snapshot.isRunning else {
            injectionPhase = .idle
            return
        }
        if isAccessoryLocationConfirmed {
            injectionPhase = .activeConfirmed
        } else if !snapshot.activeSentences.isEmpty || snapshot.packetsAcknowledged > 0 {
            injectionPhase = .injectingPendingLock
        } else if snapshot.authenticated {
            injectionPhase = .waitingSubscription
        } else {
            injectionPhase = .connecting
        }
    }

    /// Launches a floating PiP countdown guide and jumps straight to iOS Location Services Settings
    /// for a guaranteed 100% cache flush when `locationd` clings to a stale internal GNSS/Wi-Fi fix.
    public func launchOneTapLocationRefresh() {
        guard snapshot.isRunning else { return }
        // Cancel background pulse/watchdog tasks immediately so they never stop CLLocationManager
        // and falsely trigger a 0xFFFC "5 秒" flash before the user touches Location Services.
        cancelTriggerTasks()
        // Guarantee silent audio keep-alive is active before toggling Location Services OFF in Settings,
        // otherwise iOS may suspend Reloc mid-countdown and drop the iAP2 tunnel.
        keepAlive.ensureAudioKeepAliveForSettingsToggle()
        isLocationRefreshGuideActive = true
        locationRefreshSawDisabled = false
        lastRestoreAuthStatus = coreLocation.authorizationStatus
        LocationRefreshPresenter.shared.startLocationRefreshGuide()
        session?.triggerFastBurst(seconds: 45.0)
        // Wait briefly for PiP to enter smoothly before switching to Settings (prevents stutter).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, self.isLocationRefreshGuideActive, self.snapshot.isRunning else { return }
            self.openLocationServicesSettings()
        }
    }

    /// Manually triggers a zero-click iAP2 soft-reconnect + fast NMEA burst without leaving Reloc.
    public func retryAutoLock() {
        guard snapshot.isRunning else { return }
        needsLocationServiceRefresh = false
        didAutoSoftReconnectForCurrentTarget = true
        session?.triggerFastBurst(seconds: 15.0)
        if snapshot.activeSentences.isEmpty {
            keepAlive.pulseLocationSubscription()
            coreLocation.pulseForAccessoryLock()
            handleSessionAuthenticated()
        } else {
            session?.requestLinkReconnect(reason: "manual_retry_soft_reconnect")
            keepAlive.nudgeLocationSubscription()
            coreLocation.nudgeForAccessoryLock()
            scheduleLockWatchdog()
        }
    }

    private func startLocationRefreshCountdown() {
        refreshCountdownTask?.cancel()
        refreshCountdownTask = Task { @MainActor [weak self] in
            for remaining in stride(from: 7, through: 1, by: -1) {
                guard !Task.isCancelled, let self, self.isLocationRefreshGuideActive else { return }
                LocationRefreshPresenter.shared.updateLocationRefresh(
                    step: 2,
                    headline: L10n.tr("pip.step2.headline"),
                    subtitle: L10n.tr("pip.step2.subtitle"),
                    countdown: remaining
                )
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard !Task.isCancelled, let self, self.isLocationRefreshGuideActive else { return }
            RelocTheme.hapticMedium()
            LocationRefreshPresenter.shared.updateLocationRefresh(
                step: 3,
                headline: L10n.tr("pip.step3.enable.headline"),
                subtitle: L10n.tr("pip.step3.enable.subtitle"),
                countdown: 0
            )
        }
    }

    public func openLocationServicesSettings() {
        let candidates = [
            "App-Prefs:root=Privacy&path=LOCATION",
            "prefs:root=Privacy&path=LOCATION",
            UIApplication.openSettingsURLString,
        ]
        openFirstSupportedURL(candidates)
    }

    public func openAppSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    private func openFirstSupportedURL(_ strings: [String], index: Int = 0) {
        guard index < strings.count, let url = URL(string: strings[index]) else { return }
        UIApplication.shared.open(url, options: [:]) { [weak self] success in
            if !success {
                Task { @MainActor in
                    self?.openFirstSupportedURL(strings, index: index + 1)
                }
            }
        }
    }

    // MARK: - Places Management

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
