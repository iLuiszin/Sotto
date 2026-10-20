import Foundation

/// What Sotto saw of a call while recording: which app, where, who took part and, when
/// the app shows it, who was speaking when.
nonisolated struct CallContext: Equatable {
    struct Participant: Equatable {
        let name: String
        /// Recording-relative times at which this participant's microphone was on.
        var micOnAt: [TimeInterval]
    }

    /// A moment at which the app named someone as speaking (Google Meet captions).
    struct SpeakerSighting: Equatable {
        let name: String
        let at: TimeInterval
    }

    var app: String
    /// "IBRACEM · meus-bots" for Slack, "Daily - Time AGI (jkv-pzvy-gjr)" for Meet.
    var title: String
    /// The user's own name when the app marks it ("(Eu)" in Meet's people panel).
    var selfName: String?
    /// In order of first appearance.
    var participants: [Participant] = []
    var speakerSightings: [SpeakerSighting] = []

    /// Adds newly seen participants and records whose microphone is on at `time`.
    /// `micOn == nil` means the app did not say.
    mutating func observe(participants seen: [(name: String, micOn: Bool?)], at time: TimeInterval) {
        for person in seen {
            if let index = participants.firstIndex(where: { $0.name == person.name }) {
                if person.micOn == true { participants[index].micOnAt.append(time) }
            } else {
                participants.append(.init(name: person.name, micOnAt: person.micOn == true ? [time] : []))
            }
        }
    }

    mutating func observe(speaker name: String, at time: TimeInterval) {
        speakerSightings.append(.init(name: name, at: time))
        if !participants.contains(where: { $0.name == name }) {
            participants.append(.init(name: name, micOnAt: []))
        }
    }
}

/// Decides who said each "others" segment of a call recording.
nonisolated enum SpeakerAttribution {
    /// Captions lag speech and stay on screen for a moment after it.
    static let sightingLead: TimeInterval = 1
    static let sightingLag: TimeInterval = 3

    /// The name for a system-audio segment, or `nil` to keep the generic "Others" label.
    /// - `microphoneSpeech`: when the user was talking, used to recognize the user's own
    ///   name in the captions when the app did not mark it.
    static func speaker(
        from start: TimeInterval,
        to end: TimeInterval,
        context: CallContext,
        microphoneSpeech: [ClosedRange<TimeInterval>]
    ) -> String? {
        let me = context.selfName ?? inferredSelf(context: context, microphoneSpeech: microphoneSpeech)

        let counts = context.speakerSightings
            .filter { $0.name != me && $0.at >= start - sightingLead && $0.at <= end + sightingLag }
            .reduce(into: [String: Int]()) { $0[$1.name, default: 0] += 1 }
        if let best = counts.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }) {
            return best.key
        }

        let others = context.participants.map(\.name).filter { $0 != me }
        if me != nil, others.count == 1 { return others[0] }
        return nil
    }

    /// Where someone else starts speaking within `start...end`, in recording seconds, so a
    /// system segment holding two people back to back can be cut between them.
    /// A new speaker counts once captions name them twice in a row, which ignores a single
    /// stray reading; the cut is moved back by `sightingLead`, since captions trail speech.
    static func speakerChanges(
        from start: TimeInterval,
        to end: TimeInterval,
        context: CallContext,
        microphoneSpeech: [ClosedRange<TimeInterval>],
        minimumPiece: TimeInterval = 1
    ) -> [TimeInterval] {
        let me = context.selfName ?? inferredSelf(context: context, microphoneSpeech: microphoneSpeech)
        let sightings = context.speakerSightings
            .filter { $0.name != me && $0.at >= start && $0.at <= end + sightingLead }
            .sorted { $0.at < $1.at }

        var changes: [TimeInterval] = []
        var current: String?
        var lastCut = start
        for (index, sighting) in sightings.enumerated() where sighting.name != current {
            let confirmed = index + 1 < sightings.count && sightings[index + 1].name == sighting.name
            guard confirmed else { continue }
            defer { current = sighting.name }
            guard current != nil else { continue }
            let cut = sighting.at - sightingLead
            if cut - lastCut >= minimumPiece, end - cut >= minimumPiece {
                changes.append(cut)
                lastCut = cut
            }
        }
        return changes
    }

    /// The caption name seen mostly while the microphone had speech: that is the user.
    static func inferredSelf(context: CallContext, microphoneSpeech: [ClosedRange<TimeInterval>]) -> String? {
        let byName = Dictionary(grouping: context.speakerSightings, by: \.name)
        return byName
            .compactMap { name, sightings -> (String, Double)? in
                guard sightings.count >= 3 else { return nil }
                let duringMic = sightings.filter { sighting in
                    microphoneSpeech.contains { $0.lowerBound - sightingLead <= sighting.at && sighting.at <= $0.upperBound + sightingLag }
                }.count
                let share = Double(duringMic) / Double(sightings.count)
                return share >= 0.7 ? (name, share) : nil
            }
            .max { $0.1 < $1.1 }?
            .0
    }
}
