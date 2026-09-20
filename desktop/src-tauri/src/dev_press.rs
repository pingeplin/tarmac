//! What `tarmac dev press <combo>` parses and refuses (spec 2609.0018, #183).
//!
//! Pure on purpose: the chord is raw `NSEventModifierFlags` bits, characters
//! and an ANSI key code, and the one refusal — a chord a native `terminate:`
//! item would take — is a predicate over the item's own key equivalent and
//! mask. Posting the event is wiring in `quit_intercept.rs`.

use crate::quit_guard::{expected_modifiers, COMMAND, CONTROL, OPTION, SHIFT};

#[derive(Debug, Clone, PartialEq)]
pub struct Chord {
    pub flags: u64,
    pub chars: String,
    pub key_code: u16,
}

#[derive(Debug, PartialEq)]
pub enum ChordError {
    /// A well-formed chord without `cmd`: `key` / `type` is the verb for it.
    Unsupported(String),
    /// Outside the grammar.
    Bad(String),
}

/// `cmd` plus any of `shift`, `alt`, `ctrl` (each at most once, any order), then
/// one ASCII lowercase letter or digit. Every `Bad` rule is checked before `cmd`
/// is looked for, so `Unsupported` always means a well-formed chord without it.
pub fn parse_chord(combo: &str) -> Result<Chord, ChordError> {
    let bad = |what: &str| Err(ChordError::Bad(format!("{what} in `{combo}`; the grammar is cmd[+shift][+alt][+ctrl]+<a-z|0-9>")));
    let (mods, base) = match combo.rsplit_once('+') {
        Some((mods, base)) => (mods.split('+').collect::<Vec<_>>(), base),
        None => (Vec::new(), combo),
    };
    let mut flags = 0u64;
    for m in &mods {
        let bit = match *m {
            "cmd" => COMMAND,
            "shift" => SHIFT,
            "alt" => OPTION,
            "ctrl" => CONTROL,
            "" => return bad("empty segment"),
            _ => return bad("unknown modifier"),
        };
        if flags & bit != 0 {
            return bad("repeated modifier");
        }
        flags |= bit;
    }
    let mut chars = base.chars();
    let (Some(c), None) = (chars.next(), chars.next()) else {
        return bad("the base must be one lowercase letter or digit");
    };
    let Some(key_code) = ansi_key_code(c) else {
        return bad("the base must be one lowercase letter or digit");
    };
    if flags & COMMAND == 0 {
        return Err(ChordError::Unsupported(format!(
            "`{combo}` has no cmd; `tarmac dev key` / `type` drive non-⌘ keys through the page"
        )));
    }
    let chars = if flags & SHIFT != 0 { c.to_ascii_uppercase() } else { c };
    Ok(Chord { flags, chars: chars.to_string(), key_code })
}

/// `kVK_ANSI_*` (HIToolbox `Events.h`) for the US layout's letters and digits.
fn ansi_key_code(c: char) -> Option<u16> {
    Some(match c {
        'a' => 0x00, 's' => 0x01, 'd' => 0x02, 'f' => 0x03, 'h' => 0x04, 'g' => 0x05,
        'z' => 0x06, 'x' => 0x07, 'c' => 0x08, 'v' => 0x09, 'b' => 0x0B, 'q' => 0x0C,
        'w' => 0x0D, 'e' => 0x0E, 'r' => 0x0F, 'y' => 0x10, 't' => 0x11, '1' => 0x12,
        '2' => 0x13, '3' => 0x14, '4' => 0x15, '6' => 0x16, '5' => 0x17, '9' => 0x19,
        '7' => 0x1A, '8' => 0x1C, '0' => 0x1D, 'o' => 0x1F, 'u' => 0x20, 'i' => 0x22,
        'p' => 0x23, 'l' => 0x25, 'j' => 0x26, 'k' => 0x28, 'n' => 0x2D, 'm' => 0x2E,
        _ => return None,
    })
}

/// Would AppKit hand this chord to an item carrying `key_equivalent` and
/// `item_mask`? True iff the characters match ignoring ASCII case and the
/// chord's modifiers are exactly the ones the guard itself expects of a press
/// on that item.
pub fn matches_item(chord: &Chord, key_equivalent: &str, item_mask: u64) -> bool {
    key_equivalent.eq_ignore_ascii_case(&chord.chars)
        && chord.flags == expected_modifiers(key_equivalent, item_mask)
}

#[cfg(test)]
mod tests {
    use super::*;

    // Restated as literals on purpose, so a change to the crate's bits is
    // caught here rather than mirrored.
    const CMD: u64 = 1 << 20;
    const SHF: u64 = 1 << 17;
    const CTL: u64 = 1 << 18;
    const ALT: u64 = 1 << 19;

    fn chord(flags: u64, chars: &str, key_code: u16) -> Chord {
        Chord { flags, chars: chars.into(), key_code }
    }

    /// S3 — flags, characters and ANSI key codes, every value literal.
    #[test]
    fn parse_chord_gives_flags_chars_and_ansi_key_codes() {
        assert_eq!(parse_chord("cmd+q"), Ok(chord(CMD, "q", 12)));
        assert_eq!(parse_chord("cmd+v"), Ok(chord(CMD, "v", 9)));
        assert_eq!(parse_chord("cmd+t"), Ok(chord(CMD, "t", 17)));
        assert_eq!(parse_chord("cmd+w"), Ok(chord(CMD, "w", 13)));
        assert_eq!(parse_chord("cmd+k"), Ok(chord(CMD, "k", 40)));
        assert_eq!(parse_chord("cmd+shift+z"), Ok(chord(CMD | SHF, "Z", 6)));
        assert_eq!(parse_chord("alt+cmd+q"), Ok(chord(CMD | ALT, "q", 12)));
        assert_eq!(parse_chord("ctrl+cmd+a"), Ok(chord(CMD | CTL, "a", 0)));
        assert_eq!(parse_chord("cmd+1"), Ok(chord(CMD, "1", 18)));
        assert_eq!(parse_chord("cmd+0"), Ok(chord(CMD, "0", 29)));
        assert_eq!(parse_chord("cmd+shift+1"), Ok(chord(CMD | SHF, "1", 18)));
    }

    /// S7 — the refusal predicate, with chords from the parser.
    #[test]
    fn matches_item_applies_the_guards_own_modifier_rule() {
        let m = |combo: &str, key_equivalent: &str, mask: u64| {
            matches_item(&parse_chord(combo).unwrap(), key_equivalent, mask)
        };
        assert!(m("cmd+q", "q", CMD));
        assert!(m("cmd+shift+q", "Q", CMD));
        assert!(m("cmd+shift+q", "q", CMD | SHF));
        assert!(m("alt+cmd+q", "q", CMD | ALT));
        assert!(m("cmd+q", "q", CMD | (1 << 16)), "Caps Lock in the item's mask is ignored");

        assert!(!m("cmd+q", "Q", CMD));
        assert!(!m("cmd+q", "q", CMD | ALT));
        assert!(!m("alt+cmd+q", "q", CMD));
        assert!(!m("cmd+shift+q", "q", CMD));
        assert!(!m("cmd+t", "q", CMD));
    }

    /// S32 — every refusal, and the order: `bad_combo` rules run before `cmd`
    /// is looked for.
    #[test]
    fn parse_chord_refuses_outside_the_grammar() {
        for combo in ["q", "shift+q", "alt+ctrl+q"] {
            assert!(
                matches!(parse_chord(combo), Err(ChordError::Unsupported(_))),
                "{combo:?} should be Unsupported, got {:?}",
                parse_chord(combo)
            );
        }
        for combo in ["meta+q", "cmd+cmd+q", "cmd+", "cmd", "cmd+Q", "cmd+enter", "cmd+qq", "cmd++q", "", "cmd+é"] {
            assert!(
                matches!(parse_chord(combo), Err(ChordError::Bad(_))),
                "{combo:?} should be Bad, got {:?}",
                parse_chord(combo)
            );
        }
    }
}
