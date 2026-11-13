import Testing
@testable import RescueCore

@Suite struct ValidatorTests {
    private func categories(_ text: String) -> [SentinelFlag.Category] {
        TranscriptValidator.check(text).map(\.category)
    }

    @Test(arguments: [
        ("Check his pulse first.", SentinelFlag.Category.pulseCheck),
        ("Try to feel for a pulse at the neck.", .pulseCheck),
        ("You can stop compressions now.", .stopCpr),
        ("Pause CPR for a moment.", .stopCpr),
        ("You can stop.", .stopCpr),
        ("Give 5 mg of it.", .dose),
        ("Use 0.3 milligrams.", .dose),
        ("I think he is dead.", .deathStatement),
        ("It's too late.", .deathStatement),
        ("He sounds fine.", .reassurance),
        ("She's okay.", .reassurance),
        ("They seem fine.", .reassurance),
        ("He's breathing normally.", .reassurance),
        ("There's no need to call 911.", .reassurance),
        ("You don\u{2019}t need CPR.", .reassurance),
        // A negation in another clause doesn't negate this one.
        ("Don't worry, you should stop compressions now.", .stopCpr),
        ("Never mind, check his pulse.", .pulseCheck),
        ("Don't worry, he is dead.", .deathStatement),
        // Subjects and forms that plain pronoun rules miss.
        ("The patient is fine.", .reassurance),
        ("The person looks okay.", .reassurance),
        ("The patient is breathing normally.", .reassurance),
        ("Everything's okay.", .reassurance),
        ("Everything is going to be fine.", .reassurance),
        ("He's going to be fine.", .reassurance),
        ("She'll be okay.", .reassurance),
        ("It's okay to stop now.", .stopCpr),
        ("It's fine to rest.", .stopCpr),
        ("You don't have to keep going.", .stopCpr),
        ("You do not need to continue.", .stopCpr),
        ("Stop now.", .stopCpr),
        ("He has passed away.", .deathStatement),
        ("The patient died.", .deathStatement),
        ("He didn't make it.", .deathStatement),
        ("Give him an aspirin.", .dose),
        ("Use the epipen.", .dose),
    ])
    func flagsBadLines(text: String, expected: SentinelFlag.Category) {
        #expect(categories(text).contains(expected), "\(text)")
    }

    @Test(arguments: [
        "Do not check for a pulse.",
        "Don't check his pulse, keep pushing.",
        "Do not stop compressions.",
        "Never stop CPR until EMS takes over.",
        "Are they breathing normally?",
        "Is he breathing normally?",
        "He's not breathing normally.",
        "Push hard and fast.",
        "Follow the AED.",
        "Call 911 now.",
        "Don't stop, keep pushing.",
        "Do not stop. Keep pushing.",
        "Don't worry, keep pushing.",
        "Never mind, keep pushing.",
        "Is the patient breathing normally?",
        "Do not give aspirin.",
        "Do not stop now.",
        "Keep going.",
    ])
    func allowsCorrectLines(text: String) {
        #expect(categories(text).isEmpty, "\(text) gave \(categories(text))")
    }

    @Test func bufferCatchesAcrossDeltasAndReportsOnce() {
        var buffer = TranscriptBuffer()
        #expect(buffer.feed("You can ").isEmpty)
        #expect(buffer.feed("stop compressions").map(\.category) == [.stopCpr])
        #expect(buffer.feed(" now, really.").isEmpty)
        buffer.endTurn()
        #expect(buffer.feed("Stop compressions.").map(\.category) == [.stopCpr])
    }
}
