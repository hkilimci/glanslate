import AppKit

/// Glanslate's application delegate. The app target only creates this and runs
/// the application; everything else is composed by ``AppController``.
@MainActor
public final class GlanslateAppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?

    override public init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = AppController()
        self.controller = controller
        controller.start()
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controller?.prepareForTermination()
        return .terminateNow
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { controller?.handleReopen() }
        return true
    }

    public func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
