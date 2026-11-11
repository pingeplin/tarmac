// Console-capture + escape-hatch + zoom + scroll-report + default-scheme +
// font-properties shim for sandboxed HTML doc cards (specs 2607.0004,
// 2607.0006, 2610.0003, 2610.0007, 2610.0010, 2610.0011). Placed
// by CardProtocol.respond in every tarmac-card:// response after the file's
// leading doctype, so it runs before any author script and observes
// console/error/escape activity from the very first line of card script. Must
// never throw or break the host page — every path here is defensive.
(function () {
  // Filled with the user's fonts per request (CardFontVariables.filling); the
  // file as it stands is valid JavaScript and holds none.
  var bootFonts = [/*tarmac-fonts*/][0];

  // The default colour scheme (spec 2610.0007): a card follows the appearance
  // unless its author states a scheme. A meta is the weakest statement there
  // is, so a color-scheme in the author's CSS wins with no code here. But the
  // first such meta in the tree is the one read, so this one leaves when the
  // author's is parsed: the observer's callback runs before the next paint.
  try {
    var defaultScheme = document.createElement("meta");
    defaultScheme.name = "color-scheme";
    defaultScheme.content = "light dark";
    document.head.appendChild(defaultScheme);
    var authorScheme = new MutationObserver(function () {
      var stated = document.querySelectorAll('meta[name="color-scheme" i]');
      for (var i = 0; i < stated.length; i++) {
        if (stated[i] !== defaultScheme) {
          defaultScheme.remove();
          authorScheme.disconnect();
          return;
        }
      }
    });
    authorScheme.observe(document.documentElement, { childList: true, subtree: true });
    document.addEventListener("DOMContentLoaded", function () {
      authorScheme.disconnect();
    });
  } catch (e) {
    // A document with no default scheme is the one it was before.
  }

  // The card is kept out of sight until its document has started, which is
  // now: what there is to see before that is white, and this document
  // may be dark. Said here, and not at the end of the load: a document that
  // stops its own load never ends it.
  try {
    window.parent.postMessage({ tarmac: "started", source: location.href }, "*");
  } catch (e) {
    // The host page counts a frame that has loaded as started.
  }

  // The user's fonts (spec 2610.0010) are custom properties of one rule in a
  // constructed stylesheet. The inline style of the root would drop an
  // author's <html style>, and a <style> element would come before the
  // author's own, whose :root rule would then win.
  var fontStyle = null;

  function applyFonts(vars) {
    try {
      if (!vars || typeof vars !== "object" || Array.isArray(vars)) return;
      if (!fontStyle) {
        var sheet = new CSSStyleSheet();
        sheet.replaceSync(":root{}");
        document.adoptedStyleSheets = document.adoptedStyleSheets.concat(sheet);
        fontStyle = sheet.cssRules[0].style;
      }
      Object.keys(vars).forEach(function (name) {
        if (name.indexOf("--tarmac-") === 0 && typeof vars[name] === "string") {
          fontStyle.setProperty(name, vars[name]);
        }
      });
    } catch (e) {
      // A page without the properties is the page it was.
    }
  }

  applyFonts(bootFonts);

  function safeSerialize(args) {
    return Array.prototype.map.call(args, serializeOne);
  }

  function serializeOne(v) {
    try {
      if (v === null || v === undefined) return v;
      var t = typeof v;
      if (t === "string" || t === "number" || t === "boolean") return v;
      if (t === "function" || t === "symbol" || t === "bigint") return String(v);
      if (typeof Node !== "undefined" && v instanceof Node) {
        return "[" + (v.nodeName || "NODE") + "]";
      }
      var seen = new Set();
      return JSON.parse(
        JSON.stringify(v, function (_key, val) {
          if (typeof val === "object" && val !== null) {
            if (seen.has(val)) return "[circular]";
            seen.add(val);
          }
          if (typeof val === "function" || typeof val === "symbol" || typeof val === "bigint") {
            return String(val);
          }
          return val;
        }),
      );
    } catch (e) {
      return "[unserializable]";
    }
  }

  function relay(level, args) {
    try {
      window.parent.postMessage({ tarmac: "console", level: level, args: safeSerialize(args) }, "*");
    } catch (e) {
      // Never let a relay failure break the card.
    }
  }

  var originals = {};
  ["log", "info", "warn", "error"].forEach(function (level) {
    originals[level] = console[level] ? console[level].bind(console) : function () {};
    console[level] = function () {
      try {
        originals[level].apply(console, arguments);
      } catch (e) {
        // ignore
      }
      relay(level, Array.prototype.slice.call(arguments));
    };
  });

  window.addEventListener("error", function (e) {
    try {
      relay("error", [e && e.message ? e.message : String(e)]);
    } catch (err) {
      // ignore
    }
  });

  window.addEventListener("unhandledrejection", function (e) {
    try {
      var reason = e && "reason" in e ? e.reason : e;
      relay("error", [reason]);
    } catch (err) {
      // ignore
    }
  });

  window.addEventListener("keydown", function (e) {
    try {
      if (e.key === "Escape") {
        window.parent.postMessage({ tarmac: "escape" }, "*");
      }
    } catch (err) {
      // ignore
    }
  });

  // Scheduler gate (spec 2609.0002): the board pauses a culled card's
  // schedulers. The natives are captured HERE — at load, before any card script
  // runs — so the resume path can never route through the gate's own wrappers,
  // and a card that overwrites a scheduler global cannot break resume.
  var nativeRaf = window.requestAnimationFrame.bind(window);
  var nativeCancelRaf = window.cancelAnimationFrame.bind(window);
  var nativeSetTimeout = window.setTimeout.bind(window);
  var nativeClearTimeout = window.clearTimeout.bind(window);
  var nativeSetInterval = window.setInterval.bind(window);

  var paused = false;
  // rAF needs its own id space: a call made while paused never reaches the
  // native, so there is no native id to hand back — yet cancelAnimationFrame
  // must still accept what we returned. The timers need none; both always reach
  // their native at call time, so both return the native id directly.
  var rafSeq = 0;
  var rafHeld = {}; // shim id -> { cb, nativeId | null }
  var timeoutHeld = {}; // native timeout id -> { cb, args }
  var catchUpId = null; // the single native frame a resume issues

  function idsAscending(held) {
    var out = [];
    for (var k in held) out.push(Number(k));
    return out.sort(function (a, b) {
      return a - b;
    });
  }

  function runHeld(fn, args) {
    // One throwing callback must not strand the rest of the flush — the native
    // schedulers isolate callbacks by running each in its own task. It must
    // still be REPORTED, though: the live path lets a throw reach window.onerror
    // and the error relay, and swallowing it here would make a card's exception
    // vanish precisely when the callback happened to be flushed after a cull.
    try {
      fn.apply(null, args);
    } catch (e) {
      relay("error", [e && e.message ? e.message : String(e)]);
    }
  }

  function pauseSchedulers() {
    if (paused) return;
    paused = true;
    if (catchUpId !== null) {
      nativeCancelRaf(catchUpId);
      catchUpId = null;
    }
    // Cancelling, not merely holding, is the load-bearing half: an outstanding
    // request the engine never services still costs the page a standing charge
    // until WebKit's next 10 s tick for a non-visible frame.
    var ids = idsAscending(rafHeld);
    for (var i = 0; i < ids.length; i++) {
      var e = rafHeld[ids[i]];
      if (e.nativeId !== null) {
        nativeCancelRaf(e.nativeId);
        e.nativeId = null;
      }
    }
  }

  function resumeSchedulers() {
    if (!paused) return;
    paused = false;
    flushTimeouts();
    flushFrames();
  }

  function flushTimeouts() {
    var ids = idsAscending(timeoutHeld);
    if (ids.length === 0) return;
    // A native hop, so card code never runs re-entrantly inside the shim's own
    // message listener.
    nativeSetTimeout(function () {
      for (var i = 0; i < ids.length; i++) {
        var e = timeoutHeld[ids[i]];
        if (!e || paused) continue; // cleared, or culled again mid-flush
        delete timeoutHeld[ids[i]];
        runHeld(e.cb, e.args);
      }
    }, 0);
  }

  function flushFrames() {
    var ids = idsAscending(rafHeld);
    if (ids.length === 0) return;
    // One catch-up frame for the whole queue — the card sees one frame, not one
    // per frame missed.
    catchUpId = nativeRaf(function (ts) {
      catchUpId = null;
      for (var i = 0; i < ids.length; i++) {
        var e = rafHeld[ids[i]];
        if (!e || paused) continue;
        delete rafHeld[ids[i]];
        runHeld(e.cb, [ts]);
      }
    });
  }

  function gatedRaf(cb) {
    var id = ++rafSeq;
    if (paused) {
      rafHeld[id] = { cb: cb, nativeId: null };
      return id;
    }
    rafHeld[id] = {
      cb: cb,
      nativeId: nativeRaf(function (ts) {
        delete rafHeld[id];
        cb(ts);
      }),
    };
    return id;
  }

  function gatedCancelRaf(id) {
    var e = rafHeld[id];
    if (!e) return;
    delete rafHeld[id];
    if (e.nativeId !== null) nativeCancelRaf(e.nativeId);
  }

  function gatedSetTimeout(cb, delay) {
    if (typeof cb !== "function") return nativeSetTimeout(cb, delay);
    var extra = Array.prototype.slice.call(arguments, 2);
    // Gated at FIRE time, not call time: a timeout armed before the cull is
    // still outstanding across it, and a culled frame's timers are throttled to
    // ~1 Hz rather than stopped — so a call-time gate would run card code while
    // the card is paused.
    var id = nativeSetTimeout(function () {
      if (paused) {
        timeoutHeld[id] = { cb: cb, args: extra };
        return;
      }
      cb.apply(null, extra);
    }, delay);
    return id;
  }

  function gatedClearTimeout(id) {
    delete timeoutHeld[id];
    nativeClearTimeout(id);
  }

  function gatedSetInterval(cb, delay) {
    if (typeof cb !== "function") return nativeSetInterval(cb, delay);
    var extra = Array.prototype.slice.call(arguments, 2);
    // Ticks missed during a pause are dropped, never queued: an interval is a
    // cadence, and flushing N of them on resume is the frame storm this gate
    // exists to avoid. The native keeps ticking so its id stays clearable.
    return nativeSetInterval(function () {
      if (paused) return;
      cb.apply(null, extra);
    }, delay);
  }

  window.requestAnimationFrame = gatedRaf;
  window.cancelAnimationFrame = gatedCancelRaf;
  window.setTimeout = gatedSetTimeout;
  window.clearTimeout = gatedClearTimeout;
  window.setInterval = gatedSetInterval;
  // clearInterval is deliberately not wrapped: an interval holds no shim-side
  // state, so the native one is already correct.

  // Magnify zoom mode (spec 2607.0006), frozen-K per docs/designs/2608.0001:
  // the host posts exactly one root zoom per document load, in reply to ready.
  var pendingZoom = null;
  var ready = false;

  function applyZoom(z) {
    try {
      document.documentElement.style.zoom = z;
    } catch (e) {
      // ignore
    }
  }

  function readMeta() {
    try {
      var el = document.querySelector('meta[name="tarmac-zoom"]');
      return el ? el.content || "" : null;
    } catch (e) {
      return null;
    }
  }

  window.addEventListener("message", function (e) {
    try {
      // Only the host drives zoom, the cull, the scroll and the fonts: a nested
      // iframe or the card posting at its own window must not. Origin is never
      // asserted — this document is opaque-origin, so the host's origin string
      // is not stable.
      if (e.source !== window.parent) return;
      var d = e.data;
      if (!d) return;
      // A state, not a toggle — the host re-asserts it on every ready, and must
      // not have to know whether that is redundant. Anything but a real boolean
      // leaves the gate exactly where it was.
      if (d.tarmac === "cull") {
        if (d.culled === true) pauseSchedulers();
        else if (d.culled === false) resumeSchedulers();
        return;
      }
      // Applied at once, even before the document is parsed: unlike the zoom
      // it waits for nothing, and it sets no timer a culled card would hold.
      if (d.tarmac === "fonts") {
        applyFonts(d.vars);
        return;
      }
      // The scroll thumb is being dragged: the root goes where the host says,
      // at once. Nothing but a finite number is a position.
      if (d.tarmac === "scrollTo") {
        if (typeof d.y === "number" && isFinite(d.y)) {
          window.scrollTo({ left: window.scrollX, top: d.y, behavior: "instant" });
        }
        return;
      }
      if (d.tarmac !== "zoom") return;
      if (ready) applyZoom(d.z);
      else pendingZoom = d.z;
    } catch (err) {
      // ignore
    }
  });

  // Where the root is scrolled to, for the card's scroll thumb. Posted as the
  // event happens: no frame is asked for and no timer set, so a culled card
  // schedules nothing for it. In quirks mode there is no scrolling element before
  // the body exists, or while the body is itself scrollable, and there is nothing
  // to say.
  function postScroll() {
    try {
      var root = document.scrollingElement;
      if (!root) return;
      window.parent.postMessage(
        { tarmac: "scrolled", offset: window.scrollY, visible: root.clientHeight, total: root.scrollHeight },
        "*"
      );
    } catch (e) {
      // ignore
    }
  }

  // Captured: a nested scroller's event does not bubble, and is not the root's.
  document.addEventListener("scroll", function (e) {
    if (e.target === document) postScroll();
  }, true);
  window.addEventListener("resize", postScroll);
  // The root's size changes when the zoom lands and when content grows, with
  // no scroll to say so.
  if (typeof ResizeObserver === "function") {
    try {
      new ResizeObserver(postScroll).observe(document.documentElement);
    } catch (e) {
      // ignore
    }
  }

  // Publish the declaration, exactly once per document load. Nothing is
  // measured first: the macOS 26 floor decides zoom capability, so there is no
  // layout to wait for and a card loading inside a display:none board posts
  // here like any other (docs/designs/2608.0001, "Capability").
  function postReady() {
    if (ready) return;
    ready = true;
    // The host posts zoom in reply to ready, so pendingZoom is normally empty;
    // it catches a zoom aimed at a previous load that crosses a reload in
    // flight.
    if (pendingZoom !== null) applyZoom(pendingZoom);
    try {
      // The card draws the root's scroll position itself.
      document.documentElement.style.scrollbarWidth = "none";
      window.parent.postMessage({ tarmac: "ready", meta: readMeta() }, "*");
    } catch (e) {
      // ignore
    }
  }

  document.addEventListener("DOMContentLoaded", postReady);
})();
