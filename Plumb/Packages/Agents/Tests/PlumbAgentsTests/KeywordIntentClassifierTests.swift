import Foundation
import Testing
@testable import PlumbAgents

private let classifier = KeywordIntentClassifier()

@Suite struct KeywordIntentClassifierTests {
    @Test(arguments: [
        "How fast am I going?", "what's my rate", "Am I too slow?", "Should I go faster?", "Slow down?",
        "Am I on the beat?", "Is my speed OK?", "how's my pace", "Am I keeping up with the metronome?",
        "Am I rushing?", "how many per minute", "How many compressions a minute am I doing?", "Tempo?",
        "WHAT IS MY RATE", "Am I pushing too quickly?", "BPM?",
    ])
    func rateQuestions(_ question: String) {
        #expect(classifier.intent(for: question) == .rate)
    }

    @Test(arguments: [
        "How deep am I going?", "Is my depth good?", "Am I pushing hard enough?", "Should I push harder?",
        "Am I too shallow?", "Deeper?", "How many centimetres?", "Am I pressing too softly?",
        "Is that deep enough", "am i going far enough down", "Am I using enough force?", "How hard should I press?",
    ])
    func depthQuestions(_ question: String) {
        #expect(classifier.intent(for: question) == .depth)
    }

    @Test(arguments: [
        "Did I pause too long?", "How long was my last pause?", "Am I taking too many breaks?",
        "Did I stop?", "How long have I been stopped?", "Any gaps?", "How much hands-off time?",
        "Was there an interruption?", "Am I resting too much?",
    ])
    func pauseQuestions(_ question: String) {
        #expect(classifier.intent(for: question) == .pauses)
    }

    @Test(arguments: [
        "How many compressions have I done?", "What's my count?", "How many so far?", "Count?",
        "What number am I on?", "What's the total?", "how many times have I pushed",
    ])
    func countQuestions(_ question: String) {
        #expect(classifier.intent(for: question) == .count)
    }

    @Test(arguments: [
        "How am I doing?", "How's it going?", "how is it going", "Am I doing this right?", "Am I doing OK?",
        "Tell me how I'm doing.", "Is this good?", "Give me an update", "Any feedback?", "How does it look?",
        "How are my compressions?", "Quick question, how am I doing so far?", "How's my CPR?",
        // More than one topic named at once is answered with the overall picture.
        "Am I deep enough and fast enough?", "How's my rate and depth?", "Am I stopping too much or going too slow?",
    ])
    func overallQuestions(_ question: String) {
        #expect(classifier.intent(for: question) == .overall)
    }

    @Test(arguments: [
        "", "   ", "?!", "What's the weather like?", "Play some music", "What time is it?", "Hello",
        "Is my hand position right?", "Am I leaning?", "Who made this app?",
    ])
    func questionsOutsideTheTopicsAreUnknown(_ question: String) {
        #expect(classifier.intent(for: question) == .unknown)
    }

    @Test(arguments: [
        "Is he breathing?", "Is she still alive?", "Does he have a pulse?", "Will he survive?",
        "How's my rate? Is he breathing?", "Am I pushing hard enough to save him?", "Did I break a rib?",
        "Where is the AED?", "Should I call 911?", "How many breaths should I give?", "Is his heart beating?",
        "Is he conscious?",
    ])
    func questionsAboutAPersonAreNeverAnsweredFromTheNumbers(_ question: String) {
        #expect(classifier.intent(for: question) == .unknown)
        #expect(KeywordIntentClassifier.asksAboutCondition(question))
    }

    /// No word of `condition` in them, but each asks about the person, so a number must not answer it.
    /// "doing okay" alone would read as asking how the compressions are going.
    @Test(arguments: [
        "How is he doing?", "Is he doing okay?", "Is she OK?", "How's the patient?", "Is the victim doing better?",
        "Will he make it?", "Is she going to be all right?", "How's his color?", "Is the baby doing well?",
        "How is the person doing?", "Is the kid okay?", "How's she looking?",
        // Naming the person is enough, even about the pushing: the topics are said instead of a number.
        "Am I pushing hard enough on him?",
    ])
    func questionsNamingThePersonAreNeverAnsweredFromTheNumbers(_ question: String) {
        #expect(classifier.intent(for: question) == .unknown)
        #expect(KeywordIntentClassifier.asksAboutCondition(question))
    }

    @Test func ordinaryQuestionsAreNotMistakenForQuestionsAboutAPerson() {
        for question in ["How fast am I going?", "How am I doing?", "Am I pushing hard enough?", "Did I stop?",
                         "Is this good?", "How are my compressions?", "Am I doing this right?", "Is it working?"] {
            #expect(!KeywordIntentClassifier.asksAboutCondition(question), "\(question)")
        }
    }

    @Test func wordsAreFoldedToPlainLowerCase() {
        #expect(KeywordIntentClassifier.words(in: "How’s  my PACE, réally?") == ["hows", "my", "pace", "really"])
        #expect(KeywordIntentClassifier.words(in: "hands-off") == ["hands", "off"])
    }

    @Test func theSameWordsAlwaysGiveTheSameIntent() async {
        let reading = await classifier.classify("how fast am I going")

        #expect(reading == IntentReading(intent: .rate, classifiedBy: .keywords, fallbackReason: nil))
        #expect(await classifier.classify("how fast am I going") == reading)
    }
}
