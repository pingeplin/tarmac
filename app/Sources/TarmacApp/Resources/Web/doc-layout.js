// The markdown doc card's layout rules (spec 2611.0021). It touches no DOM, so
// XCTest runs it as shipped in a bare JavaScriptCore context after marked.
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
        if (token.type === "codespan") return "";
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

  const defaults = marked.Renderer.prototype;
  const layout = new marked.Marked();
  layout.use({
    renderer: {
      table(token) {
        textColumns(token).forEach(function (text, column) {
          if (!text) return;
          token.header[column].textColumn = true;
          token.rows.forEach(function (row) {
            row[column].textColumn = true;
          });
        });
        return '<div class="doc-table">' + defaults.table.call(this, token) + "</div>\n";
      },
      tablecell(token) {
        const html = defaults.tablecell.call(this, token);
        return token.textColumn ? html.replace(">", ' class="doc-text-col">') : html;
      },
    },
  });

  globalThis.tarmacDocLayout = {
    render(markdown) {
      return layout.parse(markdown, { async: false });
    },
    textColumns,
  };
})();
