import Cocoa
import CoreGraphics
import ScreenCaptureKit

enum CaptureError: Error, LocalizedError {
    case noScreenRecordingPermission
    case noShareableContent
    case noDisplay
    case imageCreationFailed
    case imageWriteFailed
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noScreenRecordingPermission: return "没有屏幕录制权限。请在 系统设置 → 隐私与安全性 → 屏幕录制 中授权 Capit。"
        case .noShareableContent: return "无法获取屏幕内容。"
        case .noDisplay: return "找不到可截取的显示器。"
        case .imageCreationFailed: return "截图图像生成失败。"
        case .imageWriteFailed: return "无法编码或写入 PNG 图像。"
        case .cancelled: return "已取消截图。"
        }
    }
}

/// Swift-friendly ScreenCaptureKit surface. Uses ScreenCaptureKit for stills on
/// macOS 14+, and falls back to the classic CGWindow / CGDisplay capture on older systems.
enum CaptureKit {

    static var isAuthorized: Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func shareableContent() async throws -> SCShareableContent {
        guard isAuthorized else {
            throw CaptureError.noScreenRecordingPermission
        }
        do {
            return try await SCShareableContent.current
        } catch {
            throw CaptureError.noShareableContent
        }
    }

    static func capture(display: SCDisplay) async throws -> CGImage {
        if #available(macOS 14.0, *) {
            let scale = backingScale(for: display.displayID)
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = Int(CGFloat(display.width) * scale)
            config.height = Int(CGFloat(display.height) * scale)
            config.showsCursor = false
            if let img = try? await captureStill(filter: filter, config: config) {
                return img
            }
        }
        guard let img = CGDisplayCreateImage(display.displayID) else {
            throw CaptureError.imageCreationFailed
        }
        return img
    }

    @available(macOS 14.0, *)
    private static func captureStill(filter: SCContentFilter,
                                     config: SCStreamConfiguration) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(contentFilter: filter,
                                             configuration: config) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: CaptureError.imageCreationFailed)
                }
            }
        }
    }

    @available(macOS 14.0, *)
    static func captureWindow(scWindow: SCWindow, scale: CGFloat) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = SCStreamConfiguration()
        config.width = max(1, Int(scWindow.frame.width * scale))
        config.height = max(1, Int(scWindow.frame.height * scale))
        config.showsCursor = false
        return try await captureStill(filter: filter, config: config)
    }

    static func captureWindowNative(id: CGWindowID) async throws -> CGImage {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("capit_win_\(id)_\(UUID().uuidString).png")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        proc.arguments = ["-l", "\(id)", "-x", "-o", tmp.path]
        try proc.run()
        proc.waitUntilExit()
        guard FileManager.default.fileExists(atPath: tmp.path),
              let nsImage = NSImage(contentsOf: tmp),
              let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            try? FileManager.default.removeItem(at: tmp)
            throw CaptureError.imageCreationFailed
        }
        try? FileManager.default.removeItem(at: tmp)
        return cg
    }

    private static func backingScale(for displayID: CGDirectDisplayID) -> CGFloat {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
        return screen?.backingScaleFactor ?? 2.0
    }
}
