import CoreLocation
import Foundation

public struct TargetLocation: Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double
    public var speedKnots: Double
    public var courseDegrees: Double

    public init(
        latitude: Double,
        longitude: Double,
        altitude: Double = 10.0,
        speedKnots: Double = 0.0,
        courseDegrees: Double = 0.0
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.speedKnots = speedKnots
        self.courseDegrees = courseDegrees
    }
}

public enum NMEAGeneratorError: LocalizedError {
    case coordinateOutOfRange(Double)
    case encodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .coordinateOutOfRange(let value):
            return "Coordinate out of range: \(value)"
        case .encodingFailed(let reason):
            return reason
        }
    }
}

/// Faithful Swift port of accessory-location's profile.py (iAP2 identity & NMEA GGA/RMC).
public enum NMEAGenerator {
    /// Formats a decimal coordinate into NMEA DDMM.MMMM / DDDMM.MMMM + hemisphere.
    /// Uses integer minute-ten-thousandths to avoid rounding to invalid 60.0000 minutes.
    public static func formatCoordinate(_ value: Double, isLatitude: Bool) throws -> (String, String) {
        let limit = isLatitude ? 90.0 : 180.0
        guard value.isFinite, value >= -limit, value <= limit else {
            throw NMEAGeneratorError.coordinateOutOfRange(value)
        }
        let units = Int((abs(value) * 60.0 * 10000.0).rounded())
        let degrees = units / 600_000
        let minuteUnits = units % 600_000
        let minutes = Double(minuteUnits) / 10000.0
        let hemisphere = isLatitude ? (value < 0 ? "S" : "N") : (value < 0 ? "W" : "E")
        let formatted = isLatitude
            ? String(format: "%02d%07.4f", degrees, minutes)
            : String(format: "%03d%07.4f", degrees, minutes)
        return (formatted, hemisphere)
    }

    /// Computes XOR NMEA checksum and wraps body as `$<body>*<XX>\r\n`.
    public static func sentence(body: String) -> String {
        var checksum: UInt8 = 0
        for byte in body.utf8 {
            checksum ^= byte
        }
        return String(format: "$%@*%02X\r\n", body, checksum)
    }

    private static func utcTimestampStrings(for date: Date) -> (clock: String, ddmmyy: String) {
        let interval = date.timeIntervalSince1970
        let wholeSeconds = floor(interval)
        var rawTime = time_t(wholeSeconds)
        var utcTime = tm()
        gmtime_r(&rawTime, &utcTime)
        let centiseconds = min(99, max(0, Int(((interval - wholeSeconds) * 100.0).rounded(.down))))
        let clock = String(
            format: "%02d%02d%02d.%02d",
            utcTime.tm_hour,
            utcTime.tm_min,
            utcTime.tm_sec,
            centiseconds
        )
        let ddmmyy = String(
            format: "%02d%02d%02d",
            utcTime.tm_mday,
            utcTime.tm_mon + 1,
            (Int(utcTime.tm_year) + 1900) % 100
        )
        return (clock, ddmmyy)
    }

    /// Generates NMEA sentences keyed by iAP2 location sentence ID: 1 = GPGGA, 2 = GPRMC.
    public static func locationSentences(
        for location: TargetLocation,
        at date: Date = Date(),
        hdop: Double = 0.5,
        fixQuality: Int = 2
    ) throws -> [UInt16: String] {
        let (lat, north) = try formatCoordinate(location.latitude, isLatitude: true)
        let (lon, east) = try formatCoordinate(location.longitude, isLatitude: false)
        let (clock, ddmmyy) = utcTimestampStrings(for: date)

        let safeQuality = max(0, min(8, fixQuality))
        let safeHDOP = hdop.isFinite ? max(0.1, hdop) : 0.5
        let hdopStr = String(format: "%.1f", safeHDOP)
        let safeAltitude = location.altitude.isFinite ? min(50_000.0, max(-500.0, location.altitude)) : 10.0
        let altitudeStr = String(format: "%.1f", safeAltitude)
        let speedStr = String(format: "%.1f", max(0.0, location.speedKnots.isFinite ? location.speedKnots : 0.0))
        let courseNorm = location.courseDegrees.isFinite
            ? ((location.courseDegrees.truncatingRemainder(dividingBy: 360.0)) + 360.0)
                .truncatingRemainder(dividingBy: 360.0)
            : 0.0
        let courseStr = String(format: "%.1f", courseNorm)
        let rmcMode = safeQuality == 2 ? "D" : "A"

        let gga = sentence(
            body: "GPGGA,\(clock),\(lat),\(north),\(lon),\(east),\(safeQuality),12,\(hdopStr),\(altitudeStr),M,0.0,M,,"
        )
        let rmc = sentence(
            body: "GPRMC,\(clock),A,\(lat),\(north),\(lon),\(east),\(speedStr),\(courseStr),\(ddmmyy),,,\(rmcMode)"
        )
        return [1: gga, 2: rmc]
    }

    /// Generates standard NMEA-0183 void/invalid-fix sentences (GGA quality=0, RMC status=V)
    /// sent right before tearing down the iAP2 link so `locationd` immediately drops the
    /// external accessory fix and falls back to internal GNSS/Wi-Fi/Cellular positioning.
    public static func voidLocationSentences(at date: Date = Date()) -> [UInt16: String] {
        let (clock, ddmmyy) = utcTimestampStrings(for: date)
        let gga = sentence(body: "GPGGA,\(clock),0000.0000,N,00000.0000,E,0,00,99.9,0.0,M,0.0,M,,")
        let rmc = sentence(body: "GPRMC,\(clock),V,,,,,0.0,0.0,\(ddmmyy),,,N")
        return [1: gga, 2: rmc]
    }

    /// Encodes `0xFFFB` LocationInformation with each NMEA sentence as parameter 0.
    public static func locationMessage(sentences: [String]) throws -> RLIAP2Message {
        var body = Data()
        for item in sentences {
            let param = try RLIAP2Parameter.encodeText(0, string: item)
            body.append(param)
        }
        return RLIAP2Message(identifier: 0xFFFB, body: body)
    }

    /// Builds `0x1D01` IdentificationInformation matching accessory-location's USB/CarKit profile.
    public static func identificationMessage(
        name: String = "Accessory Location Lab",
        model: String = "AL-1",
        manufacturer: String = "Local Research",
        serialNumber: String = "AL-LOCAL-001",
        firmwareVersion: String = "0.1",
        hardwareVersion: String = "1"
    ) throws -> RLIAP2Message {
        var body = Data()
        let strings: [(UInt16, String)] = [
            (0, name),
            (1, model),
            (2, manufacturer),
            (3, serialNumber),
            (4, firmwareVersion),
            (5, hardwareVersion),
        ]
        for (id, value) in strings {
            body.append(try RLIAP2Parameter.encodeText(id, string: value))
        }

        // MessagesSentByAccessory: 0xFFFB (LocationInformation)
        body.append(RLIAP2Parameter.encode(6, data: Data([0xFF, 0xFB])))
        // MessagesReceivedFromDevice: 0xFFFA (StartLocation), 0xFFFC (StopLocation)
        body.append(RLIAP2Parameter.encode(7, data: Data([0xFF, 0xFA, 0xFF, 0xFC])))
        // PowerProvidingCapability = None (0)
        body.append(RLIAP2Parameter.encode(8, data: Data([0x00])))
        // MaximumCurrentDrawnFromDevice = 0 mA
        body.append(RLIAP2Parameter.encode(9, data: Data([0x00, 0x00])))
        // CurrentLanguage & SupportedLanguage
        body.append(try RLIAP2Parameter.encodeText(12, string: "en"))
        body.append(try RLIAP2Parameter.encodeText(13, string: "en"))

        // USBHostTransportComponent (param 16)
        var transportComponent = Data()
        transportComponent.append(RLIAP2Parameter.encode(0, data: Data([0x00, 0x00])))
        transportComponent.append(try RLIAP2Parameter.encodeText(1, string: "Location Transport"))
        transportComponent.append(RLIAP2Parameter.encode(2, data: Data()))
        body.append(RLIAP2Parameter.encode(16, data: transportComponent))

        // LocationInformationComponent (param 22): ID 0, Name "GPS", GGA (17), RMC (18)
        var locationComponent = Data()
        locationComponent.append(RLIAP2Parameter.encode(0, data: Data([0x00, 0x00])))
        locationComponent.append(try RLIAP2Parameter.encodeText(1, string: "GPS"))
        locationComponent.append(RLIAP2Parameter.encode(17, data: Data()))
        locationComponent.append(RLIAP2Parameter.encode(18, data: Data()))
        body.append(RLIAP2Parameter.encode(22, data: locationComponent))

        return RLIAP2Message(identifier: 0x1D01, body: body)
    }
}

/// Optional GCJ-02 <-> WGS-84 coordinate conversion for Mainland China Apple Maps alignment.
public enum CoordinateTransform {
    private static let a = 6378245.0
    private static let ee = 0.00669342162296594323

    public static func isOutsideChina(lat: Double, lon: Double) -> Bool {
        lon < 72.004 || lon > 137.8347 || lat < 0.8293 || lat > 55.8271
    }

    public static func wgs84ToGCJ02(lat: Double, lon: Double) -> CLLocationCoordinate2D {
        if isOutsideChina(lat: lat, lon: lon) {
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        let d = delta(lat: lat, lon: lon)
        return CLLocationCoordinate2D(latitude: lat + d.lat, longitude: lon + d.lon)
    }

    public static func gcj02ToWGS84(lat: Double, lon: Double) -> CLLocationCoordinate2D {
        if isOutsideChina(lat: lat, lon: lon) {
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        // 3-step fixed-point refinement gives sub-millimeter inverse accuracy.
        var wgsLat = lat
        var wgsLon = lon
        for _ in 0..<3 {
            let gcj = wgs84ToGCJ02(lat: wgsLat, lon: wgsLon)
            wgsLat += lat - gcj.latitude
            wgsLon += lon - gcj.longitude
        }
        return CLLocationCoordinate2D(latitude: wgsLat, longitude: wgsLon)
    }

    /// Applies optional sub-meter GPS micro-jitter (horizontal + subtle vertical) so stationary fixes feel more lifelike.
    public static func applyMicroJitter(to location: TargetLocation, radiusMeters: Double = 0.6) -> TargetLocation {
        guard radiusMeters > 0 else { return location }
        let angle = Double.random(in: 0..<(2.0 * .pi))
        let radius = Double.random(in: 0...radiusMeters)
        let dLat = (radius * cos(angle)) / 111_320.0
        let cosLat = max(0.01, cos(location.latitude * .pi / 180.0))
        let dLon = (radius * sin(angle)) / (111_320.0 * cosLat)
        let baseAlt = location.altitude.isFinite ? location.altitude : 10.0
        let dAlt = Double.random(in: -0.3...0.3)
        var copy = location
        copy.latitude = min(90.0, max(-90.0, location.latitude + dLat))
        copy.longitude = min(180.0, max(-180.0, location.longitude + dLon))
        copy.altitude = min(50_000.0, max(-500.0, baseAlt + dAlt))
        return copy
    }

    private static func delta(lat: Double, lon: Double) -> (lat: Double, lon: Double) {
        var dLat = transformLat(x: lon - 105.0, y: lat - 35.0)
        var dLon = transformLon(x: lon - 105.0, y: lat - 35.0)
        let radLat = lat / 180.0 * .pi
        var magic = sin(radLat)
        magic = 1.0 - ee * magic * magic
        let sqrtMagic = sqrt(magic)
        dLat = (dLat * 180.0) / ((a * (1.0 - ee)) / (magic * sqrtMagic) * .pi)
        dLon = (dLon * 180.0) / (a / sqrtMagic * cos(radLat) * .pi)
        return (dLat, dLon)
    }

    private static func transformLat(x: Double, y: Double) -> Double {
        var ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        ret += (20.0 * sin(y * .pi) + 40.0 * sin(y / 3.0 * .pi)) * 2.0 / 3.0
        ret += (160.0 * sin(y / 12.0 * .pi) + 320.0 * sin(y * .pi / 30.0)) * 2.0 / 3.0
        return ret
    }

    private static func transformLon(x: Double, y: Double) -> Double {
        var ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        ret += (20.0 * sin(x * .pi) + 40.0 * sin(x / 3.0 * .pi)) * 2.0 / 3.0
        ret += (150.0 * sin(x / 12.0 * .pi) + 300.0 * sin(x / 30.0 * .pi)) * 2.0 / 3.0
        return ret
    }
}
