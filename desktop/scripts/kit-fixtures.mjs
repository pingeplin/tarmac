// Hand-authored sample props for the 10 in-scope kit components, used by
// build-kit.mjs to generate each components/<name>/index.html preview. Fixtures
// are split into `props` (plain JSON-serializable data, embedded verbatim as a
// JS object literal) and `fns` (a map of prop name -> function SOURCE TEXT,
// spliced onto the props object in the page's inline <script> since functions
// cannot round-trip through JSON). Kept out of desktop/src/ — these are build
// tooling, not shipped app/kit code.
//
// See docs/designs/2607.0001_tarmac_ui_kit_design_sync_export.md decision (e).

/** @type {Record<string, { group: "Cards" | "Overlays" | "Chrome", wrapInBoard?: boolean, props: object, fns?: Record<string, string> }>} */
export const fixtures = {
  CardShell: {
    group: "Cards",
    props: {
      frame: { x: 0, y: 0, w: 360, h: 220 },
      z: 1,
      prime: true,
      focused: true,
      selected: false,
      hasClose: false,
      header: "readme.md",
      children:
        "CardShell is the shared frame every card (doc or terminal) is built on: " +
        "a 30px drag header, 8 resize handles, and the chrome-state classes.",
    },
    fns: {
      getZoom: "() => 1",
    },
  },

  DocCard: {
    group: "Cards",
    wrapInBoard: true,
    props: {
      model: {
        kind: "doc",
        path: "/Users/dev/tarmac/docs/README.md",
        frame: { x: 0, y: 0, w: 360, h: 520 },
        z: 1,
        ownerTermId: "term-1",
        repoColor: 2,
        fresh: false,
        attached: true,
      },
      markdown:
        "# Tarmac UI Kit\n\n" +
        "This is a **standalone** preview of `DocCard`, rendered with no daemon " +
        "and no live `BoardEngine` behind it.\n\n" +
        "- prose collapses without `--card-w`/`--card-h` on `:root`\n" +
        "- fixed here by `preview-defaults.css` (kit-only, never shipped to the app)\n" +
        "- markdown is parsed by the `marked` library, inlined into the bundle\n\n" +
        "> Every mark on the board is backed by an observable OS fact — never by " +
        "parsing agent output.\n",
      ownerName: "agent-1",
      selected: true,
    },
    fns: {
      getZoom: "() => 1",
      onMove: "() => {}",
      onGrab: "() => {}",
      onClose: "() => {}",
    },
  },

  BoardSwitcher: {
    group: "Overlays",
    props: {
      visible: true,
      rows: [
        { boardID: "main", display: "main", isActive: true, isLive: true, running: 2, bell: 0, cards: 5, meta: "2 running · 5 cards" },
        { boardID: "scratch", display: "scratch", isActive: false, isLive: false, running: 0, bell: 1, cards: 2, meta: "1 bell · 2 cards" },
        { boardID: "release-0-7", display: "release-0.7", isActive: false, isLive: true, running: 1, bell: 0, cards: 3, meta: "1 running · 3 cards" },
      ],
      selected: 0,
      query: "",
      editing: false,
      editBuffer: "",
      confirmingDelete: false,
      deleteTarget: null,
    },
    fns: {
      onDismiss: "() => {}",
      onPickRow: "() => {}",
    },
  },

  ToastOverlay: {
    group: "Overlays",
    props: {
      toasts: [
        {
          id: "t1",
          icon: "¶",
          title: "doc opened",
          body: "README.md",
          chips: [],
          expiresAtMs: Date.now() + 7000,
        },
        {
          id: "t2",
          icon: "›_",
          title: "shell exited",
          body: null,
          chips: [{ label: "undo" }],
          expiresAtMs: Date.now() + 7000,
        },
      ],
    },
    fns: {
      onChipClick: "() => {}",
    },
  },

  OffscreenHints: {
    group: "Overlays",
    props: {
      pills: [
        { cardId: "c1", signal: "bell", label: "shell", edge: "right", arrow: "→", left: 900, top: 120 },
        { cardId: "c2", signal: "live", label: "README.md", edge: "bottom", arrow: "↓", left: 300, top: 560 },
      ],
    },
  },

  MinimapOverlay: {
    group: "Overlays",
    props: {
      items: [
        { worldRect: { x: 0, y: 0, w: 360, h: 220 }, signal: "live" },
        { worldRect: { x: 420, y: 40, w: 360, h: 480 }, signal: "none" },
        { worldRect: { x: -200, y: 300, w: 240, h: 160 }, signal: "bell" },
      ],
      viewportWorldRect: { x: -100, y: -60, w: 900, h: 640 },
    },
    fns: {
      onJump: "() => {}",
    },
  },

  CycleHud: {
    group: "Overlays",
    props: {
      hud: { labels: ["shell", "npm run dev", "claude"], activeIndex: 1 },
    },
  },

  StatusBar: {
    group: "Chrome",
    props: {
      connected: true,
      cards: 5,
    },
  },

  ZoomControl: {
    group: "Chrome",
    props: {
      zoom: 1.25,
    },
    fns: {
      onZoomIn: "() => {}",
      onZoomOut: "() => {}",
      onFit: "() => {}",
    },
  },

  DockPane: {
    group: "Chrome",
    props: {
      visible: true,
      label: "zsh",
    },
    fns: {
      bodyRef: "() => {}",
    },
  },
};
