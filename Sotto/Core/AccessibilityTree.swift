import AppKit
import ApplicationServices

/// Read-only helpers over another app's accessibility tree, shared by the call observers.
@MainActor
enum AccessibilityTree {
    /// The application element, with its accessibility tree switched on. Chromium-based apps
    /// (Chrome, Slack's Electron shell) only build it once an assistive app asks.
    static func application(bundleID: String) -> AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        return element
    }

    static func windows(of app: AXUIElement) -> [AXUIElement] {
        attribute(app, kAXWindowsAttribute) ?? []
    }

    static func children(of element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) ?? []
    }

    static func role(of element: AXUIElement) -> String? {
        attribute(element, kAXRoleAttribute)
    }

    static func title(of element: AXUIElement) -> String? {
        attribute(element, kAXTitleAttribute)
    }

    static func value(of element: AXUIElement) -> String? {
        attribute(element, kAXValueAttribute)
    }

    /// The address of a web area.
    static func url(of element: AXUIElement) -> URL? {
        attribute(element, kAXURLAttribute)
    }

    /// Chromium puts a control's text in its title or its description, depending on the element.
    static func label(of element: AXUIElement) -> String? {
        [kAXTitleAttribute, kAXDescriptionAttribute]
            .compactMap { (attribute(element, $0) as String?) }
            .first { !$0.isEmpty }
    }

    @discardableResult
    static func press(_ element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    /// Depth-first, bounded so a huge web page cannot stall the main thread.
    /// `visit` gets the element and its depth, and returns whether to descend into it.
    static func walk(
        _ element: AXUIElement,
        maxDepth: Int = 60,
        maxElements: Int = 5_000,
        visit: (AXUIElement, Int) -> Bool
    ) {
        var visited = 0
        func step(_ element: AXUIElement, _ depth: Int) {
            guard depth < maxDepth, visited < maxElements else { return }
            visited += 1
            guard visit(element, depth) else { return }
            for child in children(of: element) {
                step(child, depth + 1)
            }
        }
        step(element, 0)
    }

    /// The first element, depth-first, that matches.
    static func first(in root: AXUIElement, where matches: (AXUIElement) -> Bool) -> AXUIElement? {
        var found: AXUIElement?
        walk(root) { element, _ in
            guard found == nil else { return false }
            if matches(element) { found = element; return false }
            return true
        }
        return found
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}
