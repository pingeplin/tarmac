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

  // The text a reader reads as prose; inline code is not.
  function prose(tokens) {
    return tokens
      .map(function (token) {
        if (token.tokens) return prose(token.tokens);
        if (token.type === "text" || token.type === "escape") return token.text;
        if (token.type === "br") return " ";
        return "";
      })
      .join("");
  }

  // marked pads and cuts every body row to the header's length, so a row
  // always has cell `column`.
  function textColumns(table) {
    return table.header.map(function (_, column) {
      return table.rows.some(function (row) {
        return width(prose(row[column].tokens).trim()) >= textColumnWidth;
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

  // marked gives an escape's and a code span's text as written, entities and
  // all; only a text token's entities are decoded.
  function plain(tokens) {
    return tokens
      .map(function (token) {
        if (token.type === "escape" || token.type === "codespan") return token.text;
        if (token.type === "image") return "";
        if (token.tokens) return plain(token.tokens);
        if (token.type === "text") return decode(token.text);
        if (token.type === "br") return " ";
        return "";
      })
      .join("");
  }

  // walkTokens runs over the whole doc before any token is rendered.
  let outline = [];
  let mark = "";

  const defaults = marked.Renderer.prototype;
  const layout = new marked.Marked();
  layout.use({
    walkTokens(token) {
      if (token.type === "heading" && token.depth <= 3) {
        token.outlineIndex = outline.length;
        outline.push({ depth: token.depth, text: plain(token.tokens).replace(/\s+/g, " ").trim() });
      }
      if (token.type !== "table") return;
      // Marked before any cell is rendered: a cell's renderer is not told its column.
      textColumns(token).forEach(function (text, column) {
        if (!text) return;
        [token.header].concat(token.rows).forEach(function (row) {
          row[column].textColumn = true;
        });
      });
    },
    renderer: {
      heading(token) {
        const html = defaults.heading.call(this, token);
        if (!mark || token.outlineIndex === undefined) return html;
        return html.replace("<h" + token.depth, "<h" + token.depth + ' data-outline="' + mark + "-" + token.outlineIndex + '"');
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

  function parse(markdown, renderMark) {
    outline = [];
    mark = renderMark;
    const html = layout.parse(markdown, { async: false });
    return { html, outline };
  }

  function shownMode(state, fieldCount, outlineCount) {
    return fieldCount === 0 && outlineCount === 0 ? "none" : state.mode;
  }

  function geometry(state, cardWidth, drag) {
    const strip = { textWidth: cardWidth - state.strip, offset: state.strip, panel: 0 };
    function docked(width) {
      return { textWidth: cardWidth - width - state.grip, offset: width + state.grip, panel: width };
    }
    switch (state.mode) {
      case "strip":
        return strip;
      case "docked":
        if (!drag) return docked(state.width);
        return drag.collapsed ? strip : docked(drag.width);
      case "overlay":
        return Object.assign(strip, { panel: !drag ? state.width : drag.collapsed ? 0 : drag.width });
      default:
        return { textWidth: cardWidth, offset: 0, panel: 0 };
    }
  }

  globalThis.tarmacDocLayout = {
    render(markdown) {
      return parse(markdown, "").html;
    },
    textColumns,
    parse,
    currentSection(tops, scrollTop, viewHeight, scrollHeight, zoom) {
      if (tops.length === 0) return -1;
      if (scrollHeight > viewHeight + 1 && scrollTop + viewHeight >= scrollHeight - 1) return tops.length - 1;
      const line = scrollTop + 24 * zoom;
      let current = 0;
      tops.forEach(function (top, index) {
        if (top <= line) current = index;
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
    release(moved, drag) {
      if (!moved) return null;
      return drag.collapsed ? { action: "close" } : { action: "resize", width: drag.width };
    },
    strip(fieldCount, outline, current) {
      const icons = [];
      if (fieldCount > 0) icons.push("fields");
      if (outline.length > 0) icons.push("outline");
      const ticks = [];
      outline.forEach(function (entry, index) {
        if (entry.depth <= 2) ticks.push(index);
      });
      const lit = ticks.filter(function (tick) {
        return tick <= current;
      });
      return { icons, ticks, lit: lit.length ? lit[lit.length - 1] : -1 };
    },
    iconClick(mode, section, icon) {
      if (mode === "strip") return { post: "open", section: icon };
      if (mode === "overlay" && icon === section) return { post: "close", section };
      return { post: null, section: mode === "overlay" ? icon : section };
    },
    // The strip shows unless a docked panel covers its place; a collapsed
    // drag has no panel.
    parts(mode, box, state) {
      return {
        strip: mode !== "none" && !(mode === "docked" && box.panel > 0),
        panelLeft: mode === "overlay" ? state.strip : 0,
        grip: state.resizable && box.panel > 0,
      };
    },
    pressOnText(mode) {
      return mode === "overlay" ? "close" : null;
    },
    scrollTarget(headingTop, viewHeight, scrollHeight, zoom) {
      return Math.min(Math.max(headingTop - 8 * zoom, 0), Math.max(0, scrollHeight - viewHeight));
    },
  };
})();
