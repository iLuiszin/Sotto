import AppKit
import ApplicationServices
import os

private let logger = Logger(subsystem: "com.sotto.app", category: "SlackHuddle")

/// What Sotto saw of a Slack huddle while recording: where it was and who took part.
nonisolated struct HuddleContext: Equatable {
    struct Participant: Equatable {
        let name: String
        /// Recording-relative times at which this participant's microphone was on.
        var micOnAt: [TimeInterval]
    }

    var workspace: String
    var channel: String
    /// In order of first appearance.
    var participants: [Participant]
}

/// Parses the accessibility labels of Slack's huddle window. Slack localizes them; the
/// app is used in Portuguese and English, so both are recognized.
nonisolated enum SlackHuddleLabels {
    /// "meus-bots - IBRACEM - Slack" → ("meus-bots", "IBRACEM").
    static func parseWindowTitle(_ title: String) -> (channel: String, workspace: String)? {
        let parts = title.components(separatedBy: " - ")
        guard parts.count == 3, parts[2] == "Slack", !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }

    private static let profilePrefixes = ["Ver perfil de ", "View profile of ", "View profile for "]

    /// A participant tile row: "Ver perfil de Luís Felipe Matos Corrêa" → "Luís Felipe Matos Corrêa".
    static func participantName(fromRowTitle title: String) -> String? {
        for prefix in profilePrefixes where title.hasPrefix(prefix) {
            let name = title.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }
        return nil
    }

    /// The tile button: "vídeo está desativado, áudio está ativado". `nil` when the label
    /// is not a media-state label, so unrelated buttons are not mistaken for tiles.
    static func isMicOn(fromTileLabel label: String) -> Bool? {
        let lower = label.lowercased()
        for (on, off) in [("áudio está ativado", "áudio está desativado"), ("audio is on", "audio is off")] {
            if lower.contains(off) { return false }
            if lower.contains(on) { return true }
        }
        return nil
    }
}

/// Polls Slack's huddle window through Accessibility while a recording runs.
///
/// Slack (Electron) only builds its accessibility tree once an assistive app asks for it
/// through `AXManualAccessibility`. Sotto already holds Accessibility permission for text
/// insertion. Names come only from participant tile rows, never from other text in the
/// window, where message previews such as "Daniel: ..." also appear.
@MainActor
final class SlackHuddleObserver {
    private static let slackBundleID = "com.tinyspeck.slackmacgap"
    private static let pollInterval: TimeInterval = 10
    private static let maxDepth = 40
    private static let maxElements = 3_000

    private var timer: Timer?
    private var startDate: Date?
    private(set) var context: HuddleContext?

    func start() {
        stop()
        context = nil
        startDate = Date()
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
    }

    /// Takes one last sample, then returns everything seen during the recording.
    @discardableResult
    func stop() -> HuddleContext? {
        guard timer != nil else { return context }
        poll()
        timer?.invalidate()
        timer = nil
        return context
    }

    private func poll() {
        guard AXIsProcessTrusted(),
              let slack = NSRunningApplication.runningApplications(withBundleIdentifier: Self.slackBundleID).first,
              let startDate
        else { return }

        let app = AXUIElementCreateApplication(slack.processIdentifier)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        let elapsed = Date().timeIntervalSince(startDate)
        for window in Self.children(of: app, attribute: kAXWindowsAttribute) {
            guard let title: String = Self.attribute(window, kAXTitleAttribute),
                  let place = SlackHuddleLabels.parseWindowTitle(title)
            else { continue }
            let tiles = Self.participantTiles(in: window)
            guard !tiles.isEmpty else { continue }
            record(place: place, tiles: tiles, at: elapsed)
            return
        }
    }

    private func record(place: (channel: String, workspace: String), tiles: [(name: String, micOn: Bool)], at time: TimeInterval) {
        var updated = context ?? HuddleContext(workspace: place.workspace, channel: place.channel, participants: [])
        for tile in tiles {
            if let index = updated.participants.firstIndex(where: { $0.name == tile.name }) {
                if tile.micOn { updated.participants[index].micOnAt.append(time) }
            } else {
                updated.participants.append(.init(name: tile.name, micOnAt: tile.micOn ? [time] : []))
            }
        }
        if updated != context {
            logger.info("Huddle in \(place.workspace, privacy: .public): \(updated.participants.count) participants")
        }
        context = updated
    }

    // MARK: - Accessibility tree

    /// Rows titled "Ver perfil de NAME" that contain a media-state button. A name shows up
    /// in more than one cell of the gallery, so each name is reported once.
    private static func participantTiles(in window: AXUIElement) -> [(name: String, micOn: Bool)] {
        var tiles: [(name: String, micOn: Bool)] = []
        var visited = 0
        walk(window, depth: 0, visited: &visited) { element in
            guard role(of: element) == kAXRowRole,
                  let title = label(of: element),
                  let name = SlackHuddleLabels.participantName(fromRowTitle: title),
                  !tiles.contains(where: { $0.name == name })
            else { return true }
            var micOn: Bool?
            var innerVisited = 0
            walk(element, depth: 0, visited: &innerVisited) { child in
                guard micOn == nil, role(of: child) == kAXButtonRole else { return micOn == nil }
                micOn = label(of: child).flatMap(SlackHuddleLabels.isMicOn(fromTileLabel:))
                return micOn == nil
            }
            if let micOn { tiles.append((name, micOn)) }
            return false
        }
        return tiles
    }

    /// Depth-first; `visit` returns whether to descend into the element.
    private static func walk(_ element: AXUIElement, depth: Int, visited: inout Int, visit: (AXUIElement) -> Bool) {
        guard depth < maxDepth, visited < maxElements else { return }
        visited += 1
        guard visit(element) else { return }
        for child in children(of: element, attribute: kAXChildrenAttribute) {
            walk(child, depth: depth + 1, visited: &visited, visit: visit)
        }
    }

    private static func role(of element: AXUIElement) -> String? {
        attribute(element, kAXRoleAttribute)
    }

    /// Electron puts a control's text in its title or its description, depending on the element.
    private static func label(of element: AXUIElement) -> String? {
        [kAXTitleAttribute, kAXDescriptionAttribute]
            .compactMap { (attribute(element, $0) as String?) }
            .first { !$0.isEmpty }
    }

    private static func children(of element: AXUIElement, attribute name: String) -> [AXUIElement] {
        attribute(element, name) ?? []
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}
