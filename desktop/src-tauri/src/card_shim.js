// Console-capture + escape-hatch shim for sandboxed HTML doc cards (spec
// 2607.0004). Prepended by card_protocol.rs to every tarmac-card:// response,
// strictly before the file's own bytes, so it observes console/error/escape
// activity from the very first line of card script. Must never throw or break
// the host page — every path here is defensive.
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
})();
