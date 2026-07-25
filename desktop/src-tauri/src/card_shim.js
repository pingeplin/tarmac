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

  // Magnify zoom mode (spec 2607.0006). Mirrored as ZOOM_PROBE_FACTOR in
  // kit/zoomMode.ts — the two must be kept in sync.
  var ZOOM_PROBE_FACTOR = 2;
  // Not a backstop against layout that never arrives — per tryReady below, a
  // silent observer never retriggers a probe, so that case costs exactly one.
  // What it bounds is pathological repeated deliveries: a root resizing among
  // zero-ish widths before it settles, under the never-re-observe shape below.
  var MAX_PROBES = 16;
  var probes = 0;
  var pendingZoom = null;
  var ready = false;

  function applyZoom(z) {
    try {
      document.documentElement.style.zoom = z;
    } catch (e) {
      // ignore
    }
  }

  // Mutate → read → restore synchronously in one task: no paint happens
  // between synchronous style writes, so the probe cannot flash. overflow is
  // pinned across both reads so an appearing scrollbar cannot perturb them.
  // The throwaway element is never itself zoomed: absolutely positioned with
  // no positioned ancestor, it resolves against the initial containing block,
  // so width:100% measures the ICB in local layout units — the space wrap
  // points live in — independent of compat mode (every tarmac-card:// document
  // is quirks mode). One narrow exception: a card that makes html itself a
  // containing block AND fixes its width traps the probe against html's own
  // padding box and reads ratio 1.0, so magnify stays off — it fails closed.
  // Root zoom is applied and it is re-read to see whether that ICB was
  // divided: layout, not rendering. cssText round-trips the whole inline style
  // because overflow is a shorthand and priority is invisible to the getter,
  // so a property-wise restore would delete a card's overflow-x.
  function probeZoom() {
    var root = document.documentElement;
    var priorCss = root.style.cssText;
    var el = document.createElement("div");
    el.style.cssText = "position:absolute;left:0;top:0;width:100%;height:0;visibility:hidden";
    root.appendChild(el);
    try {
      root.style.overflow = "hidden";
      var base = el.offsetWidth;
      root.style.zoom = ZOOM_PROBE_FACTOR;
      var zoomed = el.offsetWidth;
      return { base: base, zoomed: zoomed };
    } finally {
      root.style.cssText = priorCss;
      el.remove();
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
      if (!d || d.tarmac !== "zoom") return;
      if (ready) applyZoom(d.z);
      else pendingZoom = d.z;
    } catch (err) {
      // ignore
    }
  });

  // Publish the verdict, exactly once per document load.
  function postReady(probe) {
    if (ready) return;
    ready = true;
    // The settle and the document load race; the retained value wins. It is
    // applied after the probe, which must measure an unzoomed root.
    if (pendingZoom !== null) applyZoom(pendingZoom);
    try {
      window.parent.postMessage({ tarmac: "ready", meta: readMeta(), probe: probe }, "*");
    } catch (e) {
      // ignore
    }
  }

  // True once the verdict is settled. A document that loads on a non-active
  // board sits inside display:none and has no layout, so a clean base of 0
  // means "not measurable yet", not "incapable": the host honors only the
  // first ready per load, so posting that verdict would strand the card in
  // reveal for the life of the document. It waits for layout instead — one
  // that never comes means the card was never visible. A probe that THROWS is
  // the opposite case and is terminal: answer it now with a fail-closed
  // {0, 0}, which still emits a capability line, because retrying a throwing
  // probe never terminates.
  function tryReady() {
    if (ready) return true;
    var probe;
    probes++;
    try {
      probe = probeZoom();
    } catch (e) {
      postReady({ base: 0, zoomed: 0 });
      return true;
    }
    if (probe.base > 0 || probes >= MAX_PROBES) {
      postReady(probe);
      return true;
    }
    return false;
  }

  // No requestAnimationFrame fallback: ResizeObserver is universally present
  // on the macOS 14+ WKWebView floor, and WebKit services rAF at ~22 fps
  // inside a display:none iframe, so any bounded poll expires while hidden and
  // strands the card. Without ResizeObserver the card stays in reveal.
  //
  // The callback is a SIGNAL only, under two rules that a 48-load matrix (4
  // card styles × reveal/never-reveal × 3 runs × both engines) settled:
  //
  // Never re-observe while waiting. A fresh observe() on a non-rendered root
  // re-delivers every frame, which burns the attempt cap and posts {0, 0} while
  // the card is still hidden (~240 ms) — stranding it in reveal for the life of
  // the document. So the observer stays armed and is disconnected only once the
  // verdict is settled, cap exhaustion included.
  //
  // Hop the probe out of the delivery cycle. Layout mutated *during* delivery
  // makes the engine raise "ResizeObserver loop completed with undelivered
  // notifications", which this shim's own error listener relays into the card's
  // console strip as a phantom "Script error." attributed to the card's own JS.
  // A microtask is not far enough — microtasks drain inside the delivery loop —
  // so the hop is a one-shot setTimeout(…, 0): a single macrotask per delivery,
  // not the bounded poll rejected above. The probe body stays synchronous
  // inside that callback, so mutate → read → restore is still one task and
  // still cannot flash. Measured: zero relayed errors and a correct verdict in
  // all 16 cells, against 1 relay per hidden load on WebKit when the probe runs
  // inside delivery, and 14–31 per load for disconnect-then-re-observe (which
  // also introduces the error on Chromium).
  function waitForLayout() {
    try {
      var ro = new ResizeObserver(function () {
        try {
          setTimeout(function () {
            try {
              if (tryReady()) ro.disconnect();
            } catch (e) {
              // ignore
            }
          }, 0);
        } catch (e) {
          // ignore
        }
      });
      ro.observe(document.documentElement);
    } catch (e) {
      // ignore
    }
  }

  document.addEventListener("DOMContentLoaded", function () {
    try {
      if (!tryReady()) waitForLayout();
    } catch (e) {
      // ignore
    }
  });
})();
