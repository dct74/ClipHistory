import AppKit

/// Entry point.
///
/// Lives here rather than in `main.swift` so the module has no top-level code and
/// the unit tests can `@testable import ClipHistory`.
@main
enum ClipHistoryApp {

    /// Posted by a second launch so the running instance can show itself.
    static let openSettingsNotification = Notification.Name("com.weiyuankong.cliphistory.openSettings")

    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)

        // One instance only: two copies would each own a menu bar item, and the
        // icon on screen would belong to whichever started first.
        if let bundleID = Bundle.main.bundleIdentifier,
           let running = NSRunningApplication
               .runningApplications(withBundleIdentifier: bundleID)
               .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            DistributedNotificationCenter.default().post(name: openSettingsNotification, object: nil)
            running.activate()
            exit(0)
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
