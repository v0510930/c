import AVFoundation
import AVKit
import CoreMedia
import CoreVideo
import Foundation
import UIKit

/// Floating Picture-in-Picture (PiP) live guidance card displayed over iOS Settings during
/// on-device Remote Pairing. Works inside the single main app bundle without needing a
/// separate Widget Extension provisioning profile.
@MainActor
final class PairingPiPPresenter: NSObject, ObservableObject {
    static let shared = PairingPiPPresenter()

    @Published private(set) var isSupported: Bool = AVPictureInPictureController.isPictureInPictureSupported()
    @Published private(set) var isActive = false
    @Published private(set) var isPossible = false

    private var hostView: SampleBufferHostView?
    private var pipController: AVPictureInPictureController?
    private var possibleObserver: NSKeyValueObservation?
    private var refreshTimer: Timer?
    private var dismissTimer: Timer?

    private var stepIndex: Int = 1
    private var headline: String = "准备设备配对…"
    private var subtitle: String = "请保持本机网络回环已开启"
    private var pin: String?
    private var outcome: Outcome = .inProgress
    private var deadline: Date = Date().addingTimeInterval(300)
    private var frameCounter: Int64 = 0
    private var wantsAutoStart = false

    enum Outcome {
        case inProgress
        case succeeded
        case failed
    }

    private override init() {
        super.init()
    }

    func startSession(deadline: Date) {
        dismissTimer?.invalidate()
        dismissTimer = nil

        self.deadline = deadline
        self.stepIndex = 1
        self.headline = "准备本机配对服务…"
        self.subtitle = "正在启动 Bonjour 配对广播"
        self.pin = nil
        self.outcome = .inProgress
        self.wantsAutoStart = true

        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            isSupported = false
            return
        }
        isSupported = true

        configureAudioSession()
        ensureControllerAttached()
        enqueueCurrentFrame()
        startRefreshTimer()

        // Try starting PiP once the system marks it possible (short warmup).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.tryStartPiPIfDesired()
        }
    }

    func update(step: Int, headline: String, subtitle: String, pin: String? = nil) {
        self.stepIndex = step
        self.headline = headline
        self.subtitle = subtitle
        self.pin = pin
        self.outcome = .inProgress
        enqueueCurrentFrame()
    }

    func finish(succeeded: Bool, message: String) {
        self.outcome = succeeded ? .succeeded : .failed
        self.stepIndex = succeeded ? 3 : self.stepIndex
        self.headline = succeeded ? "配对成功 · 记录已保存" : "配对未完成"
        self.subtitle = message
        self.pin = nil
        self.wantsAutoStart = false
        enqueueCurrentFrame()

        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: succeeded ? 3.5 : 4.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.teardown()
            }
        }
    }

    func togglePiP() {
        guard let pip = pipController else {
            ensureControllerAttached()
            enqueueCurrentFrame()
            wantsAutoStart = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.tryStartPiPIfDesired()
            }
            return
        }
        if pip.isPictureInPictureActive {
            wantsAutoStart = false
            pip.stopPictureInPicture()
        } else if pip.isPictureInPicturePossible {
            pip.startPictureInPicture()
        } else {
            wantsAutoStart = true
            enqueueCurrentFrame()
        }
    }

    func teardown() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        wantsAutoStart = false

        if let pip = pipController, pip.isPictureInPictureActive {
            pip.stopPictureInPicture()
        }
        possibleObserver?.invalidate()
        possibleObserver = nil
        pipController = nil
        hostView?.removeFromSuperview()
        hostView = nil
        isActive = false
        isPossible = false
    }

    // MARK: - Setup & Frame Rendering

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        try? session.setActive(true)
    }

    private func ensureControllerAttached() {
        guard let window = Self.activeKeyWindow() else { return }

        if hostView == nil {
            let view = SampleBufferHostView(frame: CGRect(x: 16, y: 120, width: 320, height: 112))
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            view.alpha = 0.02 // Must stay non-zero & attached in window hierarchy for PiP eligibility
            window.addSubview(view)
            hostView = view
        } else if hostView?.superview == nil {
            window.addSubview(hostView!)
        }

        guard let displayLayer = hostView?.displayLayer else { return }
        displayLayer.videoGravity = .resizeAspect

        if pipController == nil {
            let source = AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: displayLayer,
                playbackDelegate: self
            )
            let controller = AVPictureInPictureController(contentSource: source)
            controller.delegate = self
            controller.canStartPictureInPictureAutomaticallyFromInline = true
            controller.requiresLinearPlayback = true
            possibleObserver = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] ctrl, _ in
                let possible = ctrl.isPictureInPicturePossible
                Task { @MainActor in
                    self?.isPossible = possible
                    if possible {
                        self?.tryStartPiPIfDesired()
                    }
                }
            }
            pipController = controller
        }
    }

    private func tryStartPiPIfDesired() {
        guard wantsAutoStart, let pip = pipController else { return }
        if !pip.isPictureInPictureActive && pip.isPictureInPicturePossible {
            pip.startPictureInPicture()
        }
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.enqueueCurrentFrame()
            }
        }
    }

    private func enqueueCurrentFrame() {
        guard let displayLayer = hostView?.displayLayer else { return }
        if displayLayer.sampleBufferRenderer.status == .failed {
            displayLayer.sampleBufferRenderer.flush()
        }
        guard let buffer = renderSampleBuffer() else { return }
        displayLayer.sampleBufferRenderer.enqueue(buffer)
    }

    private func renderSampleBuffer() -> CMSampleBuffer? {
        let width = 640
        let height = 224

        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ]
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pb = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

        guard let ctx = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        // Flip coordinates so UIKit/NSString drawing is upright
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1.0, y: -1.0)

        UIGraphicsPushContext(ctx)
        drawCard(in: CGRect(x: 0, y: 0, width: width, height: height))
        UIGraphicsPopContext()

        var formatDesc: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pb,
            formatDescriptionOut: &formatDesc
        ) == noErr, let format = formatDesc else { return nil }

        frameCounter += 1
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 1),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pb,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sb = sampleBuffer else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true) as? [NSMutableDictionary],
           let first = attachments.first {
            first[kCMSampleAttachmentKey_DisplayImmediately] = kCFBooleanTrue
        }
        return sb
    }

    private func drawCard(in rect: CGRect) {
        // Dark sleek surface gradient
        let bgColors: [CGColor]
        switch outcome {
        case .inProgress:
            bgColors = [
                UIColor(red: 0.08, green: 0.10, blue: 0.16, alpha: 1).cgColor,
                UIColor(red: 0.05, green: 0.06, blue: 0.11, alpha: 1).cgColor,
            ]
        case .succeeded:
            bgColors = [
                UIColor(red: 0.05, green: 0.22, blue: 0.16, alpha: 1).cgColor,
                UIColor(red: 0.04, green: 0.13, blue: 0.10, alpha: 1).cgColor,
            ]
        case .failed:
            bgColors = [
                UIColor(red: 0.24, green: 0.08, blue: 0.09, alpha: 1).cgColor,
                UIColor(red: 0.14, green: 0.05, blue: 0.06, alpha: 1).cgColor,
            ]
        }

        if let ctx = UIGraphicsGetCurrentContext(),
           let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: bgColors as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: rect.maxX, y: rect.maxY), options: [])
        }

        // Top accent bar
        let accentColor: UIColor
        switch outcome {
        case .inProgress:
            accentColor = pin != nil
                ? UIColor(red: 0.98, green: 0.67, blue: 0.16, alpha: 1)
                : UIColor(red: 0.30, green: 0.56, blue: 1.0, alpha: 1)
        case .succeeded:
            accentColor = UIColor(red: 0.16, green: 0.82, blue: 0.54, alpha: 1)
        case .failed:
            accentColor = UIColor(red: 0.96, green: 0.34, blue: 0.34, alpha: 1)
        }
        accentColor.setFill()
        UIRectFill(CGRect(x: 0, y: 0, width: rect.width, height: 6))

        // Header badge: "Reloc · 设备配对"
        let dotRect = CGRect(x: 24, y: 26, width: 12, height: 12)
        UIBezierPath(ovalIn: dotRect).fill()

        let headerText = "Reloc · 设备配对指引" as NSString
        headerText.draw(
            at: CGPoint(x: 46, y: 20),
            withAttributes: [
                .font: UIFont.systemFont(ofSize: 21, weight: .semibold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.88),
            ]
        )

        // Right countdown or step pill
        if outcome == .inProgress {
            let remaining = max(0, Int(deadline.timeIntervalSinceNow.rounded()))
            let countdown = String(format: "%02d:%02d  步骤 %d/3", remaining / 60, remaining % 60, stepIndex) as NSString
            let size = countdown.size(withAttributes: [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 19, weight: .semibold),
            ])
            countdown.draw(
                at: CGPoint(x: rect.width - size.width - 24, y: 22),
                withAttributes: [
                    .font: UIFont.monospacedDigitSystemFont(ofSize: 19, weight: .semibold),
                    .foregroundColor: accentColor,
                ]
            )
        }

        // Subtle divider
        UIColor.white.withAlphaComponent(0.12).setFill()
        UIRectFill(CGRect(x: 24, y: 58, width: rect.width - 48, height: 1.5))

        if let pin, !pin.isEmpty {
            // Giant 6-digit PIN layout
            let formatted = Self.formatPin(pin) as NSString
            let pinAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 78, weight: .bold),
                .foregroundColor: UIColor(red: 1.0, green: 0.80, blue: 0.28, alpha: 1),
            ]
            let pinSize = formatted.size(withAttributes: pinAttrs)
            formatted.draw(
                at: CGPoint(x: (rect.width - pinSize.width) / 2, y: 70),
                withAttributes: pinAttrs
            )

            let hint = "请在「系统设置」弹窗中输入以上 6 位配对码" as NSString
            let hintAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 21, weight: .medium),
                .foregroundColor: UIColor.white.withAlphaComponent(0.78),
            ]
            let hintSize = hint.size(withAttributes: hintAttrs)
            hint.draw(
                at: CGPoint(x: (rect.width - hintSize.width) / 2, y: 170),
                withAttributes: hintAttrs
            )
        } else {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail

            (headline as NSString).draw(
                in: CGRect(x: 24, y: 76, width: rect.width - 48, height: 42),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 30, weight: .bold),
                    .foregroundColor: UIColor.white,
                    .paragraphStyle: paragraph,
                ]
            )

            let subPara = NSMutableParagraphStyle()
            subPara.lineSpacing = 4
            (subtitle as NSString).draw(
                in: CGRect(x: 24, y: 126, width: rect.width - 48, height: 76),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 22, weight: .medium),
                    .foregroundColor: UIColor.white.withAlphaComponent(0.76),
                    .paragraphStyle: subPara,
                ]
            )
        }
    }

    static func formatPin(_ pin: String) -> String {
        let digits = pin.filter { !$0.isWhitespace }
        guard digits.count == 6 else { return pin }
        return "\(digits.prefix(3))  \(digits.suffix(3))"
    }

    private static func activeKeyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
            ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first
    }
}

extension PairingPiPPresenter: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            self.isActive = true
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            self.isActive = false
        }
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        Task { @MainActor in
            self.isActive = false
        }
    }
}

extension PairingPiPPresenter: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {}

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        false
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        Task { @MainActor in
            self.enqueueCurrentFrame()
        }
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}

private final class SampleBufferHostView: UIView {
    override class var layerClass: AnyClass {
        AVSampleBufferDisplayLayer.self
    }

    var displayLayer: AVSampleBufferDisplayLayer {
        layer as! AVSampleBufferDisplayLayer
    }
}
