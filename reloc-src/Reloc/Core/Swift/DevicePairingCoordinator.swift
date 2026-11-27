import Foundation
import RelocDeviceBridge
import SwiftUI
import UIKit

private final class DevicePairingContext {
    weak var owner: DevicePairingCoordinator?
    let session: UUID

    init(owner: DevicePairingCoordinator, session: UUID) {
        self.owner = owner
        self.session = session
    }
}

private let devicePairingEventCallback: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = { pointer, context in
    guard let pointer, let context else { return }
    let text = String(cString: pointer)
    DispatchQueue.main.async {
        let box = Unmanaged<DevicePairingContext>.fromOpaque(context).takeUnretainedValue()
        let event = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
        box.owner?.receive(event, session: box.session)
        if ["completed", "failed", "cancelled"].contains(event["type"] as? String ?? "") {
            Unmanaged<DevicePairingContext>.fromOpaque(context).release()
        }
    }
}

/// On-device iOS 27 Remote Pairing responder with PiP floating live guide and background keep-alive.
@MainActor
final class DevicePairingCoordinator: NSObject, ObservableObject, NetServiceDelegate {
    static let shared = DevicePairingCoordinator()

    @Published private(set) var isRunning = false
    @Published private(set) var stepIndex = 0 // 0=idle, 1=broadcasting, 2=connected/pin, 3=completed
    @Published private(set) var status = "尚未开始设备配对"
    @Published private(set) var pin: String?
    @Published private(set) var error: String?

    private var service: NetService?
    private var handle: UInt64 = 0
    private var session: UUID?
    private var cancelReason: String?
    private var background: UIBackgroundTaskIdentifier = .invalid
    private var onSaveRecord: ((Data, Data, String) throws -> Void)?
    private let pip = PairingPiPPresenter.shared
    private let keepAlive = BackgroundKeepAlive()

    func start(onSaveRecord: @escaping (Data, Data, String) throws -> Void) {
        guard !isRunning else { return }
        #if targetEnvironment(simulator)
        error = "设备端配对需要 iOS 27 或更新版本的真实 iPhone。"
        status = error ?? ""
        return
        #else
        guard #available(iOS 27.0, *) else {
            error = "当前系统请导入已有的配对文件；设备端直接配对需要 iOS 27。"
            status = error ?? ""
            return
        }

        self.onSaveRecord = onSaveRecord
        let id = UUID()
        session = id
        isRunning = true
        stepIndex = 1
        pin = nil
        error = nil
        cancelReason = nil
        status = "正在准备本机配对服务…"

        let deadline = Date().addingTimeInterval(300)
        keepAlive.start(useSilentAudio: true)
        pip.startSession(deadline: deadline)

        do {
            let request: [String: Any] = [:]
            let json = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
            background = UIApplication.shared.beginBackgroundTask(withName: "Reloc Device Pairing") { [weak self] in
                Task { @MainActor in
                    self?.cancel(reason: "系统结束了后台配对时间，请返回 Reloc 重试。")
                }
            }
            let context = Unmanaged.passRetained(DevicePairingContext(owner: self, session: id)).toOpaque()
            handle = json.withCString { rl_device_pairing_start($0, devicePairingEventCallback, context) }
            if handle == 0 {
                Unmanaged<DevicePairingContext>.fromOpaque(context).release()
                finish(error: "无法启动设备配对服务。")
            }
        } catch {
            finish(error: error.localizedDescription)
        }
        #endif
    }

    func toggleFloatingGuide() {
        pip.togglePiP()
    }

    func cancel(reason: String? = nil) {
        cancelReason = reason
        service?.stop()
        service = nil
        if handle != 0 {
            rl_device_pairing_cancel(handle)
        } else {
            finish(error: reason)
        }
    }

    fileprivate func receive(_ event: [String: Any], session id: UUID) {
        guard session == id else { return }
        switch event["type"] as? String {
        case "ready":
            guard let identifier = event["identifier"] as? String,
                  let port = event["port"] as? Int,
                  (1...65535).contains(port),
                  let txt = event["txt"] as? [String: String] else {
                cancel(reason: "配对服务返回了无效的广播参数。")
                return
            }
            let netService = NetService(
                domain: "local.",
                type: "_remotepairing-pairable-host._tcp.",
                name: identifier,
                port: Int32(port)
            )
            netService.delegate = self
            netService.setTXTRecord(NetService.data(fromTXTRecord: txt.mapValues { Data($0.utf8) }))
            self.service = netService
            netService.publish()
            stepIndex = 1
            status = "请前往「设置 → 隐私与安全性 → 开发者模式」，在底部选择「与 Reloc 配对」。"
            pip.update(
                step: 1,
                headline: "① 设置 → 隐私与安全性 → 开发者模式",
                subtitle: "滑到底部点击「与 Reloc 配对」，配对码将显示在此处"
            )

        case "connected":
            stepIndex = 2
            status = "系统已连接，正在生成配对码…"
            pip.update(
                step: 2,
                headline: "② 系统已连接",
                subtitle: "正在协商安全通道并生成 6 位配对码…"
            )

        case "pin":
            guard let pin = event["pin"] as? String else { return }
            self.pin = pin
            stepIndex = 2
            status = "请在系统设置中输入以下 6 位配对码。"
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            pip.update(
                step: 2,
                headline: "请输入配对码",
                subtitle: "请在系统设置弹窗中输入 6 位配对码",
                pin: pin
            )

        case "completed":
            guard let encoded = event["record"] as? String,
                  let record = Data(base64Encoded: encoded),
                  let irk = (event["host_irk"] as? String).flatMap({ Data(base64Encoded: $0) }),
                  irk.count == 16,
                  let save = onSaveRecord else {
                finish(error: "系统未返回完整的配对记录。")
                return
            }
            let udid = event["udid"] as? String ?? ""
            do {
                try save(record, irk, udid)
                stepIndex = 3
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                finish(error: nil, succeeded: true)
                status = "配对记录已自动保存"
            } catch {
                finish(error: error.localizedDescription)
            }

        case "failed":
            finish(error: event["error"] as? String ?? "设备配对未完成。")

        case "cancelled":
            finish(error: cancelReason)

        default:
            break
        }
    }

    private func finish(error: String?, succeeded: Bool = false) {
        self.error = error
        status = error ?? (succeeded ? "配对记录已自动保存" : "配对已结束")
        isRunning = false
        stepIndex = succeeded ? 3 : 0
        pin = nil
        handle = 0
        session = nil
        onSaveRecord = nil
        service?.delegate = nil
        service?.stop()
        service = nil
        if background != .invalid {
            UIApplication.shared.endBackgroundTask(background)
            background = .invalid
        }
        keepAlive.stop()
        let finalMessage = error ?? (succeeded ? "配对完成，可返回 Reloc 开始定位" : "配对已结束")
        pip.finish(succeeded: succeeded, message: finalMessage)
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        guard sender === service else { return }
        let code = errorDict[NetService.errorCode]?.intValue ?? 0
        cancel(reason: "无法发布配对服务（错误码 \(code)），请在系统「设置 → 隐私与安全性 → 本地网络 / 區域網路」中允许 Reloc 访问后重试。")
    }
}
