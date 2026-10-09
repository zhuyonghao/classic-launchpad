import AppKit
import Carbon

enum LauncherStartup {
    static func shouldShowLauncher(launchEvent: NSAppleEventDescriptor?, isDefaultLaunch: Bool? = nil) -> Bool {
        // AppKit marks launches that restore saved state as non-default launches.
        if isDefaultLaunch == false { return false }
        guard let launchEvent, launchEvent.eventClass == kCoreEventClass,
              launchEvent.eventID == kAEOpenApplication || launchEvent.eventID == kAEReopenApplication else {
            return true
        }

        let reason = launchEvent.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
        if reason == keyAELaunchedAsLogInItem || reason == keyAELaunchedAsServiceItem { return false }
        return launchEvent.paramDescriptor(forKeyword: keyAERestoreAppState)?.enumCodeValue != kAEYes
    }
}
