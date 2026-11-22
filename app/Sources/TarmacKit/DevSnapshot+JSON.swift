import CoreGraphics
import Foundation

extension DevSnapshot {
    public static func build(_ input: Input) -> JSONValue {
        [
            "v": 1,
            "board_id": .string(input.boardID),
            "visibility": .string(input.visibility.rawValue),
            "viewport": [
                "zoom": .number(input.viewport.zoom),
                "cx": .number(input.viewport.center.x),
                "cy": .number(input.viewport.center.y),
                "view_rect": rect(input.viewRect),
            ],
            "cards": .array(input.cards.map { card(for: $0, in: input) }),
            "content_origin": input.contentOrigin.map { ["x": .number($0.x), "y": .number($0.y)] } ?? .null,
            "focused_card": optional(input.selectedCard),
            "active_element": ActiveElement(input.keyboardFocus).json,
            "quit_guard": input.quitGuard.map(quitGuard) ?? .null,
            "fonts": fonts(input.fonts),
            "theme": theme(input.theme),
            "restore_card": input.restoreCard.map { card in
                [
                    "lines": .array(card.lines.map { .string($0.string) }),
                    "choices": .array(card.choices.map { .string($0.text) }),
                ]
            } ?? .null,
            "inbox": inbox(input.inbox),
            "toasts": .array(input.toasts.map(JSONValue.string)),
            "hints": .array(
                input.hints.map { hint in
                    [
                        "card": .string(hint.card), "signal": .string(hint.signal.rawValue),
                        "edge": .string(hint.edge.rawValue),
                    ]
                }),
        ]
    }

    private static func inbox(_ facts: InboxFacts) -> JSONValue {
        let selected = facts.selected.flatMap { id in facts.items.first { $0.id == id } }
        return [
            "open": .bool(facts.open),
            "badge": .string(InboxBadge.text(unread: facts.unread)),
            "filter": .string(facts.filter.rawValue),
            "selected": selected.map { ["kind": .string(InboxCopy.tag($0.kind)), "term": .string($0.termID)] } ?? .null,
            "items": .array(
                facts.items.map { item in
                    [
                        "kind": .string(InboxCopy.tag(item.kind)), "term": .string(item.termID),
                        "board": .string(item.boardID), "read": .bool(item.read),
                        "title": .string(InboxCopy.title(item)),
                    ]
                }),
        ]
    }

    private static func theme(_ theme: Theme) -> JSONValue {
        [
            "choice": .string(theme.choice.rawValue), "in_effect": .string(theme.inEffect.rawValue),
            "name": .string(theme.name), "folder": .string(theme.folder),
            "available": .array(theme.available.map(JSONValue.string)),
            "refused": .array(theme.refused.map(JSONValue.string)),
            "findings": .array(theme.findings.map(JSONValue.string)),
        ]
    }

    private static func fonts(_ fonts: Fonts) -> JSONValue {
        [
            "terminal": [
                "saved": optional(fonts.saved[.terminal]), "face": .string(fonts.terminalFace),
                "size": .number(fonts.terminalSize),
            ],
            "interface": ["saved": optional(fonts.saved[.interface]), "face": .string(fonts.interfaceFace)],
            "document": [
                "saved": optional(fonts.saved[.document]), "css": .string(fonts.documentCSS),
                "size": .number(fonts.documentSize),
            ],
        ]
    }

    private static func card(for card: Card, in input: Input) -> JSONValue {
        var fields: [String: JSONValue] = [
            "id": .string(card.id),
            "kind": .string(card.kind.rawValue),
            "board_rect": rect(card.frame),
            "screen_rect": card.screenRect.map(rect) ?? .null,
            "focused": .bool(card.id == input.selectedCard),
            "scroll": card.scroll.map(scroll) ?? .null,
        ]
        switch card.content {
        case .doc:
            fields["borrowed"] = .bool(card.id == input.borrowedCard)
        case .term(let terminal):
            var term: [String: JSONValue] = [
                "alive": .bool(terminal.live && !terminal.dead),
                "cols": .number(Double(terminal.cols)),
                "rows": .number(Double(terminal.rows)),
                "proc": optional(terminal.proc),
                // "" would make `contains ""` match vacuously.
                "selection": optional(terminal.selection.flatMap { $0.isEmpty ? nil : $0 }),
                "scrollback_tail": .string(terminal.scrollbackTail),
                "cursor_row": .number(Double(terminal.cursorRow)),
            ]
            // Present only with an offer (2611.0011) or a chip (2611.0015): a
            // terminal with none keeps its seven keys.
            if let resume = terminal.resume {
                let panel = resume.panel
                term["resume"] = [
                    "cmd": .string(panel.command), "armed": .bool(resume.armed), "queued": .bool(resume.queued),
                    "title": .string(panel.title), "buttons": .array(panel.buttons.map { .string($0.text) }),
                ]
            }
            if terminal.reopen { term["reopen"] = true }
            if let chip = terminal.resumeChip { term["resume_chip"] = .string(chip) }
            fields["term"] = .object(term)
        }
        return .object(fields)
    }

    private static func quitGuard(_ facts: QuitGuard) -> JSONValue {
        [
            "retargeted": .bool(facts.retargeted),
            "enabled": .bool(facts.enabled),
            "phase": .string(facts.phase.rawValue),
            "notice": [
                "visible": .bool(facts.noticeVisible),
                // A hidden panel keeps the alpha it was left at, which AppKit
                // resets to 1; reported, that reads as a notice at full opacity.
                "alpha": .number(facts.noticeVisible ? facts.noticeAlpha : 0),
            ],
            "last_press": facts.lastPress.map { press in
                [
                    "press_ms": .number(Double(press.pressMs)),
                    "route": .string(press.route.rawValue),
                    "age_ms": .number(Double(press.ageMs)),
                ]
            } ?? .null,
        ]
    }

    private static func scroll(_ scroll: Scroll) -> JSONValue {
        [
            "offset": .number(scroll.metrics.offset),
            "visible": .number(scroll.metrics.visible),
            "total": .number(scroll.metrics.total),
            "shown": .bool(scroll.laidOut && scroll.alpha > 0),
            "thumb": scroll.laidOut ? scroll.thumb.map(rect) ?? .null : .null,
        ]
    }

    private static func rect(_ rect: CGRect) -> JSONValue {
        [
            "x": .number(rect.origin.x),
            "y": .number(rect.origin.y),
            "w": .number(rect.size.width),
            "h": .number(rect.size.height),
        ]
    }
}
