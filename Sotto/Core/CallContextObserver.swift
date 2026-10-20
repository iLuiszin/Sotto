import AppKit
import ApplicationServices
import os
@preconcurrency import UserNotifications

private let logger = Logger(subsystem: AppConstants.loggerSubsystem, category: "CallContext")

/// Watches the call app (Google Meet in Chrome, or a Slack huddle) while a recording runs.
///
/// Every tick reads only Meet's captions, to catch who is speaking; every tenth tick reads
/// the whole call (participants, title, microphones). Needs Accessibility permission,
/// which Sotto already holds for text insertion.
@MainActor
final class CallContextObserver {
    private static let tickInterval: TimeInterval = 1
    private static let fullReadEvery = 10
    /// Unchanged caption reads, in ticks, before the captions region is looked up again.
    private static let staleCaptionReads = 2
    static let meetApp = "Google Meet"
    static let slackApp = "Slack"

    private var timer: Timer?
    private var startDate: Date?
    private var tickCount = 0
    private var preparedMeet = false
    private var captionsRegion: AXUIElement?
    private var lastCaption: (speaker: String, text: String)?
    private var unchangedCaptionReads = 0
    private(set) var context: CallContext?

    func start() {
        stop()
        // Reading call apps needs Accessibility. Asking through the system prompt also
        // registers Sotto in that list, which adding it by hand does not always do.
        let options = ["AXTrustedCheckOptionPrompt" as CFString: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            logger.warning("Accessibility not granted; call context unavailable")
        }
        context = nil
        startDate = Date()
        tickCount = 0
        preparedMeet = false
        captionsRegion = nil
        lastCaption = nil
        unchangedCaptionReads = 0
        fullRead()
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    /// Takes one last full reading, then returns everything seen during the recording.
    @discardableResult
    func stop() -> CallContext? {
        guard timer != nil else { return context }
        fullRead()
        timer?.invalidate()
        timer = nil
        return context
    }

    private var elapsed: TimeInterval? {
        startDate.map { Date().timeIntervalSince($0) }
    }

    private func tick() {
        tickCount += 1
        if tickCount % Self.fullReadEvery == 0 {
            fullRead()
        } else if context?.app == Self.meetApp {
            readCaption()
        }
    }

    private func fullRead() {
        guard AXIsProcessTrusted(), let elapsed else { return }

        if context == nil || context?.app == Self.meetApp, let meet = GoogleMeetReader.read() {
            if !preparedMeet {
                preparedMeet = true
                if !GoogleMeetReader.prepare(), !meet.captionsOn {
                    Self.remindToTurnOnCaptions()
                }
            }
            var updated = context ?? CallContext(app: Self.meetApp, title: meet.title)
            updated.title = meet.title
            updated.selfName = meet.selfName ?? updated.selfName
            updated.observe(participants: meet.participants, at: elapsed)
            context = updated
            if let caption = meet.currentCaption { record(caption, at: elapsed) }
            return
        }

        if context == nil || context?.app == Self.slackApp, let slack = SlackHuddleReader.read() {
            var updated = context ?? CallContext(app: Self.slackApp, title: "\(slack.workspace) · \(slack.channel)")
            updated.observe(participants: slack.participants, at: elapsed)
            context = updated
        }
    }

    private func readCaption() {
        guard let elapsed else { return }
        if captionsRegion == nil { captionsRegion = GoogleMeetReader.findCaptionsRegion() }
        guard let region = captionsRegion else { return }
        guard let caption = GoogleMeetReader.currentCaption(in: region) else {
            // The region may be gone (captions off, layout changed): find it again next tick.
            if AccessibilityTree.role(of: region) == nil { captionsRegion = nil }
            return
        }
        // Meet can replace the captions region while the old element stays readable but
        // frozen, so a caption that stops changing is checked against a fresh lookup.
        if caption.speaker == lastCaption?.speaker, caption.text == lastCaption?.text {
            unchangedCaptionReads += 1
            if unchangedCaptionReads >= Self.staleCaptionReads {
                unchangedCaptionReads = 0
                captionsRegion = nil
            }
        } else {
            unchangedCaptionReads = 0
        }
        record(caption, at: elapsed)
    }

    /// A caption stays on screen after its speaker stops; it counts as speech only while
    /// its text keeps changing.
    private func record(_ caption: (speaker: String, text: String), at time: TimeInterval) {
        defer { lastCaption = caption }
        guard caption.speaker != lastCaption?.speaker || caption.text != lastCaption?.text else { return }
        // Meet captions the user as "Você"/"You": count it as them, not as another person.
        let speaker = GoogleMeetLabels.selfCaptionNames.contains(caption.speaker)
            ? context?.selfName
            : caption.speaker
        guard let speaker else { return }
        logger.debug("Caption speaker \(speaker, privacy: .private) at \(time)")
        context?.observe(speaker: speaker, at: time)
    }

    private static func remindToTurnOnCaptions() {
        logger.warning("Could not turn on Meet captions; reminding the user")
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Turn on Meet captions")
            content.body = String(localized: "Sotto uses Meet's captions to tell who is speaking. Turn them on with the CC button.")
            center.add(UNNotificationRequest(identifier: "meet-captions", content: content, trigger: nil))
        }
    }
}
