import XCTest

@testable import TarmacKit

/// The markdown doc page as it ships (`TarmacApp/Resources/DocTemplate.html`):
/// the policy every doc is rendered under, and the factor its prose is laid
/// out at.
final class DocTemplateTests: XCTestCase {
    private func template() throws -> String { try AppSource.text("Resources/DocTemplate.html") }

    private func host() throws -> String { try AppSource.text("Resources/Web/card-host.html") }

    private func count(of part: String, in text: String) -> Int {
        text.components(separatedBy: part).count - 1
    }

    private func firstMatch(_ pattern: String, in text: String) throws -> String {
        let regex = try NSRegularExpression(pattern: pattern)
        let match = try XCTUnwrap(
            regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), "no match for \(pattern)"
        )
        return String(text[try XCTUnwrap(Range(match.range(at: 1), in: text))])
    }

    /// The rules of the template's style sheet, in order: each selector list,
    /// split at its commas, and the declarations between its braces.
    private func rules() throws -> [(selectors: [String], body: String)] {
        let text = try template()
        let start = try XCTUnwrap(text.range(of: "<style>")).upperBound
        let end = try XCTUnwrap(text.range(of: "</style>")).lowerBound
        let sheet = String(text[start..<end]).replacingOccurrences(
            of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression
        )
        let regex = try NSRegularExpression(pattern: #"([^{}]+)\{([^{}]*)\}"#)
        return try regex.matches(in: sheet, range: NSRange(sheet.startIndex..., in: sheet)).map { match in
            let selectors = String(sheet[try XCTUnwrap(Range(match.range(at: 1), in: sheet))])
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            return (selectors, String(sheet[try XCTUnwrap(Range(match.range(at: 2), in: sheet))]))
        }
    }

    /// The declarations of every rule that names `selector`, in order.
    private func rule(for selector: String) throws -> String {
        let bodies = try rules().filter { $0.selectors.contains(selector) }.map(\.body)
        XCTAssertFalse(bodies.isEmpty, "no rule for \(selector)")
        return bodies.joined(separator: ";")
    }

    private static let k = "var(--oversample-k)"

    /// A doc's raw HTML never runs, embeds no plugin, and frames web pages
    /// only — never the card scheme, where a framed local file would sit
    /// unsandboxed beside an attacker's.
    func testTheContentSecurityPolicy() throws {
        let policy = try firstMatch(
            #"<meta http-equiv="Content-Security-Policy" content="([^"]*)">"#, in: try template()
        )
        XCTAssertEqual(policy, "script-src 'none'; object-src 'none'; frame-src http: https:")
    }

    func testThePolicyIsTheFirstThingInTheHead() throws {
        let text = try template()
        let head = try XCTUnwrap(text.range(of: "<head>"))
        let policy = try XCTUnwrap(text.range(of: "http-equiv=\"Content-Security-Policy\""))
        let between = text[head.upperBound..<policy.lowerBound]
        XCTAssertFalse(between.contains("<style"), "a style sheet ahead of the policy escapes it")
        XCTAssertFalse(between.contains("<script"))
    }

    /// The prose is laid out once at this factor and scaled down to the zoom.
    /// Below the board's max zoom the scale would be an upsample, and blur; an
    /// HTML card is magnified by the same factor.
    func testTheOversampleFactorIsThreeAndCoversTheBoardsMaxZoom() throws {
        let factor = try firstMatch(#"--oversample-k:\s*([^;]+);"#, in: try template())
        XCTAssertEqual(factor, "3")
        XCTAssertEqual(Double(factor), Double(CardZoom.magnifyK))
        XCTAssertGreaterThanOrEqual(CardZoom.magnifyK, BoardZoom.max)
    }

    /// 2610.0006 S10 — the page's own prose size, before the app sets one, is
    /// the kit's standard, and the prose reads it from the property.
    func testTheProseSizeIsAPropertyThatStartsAtTheStandard() throws {
        let text = try template()
        XCTAssertEqual(
            try firstMatch(#"--prose-size:\s*([^;]+);"#, in: text),
            FontCSS.proseSize(FontSizeRule.document.standard)
        )
        let prose = try firstMatch(#"\n  \.doc-prose \{([^}]*)\}"#, in: text)
        XCTAssertEqual(
            try firstMatch(#"font-size:\s*([^;]+);"#, in: prose), "calc(var(--prose-size) * var(--oversample-k))"
        )
        XCTAssertFalse(prose.contains("14px"))
    }

    /// 2610.0007 S17 — the doc page's colours are the theme's and nothing
    /// else: one marker in `:root`, and no colour written into the page.
    func testS17TheDocPageTakesEveryColourFromTheTheme() throws {
        let text = try template()
        XCTAssertEqual(count(of: ThemeCSS.marker, in: text), 1)
        let root = try firstMatch(#":root \{([^}]*)\}"#, in: text)
        XCTAssertTrue(root.contains(ThemeCSS.marker))
        for literal in [#"#[0-9a-fA-F]{3,8}\b"#, #"rgba?\("#] {
            XCTAssertNil(text.range(of: literal, options: .regularExpression), "a colour literal: \(literal)")
        }
        let prose = try firstMatch(#"\n  \.doc-prose \{([^}]*)\}"#, in: text)
        XCTAssertTrue(prose.contains("color: var(--prose-text);"))
        XCTAssertTrue(ThemeCSS.page(text, ThemeCatalog.standard(for: .dark).palette).contains("--term-bg: #31363b;"))
    }

    /// 2610.0007 S17 — the HTML card's host page takes its backdrop from the
    /// theme and states no scheme of its own: an author's page was measured
    /// under a host page with none.
    func testS17TheHostPageTakesItsBackdropFromTheThemeAndStatesNoScheme() throws {
        let text = try host()
        XCTAssertEqual(count(of: ThemeCSS.backdropMarker, in: text), 1)
        XCTAssertFalse(text.contains(ThemeCSS.marker))
        XCTAssertFalse(text.contains("#2b3036"))
        XCTAssertFalse(text.contains("color-scheme"))
        let root = try firstMatch(#":root \{([^}]*)\}"#, in: text)
        XCTAssertTrue(root.contains(ThemeCSS.backdropMarker))
        let backdrop = try firstMatch(#"html,\s*body \{([^}]*)\}"#, in: text)
        XCTAssertTrue(backdrop.contains("background: var(--bg1);"))
        let page = ThemeCSS.page(text, ThemeCatalog.standard(for: .light).palette)
        XCTAssertTrue(page.contains("--bg1: #eff0f1;"))
        XCTAssertFalse(page.contains("color-scheme"))
    }

    /// 2611.0021 S1 — the column's measure is written once, where `em` is the
    /// prose's own size.
    func test2611_0021S1TheColumnIsFortySixEmOnceInTheProseRule() throws {
        let text = try template()
        XCTAssertEqual(count(of: "46em", in: text), 1)
        XCTAssertTrue(try firstMatch(#"\n  \.doc-prose \{([^}]*)\}"#, in: text).contains("46em"))
        XCTAssertFalse(text.contains("720px"))
    }

    /// 2611.0021 S2 — a table or a code block of the prose itself breaks out
    /// to the cap.
    func test2611_0021S2WideBlocksAreCappedAt1040() throws {
        for selector in [".doc-prose > .doc-table", ".doc-prose > pre"] {
            let maxWidth = try firstMatch(#"max-width:\s*([^;]+);"#, in: try rule(for: selector))
            XCTAssertTrue(maxWidth.contains("calc(1040px * \(Self.k))"), selector)
        }
    }

    /// 2611.0021 S3 — the table look; the last three checks are regression
    /// guards that hold on `main` too.
    func test2611_0021S3TheTableLook() throws {
        let box = try rule(for: ".doc-table")
        XCTAssertTrue(box.contains("solid var(--line)"))
        XCTAssertTrue(box.contains("border-radius: calc(8px * \(Self.k));"))
        XCTAssertTrue(box.contains("overflow-x: auto;"))
        let header = try rule(for: ".doc-table th")
        for part in ["var(--bg2)", "var(--muted)", "white-space: nowrap;"] {
            XCTAssertTrue(header.contains(part), part)
        }
        XCTAssertTrue(try rule(for: ".doc-table td code").contains("white-space: nowrap;"))

        let cellSelector = try NSRegularExpression(pattern: #"(^|[\s>+~])(th|td)\b"#)
        for rule in try rules() {
            for selector in rule.selectors
            where cellSelector.firstMatch(in: selector, range: NSRange(selector.startIndex..., in: selector)) != nil {
                XCTAssertTrue(selector.contains(".doc-table"), selector)
            }
            let touchesTable = rule.selectors.contains { $0.contains(".doc-table") }
            let declarations = rule.body.components(separatedBy: ";").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            for side in ["border-left", "border-right", "border-inline"] where touchesTable {
                XCTAssertFalse(rule.body.contains(side), "\(side) in \(rule.selectors)")
            }
            for border in declarations where touchesTable && border.hasPrefix("border") {
                guard !border.hasPrefix("border-radius"), !border.hasPrefix("border-collapse") else { continue }
                XCTAssertTrue(
                    border.hasSuffix(": 0") || border.contains(": calc(1px * \(Self.k)) "), "a border width: \(border)"
                )
            }
        }
    }

    /// 2611.0021 S4 — a code line does not wrap; it scrolls in its block.
    func test2611_0021S4ACodeBlockScrollsSideways() throws {
        let pre = try rule(for: ".doc-prose pre")
        XCTAssertTrue(pre.contains("white-space: pre;"))
        XCTAssertTrue(pre.contains("overflow-x: auto;"))
        XCTAssertFalse(try template().contains("pre-wrap"))
    }

    /// 2611.0021 S5
    func test2611_0021S5ATextColumnKeepsItsMinimum() throws {
        XCTAssertTrue(try rule(for: ".doc-table .doc-text-col").contains("min-width: calc(220px * \(Self.k));"))
    }

    /// 2611.0021 S25 — marked's `align` beats the left default.
    func test2611_0021S25ColumnAlignmentWinsOverTheLeftDefault() throws {
        let all = try rules()
        let left = try XCTUnwrap(all.firstIndex { $0.body.contains("text-align: left;") })
        for (side, selector) in [
            ("center", #".doc-table td[align="center"]"#), ("right", #".doc-table td[align="right"]"#),
        ] {
            let index = try XCTUnwrap(all.firstIndex { $0.selectors.contains(selector) }, selector)
            XCTAssertTrue(all[index].selectors.contains(selector.replacingOccurrences(of: " td[", with: " th[")))
            XCTAssertTrue(all[index].body.contains("text-align: \(side);"))
            XCTAssertGreaterThan(index, left)
        }
    }

    /// 2611.0021 S37 — a thematic break is a whole line on screen: the
    /// default 1px border, laid out at K, is a third of a pixel and can vanish.
    func test2611_0021S37AThematicBreakIsOneScreenPixel() throws {
        let rule = try rule(for: ".doc-prose hr")
        XCTAssertTrue(rule.contains("border: 0;"))
        XCTAssertTrue(rule.contains("border-top: calc(1px * \(Self.k)) solid var(--line);"))
    }

    /// #461 — a link underline, laid out at K like the prose, is one screen
    /// pixel at zoom 1, not a third of one.
    func test461ALinkUnderlineIsOneScreenPixel() throws {
        XCTAssertTrue(
            try rule(for: ".doc-prose a").contains("border-bottom: calc(1px * \(Self.k)) dashed var(--agent);")
        )
    }

    /// #455 — the grip's line is a border, never less than one device pixel.
    func test455TheGripDrawsItsLineAsABorder() throws {
        let grip = try rule(for: ".doc-side-grip")
        XCTAssertTrue(grip.contains("border: 0 solid var(--line);"))
        XCTAssertTrue(grip.contains("border-left-width: calc(1px * var(--zoom));"))
        XCTAssertFalse(grip.contains("background"))
        XCTAssertTrue(try rule(for: #"[data-side="overlay"] .doc-side-grip"#).contains("border-style: none;"))
    }

    /// 2611.0022 S30 — the text is laid out in the width the sidebar leaves.
    func test2611_0022S30TheTextIsLaidOutAtTheTextWidth() throws {
        let text = try template()
        XCTAssertTrue(try firstMatch(#":root \{([^}]*)\}"#, in: text).contains("--text-w: var(--card-w);"))
        let prose = try firstMatch(#"\n  \.doc-prose \{([^}]*)\}"#, in: text)
        XCTAssertTrue(prose.contains("var(--text-w)"))
        XCTAssertFalse(prose.contains("var(--card-w)"))
        for selector in [".doc-prose > .doc-table", ".doc-prose > pre"] {
            let maxWidth = try firstMatch(#"max-width:\s*([^;]+);"#, in: try rule(for: selector))
            XCTAssertTrue(maxWidth.contains("var(--text-w)"), selector)
            XCTAssertFalse(maxWidth.contains("var(--card-w)"), selector)
        }
    }

    /// 2611.0022 S31 — the sidebar is scaled as the prose is, outside the
    /// prose's scroller.
    func test2611_0022S31TheSidebarScalerIsOutsideTheScroller() throws {
        let text = try template()
        let body = String(text[try XCTUnwrap(text.range(of: "<body>")).upperBound...])
        let scaler = try XCTUnwrap(body.range(of: #"<div class="doc-side-scaler""#)).lowerBound
        let scroll = try XCTUnwrap(body.range(of: #"<div class="doc-scroll" id="scroll">"#))
        let tags = try NSRegularExpression(pattern: #"<div\b|</div>"#)
        var depth = 1
        var end = body.endIndex
        for tag in tags.matches(in: body, range: NSRange(scroll.upperBound..., in: body)) {
            let range = try XCTUnwrap(Range(tag.range, in: body))
            depth += body[range] == "</div>" ? -1 : 1
            if depth == 0 {
                end = range.upperBound
                break
            }
        }
        XCTAssertTrue(scaler < scroll.lowerBound || scaler >= end)
        let rule = try rule(for: ".doc-side-scaler")
        XCTAssertTrue(rule.contains("transform: scale(calc(var(--zoom) / \(Self.k)));"))
        XCTAssertTrue(rule.contains("transform-origin: 0 0;"))
    }

    /// 2611.0025 S9 — on the Right each place of the sidebar is mirrored, and
    /// its content keeps clear of the card's scroll thumb.
    func test2611_0025S9TheRightSideMirrorsTheSidebar() throws {
        let right = #":root[data-sidebar-side="right"]"#
        let expected: [(String, [String])] = [
            ("\(right) .doc-scroll", ["left: 0;", "right: calc(var(--side-offset) * var(--zoom));"]),
            ("\(right) .doc-side-strip", ["left: auto;", "right: 0;"]),
            ("\(right) .doc-side-panel", ["left: auto;", "right: calc(var(--side-panel-start) * var(--zoom));"]),
            (
                #"\#(right)[data-side="overlay"] .doc-side-panel"#,
                ["border-right: 0;", "border-left: calc(1px * var(--zoom)) solid var(--line);"]
            ),
            (
                "\(right) .doc-side-grip",
                [
                    "left: auto;", "right: calc((var(--side-panel-start) + var(--side-panel)) * var(--zoom));",
                    "border-left-width: 0;", "border-right-width: calc(1px * var(--zoom));",
                ]
            ),
            ("\(right) .doc-strip", ["padding-right: calc(var(--side-thumb-reach) * \(Self.k));"]),
            ("\(right) .doc-side-content", ["padding-right: calc(var(--side-thumb-reach) * \(Self.k));"]),
            ("\(right) .doc-side-close", ["transform: scaleX(-1);"]),
        ]
        let all = try rules()
        for (selector, declarations) in expected {
            let matching = all.filter { $0.selectors.contains(selector) }
            XCTAssertEqual(matching.count, 1, selector)
            let found = Set(
                matching.flatMap {
                    $0.body.split(separator: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                }.filter { !$0.isEmpty })
            XCTAssertEqual(found, Set(declarations.map { String($0.dropLast()) }), selector)
        }
        XCTAssertFalse(try template().contains("--side-panel-left"))
        XCTAssertTrue(try rule(for: ".doc-side-panel").contains("left: calc(var(--side-panel-start) * var(--zoom));"))
        XCTAssertTrue(
            try rule(for: ".doc-side-grip").contains(
                "left: calc((var(--side-panel-start) + var(--side-panel)) * var(--zoom));")
        )
        // A border style here would outrank the overlay grip's `border-style: none`.
        for rule in try rules()
        where rule.selectors.contains(where: { $0.contains("data-sidebar-side") && $0.contains(".doc-side-grip") }) {
            let styled = ["border-style", "border:", "border-left:", "border-right:"].contains(
                where: rule.body.contains)
            XCTAssertFalse(styled, "\(rule.selectors)")
        }
        XCTAssertTrue(try rule(for: ".doc-side-strip").contains("left: 0;"))
        XCTAssertTrue(try rule(for: ".doc-scroll").contains("left: calc(var(--side-offset) * var(--zoom));"))
        XCTAssertTrue(
            try rule(for: #"[data-side="overlay"] .doc-side-panel"#)
                .contains("border-right: calc(1px * var(--zoom)) solid var(--line);")
        )
    }

    /// 2611.0025 D10 — every sidebar length the template reads is one the
    /// page sets, and both name the side's attribute.
    func test2611_0025TheTemplateReadsOnlyTheSidebarLengthsThePageSets() throws {
        let render = try AppSource.text("Resources/Web/doc-render.js")
        let regex = try NSRegularExpression(pattern: #"var\((--side-[a-z-]+)\)"#)
        let text = try template()
        let read = Set(
            regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
                Range($0.range(at: 1), in: text).map { String(text[$0]) }
            })
        XCTAssertFalse(read.isEmpty)
        for name in read {
            XCTAssertTrue(render.contains(#"px("\#(name)""#), name)
        }
        XCTAssertTrue(text.contains("data-sidebar-side"))
        XCTAssertTrue(render.contains(#""data-sidebar-side""#))
    }
}
