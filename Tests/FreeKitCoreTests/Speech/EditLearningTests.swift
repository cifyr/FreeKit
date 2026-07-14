import XCTest
@testable import FreeKitCore

final class EditLearningTests: XCTestCase {
    func testSimpleSubstitutionIsExtracted() {
        let inserted = "My specialty is to use cloud code on projects."
        let pairs = EditDiff.corrections(
            inserted: inserted,
            before: "Note: My specialty is to use cloud code on projects.",
            after: "Note: My specialty is to use Claude Code on projects.")
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].from, "cloud code")
        XCTAssertEqual(pairs[0].to, "Claude Code")
    }

    func testSingleWordCorrection() {
        let pairs = EditDiff.corrections(
            inserted: "my name is Keaton Warren",
            before: "my name is Keaton Warren",
            after: "my name is Caden Warren")
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].from, "keaton")
        XCTAssertEqual(pairs[0].to, "Caden")
    }

    func testEditsOutsideInsertedTextAreIgnored() {
        // "meeting" was never in the dictated text, so changing it teaches nothing.
        let pairs = EditDiff.corrections(
            inserted: "see you tomorrow",
            before: "meeting notes. see you tomorrow",
            after: "standup notes. see you tomorrow")
        XCTAssertTrue(pairs.isEmpty)
    }

    func testPureInsertionsAndDeletionsAreIgnored() {
        XCTAssertTrue(EditDiff.corrections(
            inserted: "hello world",
            before: "hello world",
            after: "hello brave new world").isEmpty)
        XCTAssertTrue(EditDiff.corrections(
            inserted: "hello brave world",
            before: "hello brave world",
            after: "hello world").isEmpty)
    }

    func testUnchangedTextYieldsNothing() {
        XCTAssertTrue(EditDiff.corrections(
            inserted: "hello", before: "hello there", after: "hello there").isEmpty)
    }

    func testCaseOnlyCorrectionIsLearned() {
        let pairs = EditDiff.corrections(
            inserted: "i use freespeech daily",
            before: "i use freespeech daily",
            after: "i use FreeSpeech daily")
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].from, "freespeech")
        XCTAssertEqual(pairs[0].to, "FreeSpeech")
    }

    func testOversizedFieldIsSkipped() {
        let huge = Array(repeating: "word", count: EditDiff.maxWords + 1).joined(separator: " ")
        XCTAssertTrue(EditDiff.corrections(
            inserted: "word", before: huge, after: huge + " extra").isEmpty)
    }
}

final class LearningStoreTests: XCTestCase {
    private var url: URL!
    private var store: LearningStore!

    override func setUp() {
        super.setUp()
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("learning-test-\(UUID().uuidString).json")
        store = LearningStore(fileURL: url)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
        super.tearDown()
    }

    func testRuleNotAppliedBeforePromotion() {
        store.recordCorrections([("cloud code", "Claude Code")])
        XCTAssertEqual(store.apply(to: "I use cloud code"), "I use cloud code")
        XCTAssertEqual(store.promotedCount, 0)
    }

    func testRuleAppliedAfterSecondObservation() {
        store.recordCorrections([("cloud code", "Claude Code")])
        store.recordCorrections([("cloud code", "Claude Code")])
        XCTAssertEqual(store.promotedCount, 1)
        XCTAssertEqual(store.apply(to: "I use cloud code daily"), "I use Claude Code daily")
        XCTAssertEqual(store.apply(to: "Cloud Code rocks"), "Claude Code rocks")
    }

    func testWordBoundaryRespected() {
        store.recordCorrections([("cat", "Kat")])
        store.recordCorrections([("cat", "Kat")])
        XCTAssertEqual(store.apply(to: "concatenate the cat"), "concatenate the Kat")
    }

    func testPersistenceAcrossInstances() {
        store.recordCorrections([("keaton", "Caden")])
        store.recordCorrections([("keaton", "Caden")])
        let reloaded = LearningStore(fileURL: url)
        XCTAssertEqual(reloaded.apply(to: "keaton was here"), "Caden was here")
    }

    func testVocabularyTermsFromPromotedRules() {
        store.recordCorrections([("keaton", "Caden"), ("keaton", "Caden")])
        store.recordCorrections([("once only", "ignored")])
        XCTAssertEqual(store.vocabularyTerms(), ["Caden"])
    }

    func testReset() {
        store.recordCorrections([("a", "b"), ("a", "b")])
        store.reset()
        XCTAssertEqual(store.ruleCount, 0)
        XCTAssertEqual(store.apply(to: "a"), "a")
    }
}

final class HotkeyComboTests: XCTestCase {
    func testComboDisplayNameUsesAppleSymbolOrder() {
        let preset = HotkeyPreset.custom(keyCode: 40, modifiers: [.command, .option])  // K
        XCTAssertEqual(preset.displayName, "\u{2325}\u{2318} K")
        XCTAssertEqual(preset.kind, .key)
    }

    func testBareModifierStaysModifierKind() {
        XCTAssertEqual(HotkeyPreset.custom(keyCode: 61).kind, .modifier)
        XCTAssertEqual(HotkeyPreset.custom(keyCode: 61, modifiers: [.command]).kind, .key)
    }

    func testComboSettingsRoundTrip() {
        let defaults = UserDefaults(suiteName: "com.cadenwarren.freespeech.combo-tests")!
        defaults.removePersistentDomain(forName: "com.cadenwarren.freespeech.combo-tests")
        let settings = Settings(defaults: defaults)
        settings.hotkey = HotkeyPreset.custom(keyCode: 40, modifiers: [.command, .shift])
        let restored = Settings(defaults: defaults).hotkey
        XCTAssertEqual(restored.keyCode, 40)
        XCTAssertEqual(restored.modifiers, [.command, .shift])
        XCTAssertEqual(restored.kind, .key)
    }

    func testModifierRawValuesMatchCGEventFlags() {
        XCTAssertEqual(HotkeyModifiers.command.rawValue, 0x100000)
        XCTAssertEqual(HotkeyModifiers.option.rawValue, 0x80000)
        XCTAssertEqual(HotkeyModifiers.shift.rawValue, 0x20000)
        XCTAssertEqual(HotkeyModifiers.control.rawValue, 0x40000)
    }
}

final class MicPriorityTests: XCTestCase {
    func testPicksFirstConnectedInPriorityOrder() {
        XCTAssertEqual(
            MicPriority.pick(priority: ["a", "b", "c"], connected: ["c", "b"]), "b")
    }

    func testEmptyPriorityMeansSystemDefault() {
        XCTAssertNil(MicPriority.pick(priority: [], connected: ["a"]))
    }

    func testNoPriorityDeviceConnectedMeansSystemDefault() {
        XCTAssertNil(MicPriority.pick(priority: ["x"], connected: ["a", "b"]))
    }
}
