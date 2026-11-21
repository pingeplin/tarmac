// The markdown doc card's layout and sidebar rules (specs 2611.0021 and
// 2611.0022). It touches no DOM, so XCTest runs it as shipped in a bare
// JavaScriptCore context after marked.
(function () {
  const textColumnWidth = 40;

  // East Asian wide and fullwidth blocks: such a character takes about two
  // Latin widths, so a cell of them is as long as twice its count.
  const wideRanges = [
    [0x1100, 0x115f], [0x2e80, 0x303e], [0x3041, 0x33ff], [0x3400, 0x4dbf], [0x4e00, 0x9fff],
    [0xa000, 0xa4cf], [0xac00, 0xd7a3], [0xf900, 0xfaff], [0xfe30, 0xfe4f], [0xff00, 0xff60],
    [0xffe0, 0xffe6], [0x1f300, 0x1f64f], [0x1f900, 0x1f9ff], [0x20000, 0x3fffd],
  ];

  function width(text) {
    let total = 0;
    for (const character of text) {
      const point = character.codePointAt(0);
      total += wideRanges.some(([low, high]) => point >= low && point <= high) ? 2 : 1;
    }
    return total;
  }

  // The text of inline tokens. marked gives an escape's and a code span's
  // text as written, entities and all; `text` maps a text token's. An image
  // has child tokens (its alt text), so `images` says whether they count.
  function inlineText(tokens, options) {
    return tokens
      .map(function (token) {
        if (token.type === "codespan") return options.code ? token.text : "";
        if (token.type === "image" && !options.images) return "";
        if (token.tokens) return inlineText(token.tokens, options);
        if (token.type === "escape") return token.text;
        if (token.type === "text") return options.text(token.text);
        if (token.type === "br") return " ";
        return "";
      })
      .join("");
  }

  // The text a reader reads as prose; inline code is not.
  const proseText = { code: false, images: true, text: (text) => text };

  // marked pads and cuts every body row to the header's length, so a row
  // always has cell `column`.
  function textColumns(table) {
    return table.header.map(function (_, column) {
      return table.rows.some(function (row) {
        return width(inlineText(row[column].tokens, proseText).trim()) >= textColumnWidth;
      });
    });
  }

  const entities = { amp: "&", lt: "<", gt: ">", quot: '"' };

  // One pass, so "&amp;lt;" stays "&lt;". A code point past Unicode stays as
  // written: fromCodePoint would throw and stop the render.
  function decode(text) {
    return text.replace(/&(amp|lt|gt|quot|#(\d+)|#[xX]([0-9a-fA-F]+));/g, function (entity, name, decimal, hex) {
      if (entities[name]) return entities[name];
      const point = decimal !== undefined ? parseInt(decimal, 10) : parseInt(hex, 16);
      return point <= 0x10ffff ? String.fromCodePoint(point) : entity;
    });
  }

  // A heading's outline text: what the reader sees, code spans included.
  const headingText = { code: true, images: false, text: decode };

  // Marked before any cell is rendered: a cell's renderer is not told its column.
  function markTextColumns(table) {
    textColumns(table).forEach(function (text, column) {
      if (!text) return;
      [table.header].concat(table.rows).forEach(function (row) {
        row[column].textColumn = true;
      });
    });
  }

  const defaults = marked.Renderer.prototype;
  const layout = new marked.Marked();
  layout.use({
    renderer: {
      heading(token) {
        const html = defaults.heading.call(this, token);
        if (!token.outlineMark) return html;
        return html.replace("<h" + token.depth, "<h" + token.depth + ' data-outline="' + token.outlineMark + '"');
      },
      table(token) {
        return '<div class="doc-table">' + defaults.table.call(this, token) + "</div>\n";
      },
      tablecell(token) {
        const html = defaults.tablecell.call(this, token);
        return token.textColumn ? html.replace(">", ' class="doc-text-col">') : html;
      },
    },
  });

  // Each outlined heading token carries its own attribute value, so the
  // renderer reads nothing shared.
  function parse(markdown, mark) {
    const tokens = layout.lexer(markdown);
    const outline = [];
    layout.walkTokens(tokens, function (token) {
      if (token.type === "table") markTextColumns(token);
      if (token.type !== "heading" || token.depth > 3) return;
      if (mark) token.outlineMark = mark + "-" + outline.length;
      outline.push({ depth: token.depth, text: inlineText(token.tokens, headingText).replace(/\s+/g, " ").trim() });
    });
    return { html: layout.parser(tokens), outline };
  }

  function shownMode(state, fieldCount, outlineCount) {
    return !state || (fieldCount === 0 && outlineCount === 0) ? "none" : state.mode;
  }

  function release(moved, drag) {
    if (!moved) return null;
    return drag.collapsed ? { action: "close" } : { action: "resize", width: drag.width };
  }

  function geometry(state, cardWidth, drag) {
    const panel = !drag ? state.width : drag.collapsed ? 0 : drag.width;
    const strip = { textWidth: cardWidth - state.strip, offset: state.strip, panel: 0 };
    switch (state.mode) {
      case "strip":
        return strip;
      case "docked":
        return panel > 0 ? { textWidth: cardWidth - panel - state.grip, offset: panel + state.grip, panel } : strip;
      case "overlay":
        return Object.assign(strip, { panel });
      default:
        return { textWidth: cardWidth, offset: 0, panel: 0 };
    }
  }

  // The outline index of the last tick at or before `current`, or -1.
  function lit(ticks, current) {
    let last = -1;
    ticks.forEach(function (tick) {
      if (tick <= current) last = tick;
    });
    return last;
  }

  globalThis.tarmacDocLayout = {
    render(markdown) {
      return parse(markdown, "").html;
    },
    textColumns,
    parse,
    // A null top is a heading the render did not mark: never current.
    currentSection(tops, scrollTop, viewHeight, scrollHeight, zoom) {
      const marked = [];
      tops.forEach(function (top, index) {
        if (top !== null) marked.push(index);
      });
      if (marked.length === 0) return -1;
      if (scrollHeight > viewHeight + 1 && scrollTop + viewHeight >= scrollHeight - 1) return marked[marked.length - 1];
      const line = scrollTop + 24 * zoom;
      let current = marked[0];
      marked.forEach(function (index) {
        if (tops[index] <= line) current = index;
      });
      return current;
    },
    dragWidth(startWidth, deltaScreen, zoom, direction, minWidth, maxWidth) {
      const width = startWidth + (direction * deltaScreen) / zoom;
      const collapsed = width < minWidth;
      return { width: collapsed ? width : Math.min(width, maxWidth), collapsed };
    },
    shownMode,
    geometry,
    release,
    // `moved`: the pointer moved during this press. A pointer back at its
    // start has not moved either. A reported width is kept until the app
    // answers the report.
    dragEnd(moved, delta, drag) {
      const report = release(moved && delta !== 0, drag);
      return { report, drag: report ? drag : null };
    },
    // Only the app's answer to an action ends a released drag; a layout (a
    // zoom, a card resize) keeps it, and a held drag goes on.
    dragOnState(dragging, drag, fromAction) {
      return !dragging && fromAction ? null : drag;
    },
    sameDrag(previous, next) {
      return previous !== null && previous.width === next.width && previous.collapsed === next.collapsed;
    },
    side(state) {
      return state !== null && typeof state === "object" && state.side === "right" ? "right" : "left";
    },
    direction(side) {
      return side === "right" ? -1 : 1;
    },
    strip(fieldCount, outline, current) {
      const icons = [];
      if (fieldCount > 0) icons.push("fields");
      if (outline.length > 0) icons.push("outline");
      const ticks = [];
      outline.forEach(function (entry, index) {
        if (entry.depth <= 2) ticks.push(index);
      });
      // `section`: what a new render's panel shows first.
      return { icons, ticks, lit: lit(ticks, current), section: icons.length ? icons[0] : null };
    },
    lit,
    // `scroll` says when the panel scrolls to the section: once the app's
    // state opens it, now, or not at all.
    iconClick(mode, section, icon) {
      if (mode === "strip") return { post: "open", section: icon, scroll: "onOpen" };
      if (mode !== "overlay") return { post: null, section, scroll: null };
      if (icon === section) return { post: "close", section, scroll: null };
      return { post: null, section: icon, scroll: "now" };
    },
    // Any state ends the wait; one that shows the panel shows the section.
    sectionOnState(pending, panelShown) {
      return pending && panelShown;
    },
    activeIcon(mode, section) {
      return mode === "overlay" ? section : null;
    },
    // The strip shows unless a docked panel covers its place; a collapsed
    // drag has no panel. The panel starts from the sidebar's outer edge.
    parts(mode, box, state) {
      return {
        strip: mode !== "none" && !(mode === "docked" && box.panel > 0),
        panel: box.panel > 0,
        panelStart: mode === "overlay" ? state.strip : 0,
        grip: state.resizable && box.panel > 0,
      };
    },
    pressOnText(mode) {
      return mode === "overlay" ? "close" : null;
    },
    scrollTarget(headingTop, viewHeight, scrollHeight, zoom) {
      if (headingTop === null) return null;
      return Math.min(Math.max(headingTop - 8 * zoom, 0), Math.max(0, scrollHeight - viewHeight));
    },
  };
})();
