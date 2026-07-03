import AVFoundation
import CoreGraphics
import Foundation

public struct PermissionStatus: Sendable {
    public let accessibility: Bool
    public let microphone: Bool
    public let screenRecording: Bool
    public let gcalcliInstalled: Bool
    public let gcalcliAuthenticated: Bool

    public var allGranted: Bool { accessibility && microphone && screenRecording }
}

public enum PermissionsChecker {
    public static func check(promptAccessibility: Bool = false) -> PermissionStatus {
        let config = (try? MeetscribeConfig.load()) ?? MeetscribeConfig()
        return PermissionStatus(
            accessibility: AccessibilitySpeakerWatcher.isAccessibilityTrusted(prompt: promptAccessibility),
            microphone: microphoneGranted(),
            screenRecording: screenRecordingGranted(),
            gcalcliInstalled: CalendarLookup.gcalcliInstalled(config: config),
            gcalcliAuthenticated: CalendarLookup.authorizationGranted(config: config)
        )
    }

    private static func microphoneGranted() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        default:
            return false
        }
    }

    private static func screenRecordingGranted() -> Bool {
        if #available(macOS 11.0, *) {
            return CGPreflightScreenCaptureAccess()
        }
        return true
    }

    public static func requestScreenRecordingAccess() -> Bool {
        if #available(macOS 11.0, *) {
            return CGRequestScreenCaptureAccess()
        }
        return true
    }
}
