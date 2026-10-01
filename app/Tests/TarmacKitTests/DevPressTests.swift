import XCTest
@testable import TarmacKit

/// `tarmac dev press <combo>` (spec 2609.0018, #183; parity row Q19): the chord
/// grammar, the one refusal, and the flag ranges. The chord tables are
/// `desktop/src-tauri/src/dev_press.rs`'s tests, value for value.
final class DevPressTests: XCTestCase {
    // Restated as literals on purpose, so a change to the kit's bits is caught
    // here rather than mirrored.
    private let cmd: UInt64 = 1 << 20
    private let shift: UInt64 = 1 << 17
    private let ctrl: UInt64 = 1 << 18
    private let alt: UInt64 = 1 << 19

    private func chord(_ flags: UInt64, _ characters: String, _ keyCode: UInt16) -> Result<DevPress.Chord, DevError> {
        .success(DevPress.Chord(flags: flags, characters: characters, keyCode: keyCode))
    }

    private func code<T>(_ result: Result<T, DevError>) -> DevError.Code? {
        guard case .failure(let error) = result else { return nil }
        return error.code
    }

    // MARK: - the chord

    func testS3AChordIsFlagsCharactersAndTheANSIKeyCode() {
        XCTAssertEqual(DevPress.parse("cmd+q"), chord(cmd, "q", 12))
        XCTAssertEqual(DevPress.parse("cmd+v"), chord(cmd, "v", 9))
        XCTAssertEqual(DevPress.parse("cmd+t"), chord(cmd, "t", 17))
        XCTAssertEqual(DevPress.parse("cmd+w"), chord(cmd, "w", 13))
        XCTAssertEqual(DevPress.parse("cmd+k"), chord(cmd, "k", 40))
        XCTAssertEqual(DevPress.parse("cmd+shift+z"), chord(cmd | shift, "Z", 6))
        XCTAssertEqual(DevPress.parse("alt+cmd+q"), chord(cmd | alt, "q", 12))
        XCTAssertEqual(DevPress.parse("ctrl+cmd+a"), chord(cmd | ctrl, "a", 0))
        XCTAssertEqual(DevPress.parse("cmd+1"), chord(cmd, "1", 18))
        XCTAssertEqual(DevPress.parse("cmd+0"), chord(cmd, "0", 29))
        XCTAssertEqual(DevPress.parse("cmd+shift+1"), chord(cmd | shift, "1", 18))
    }

    /// Every `bad_combo` rule runs before `cmd` is looked for, so
    /// `unsupported_combo` always means a well-formed chord without it.
    func testS32AChordOutsideTheGrammarIsRefused() {
        for combo in ["q", "shift+q", "alt+ctrl+q"] {
            XCTAssertEqual(code(DevPress.parse(combo)), .unsupportedCombo, combo)
        }
        for combo in ["meta+q", "cmd+cmd+q", "cmd+", "cmd", "cmd+Q", "cmd+enter", "cmd+qq", "cmd++q", "", "cmd+é"] {
            XCTAssertEqual(code(DevPress.parse(combo)), .badCombo, combo)
        }
    }

    // MARK: - the refusal

    private func matches(_ combo: String, _ keyEquivalent: String, _ mask: UInt64) -> Bool {
        guard case .success(let chord) = DevPress.parse(combo) else {
            XCTFail("\(combo) did not parse")
            return false
        }
        return DevPress.matchesItem(chord, keyEquivalent: keyEquivalent, mask: mask)
    }

    func testS7AChordMatchesAnItemUnderTheGuardsOwnModifierRule() {
        XCTAssertTrue(matches("cmd+q", "q", cmd))
        XCTAssertTrue(matches("cmd+shift+q", "Q", cmd))
        XCTAssertTrue(matches("cmd+shift+q", "q", cmd | shift))
        XCTAssertTrue(matches("alt+cmd+q", "q", cmd | alt))
        XCTAssertTrue(matches("cmd+q", "q", cmd | (1 << 16)), "Caps Lock in the item's mask is ignored")

        XCTAssertFalse(matches("cmd+q", "Q", cmd))
        XCTAssertFalse(matches("cmd+q", "q", cmd | alt))
        XCTAssertFalse(matches("alt+cmd+q", "q", cmd))
        XCTAssertFalse(matches("cmd+shift+q", "q", cmd))
        XCTAssertFalse(matches("cmd+t", "q", cmd))
    }

    // MARK: - the flags

    func testAPressWithNoFlagsIsATapStampedNow() {
        XCTAssertEqual(
            DevPress.plan(combo: "cmd+q", holdMs: nil, ageMs: nil, busyMs: nil),
            .success(DevPress.Plan(
                chord: DevPress.Chord(flags: cmd, characters: "q", keyCode: 12), holdMs: 100, ageMs: 0, busyMs: nil
            ))
        )
    }

    func testTheFlagsAreCarriedAsGiven() {
        let chord = DevPress.Chord(flags: cmd, characters: "q", keyCode: 12)
        XCTAssertEqual(
            DevPress.plan(combo: "cmd+q", holdMs: 300, ageMs: 2_500, busyMs: nil),
            .success(DevPress.Plan(chord: chord, holdMs: 300, ageMs: 2_500, busyMs: nil))
        )
        XCTAssertEqual(
            DevPress.plan(combo: "cmd+q", holdMs: 10_000, ageMs: nil, busyMs: 1_800),
            .success(DevPress.Plan(chord: chord, holdMs: 10_000, ageMs: 0, busyMs: 1_800))
        )
        XCTAssertEqual(
            DevPress.plan(combo: "cmd+q", holdMs: 1, ageMs: 60_000, busyMs: nil),
            .success(DevPress.Plan(chord: chord, holdMs: 1, ageMs: 60_000, busyMs: nil))
        )
    }

    /// The CLI has already refused these; this guards a hand-built frame.
    func testAFlagOutOfRangeIsABadRequest() {
        let outOfRange: [(hold: Int?, age: Int?, busy: Int?)] = [
            (0, nil, nil), (10_001, nil, nil), (-1, nil, nil),
            (nil, 60_001, nil), (nil, -1, nil),
            (nil, nil, 0), (nil, nil, 1_801),
        ]
        for flags in outOfRange {
            XCTAssertEqual(
                code(DevPress.plan(combo: "cmd+q", holdMs: flags.hold, ageMs: flags.age, busyMs: flags.busy)),
                .badRequest, "\(flags)"
            )
        }
    }

    /// Their sum could cross the guard's freshness bound and really quit, so the
    /// pair is refused even at `--age 0`.
    func testBusyWithAgeIsABadRequest() {
        XCTAssertEqual(code(DevPress.plan(combo: "cmd+q", holdMs: nil, ageMs: 0, busyMs: 500)), .badRequest)
    }

    func testTheFlagsAreCheckedBeforeTheChord() {
        XCTAssertEqual(code(DevPress.plan(combo: "nonsense", holdMs: 0, ageMs: nil, busyMs: nil)), .badRequest)
        XCTAssertEqual(code(DevPress.plan(combo: "nonsense", holdMs: nil, ageMs: nil, busyMs: nil)), .badCombo)
        XCTAssertEqual(code(DevPress.plan(combo: "shift+q", holdMs: nil, ageMs: nil, busyMs: nil)), .unsupportedCombo)
    }

    // MARK: - the reply and the refusals

    /// `lib.mjs` reads `press_ms`, `hold_ms`, `activated` and `busy_ms` off this.
    func testTheReplySaysWhatWasPostedNotWhatTheKeyCaused() {
        let chord = DevPress.Chord(flags: cmd, characters: "q", keyCode: 12)
        XCTAssertEqual(
            DevPress.reply(
                combo: "cmd+q", pressMs: 268_318_196,
                plan: DevPress.Plan(chord: chord, holdMs: 300, ageMs: 0, busyMs: nil), activated: false
            ),
            ["combo": "cmd+q", "press_ms": 268_318_196, "hold_ms": 300, "activated": false, "busy_ms": .null]
        )
        XCTAssertEqual(
            DevPress.reply(
                combo: "cmd+q", pressMs: 5,
                plan: DevPress.Plan(chord: chord, holdMs: 100, ageMs: 0, busyMs: 1_000), activated: true
            ),
            ["combo": "cmd+q", "press_ms": 5, "hold_ms": 100, "activated": true, "busy_ms": 1_000]
        )
    }

    func testTheRefusalsCarryTheirCodes() {
        XCTAssertEqual(DevPress.notRetargeted(combo: "cmd+q").code, .notRetargeted)
        XCTAssertTrue(DevPress.notRetargeted(combo: "cmd+q").message.contains("`cmd+q`"))
        XCTAssertEqual(DevPress.notKey.code, .notKey)
    }
}
