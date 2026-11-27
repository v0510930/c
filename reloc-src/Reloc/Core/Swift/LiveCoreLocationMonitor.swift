import CoreLocation
import Foundation

public struct LiveLocationTelemetry: Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let altitude: Double
    public let horizontalAccuracy: Double
    public let isSimulatedBySoftware: Bool?
    public let isProducedByAccessory: Bool?
    public let timestamp: Date
}

/// Lightweight CoreLocation observer used for "fly to current location" and live
/// inspection of iOS CLLocationSourceInformation flags (isSimulatedBySoftware / isProducedByAccessory).
@MainActor
public final class LiveCoreLocationMonitor: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published public private(set) var latest: LiveLocationTelemetry?
    @Published public private(set) var isMonitoring = false

    private let manager = CLLocationManager()

    public override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.pausesLocationUpdatesAutomatically = false
    }

    public func requestAndStart() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestAlwaysAuthorization()
        }
        manager.startUpdatingLocation()
        isMonitoring = true
    }

    public func requestOneShot() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        manager.requestLocation()
    }

    public func stop() {
        manager.stopUpdatingLocation()
        isMonitoring = false
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        let snap = LiveLocationTelemetry(
            latitude: loc.coordinate.latitude,
            longitude: loc.coordinate.longitude,
            altitude: loc.altitude,
            horizontalAccuracy: loc.horizontalAccuracy,
            isSimulatedBySoftware: loc.sourceInformation?.isSimulatedBySoftware,
            isProducedByAccessory: loc.sourceInformation?.isProducedByAccessory,
            timestamp: loc.timestamp
        )
        Task { @MainActor in
            self.latest = snap
        }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Ignore transient CoreLocation failures.
    }
}
