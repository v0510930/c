import CoreLocation
import Foundation
import MapKit

// MARK: - Control Mode & Route Models

public enum LocationControlMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case fixed
    case route

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .fixed: return L10n.tr("mode.fixed")
        case .route: return L10n.tr("mode.route")
        }
    }
}

public enum RouteTransportPreset: String, CaseIterable, Codable, Identifiable, Sendable {
    case walking
    case running
    case cycling
    case driving

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .walking: return L10n.tr("route.preset.walking")
        case .running: return L10n.tr("route.preset.running")
        case .cycling: return L10n.tr("route.preset.cycling")
        case .driving: return L10n.tr("route.preset.driving")
        }
    }

    public var systemImage: String {
        switch self {
        case .walking: return "figure.walk"
        case .running: return "figure.run"
        case .cycling: return "bicycle"
        case .driving: return "car.fill"
        }
    }

    /// Default cruising speed in meters per second.
    public var defaultSpeedMps: Double {
        switch self {
        case .walking: return 1.4      // ~5.0 km/h
        case .running: return 3.0      // ~10.8 km/h (~5'33"/km)
        case .cycling: return 5.5      // ~19.8 km/h
        case .driving: return 13.9     // ~50.0 km/h
        }
    }

    public var speedRangeMps: ClosedRange<Double> {
        switch self {
        case .walking: return 0.5...3.0
        case .running: return 1.8...6.5
        case .cycling: return 2.5...14.0
        case .driving: return 4.0...35.0
        }
    }

    public var speedStepMps: Double {
        switch self {
        case .walking, .running: return 0.1
        case .cycling: return 0.5
        case .driving: return 1.0
        }
    }

    /// Realistic pace variation fraction (±%).
    public var paceVarianceFraction: Double {
        switch self {
        case .walking: return 0.08
        case .running: return 0.06
        case .cycling: return 0.07
        case .driving: return 0.05
        }
    }

    /// Minimum speed multiplier on sharp corners (≥ 90° turn).
    public var sharpTurnSpeedFactor: Double {
        switch self {
        case .walking: return 0.60
        case .running: return 0.55
        case .cycling: return 0.45
        case .driving: return 0.35
        }
    }

    /// Physically plausible acceleration/deceleration bound (m/s²).
    public var maxAccelerationMps2: Double {
        switch self {
        case .walking: return 1.0
        case .running: return 1.5
        case .cycling: return 2.2
        case .driving: return 3.5
        }
    }

    /// Subtle lateral GPS meander amplitude (meters) perpendicular to heading.
    public var lateralDriftMeters: Double {
        switch self {
        case .walking: return 0.45
        case .running: return 0.55
        case .cycling: return 0.45
        case .driving: return 0.30
        }
    }

    /// Primary `MKDirectionsTransportType` (iOS 16+ compatible).
    public var directionsTransportType: MKDirectionsTransportType {
        switch self {
        case .walking, .running, .cycling:
            return .walking
        case .driving:
            return .automobile
        }
    }

    /// Whether changing between two presets requires re-querying road geometry.
    public func hasSameRoadTopology(as other: RouteTransportPreset) -> Bool {
        self.directionsTransportType == other.directionsTransportType
    }
}

public enum RouteLoopMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case once
    case roundTrip
    case loop

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .once: return L10n.tr("route.loop.once")
        case .roundTrip: return L10n.tr("route.loop.round_trip")
        case .loop: return L10n.tr("route.loop.closed")
        }
    }

    public var systemImage: String {
        switch self {
        case .once: return "flag.checkered"
        case .roundTrip: return "arrow.left.arrow.right"
        case .loop: return "repeat"
        }
    }
}

public struct RoutePoint: Codable, Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double

    public init(latitude: Double, longitude: Double, altitude: Double = 10.0) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
    }

    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

public struct RouteWaypoint: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double

    public init(
        id: UUID = UUID(),
        name: String,
        latitude: Double,
        longitude: Double,
        altitude: Double = 10.0
    ) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
    }

    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    public var routePoint: RoutePoint {
        RoutePoint(latitude: latitude, longitude: longitude, altitude: altitude)
    }
}

public struct SavedRoute: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var waypoints: [RouteWaypoint]
    public var points: [RoutePoint]
    public var preset: RouteTransportPreset
    public var speedMetersPerSecond: Double
    public var loopMode: RouteLoopMode
    public var totalDistanceMeters: Double
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        waypoints: [RouteWaypoint],
        points: [RoutePoint],
        preset: RouteTransportPreset,
        speedMetersPerSecond: Double,
        loopMode: RouteLoopMode,
        totalDistanceMeters: Double,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.waypoints = waypoints
        self.points = points
        self.preset = preset
        self.speedMetersPerSecond = speedMetersPerSecond
        self.loopMode = loopMode
        self.totalDistanceMeters = totalDistanceMeters
        self.createdAt = createdAt
    }
}

public struct TrajectoryProgress: Equatable, Sendable {
    public var currentLocation: TargetLocation
    public var traveledMeters: Double
    public var totalDistanceMeters: Double
    public var progress: Double
    public var currentSpeedMps: Double
    public var bearingDegrees: Double
    public var lapCount: Int
    public var isPaused: Bool
    public var isWaitingForStartLock: Bool
    public var isCompleted: Bool
    public var isReversing: Bool

    public init(
        currentLocation: TargetLocation,
        traveledMeters: Double = 0,
        totalDistanceMeters: Double = 0,
        progress: Double = 0,
        currentSpeedMps: Double = 0,
        bearingDegrees: Double = 0,
        lapCount: Int = 1,
        isPaused: Bool = false,
        isWaitingForStartLock: Bool = true,
        isCompleted: Bool = false,
        isReversing: Bool = false
    ) {
        self.currentLocation = currentLocation
        self.traveledMeters = traveledMeters
        self.totalDistanceMeters = totalDistanceMeters
        self.progress = progress
        self.currentSpeedMps = currentSpeedMps
        self.bearingDegrees = bearingDegrees
        self.lapCount = lapCount
        self.isPaused = isPaused
        self.isWaitingForStartLock = isWaitingForStartLock
        self.isCompleted = isCompleted
        self.isReversing = isReversing
    }
}

public struct TrajectoryStep: Sendable {
    public let location: TargetLocation
    public let progress: TrajectoryProgress
    public let didTeleportLap: Bool
}

public struct RoutePlanningResult: Sendable {
    public let points: [RoutePoint]
    public let totalDistanceMeters: Double
    public let usedRoadRouting: Bool
    public let usedStraightFallback: Bool
    public let isClosedCircuit: Bool
}

// MARK: - Geodesic & Formatting Helpers

public enum RouteGeometry {
    private static let earthRadiusMeters = 6_371_000.0
    public static let mpsToKnots = 1.9438444924406

    public static func distanceMeters(from a: RoutePoint, to b: RoutePoint) -> Double {
        distanceMeters(lat1: a.latitude, lon1: a.longitude, lat2: b.latitude, lon2: b.longitude)
    }

    public static func distanceMeters(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let rLat1 = lat1 * .pi / 180.0
        let rLat2 = lat2 * .pi / 180.0
        let dLat = (lat2 - lat1) * .pi / 180.0
        let dLon = (lon2 - lon1) * .pi / 180.0
        let sinHalfLat = sin(dLat * 0.5)
        let sinHalfLon = sin(dLon * 0.5)
        let h = sinHalfLat * sinHalfLat + cos(rLat1) * cos(rLat2) * sinHalfLon * sinHalfLon
        return 2.0 * earthRadiusMeters * asin(min(1.0, sqrt(max(0.0, h))))
    }

    /// Initial forward true bearing in degrees [0, 360).
    public static func bearingDegrees(from a: RoutePoint, to b: RoutePoint) -> Double {
        let lat1 = a.latitude * .pi / 180.0
        let lat2 = b.latitude * .pi / 180.0
        let dLon = (b.longitude - a.longitude) * .pi / 180.0
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let deg = atan2(y, x) * 180.0 / .pi
        return (deg + 360.0).truncatingRemainder(dividingBy: 360.0)
    }

    /// Minimal angular deflection between two bearings in degrees [0, 180].
    public static func turnAngleDegrees(from b1: Double, to b2: Double) -> Double {
        let diff = abs(b2 - b1).truncatingRemainder(dividingBy: 360.0)
        return diff > 180.0 ? 360.0 - diff : diff
    }

    /// Offsets a WGS-84 coordinate by `meters` along `bearingDegrees`.
    public static func offset(
        latitude: Double,
        longitude: Double,
        meters: Double,
        bearingDegrees: Double
    ) -> (latitude: Double, longitude: Double) {
        guard abs(meters) > 1e-6 else { return (latitude, longitude) }
        let rad = bearingDegrees * .pi / 180.0
        let dNorth = meters * cos(rad)
        let dEast = meters * sin(rad)
        let dLat = dNorth / 111_320.0
        let cosLat = max(0.01, cos(latitude * .pi / 180.0))
        let dLon = dEast / (111_320.0 * cosLat)
        return (
            min(90.0, max(-90.0, latitude + dLat)),
            min(180.0, max(-180.0, longitude + dLon))
        )
    }

    public static func totalDistance(of points: [RoutePoint]) -> Double {
        guard points.count >= 2 else { return 0 }
        var total = 0.0
        for i in 0..<(points.count - 1) {
            total += distanceMeters(from: points[i], to: points[i + 1])
        }
        return total
    }

    public static func formatDistance(_ meters: Double) -> String {
        if meters < 1000 {
            return String(format: "%.0f m", max(0, meters))
        }
        return String(format: "%.2f km", meters / 1000.0)
    }

    public static func formatSpeedKmh(_ mps: Double) -> String {
        String(format: "%.1f km/h", max(0, mps) * 3.6)
    }

    public static func formatPacePerKm(_ mps: Double) -> String? {
        guard mps >= 0.4 else { return nil }
        let secondsPerKm = Int((1000.0 / mps).rounded())
        let mins = secondsPerKm / 60
        let secs = secondsPerKm % 60
        return String(format: "%d'%02d\"/km", mins, secs)
    }

    public static func formatETA(seconds: Double) -> String {
        guard seconds.isFinite && seconds > 0 else { return "--" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let mins = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%dh %02dm", hours, mins)
        } else if mins > 0 {
            return String(format: "%dm %02ds", mins, secs)
        } else {
            return String(format: "%ds", secs)
        }
    }
}

// MARK: - Road Route Planner (MKDirections + GCJ-02 <-> WGS-84 + Elevation Profile)

public enum RoadRoutePlanner {
    /// Plans a canonical WGS-84 road-aligned route across 2+ waypoints using Apple `MKDirections`.
    /// Automatically handles Mainland China GCJ-02 <-> WGS-84 conversion, falls back cleanly when
    /// road routing is unavailable for a segment, and enriches vertices with terrain elevation.
    public static func planRoute(
        waypoints: [RouteWaypoint],
        preset: RouteTransportPreset,
        loopMode: RouteLoopMode,
        gcj02CorrectionEnabled: Bool
    ) async -> RoutePlanningResult {
        guard waypoints.count >= 2 else {
            let pts = waypoints.map(\.routePoint)
            return RoutePlanningResult(
                points: pts,
                totalDistanceMeters: 0,
                usedRoadRouting: false,
                usedStraightFallback: false,
                isClosedCircuit: false
            )
        }

        // For closed loop with 3+ waypoints whose end isn't already next to start, route back to start
        // so the path forms a continuous road circuit with zero teleport jump.
        var routingStops = waypoints
        var isClosedCircuit = false
        if loopMode == .loop,
           waypoints.count >= 3,
           let first = waypoints.first,
           let last = waypoints.last,
           RouteGeometry.distanceMeters(from: first.routePoint, to: last.routePoint) > 25.0 {
            routingStops.append(first)
            isClosedCircuit = true
        } else if loopMode == .loop,
                  let first = waypoints.first,
                  let last = waypoints.last,
                  RouteGeometry.distanceMeters(from: first.routePoint, to: last.routePoint) <= 25.0 {
            isClosedCircuit = true
        }

        var stitched: [RoutePoint] = []
        var anyRoadRouted = false
        var anyFallback = false

        for idx in 0..<(routingStops.count - 1) {
            if Task.isCancelled { break }
            let start = routingStops[idx]
            let end = routingStops[idx + 1]

            let leg = await routeSingleLeg(
                from: start,
                to: end,
                preset: preset,
                gcj02CorrectionEnabled: gcj02CorrectionEnabled
            )
            if leg.usedRoad {
                anyRoadRouted = true
            } else {
                anyFallback = true
            }

            for pt in leg.points {
                if let prev = stitched.last,
                   RouteGeometry.distanceMeters(from: prev, to: pt) < 0.5 {
                    continue
                }
                stitched.append(pt)
            }
        }

        if stitched.count < 2 {
            stitched = routingStops.map(\.routePoint)
            anyFallback = true
        }

        // Enrich vertices with smooth terrain elevation profile (non-blocking best effort).
        if !Task.isCancelled {
            stitched = await enrichElevationProfile(for: stitched)
        }

        let total = RouteGeometry.totalDistance(of: stitched)
        return RoutePlanningResult(
            points: stitched,
            totalDistanceMeters: total,
            usedRoadRouting: anyRoadRouted,
            usedStraightFallback: anyFallback,
            isClosedCircuit: isClosedCircuit
        )
    }

    private static func toDirectionsCoord(_ wgs: CLLocationCoordinate2D, gcj02Enabled: Bool) -> CLLocationCoordinate2D {
        if gcj02Enabled && !CoordinateTransform.isOutsideChina(lat: wgs.latitude, lon: wgs.longitude) {
            return CoordinateTransform.wgs84ToGCJ02(lat: wgs.latitude, lon: wgs.longitude)
        }
        return wgs
    }

    private static func fromDirectionsCoord(_ dirCoord: CLLocationCoordinate2D, gcj02Enabled: Bool) -> CLLocationCoordinate2D {
        if gcj02Enabled && !CoordinateTransform.isOutsideChina(lat: dirCoord.latitude, lon: dirCoord.longitude) {
            return CoordinateTransform.gcj02ToWGS84(lat: dirCoord.latitude, lon: dirCoord.longitude)
        }
        return dirCoord
    }

    private static func routeSingleLeg(
        from start: RouteWaypoint,
        to end: RouteWaypoint,
        preset: RouteTransportPreset,
        gcj02CorrectionEnabled: Bool
    ) async -> (points: [RoutePoint], usedRoad: Bool) {
        let straightDist = RouteGeometry.distanceMeters(from: start.routePoint, to: end.routePoint)
        if straightDist < 5.0 {
            return ([start.routePoint, end.routePoint], false)
        }

        // Try preferred transport type first; for cycling/walking on very long distances (> 40 km),
        // fall back to `.automobile` if `.walking` fails.
        var transportAttempts: [MKDirectionsTransportType] = [preset.directionsTransportType]
        if preset == .cycling && !transportAttempts.contains(.automobile) {
            transportAttempts.append(.automobile)
        } else if (preset == .walking || preset == .running) && straightDist > 30_000 {
            transportAttempts.append(.automobile)
        } else if preset == .driving {
            transportAttempts.append(.walking)
        }

        let srcCoord = toDirectionsCoord(start.coordinate, gcj02Enabled: gcj02CorrectionEnabled)
        let dstCoord = toDirectionsCoord(end.coordinate, gcj02Enabled: gcj02CorrectionEnabled)

        for transportType in transportAttempts {
            if Task.isCancelled { break }
            if let coords = await calculateDirections(from: srcCoord, to: dstCoord, transportType: transportType),
               coords.count >= 2 {
                let startAlt = start.altitude
                let endAlt = end.altitude
                let denom = Double(max(1, coords.count - 1))
                let pts = coords.enumerated().map { idx, coord -> RoutePoint in
                    let wgs = fromDirectionsCoord(coord, gcj02Enabled: gcj02CorrectionEnabled)
                    let t = Double(idx) / denom
                    let alt = startAlt + (endAlt - startAlt) * t
                    return RoutePoint(latitude: wgs.latitude, longitude: wgs.longitude, altitude: alt)
                }
                return (pts, true)
            }
        }

        // Graceful fallback: subdivide straight segment into smooth sub-points.
        let steps = max(2, min(40, Int(ceil(straightDist / 25.0))))
        var fallback: [RoutePoint] = []
        fallback.reserveCapacity(steps + 1)
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            fallback.append(RoutePoint(
                latitude: start.latitude + (end.latitude - start.latitude) * t,
                longitude: start.longitude + (end.longitude - start.longitude) * t,
                altitude: start.altitude + (end.altitude - start.altitude) * t
            ))
        }
        return (fallback, false)
    }

    private static func calculateDirections(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        transportType: MKDirectionsTransportType
    ) async -> [CLLocationCoordinate2D]? {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: end))
        request.transportType = transportType
        request.requestsAlternateRoutes = false

        let directions = MKDirections(request: request)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                directions.calculate { response, _ in
                    guard let route = response?.routes.first else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let count = route.polyline.pointCount
                    guard count >= 2 else {
                        continuation.resume(returning: nil)
                        return
                    }
                    var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: count)
                    route.polyline.getCoordinates(&coords, range: NSRange(location: 0, length: count))
                    continuation.resume(returning: coords)
                }
            }
        } onCancel: {
            directions.cancel()
        }
    }

    /// Samples up to 16 evenly spaced points along the route using Open-Meteo's batch elevation API
    /// in a single request and linearly interpolates altitudes across all polyline vertices.
    private static func enrichElevationProfile(for points: [RoutePoint]) async -> [RoutePoint] {
        guard points.count >= 2 else { return points }
        let sampleCount = min(16, points.count)
        var sampleIndices: [Int] = []
        sampleIndices.reserveCapacity(sampleCount)
        if sampleCount == points.count {
            sampleIndices = Array(0..<points.count)
        } else {
            for i in 0..<sampleCount {
                let idx = Int((Double(i) * Double(points.count - 1) / Double(sampleCount - 1)).rounded())
                if sampleIndices.last != idx {
                    sampleIndices.append(idx)
                }
            }
        }

        let lats = sampleIndices.map { String(format: "%.5f", points[$0].latitude) }.joined(separator: ",")
        let lons = sampleIndices.map { String(format: "%.5f", points[$0].longitude) }.joined(separator: ",")
        guard let url = URL(string: "https://api.open-meteo.com/v1/elevation?latitude=\(lats)&longitude=\(lons)") else {
            return points
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 3.0
        req.setValue("Reloc/1.0 (iOS)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let values = json["elevation"] as? [NSNumber],
                  values.count == sampleIndices.count else {
                return points
            }

            let sampleAlts = values.map { min(50_000.0, max(-500.0, $0.doubleValue)) }
            guard sampleAlts.allSatisfy(\.isFinite) else { return points }

            var updated = points
            for seg in 0..<(sampleIndices.count - 1) {
                let i0 = sampleIndices[seg]
                let i1 = sampleIndices[seg + 1]
                let a0 = sampleAlts[seg]
                let a1 = sampleAlts[seg + 1]
                let span = Double(max(1, i1 - i0))
                for idx in i0...i1 {
                    let t = Double(idx - i0) / span
                    updated[idx].altitude = ((a0 + (a1 - a0) * t) * 10.0).rounded() / 10.0
                }
            }
            return updated
        } catch {
            return points
        }
    }
}

// MARK: - Realistic Kinematic Trajectory Driver (Background-Safe, Monotonic Clock)

/// Thread-safe kinematic simulator evaluated directly on `AccessoryLocationSession`'s background
/// NMEA tick loop using monotonic time. Produces smooth speed waves, look-ahead turn deceleration,
/// physically bounded acceleration, and subtle perpendicular GPS meander with zero main-thread timers.
public final class TrajectoryDriver: @unchecked Sendable {
    private let lock = NSLock()

    private let points: [RoutePoint]
    private let segmentLengths: [Double]
    private let cumulativeDistances: [Double]
    private let segmentBearings: [Double]
    private let vertexTurnAngles: [Double]
    public let totalDistanceMeters: Double
    private let isClosedCircuit: Bool

    private var preset: RouteTransportPreset
    private var baseSpeedMps: Double
    private var loopMode: RouteLoopMode
    private var realisticMotionEnabled: Bool
    private var isPaused: Bool = false
    private var isWaitingForStartLock: Bool
    private var isCompleted: Bool = false
    private var isReversing: Bool = false
    private var lapCount: Int = 1

    private var distanceAlongPath: Double = 0.0
    private var currentSpeedMps: Double = 0.0
    private var lastAdvanceTime: TimeInterval?
    private var elapsedMovingTime: TimeInterval = 0.0
    private var paceRandomWalk: Double = 0.0
    private var lateralOffsetMeters: Double = 0.0
    private var altitudeNoiseMeters: Double = 0.0
    private var lastEmittedLocation: TargetLocation

    public init?(
        points: [RoutePoint],
        preset: RouteTransportPreset,
        speedMetersPerSecond: Double,
        loopMode: RouteLoopMode,
        realisticMotionEnabled: Bool = true,
        waitForStartLock: Bool = true
    ) {
        // Deduplicate tiny zero-length segments while preserving endpoints.
        var cleaned: [RoutePoint] = []
        cleaned.reserveCapacity(points.count)
        for pt in points {
            if let prev = cleaned.last, RouteGeometry.distanceMeters(from: prev, to: pt) < 0.25 {
                continue
            }
            cleaned.append(pt)
        }
        guard cleaned.count >= 2 else { return nil }

        let segCount = cleaned.count - 1
        var lengths = [Double](repeating: 0, count: segCount)
        var cumulative = [Double](repeating: 0, count: cleaned.count)
        var bearings = [Double](repeating: 0, count: segCount)

        var running = 0.0
        for i in 0..<segCount {
            let len = RouteGeometry.distanceMeters(from: cleaned[i], to: cleaned[i + 1])
            lengths[i] = len
            running += len
            cumulative[i + 1] = running
            bearings[i] = RouteGeometry.bearingDegrees(from: cleaned[i], to: cleaned[i + 1])
        }
        guard running > 0.5 else { return nil }

        var turns = [Double](repeating: 0, count: cleaned.count)
        if cleaned.count >= 3 {
            for i in 1..<(cleaned.count - 1) {
                turns[i] = RouteGeometry.turnAngleDegrees(from: bearings[i - 1], to: bearings[i])
            }
        }

        let startEndGap = RouteGeometry.distanceMeters(from: cleaned.first!, to: cleaned.last!)
        self.points = cleaned
        self.segmentLengths = lengths
        self.cumulativeDistances = cumulative
        self.segmentBearings = bearings
        self.vertexTurnAngles = turns
        self.totalDistanceMeters = running
        self.isClosedCircuit = startEndGap <= 30.0

        self.preset = preset
        self.baseSpeedMps = max(0.3, speedMetersPerSecond)
        self.loopMode = loopMode
        self.realisticMotionEnabled = realisticMotionEnabled
        self.isWaitingForStartLock = waitForStartLock

        let first = cleaned[0]
        self.lastEmittedLocation = TargetLocation(
            latitude: first.latitude,
            longitude: first.longitude,
            altitude: first.altitude,
            speedKnots: 0.0,
            courseDegrees: 0.0
        )
    }

    public func currentTargetLocation() -> TargetLocation {
        lock.lock()
        defer { lock.unlock() }
        return lastEmittedLocation
    }

    public func initialProgress() -> TrajectoryProgress {
        lock.lock()
        defer { lock.unlock() }
        return makeProgressLocked(location: lastEmittedLocation, bearing: segmentBearings[0])
    }

    public func isWaitingForLock() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isWaitingForStartLock
    }

    @discardableResult
    public func releaseStartLock(atMonotonicTime now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if isWaitingForStartLock {
            isWaitingForStartLock = false
            lastAdvanceTime = now
            return true
        }
        return false
    }

    /// Holds trajectory progression in place if system CoreLocation stops accepting external NMEA
    /// (e.g. `CLNmeaScreener` rejection or dead-reckoning stall) until lock is genuinely re-confirmed.
    @discardableResult
    public func holdForRelock() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isCompleted else { return false }
        let changed = !isWaitingForStartLock
        isWaitingForStartLock = true
        currentSpeedMps = 0.0
        return changed
    }

    public func setPaused(_ paused: Bool, atMonotonicTime now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock()
        isPaused = paused
        if !paused {
            lastAdvanceTime = now
        } else {
            currentSpeedMps = 0.0
        }
        lock.unlock()
    }

    public func setTargetSpeed(_ mps: Double) {
        lock.lock()
        baseSpeedMps = max(0.3, min(50.0, mps))
        lock.unlock()
    }

    public func setPreset(_ newPreset: RouteTransportPreset) {
        lock.lock()
        preset = newPreset
        lock.unlock()
    }

    public func setLoopMode(_ newMode: RouteLoopMode) {
        lock.lock()
        loopMode = newMode
        if newMode != .once && isCompleted {
            isCompleted = false
            lastAdvanceTime = ProcessInfo.processInfo.systemUptime
        }
        lock.unlock()
    }

    public func setRealisticMotionEnabled(_ enabled: Bool) {
        lock.lock()
        realisticMotionEnabled = enabled
        if !enabled {
            lateralOffsetMeters = 0.0
            altitudeNoiseMeters = 0.0
            paceRandomWalk = 0.0
        }
        lock.unlock()
    }

    /// Advances the trajectory smoothly to `now` (monotonic uptime seconds) and returns the next NMEA target.
    public func advance(toMonotonicTime now: TimeInterval, stationaryJitter: Bool) -> TrajectoryStep {
        lock.lock()
        defer { lock.unlock() }

        let dt: TimeInterval
        if let prev = lastAdvanceTime {
            dt = min(5.0, max(0.0, now - prev))
        } else {
            dt = 0.0
        }
        lastAdvanceTime = now

        var didTeleportLap = false

        if isWaitingForStartLock || isPaused || isCompleted {
            currentSpeedMps = 0.0
            let sample = sampleAtDistanceLocked(distanceAlongPath, reversing: isReversing)
            var loc = TargetLocation(
                latitude: sample.latitude,
                longitude: sample.longitude,
                altitude: sample.altitude,
                speedKnots: 0.0,
                courseDegrees: 0.0
            )
            if stationaryJitter {
                loc = CoordinateTransform.applyMicroJitter(to: loc)
            }
            lastEmittedLocation = loc
            let progress = makeProgressLocked(location: loc, bearing: sample.bearing)
            return TrajectoryStep(location: loc, progress: progress, didTeleportLap: false)
        }

        // Compute realistic instantaneous target speed (pace wave + turn deceleration + endpoint braking).
        let targetSpeed = computeDesiredSpeedLocked(dt: dt)
        if dt > 0 {
            let maxDelta = preset.maxAccelerationMps2 * dt
            if targetSpeed > currentSpeedMps {
                currentSpeedMps = min(targetSpeed, currentSpeedMps + maxDelta)
            } else {
                currentSpeedMps = max(targetSpeed, currentSpeedMps - maxDelta * 1.4)
            }
            // Keep gentle minimum forward motion while actively moving so we never stall on a hairpin.
            currentSpeedMps = max(min(baseSpeedMps, 0.35), currentSpeedMps)
            elapsedMovingTime += dt
        } else if currentSpeedMps <= 0 {
            currentSpeedMps = realisticMotionEnabled ? min(baseSpeedMps, max(0.4, baseSpeedMps * 0.35)) : baseSpeedMps
        }

        let stepMeters = currentSpeedMps * dt
        if stepMeters > 0 {
            if !isReversing {
                distanceAlongPath += stepMeters
                if distanceAlongPath >= totalDistanceMeters {
                    switch loopMode {
                    case .once:
                        distanceAlongPath = totalDistanceMeters
                        currentSpeedMps = 0.0
                        isCompleted = true
                    case .roundTrip:
                        let overshoot = distanceAlongPath - totalDistanceMeters
                        distanceAlongPath = max(0.0, totalDistanceMeters - overshoot)
                        isReversing = true
                        currentSpeedMps *= 0.45
                    case .loop:
                        distanceAlongPath = distanceAlongPath.truncatingRemainder(dividingBy: totalDistanceMeters)
                        lapCount += 1
                        if !isClosedCircuit {
                            didTeleportLap = true
                            currentSpeedMps *= 0.5
                        }
                    }
                }
            } else {
                distanceAlongPath -= stepMeters
                if distanceAlongPath <= 0.0 {
                    let overshoot = -distanceAlongPath
                    distanceAlongPath = min(totalDistanceMeters, overshoot)
                    isReversing = false
                    lapCount += 1
                    currentSpeedMps *= 0.45
                }
            }
        }

        let sample = sampleAtDistanceLocked(distanceAlongPath, reversing: isReversing)
        var lat = sample.latitude
        var lon = sample.longitude
        var alt = sample.altitude

        if realisticMotionEnabled && !isCompleted {
            // Smooth perpendicular lateral GPS meander (never jumps backwards along track).
            let maxDrift = preset.lateralDriftMeters
            let stepDrift = Double.random(in: -0.18...0.18) * max(0.5, min(2.0, dt))
            lateralOffsetMeters = max(-maxDrift, min(maxDrift, lateralOffsetMeters * 0.85 + stepDrift))
            let perpBearing = (sample.bearing + 90.0).truncatingRemainder(dividingBy: 360.0)
            let drifted = RouteGeometry.offset(
                latitude: lat,
                longitude: lon,
                meters: lateralOffsetMeters,
                bearingDegrees: perpBearing
            )
            lat = drifted.latitude
            lon = drifted.longitude

            let altStep = Double.random(in: -0.12...0.12)
            altitudeNoiseMeters = max(-0.4, min(0.4, altitudeNoiseMeters * 0.85 + altStep))
            alt = min(50_000.0, max(-500.0, alt + altitudeNoiseMeters))
        }

        let emittedSpeedKnots = isCompleted ? 0.0 : (currentSpeedMps * RouteGeometry.mpsToKnots)
        let emittedCourse = (isCompleted || emittedSpeedKnots < 0.05) ? 0.0 : sample.bearing
        let loc = TargetLocation(
            latitude: lat,
            longitude: lon,
            altitude: alt,
            speedKnots: emittedSpeedKnots,
            courseDegrees: emittedCourse
        )
        lastEmittedLocation = loc
        let progress = makeProgressLocked(location: loc, bearing: sample.bearing)
        return TrajectoryStep(location: loc, progress: progress, didTeleportLap: didTeleportLap)
    }

    private func computeDesiredSpeedLocked(dt: TimeInterval) -> Double {
        guard realisticMotionEnabled else { return baseSpeedMps }

        // 1. Organic pace variation: smooth dual-harmonic wave + low-pass bounded random walk.
        let variance = preset.paceVarianceFraction
        if dt > 0 {
            let walkStep = Double.random(in: -0.025...0.025) * min(2.0, max(0.2, dt))
            paceRandomWalk = max(-variance * 0.6, min(variance * 0.6, paceRandomWalk * 0.92 + walkStep))
        }
        let harmonic = (sin(elapsedMovingTime * 0.21) * 0.6 + sin(elapsedMovingTime * 0.073 + 1.3) * 0.4) * variance * 0.55
        var factor = 1.0 + harmonic + paceRandomWalk

        // 2. Look-ahead turn deceleration.
        let lookAhead = min(45.0, max(8.0, baseSpeedMps * 3.0))
        let turnFactor = upcomingTurnSpeedFactorLocked(lookAheadMeters: lookAhead)
        factor *= turnFactor

        // 3. Smooth braking when approaching stop/turnaround.
        let remainingToTurn = isReversing ? distanceAlongPath : (totalDistanceMeters - distanceAlongPath)
        let brakeZone = min(30.0, max(6.0, baseSpeedMps * 2.5))
        if (loopMode == .once || loopMode == .roundTrip || !isClosedCircuit), remainingToTurn < brakeZone {
            let ratio = max(0.0, min(1.0, remainingToTurn / brakeZone))
            let brakeFactor = 0.35 + 0.65 * sqrt(ratio)
            factor = min(factor, brakeFactor)
        }

        return max(0.35, baseSpeedMps * factor)
    }

    private func upcomingTurnSpeedFactorLocked(lookAheadMeters: Double) -> Double {
        let floorFactor = preset.sharpTurnSpeedFactor
        var minFactor = 1.0

        if !isReversing {
            let windowEnd = distanceAlongPath + lookAheadMeters
            for idx in 1..<(points.count - 1) {
                let d = cumulativeDistances[idx]
                if d < distanceAlongPath - 3.0 { continue }
                if d > windowEnd { break }
                let angle = vertexTurnAngles[idx]
                if angle <= 18.0 { continue }
                let proximity = 1.0 - max(0.0, d - distanceAlongPath) / lookAheadMeters
                let severity = min(1.0, (angle - 18.0) / 77.0) // 18° -> 0, 95°+ -> 1
                let turnMult = 1.0 - (1.0 - floorFactor) * severity * (0.45 + 0.55 * proximity)
                minFactor = min(minFactor, turnMult)
            }
        } else {
            let windowStart = distanceAlongPath - lookAheadMeters
            for idx in stride(from: points.count - 2, through: 1, by: -1) {
                let d = cumulativeDistances[idx]
                if d > distanceAlongPath + 3.0 { continue }
                if d < windowStart { break }
                let angle = vertexTurnAngles[idx]
                if angle <= 18.0 { continue }
                let proximity = 1.0 - max(0.0, distanceAlongPath - d) / lookAheadMeters
                let severity = min(1.0, (angle - 18.0) / 77.0)
                let turnMult = 1.0 - (1.0 - floorFactor) * severity * (0.45 + 0.55 * proximity)
                minFactor = min(minFactor, turnMult)
            }
        }
        return minFactor
    }

    private func sampleAtDistanceLocked(
        _ distance: Double,
        reversing: Bool
    ) -> (latitude: Double, longitude: Double, altitude: Double, bearing: Double) {
        let clamped = min(totalDistanceMeters, max(0.0, distance))

        // Binary search cumulativeDistances for active segment.
        var lo = 0
        var hi = segmentLengths.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if cumulativeDistances[mid] <= clamped {
                lo = mid
            } else {
                hi = mid - 1
            }
        }

        let segIdx = min(segmentLengths.count - 1, max(0, lo))
        let segLen = segmentLengths[segIdx]
        let localDist = clamped - cumulativeDistances[segIdx]
        let t = segLen > 1e-6 ? min(1.0, max(0.0, localDist / segLen)) : 0.0

        let a = points[segIdx]
        let b = points[segIdx + 1]
        let lat = a.latitude + (b.latitude - a.latitude) * t
        let lon = a.longitude + (b.longitude - a.longitude) * t
        let alt = a.altitude + (b.altitude - a.altitude) * t
        let forwardBearing = segmentBearings[segIdx]
        let bearing = reversing ? (forwardBearing + 180.0).truncatingRemainder(dividingBy: 360.0) : forwardBearing
        return (lat, lon, alt, bearing)
    }

    private func makeProgressLocked(location: TargetLocation, bearing: Double) -> TrajectoryProgress {
        let ratio = totalDistanceMeters > 0 ? min(1.0, max(0.0, distanceAlongPath / totalDistanceMeters)) : 0.0
        return TrajectoryProgress(
            currentLocation: location,
            traveledMeters: distanceAlongPath,
            totalDistanceMeters: totalDistanceMeters,
            progress: ratio,
            currentSpeedMps: currentSpeedMps,
            bearingDegrees: bearing,
            lapCount: lapCount,
            isPaused: isPaused,
            isWaitingForStartLock: isWaitingForStartLock,
            isCompleted: isCompleted,
            isReversing: isReversing
        )
    }
}
