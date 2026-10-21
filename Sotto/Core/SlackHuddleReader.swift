import AppKit
import ApplicationServices

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

    /// A participant tile row: "Ver perfil de Luís Felipe Matos Corrêa" → ["Luís Felipe Matos Corrêa"].
    /// In a two-person huddle both tiles share one row, titled "Ver perfil de A Ver perfil de B".
    static func participantNames(fromRowTitle title: String) -> [String] {
        guard let prefix = profilePrefixes.first(where: title.hasPrefix) else { return [] }
        return title.components(separatedBy: prefix)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
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

/// Reads Slack's huddle window. Names come only from participant tile rows, never from
/// other text in the window, where message previews such as "Daniel: ..." also appear.
@MainActor
enum SlackHuddleReader {
    struct Snapshot {
        let channel: String
        let workspace: String
        let participants: [(name: String, micOn: Bool?)]
    }

    static func read() -> Snapshot? {
        guard let app = AccessibilityTree.application(bundleID: "com.tinyspeck.slackmacgap") else { return nil }
        for window in AccessibilityTree.windows(of: app) {
            guard let title = AccessibilityTree.title(of: window),
                  let place = SlackHuddleLabels.parseWindowTitle(title)
            else { continue }
            let tiles = participantTiles(in: window)
            if !tiles.isEmpty {
                return Snapshot(channel: place.channel, workspace: place.workspace, participants: tiles)
            }
        }
        return nil
    }

    /// Rows titled "Ver perfil de NAME" that contain a media-state button. A name shows up
    /// in more than one cell of the gallery, so each name is reported once.
    private static func participantTiles(in window: AXUIElement) -> [(name: String, micOn: Bool?)] {
        var tiles: [(name: String, micOn: Bool?)] = []
        AccessibilityTree.walk(window, maxElements: 3_000) { element, _ in
            guard AccessibilityTree.role(of: element) == kAXRowRole,
                  let title = AccessibilityTree.label(of: element)
            else { return true }
            let names = SlackHuddleLabels.participantNames(fromRowTitle: title)
            guard !names.isEmpty else { return true }
            // Media-state buttons, in tile order, so a shared row matches each name to its own.
            var micStates: [Bool] = []
            AccessibilityTree.walk(element, maxElements: 500) { child, _ in
                if AccessibilityTree.role(of: child) == kAXButtonRole,
                   let state = AccessibilityTree.label(of: child).flatMap(SlackHuddleLabels.isMicOn(fromTileLabel:)) {
                    micStates.append(state)
                }
                return true
            }
            guard !micStates.isEmpty else { return false }
            for (index, name) in names.enumerated() where !tiles.contains(where: { $0.name == name }) {
                tiles.append((name, micStates.count == names.count ? micStates[index] : nil))
            }
            return false
        }
        return tiles
    }
}
