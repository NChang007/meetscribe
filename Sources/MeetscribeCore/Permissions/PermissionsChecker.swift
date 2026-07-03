import AppKit
import AVFoundation
import CoreGraphics
import Foundation

public enum PermissionKind: Sendable {
    case microphone
    case screenRecording
    case accessibility
}

public enum PermissionError: Error, LocalizedError {
    case microphoneDenied
    case screenRecordingDenied
    case accessibilityDenied

    public var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Microphone access is required to record your voice."
        case .screenRecordingDenied:
            return "Screen Recording access is required to capture meeting/system audio."
        case .accessibilityDenied:
            return "Accessibility access is required to read active speaker names from meeting apps."
        }
    }

    public var recoverySuggestion: String? {
        let host = PermissionsChecker.hostAppName()
        switch self {
        case .microphoneDenied:
            return "Enable Microphone for \(host) in System Settings → Privacy & Security → Microphone."
        case .screenRecordingDenied:
            return "Enable Screen Recording for \(host), then quit and reopen \(host) if macOS asks."
        case .accessibilityDenied:
            return "Enable Accessibility for \(host) in System Settings → Privacy & Security → Accessibility."
        }
    }
}

public struct PermissionStatus: Sendable {
    public let accessibility: Bool
    public let microphone: Bool
    public let screenRecording: Bool
    public let gcalcliInstalled: Bool
    public let gcalcliAuthenticated: Bool

    public var recordingReady: Bool { accessibility && microphone && screenRecording }
}

public enum PermissionsChecker {
    private static let screenRecordingWaitSeconds: TimeInterval = 120
    private static let permissionPollNanoseconds: UInt64 = 500_000_000

    public static func hostAppName() -> String {
        if let termProgram = ProcessInfo.processInfo.environment["TERM_PROGRAM"],
           !termProgram.isEmpty {
            switch termProgram {
            case "Apple_Terminal": return "Terminal"
            case "iTerm.app": return "iTerm"
            default: return termProgram
            }
        }
        return "the app running meetscribe (usually Terminal)"
    }

    public static func check() -> PermissionStatus {
        let config = (try? MeetscribeConfig.load()) ?? MeetscribeConfig()
        return PermissionStatus(
            accessibility: AccessibilitySpeakerWatcher.isAccessibilityTrusted(prompt: false),
            microphone: microphoneGranted(),
            screenRecording: screenRecordingGranted(),
            gcalcliInstalled: CalendarLookup.gcalcliInstalled(config: config),
            gcalcliAuthenticated: CalendarLookup.authorizationGranted(config: config)
        )
    }

    /// Prompts for every permission needed to record. Opens System Settings when macOS requires a manual toggle.
    public static func ensureRecordingPermissions() async throws {
        try await ensureAccessibility()
        try await ensureMicrophone()
        try await ensureScreenRecording()
    }

    /// Best-effort prompts during init/install — does not fail if the user skips.
    public static func requestMissingPermissions() async {
        writeStatus("Checking macOS permissions for recording…")
        _ = AccessibilitySpeakerWatcher.isAccessibilityTrusted(prompt: true)
        _ = await requestMicrophoneAccess()
        if !screenRecordingGranted() {
            _ = await ensureScreenRecording(waitSeconds: 5)
        }
    }

    public static func openSystemSettings(for kind: PermissionKind) {
        let anchor: String
        switch kind {
        case .microphone: anchor = "Privacy_Microphone"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        case .accessibility: anchor = "Privacy_Accessibility"
        }
        let urlString = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)"
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    public static func microphoneAuthorizationStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    public static func requestMicrophoneAccess() async -> Bool {
        switch microphoneAuthorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - Private

    private static func ensureAccessibility() async throws {
        let host = hostAppName()
        if AccessibilitySpeakerWatcher.isAccessibilityTrusted(prompt: true) {
            return
        }
        writeStatus("Allow Accessibility for \(host) in the dialog (active speaker names from Zoom/Meet/Teams).")
        let deadline = Date().addingTimeInterval(screenRecordingWaitSeconds)
        while Date() < deadline {
            if AccessibilitySpeakerWatcher.isAccessibilityTrusted(prompt: false) {
                return
            }
            try await Task.sleep(nanoseconds: permissionPollNanoseconds)
        }
        openSystemSettings(for: .accessibility)
        throw PermissionError.accessibilityDenied
    }

    private static func ensureMicrophone() async throws {
        let host = hostAppName()
        if await requestMicrophoneAccess() {
            return
        }
        switch microphoneAuthorizationStatus() {
        case .notDetermined:
            break
        case .denied, .restricted:
            writeStatus("Microphone access denied — opening System Settings. Enable \(host), then run again.")
            openSystemSettings(for: .microphone)
        default:
            writeStatus("Allow microphone access for \(host) when prompted.")
        }
        throw PermissionError.microphoneDenied
    }

    private static func ensureScreenRecording() async throws {
        let host = hostAppName()
        guard await ensureScreenRecording(waitSeconds: screenRecordingWaitSeconds) else {
            writeStatus("Enable Screen Recording for \(host), then quit and reopen \(host) if macOS requires it.")
            openSystemSettings(for: .screenRecording)
            throw PermissionError.screenRecordingDenied
        }
    }

    private static func ensureScreenRecording(waitSeconds: TimeInterval) async -> Bool {
        if screenRecordingGranted() {
            return true
        }
        let host = hostAppName()
        writeStatus("Opening Screen Recording settings — turn on \(host), then return here (waiting up to \(Int(waitSeconds))s)…")
        _ = requestScreenRecordingAccess()

        let deadline = Date().addingTimeInterval(waitSeconds)
        while Date() < deadline {
            if screenRecordingGranted() {
                writeStatus("Screen Recording enabled.")
                return true
            }
            try? await Task.sleep(nanoseconds: permissionPollNanoseconds)
        }
        return screenRecordingGranted()
    }

    private static func microphoneGranted() -> Bool {
        microphoneAuthorizationStatus() == .authorized
    }

    private static func screenRecordingGranted() -> Bool {
        if #available(macOS 11.0, *) {
            return CGPreflightScreenCaptureAccess()
        }
        return true
    }

    private static func requestScreenRecordingAccess() -> Bool {
        if #available(macOS 11.0, *) {
            return CGRequestScreenCaptureAccess()
        }
        return true
    }

    private static func writeStatus(_ message: String) {
        FileHandle.standardError.write(Data("[meetscribe] \(message)\n".utf8))
    }
}
