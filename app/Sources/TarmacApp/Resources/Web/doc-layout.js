(function () {
  globalThis.tarmacDocLayout = {
    render(markdown) {
      return marked.parse(markdown, { async: false });
    },
    textColumns(table) {
      return [];
    },
  };
})();
