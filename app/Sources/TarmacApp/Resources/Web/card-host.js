// The HTML card host page's script. It carries, and bounds the size of what
// it carries: what a message means is the app's to decide. It runs in the
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
    if (data.tarmac !== "console" || !Array.isArray(data.args)) return small(data) ? data : undefined;
    if (!small(data.level)) return undefined;
    return { tarmac: "console", level: data.level, ...cutArgs(data.args) };
  }

  window.addEventListener("message", function (event) {
    // Only this card's own document is heard.
    if (event.source !== card.contentWindow) return;
    try {
      const message = carried(event.data);
      if (message !== undefined) webkit.messageHandlers.card.postMessage(message);
    } catch (error) {
      // A payload that cannot be measured or carried is not a Tarmac message.
    }
  });

  window.tarmacCard = {
    load(src) {
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
