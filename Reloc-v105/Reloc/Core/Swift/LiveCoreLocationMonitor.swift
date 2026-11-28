import CoreLocation
import Foundation

public struct LiveLocationTelemetry: Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let altitude: Double
    public let horizontalAccuracy: Double
    public let verticalAccuracy: Double
    public let speed: Double
    public let isSimulatedBySoftware: Bool?
    public let isProducedByAccessory: Bool?
    public let timestamp: Date
}

/// Lightweight CoreLocation observer used for "fly to current location", live inspection of
/// iOS `CLLocationSourceInformation` flags (`isSimulatedBySoftware` / `isProducedByAccessory`),
/// and sharing location callbacks from `BackgroundKeepAlive` during active sessions so iOS only
/// maintains a single `CLLocationManager` consumer.
@MainActor
public final class LiveCoreLocationMonitor: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published public private(set) var latest: LiveLocationTelemetry?
    @Published public private(set) var isMonitoring = false
    @Published public private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published public private(set) var accuracyAuthorization: CLAccuracyAuthorization = .fullAccuracy

    /// Always holds the most recent telemetry even while UI publishing is throttled in the background.
    public private(set) var latestRaw: LiveLocationTelemetry?
    public var onTelemetryUpdate: ((LiveLocationTelemetry) -> Void)?

    private let manager = CLLocationManager()
    private var externalFeedActive = false
    private var ownManagerRunning = false

    public var isReducedAccuracy: Bool {
        (authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse)
            && accuracyAuthorization == .reducedAccuracy
    }

    public override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .otherNavigation
        manager.pausesLocationUpdatesAutomatically = false
        authorizationStatus = manager.authorizationStatus
        accuracyAuthorization = manager.accuracyAuthorization
    }

    /// Switches between consuming `BackgroundKeepAlive`'s single `CLLocationManager` feed
    /// (zero duplicate GPS consumer during active sessions) and running our own standalone manager.
    public func setExternalFeedActive(_ active: Bool) {
        guard externalFeedActive != active else { return }
        externalFeedActive = active
        if active {
            if ownManagerRunning {
                manager.stopUpdatingLocation()
                ownManagerRunning = false
            }
            isMonitoring = true
        } else {
            isMonitoring = ownManagerRunning
        }
    }

    /// Feeds a `CLLocation` delivered by `BackgroundKeepAlive` without running a second manager.
    public func ingestExternalLocation(_ loc: CLLocation, publishToUI: Bool) {
        let snap = Self.makeTelemetry(from: loc)
        latestRaw = snap
        let flagsChanged = latest?.isProducedByAccessory != snap.isProducedByAccessory
            || latest?.isSimulatedBySoftware != snap.isSimulatedBySoftware
        if publishToUI || latest == nil || flagsChanged {
            latest = snap
        }
        onTelemetryUpdate?(snap)
    }

    /// Syncs the most recent background telemetry into `@Published latest` when returning to foreground.
    public func flushLatestToUI() {
        if let raw = latestRaw, latest != raw {
            latest = raw
        }
    }

    public func syncAuthorization(status: CLAuthorizationStatus, accuracy: CLAccuracyAuthorization) {
        if authorizationStatus != status {
            authorizationStatus = status
        }
        if accuracyAuthorization != accuracy {
            accuracyAuthorization = accuracy
        }
    }

    public func requestAndStart() {
        authorizationStatus = manager.authorizationStatus
        accuracyAuthorization = manager.accuracyAuthorization
        if manager.authorizationStatus == .notDetermined {
            manager.requestAlwaysAuthorization()
        }
        isMonitoring = true
        guard !externalFeedActive else { return }
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.startUpdatingLocation()
        ownManagerRunning = true
    }

    /// Gently nudges `locationd` to re-evaluate the navigation accuracy tier without dropping
    /// the active CoreLocation subscription (avoids triggering a spurious iAP2 `0xFFFC` stop).
    public func nudgeForAccessoryLock() {
        authorizationStatus = manager.authorizationStatus
        accuracyAuthorization = manager.accuracyAuthorization
        guard isMonitoring, !externalFeedActive else { return }
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.isMonitoring, !self.externalFeedActive else { return }
            self.manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
            self.manager.startUpdatingLocation()
            self.ownManagerRunning = true
        }
    }

    public func pulseForAccessoryLock(requestSingleFix: Bool = false) {
        authorizationStatus = manager.authorizationStatus
        accuracyAuthorization = manager.accuracyAuthorization
        guard !externalFeedActive else { return }
        manager.stopUpdatingLocation()
        ownManagerRunning = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.isMonitoring, !self.externalFeedActive else { return }
            self.manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
            self.manager.startUpdatingLocation()
            self.ownManagerRunning = true
            if requestSingleFix {
                self.manager.requestLocation()
            }
        }
    }

    public func requestOneShot() {
        authorizationStatus = manager.authorizationStatus
        accuracyAuthorization = manager.accuracyAuthorization
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        manager.requestLocation()
    }

    public func stop() {
        if ownManagerRunning {
            manager.stopUpdatingLocation()
            ownManagerRunning = false
        }
        if !externalFeedActive {
            isMonitoring = false
        }
    }

    private nonisolated static func makeTelemetry(from loc: CLLocation) -> LiveLocationTelemetry {
        LiveLocationTelemetry(
            latitude: loc.coordinate.latitude,
            longitude: loc.coordinate.longitude,
            altitude: loc.altitude,
            horizontalAccuracy: loc.horizontalAccuracy,
            verticalAccuracy: loc.verticalAccuracy,
            speed: loc.speed,
            isSimulatedBySoftware: loc.sourceInformation?.isSimulatedBySoftware,
            isProducedByAccessory: loc.sourceInformation?.isProducedByAccessory,
            timestamp: loc.timestamp
        )
    }

    public nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        let accuracy = manager.accuracyAuthorization
        Task { @MainActor in
            self.authorizationStatus = status
            self.accuracyAuthorization = accuracy
            if self.isMonitoring, !self.externalFeedActive,
               status == .authorizedAlways || status == .authorizedWhenInUse {
                self.manager.startUpdatingLocation()
                self.ownManagerRunning = true
            }
        }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        let snap = Self.makeTelemetry(from: loc)
        Task { @MainActor in
            self.latestRaw = snap
            self.latest = snap
            self.onTelemetryUpdate?(snap)
        }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Ignore transient CoreLocation failures.
    }
}
