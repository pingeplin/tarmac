const BEL: u8 = 0x07;
const CAN: u8 = 0x18;
const SUB: u8 = 0x1a;
const ESC: u8 = 0x1b;

/// Finds a BEL that rings, across chunk boundaries: one outside an escape
/// string. A BEL ends an OSC; inside a DCS, SOS, PM or APC it is payload. Raw
/// 0x80–0x9F are not taken as C1 introducers: in UTF-8 output they are
/// continuation bytes.
#[derive(Default)]
pub struct BellScan {
    state: State,
}

#[derive(Default, Clone, Copy)]
enum State {
    #[default]
    Ground,
    Escape,
    Osc,
    OtherString,
}

impl BellScan {
    pub fn feed(&mut self, chunk: &[u8]) -> bool {
        if matches!(self.state, State::Ground) && !chunk.contains(&BEL) && !chunk.contains(&ESC) {
            return false;
        }
        let mut rang = false;
        for &b in chunk {
            self.state = match (self.state, b) {
                (_, CAN | SUB) => State::Ground,
                (_, ESC) => State::Escape,
                (State::Ground | State::Escape, BEL) => {
                    rang = true;
                    self.state
                }
                (State::Osc, BEL) => State::Ground,
                (State::Escape, b']') => State::Osc,
                (State::Escape, b'P' | b'X' | b'^' | b'_') => State::OtherString,
                (State::Escape, _) => State::Ground,
                (s, _) => s,
            };
        }
        rang
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rings(chunk: &[u8]) -> bool {
        BellScan::default().feed(chunk)
    }

    #[test]
    fn a_lone_bel_rings() {
        assert!(rings(b"\x07"));
        assert!(rings(b"done\x07\r\n"));
    }

    #[test]
    fn plain_output_does_not_ring() {
        assert!(!rings(b"hello\r\n"));
    }

    #[test]
    fn an_osc_title_ended_by_bel_or_st_does_not_ring() {
        assert!(!rings(b"\x1b]2;~/src\x07"));
        assert!(!rings(b"\x1b]2;~/src\x1b\\"));
    }

    #[test]
    fn an_osc_8_hyperlink_does_not_ring() {
        assert!(!rings(b"\x1b]8;;https://example.com\x07link\x1b]8;;\x07"));
    }

    #[test]
    fn a_bel_after_an_ended_osc_rings() {
        assert!(rings(b"\x1b]2;title\x07\x07"));
        assert!(rings(b"\x1b]2;title\x1b\\\x07"));
    }

    #[test]
    fn an_esc_inside_an_osc_starts_a_new_sequence() {
        assert!(!rings(b"\x1b]2;a\x1b]2;b\x07"));
    }

    #[test]
    fn a_string_split_at_any_byte_does_not_ring() {
        let seqs: [&[u8]; 3] = [b"\x1b]2;user@host: ~/src\x07", b"\x1b]2;title\x1b\\", b"\x1bPq\x07#0\x1b\\"];
        for seq in seqs {
            for at in 0..=seq.len() {
                let mut scan = BellScan::default();
                assert!(!scan.feed(&seq[..at]), "{seq:?}: first half, split at {at}");
                assert!(!scan.feed(&seq[at..]), "{seq:?}: second half, split at {at}");
                assert!(scan.feed(b"\x07"), "{seq:?}: lone BEL after a split at {at}");
            }
        }
    }

    #[test]
    fn an_escape_sequence_ended_in_a_later_chunk_returns_to_ground() {
        let mut scan = BellScan::default();
        assert!(!scan.feed(b"\x1b"));
        assert!(!scan.feed(b"[0m"));
        assert!(scan.feed(b"]\x07"));
    }

    #[test]
    fn can_and_sub_abort_an_osc_or_a_dcs() {
        let seqs: [&[u8]; 4] = [b"\x1b]2;tit\x18\x07", b"\x1b]2;tit\x1a\x07", b"\x1bPq#0\x18\x07", b"\x1bPq#0\x1a\x07"];
        for seq in seqs {
            assert!(rings(seq), "{seq:?}");
        }
    }

    #[test]
    fn bels_inside_dcs_apc_pm_or_sos_do_not_ring() {
        for intro in [b'P', b'_', b'^', b'X'] {
            let mut scan = BellScan::default();
            assert!(!scan.feed(&[0x1b, intro, b'a', 0x07, b'b', 0x07, b'c', 0x1b, b'\\']), "{}", intro as char);
            assert!(scan.feed(b"\x07"), "lone BEL after the {} string", intro as char);
        }
    }

    #[test]
    fn a_bel_after_a_finished_escape_sequence_rings() {
        assert!(rings(b"\x1b[31mred\x1b[0m\x07"));
        assert!(rings(b"\x1b[0mPass\x07"));
    }

    #[test]
    fn a_bel_right_after_esc_or_inside_a_csi_rings() {
        assert!(rings(b"\x1b\x07"));
        assert!(rings(b"\x1b[3\x07m"));
    }

    #[test]
    fn utf8_and_raw_c1_bytes_change_nothing() {
        assert!(rings("中\x07文".as_bytes()));
        assert!(rings(b"\x9d2;title\x07"));
        assert!(rings("\u{15d}\x07".as_bytes()));
        assert!(!rings("\x1b]2;中文 ŝ\x07".as_bytes()));
    }
}
