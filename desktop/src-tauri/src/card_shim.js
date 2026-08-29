// Console-capture + escape-hatch + zoom shim for sandboxed HTML doc cards
// (specs 2607.0004, 2607.0006). Prepended by card_protocol.rs to every
// tarmac-card:// response, strictly before the file's own bytes, so it
// observes console/error/escape activity from the very first line of card
// script. Must never throw or break the host page — every path here is
// defensive.
(function () {
  function safeSerialize(args) {
    var out = [];
    for (var i = 0; i < args.length; i++) {
      out.push(serializeOne(args[i]));
    }
    return out;
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
      var seen = [];
      return JSON.parse(
        JSON.stringify(v, function (_key, val) {
          if (typeof val === "object" && val !== null) {
            if (seen.indexOf(val) !== -1) return "[circular]";
            seen.push(val);
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
      // Only the host drives zoom: a nested iframe or the card posting at its
      // own window must not. Origin is never asserted — this document is
      // opaque-origin, so the host's origin string is not stable.
      if (e.source !== window.parent) return;
      var d = e.data;
      if (!d) return;
      // The shield swallows wheel before it can reach this document, so the host
      // relays the delta instead — reading is not the "touch" the shield exists
      // to block. Deltas arrive already converted to this document's own units.
      if (d.tarmac === "scroll") {
        window.scrollBy(d.dx, d.dy);
        return;
      }
      if (d.tarmac !== "zoom") return;
      if (ready) applyZoom(d.z);
      else pendingZoom = d.z;
    } catch (err) {
      // ignore
    }
  });

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
      window.parent.postMessage({ tarmac: "ready", meta: readMeta() }, "*");
    } catch (e) {
      // ignore
    }
  }

  document.addEventListener("DOMContentLoaded", postReady);
})();
