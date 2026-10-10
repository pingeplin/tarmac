// The HTML card host page's script. It carries, and bounds the size of what
// it carries: what a message means is the app's to decide. Its own word to
// the app is that the card's document is on screen. It runs in the
// app's own content world, so the card's document has no handle on the
// message handler it posts to.
(function () {
  const card = document.getElementById("card");

  // The app keeps this many characters of a console line (`CardConsole`).
  // Receiving a message costs the app's main thread in proportion to its
  // size, and a card can send megabytes hundreds of times over: so what the
  // app would cut is cut here, before it crosses.
  const lineCap = 1000;

  // `text` up to its first `room` characters, never half of a surrogate
  // pair, and the length of what follows them. That length is the string's
  // own, in UTF-16 units: walking a megabyte to count it would cost the page
  // what the cut saves the app.
  function cut(text, room) {
    if (text.length <= room) return { head: text, kept: text.length, dropped: 0 };
    let end = 0;
    let kept = 0;
    while (kept < room && end < text.length) {
      end += text.codePointAt(end) > 0xffff ? 2 : 1;
      kept += 1;
    }
    return { head: text.slice(0, end), kept, dropped: text.length - end };
  }

  // A console entry's args as far as the first `lineCap` characters of the
  // line the app shows — each arg as text, a space between two — and the
  // count of the characters after them.
  function cutArgs(args) {
    const kept = [];
    let room = lineCap;
    let dropped = 0;
    for (const arg of args) {
      const text = typeof arg === "string" ? arg : JSON.stringify(arg) ?? String(arg);
      const part = cut(text, Math.max(room, 0));
      if (room > 0) kept.push(part.dropped === 0 ? arg : part.head);
      dropped += part.dropped + (room > 0 ? 0 : 1);
      room -= part.kept + 1;
    }
    return { args: kept, dropped };
  }

  function small(value) {
    const text = JSON.stringify(value);
    return text === undefined || text.length <= lineCap;
  }

  // What is posted to the app for `data`, or undefined for nothing: never
  // more than a console line's worth. A console entry is rebuilt, so the
  // count of what was cut is this page's and not the card's.
  function carried(data) {
    if (data === null || typeof data !== "object") return undefined;
    // This page's own word: a card cannot say that it is on screen.
    if (data.tarmac === "shown") return undefined;
    if (data.tarmac !== "console" || !Array.isArray(data.args)) return small(data) ? data : undefined;
    if (!small(data.level)) return undefined;
    return { tarmac: "console", level: data.level, ...cutArgs(data.args) };
  }

  // The app keeps this page out of sight from the moment it gives the frame
  // a source until it is told that the document is on screen. Before
  // that there is white to see, while the document may be dark: this page
  // for a frame or two before it is first drawn, then the frame with no
  // document in it. `asked` is the app's number for the source the frame
  // was last given, `started` the last one whose document has started, and
  // `replaced` the source the frame had before this one.
  let asked = 0;
  let started = 0;
  let source = null;
  let replaced = null;

  // Two frames, measured: the first is drawn with the document in it, and a
  // word posted in the second reaches the app after that drawing has. Told
  // at once, 4 opens of 5 still showed one white frame; one frame later, 2
  // of 5; two frames later, none of 15. A source that was replaced while its
  // frames were awaited is not told of: the app waits for the new one. The
  // app can know of a newer source than this page does, so the word names
  // its load and the app decides.
  function documentStarted() {
    if (started === asked) return;
    started = asked;
    const load = asked;
    requestAnimationFrame(function () {
      requestAnimationFrame(function () {
        if (load === asked) webkit.messageHandlers.card.postMessage({ tarmac: "shown", load: load });
      });
    });
  }

  // What is served for a file that cannot be read carries no shim and says
  // nothing, so a frame that has loaded counts as started. A document that
  // stops its own load never fires this, and its shim has spoken.
  card.addEventListener("load", documentStarted);

  window.addEventListener("message", function (event) {
    // Only this card's own document is heard.
    if (event.source !== card.contentWindow) return;
    try {
      // The shim's first word is for this page alone. The document that the
      // frame had before can say it after the frame was given the next one.
      if (event.data !== null && typeof event.data === "object" && event.data.tarmac === "started") {
        if (event.data.source !== replaced) documentStarted();
        return;
      }
      const message = carried(event.data);
      if (message !== undefined) webkit.messageHandlers.card.postMessage(message);
    } catch (error) {
      // A payload that cannot be measured or carried is not a Tarmac message.
    }
  });

  window.tarmacCard = {
    load(src, number) {
      asked = number;
      replaced = source;
      source = src;
      card.src = src;
    },
    post(message) {
      card.contentWindow.postMessage(message, "*");
    },
    layout(width, height, scale) {
      card.style.width = width + "px";
      card.style.height = height + "px";
      card.style.transform = scale === 1 ? "" : "scale(" + scale + ")";
    },
    focus() {
      card.focus();
    },
  };
})();
