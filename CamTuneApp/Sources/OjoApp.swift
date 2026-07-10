import AppKit
import SwiftUI

@MainActor
@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static var retainedDelegate: AppDelegate?

    private let appState = AppState()
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        retainedDelegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppState.clearPreviewState()
        installStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.clearPreviewState()
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = item.button else {
            log("status item button missing")
            return
        }

        let icon = NSImage(systemSymbolName: "video.badge.sparkles", accessibilityDescription: "Ojo")
            ?? NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "Ojo")
            ?? Self.makeStatusIcon()
        icon.isTemplate = true
        button.image = icon
        button.imagePosition = .imageOnly
        button.title = ""
        button.target = self
        button.action = #selector(togglePopover(_:))
        statusItem = item

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 400, height: 680)
        popover.contentViewController = NSHostingController(
            rootView: MenuContentView(state: appState)
                .frame(width: 400, height: 680)
        )
        self.popover = popover
        log("status item installed")
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        guard let popover else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func log(_ message: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/camtune")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let line = "\(Date()) \(message)\n"
        let url = dir.appendingPathComponent("ojo-app.log")
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    private static func makeStatusIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()

        NSColor.labelColor.setStroke()
        NSColor.labelColor.setFill()

        let stroke = NSBezierPath()
        stroke.lineWidth = 1.7
        stroke.lineCapStyle = .round
        stroke.lineJoinStyle = .round

        let left: CGFloat = 2.5
        let right: CGFloat = 15.5
        let top: CGFloat = 15.5
        let bottom: CGFloat = 2.5
        let arm: CGFloat = 4.4

        stroke.move(to: NSPoint(x: left, y: top - arm))
        stroke.line(to: NSPoint(x: left, y: top))
        stroke.line(to: NSPoint(x: left + arm, y: top))

        stroke.move(to: NSPoint(x: right - arm, y: top))
        stroke.line(to: NSPoint(x: right, y: top))
        stroke.line(to: NSPoint(x: right, y: top - arm))

        stroke.move(to: NSPoint(x: left, y: bottom + arm))
        stroke.line(to: NSPoint(x: left, y: bottom))
        stroke.line(to: NSPoint(x: left + arm, y: bottom))

        stroke.move(to: NSPoint(x: right - arm, y: bottom))
        stroke.line(to: NSPoint(x: right, y: bottom))
        stroke.line(to: NSPoint(x: right, y: bottom + arm))

        stroke.stroke()

        let lens = NSBezierPath(ovalIn: NSRect(x: 7.1, y: 7.1, width: 3.8, height: 3.8))
        lens.fill()

        let sparkle = NSBezierPath()
        sparkle.lineWidth = 1.25
        sparkle.lineCapStyle = .round
        sparkle.move(to: NSPoint(x: 13.4, y: 12.2))
        sparkle.line(to: NSPoint(x: 13.4, y: 16.4))
        sparkle.move(to: NSPoint(x: 11.3, y: 14.3))
        sparkle.line(to: NSPoint(x: 15.5, y: 14.3))
        sparkle.move(to: NSPoint(x: 12.1, y: 12.9))
        sparkle.line(to: NSPoint(x: 14.7, y: 15.7))
        sparkle.move(to: NSPoint(x: 14.7, y: 12.9))
        sparkle.line(to: NSPoint(x: 12.1, y: 15.7))
        sparkle.stroke()

        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}
