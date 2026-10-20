import AppKit
import ApplicationServices
import os

private let logger = Logger(subsystem: AppConstants.loggerSubsystem, category: "GoogleMeet")

/// Parses the accessibility labels of a Google Meet tab. Meet localizes them; Portuguese
/// (Brazil and Portugal, which Meet mixes) and English are recognized.
nonisolated enum GoogleMeetLabels {
    static let captionsRegion: Set = ["Legendas", "Captions"]
    static let participantsList: Set = ["Participantes", "Participants"]
    static let peopleButton: Set = ["Pessoas", "People"]
    static let turnOnCaptions: Set = ["Ativar legendas", "Turn on captions"]
    static let turnOffCaptions: Set = ["Desativar legendas", "Turn off captions"]
    static let selfMarkers: Set = ["(Eu)", "(Você)", "(You)"]
    /// What captions show instead of the user's own name.
    static let selfCaptionNames: Set = ["Você", "Eu", "You"]

    /// The page title of a call → its name: "Meet - Daily - Time AGI" → "Daily - Time AGI".
    /// A meeting without a name is titled with its code instead: "Meet: dqw-mgvh-abi".
    static func meetingTitle(fromPageTitle title: String) -> String? {
        guard let prefix = ["Meet - ", "Meet: "].first(where: title.hasPrefix) else { return nil }
        let name = title.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// "meet.google.com/jkv-pzvy-gjr?authuser=0" → "jkv-pzvy-gjr".
    static func meetingCode(fromAddress address: String) -> String? {
        guard address.contains("meet.google.com/"),
              let range = address.range(of: #"[a-z]{3}-[a-z]{4}-[a-z]{3}"#, options: .regularExpression)
        else { return nil }
        return String(address[range])
    }

    /// The control next to a participant in the people panel. "Desativar o som do microfone
    /// de Sarah" can only be offered while Sarah's microphone is on.
    static func isMicOn(fromParticipantControl label: String) -> Bool? {
        let lower = label.lowercased()
        let on = ["desativar o som do microfone de", "mute "]
        let off = ["não pode reativar o som", "you can't unmute", "o microfone está desativado", "microphone is off"]
        if off.contains(where: lower.contains) { return false }
        if on.contains(where: lower.hasPrefix) { return true }
        return nil
    }

    /// The captions region as (depth, text) pairs, in reading order. Each speaker's name is
    /// nested one level deeper than the caption text that follows it.
    static func captions(from texts: [(depth: Int, text: String)]) -> [(speaker: String, text: String)] {
        var result: [(speaker: String, text: String)] = []
        var index = 0
        while index < texts.count {
            let entry = texts[index]
            if index + 1 < texts.count, texts[index + 1].depth < entry.depth {
                result.append((entry.text, texts[index + 1].text))
                index += 2
            } else if let last = result.last {
                result[result.count - 1] = (last.speaker, last.text + " " + entry.text)
                index += 1
            } else {
                index += 1
            }
        }
        return result
    }
}

/// Reads a Google Meet call open in Chrome.
@MainActor
enum GoogleMeetReader {
    struct Snapshot {
        let title: String
        let selfName: String?
        let participants: [(name: String, micOn: Bool?)]
        /// The last caption block, i.e. who is speaking now and what they are saying.
        let currentCaption: (speaker: String, text: String)?
        let captionsOn: Bool
    }

    static let chromeBundleID = "com.google.Chrome"

    static func read() -> Snapshot? {
        guard let app = AccessibilityTree.application(bundleID: chromeBundleID),
              let page = meetPage(in: app)
        else { return nil }

        let pageTitle = AccessibilityTree.title(of: page) ?? ""
        let name = GoogleMeetLabels.meetingTitle(fromPageTitle: pageTitle) ?? "Meet"
        let code = AccessibilityTree.url(of: page).flatMap { GoogleMeetLabels.meetingCode(fromAddress: $0.absoluteString) }
        let people = participants(in: page)
        let region = captionsRegion(in: page)
        let captions = region.map(readCaptions(in:)) ?? []

        return Snapshot(
            title: code.map { $0 == name ? name : "\(name) (\($0))" } ?? name,
            selfName: people.selfName,
            participants: people.list,
            currentCaption: captions.last,
            captionsOn: region != nil || button(in: page, labelledOneOf: GoogleMeetLabels.turnOffCaptions) != nil
        )
    }

    /// Turns captions on and opens the people panel, so speakers and the full participant
    /// list can be read. Returns false when the captions button was not found.
    @discardableResult
    static func prepare() -> Bool {
        guard let app = AccessibilityTree.application(bundleID: chromeBundleID),
              let page = meetPage(in: app)
        else { return false }

        if participantsList(in: page) == nil,
           let people = button(in: page, labelledOneOf: GoogleMeetLabels.peopleButton) {
            AccessibilityTree.press(people)
        }
        if button(in: page, labelledOneOf: GoogleMeetLabels.turnOffCaptions) != nil { return true }
        guard let captions = button(in: page, labelledOneOf: GoogleMeetLabels.turnOnCaptions) else {
            logger.warning("Meet captions button not found")
            return false
        }
        let pressed = AccessibilityTree.press(captions)
        logger.info("Turned on Meet captions: \(pressed)")
        return pressed
    }

    /// The captions region, for cheap per-second reads without walking the whole page.
    static func findCaptionsRegion() -> AXUIElement? {
        guard let app = AccessibilityTree.application(bundleID: chromeBundleID),
              let page = meetPage(in: app)
        else { return nil }
        return captionsRegion(in: page)
    }

    /// Who is speaking now and what they are saying; `nil` when nobody is, or when the
    /// region is gone (captions turned off, call ended).
    static func currentCaption(in region: AXUIElement) -> (speaker: String, text: String)? {
        readCaptions(in: region).last
    }

    // MARK: - Tree

    /// The web area of a Meet tab. Only the active tab of a window is exposed, so a Meet
    /// call in a background tab is not seen. Matches on the page's own title: Chrome
    /// prefixes the window title with notices such as "Uso elevado da memória em Meet - …".
    private static func meetPage(in app: AXUIElement) -> AXUIElement? {
        for window in AccessibilityTree.windows(of: app) {
            guard let windowTitle = AccessibilityTree.title(of: window),
                  windowTitle.contains("Meet - ") || windowTitle.contains("Meet: ")
            else { continue }
            let page = AccessibilityTree.first(in: window) { element in
                AccessibilityTree.role(of: element) == "AXWebArea"
                    && AccessibilityTree.title(of: element).flatMap(GoogleMeetLabels.meetingTitle(fromPageTitle:)) != nil
            }
            if let page { return page }
        }
        return nil
    }

    private static func participantsList(in page: AXUIElement) -> AXUIElement? {
        AccessibilityTree.first(in: page) { element in
            AccessibilityTree.role(of: element) == kAXListRole
                && AccessibilityTree.label(of: element).map(GoogleMeetLabels.participantsList.contains) == true
        }
    }

    private static func captionsRegion(in page: AXUIElement) -> AXUIElement? {
        AccessibilityTree.first(in: page) { element in
            AccessibilityTree.role(of: element) == kAXGroupRole
                && AccessibilityTree.label(of: element).map(GoogleMeetLabels.captionsRegion.contains) == true
        }
    }

    private static func button(in page: AXUIElement, labelledOneOf labels: Set<String>) -> AXUIElement? {
        AccessibilityTree.first(in: page) { element in
            let role = AccessibilityTree.role(of: element)
            return (role == kAXButtonRole || role == kAXPopUpButtonRole)
                && AccessibilityTree.label(of: element).map(labels.contains) == true
        }
    }

    /// One group per person in the people panel, labelled with their name.
    private static func participants(in page: AXUIElement) -> (list: [(name: String, micOn: Bool?)], selfName: String?) {
        guard let list = participantsList(in: page) else { return ([], nil) }
        var people: [(name: String, micOn: Bool?)] = []
        var selfName: String?
        for row in AccessibilityTree.children(of: list) {
            guard let name = AccessibilityTree.label(of: row) else { continue }
            var micOn: Bool?
            var isSelf = false
            AccessibilityTree.walk(row, maxElements: 200) { element, _ in
                if let text = AccessibilityTree.value(of: element), GoogleMeetLabels.selfMarkers.contains(text) {
                    isSelf = true
                }
                if micOn == nil, let label = AccessibilityTree.label(of: element) {
                    micOn = GoogleMeetLabels.isMicOn(fromParticipantControl: label)
                }
                return true
            }
            if isSelf { selfName = name }
            people.append((name, micOn))
        }
        return (people, selfName)
    }

    private static func readCaptions(in region: AXUIElement) -> [(speaker: String, text: String)] {
        var texts: [(depth: Int, text: String)] = []
        AccessibilityTree.walk(region, maxElements: 500) { element, depth in
            if AccessibilityTree.role(of: element) == kAXStaticTextRole,
               let text = AccessibilityTree.value(of: element), !text.isEmpty {
                texts.append((depth, text))
            }
            return true
        }
        return GoogleMeetLabels.captions(from: texts)
    }
}
