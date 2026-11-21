// The markdown doc card's page script. It runs in the app's own content world,
// after marked: the page's policy forbids script, so nothing a doc carries can
// reach this or the message handler it posts to.
(function () {
  // Raw HTML in a doc can name an element after a property of the document
  // (`<img name="createElement">`) or of its own form, and the name then
  // hides the property. What this script calls on either comes from the
  // prototypes, which no element reaches.
  const elementById = Document.prototype.getElementById.bind(document);
  const createElement = Document.prototype.createElement.bind(document);
  const activeElement = Object.getOwnPropertyDescriptor(Document.prototype, "activeElement").get.bind(document);
  const closest = Function.prototype.call.bind(Element.prototype.closest);

  const root = document.documentElement;
  const scroll = elementById("scroll");
  const sizer = elementById("sizer");
  const prose = elementById("prose");
  const strip = elementById("strip");
  const stripContent = elementById("strip-content");
  const panel = elementById("panel");
  const sideSizer = elementById("side-sizer");
  const sideContent = elementById("side-content");
  const grip = elementById("grip");
  const K = Number(getComputedStyle(root).getPropertyValue("--oversample-k"));
  const rules = tarmacDocLayout;

  let zoom = 1;
  // The prose's height in its own K-times layout, before the scale.
  let proseHeight = 0;
  // Reading position as scrollTop / scrollHeight, so it survives a re-render,
  // a zoom and a card resize alike.
  let scrollFraction = 0;
  // The viewport height the app last said this page is laid out for.
  let viewportHeight = null;
  let renders = 0;

  // The sidebar (spec 2611.0022). Every decision is a rule of doc-layout.js;
  // this keeps what the rules are given and applies what they answer. Event
  // wiring of its own: a drag starts only on the primary button once a state
  // has landed, and a blur ends it where the pointer was last seen.
  // Set by `layout`, which the app sends before any render or state.
  let cardWidth;
  // The last state the app sent; a layout carries one before any render.
  let state = null;
  let fieldCount = 0;
  let outline = [];
  // The current render's headings, by outline index, and their tops in the
  // scroller's content (screen px).
  let headings = [];
  let tops = [];
  let current = -1;
  let entries = [];
  let ticks = [];
  let sectionHeads = {};
  let section = null;
  let icons = {};
  // An open the page asked for shows `section` once the app's state opens it.
  let showSectionOnOpen = false;
  // A drag's width, kept after the release until the app answers, and the
  // held press: where it started, how far the pointer is from it, and whether
  // it moved.
  let drag = null;
  let dragging = null;

  function report(action) {
    webkit.messageHandlers.docSidebar.postMessage(action);
  }

  function px(name, value) {
    root.style.setProperty(name, value + "px");
  }

  function shownMode() {
    return rules.shownMode(state, fieldCount, outline.length);
  }

  // Called only once a state has landed.
  function applySide() {
    const shown = Object.assign({}, state, { mode: shownMode() });
    const box = rules.geometry(shown, cardWidth, drag);
    const parts = rules.parts(shown.mode, box, shown);
    px("--side-strip", shown.strip);
    px("--side-grip", shown.grip);
    px("--text-w", box.textWidth);
    px("--side-offset", box.offset);
    px("--side-panel", box.panel);
    px("--side-panel-left", parts.panelLeft);
    root.setAttribute("data-side", shown.mode);
    strip.hidden = !parts.strip;
    panel.hidden = !parts.panel;
    grip.hidden = !parts.grip;
    const active = rules.activeIcon(shown.mode, section);
    Object.keys(icons).forEach(function (name) {
      icons[name].classList.toggle("active", name === active);
    });
    sizeSide();
    return parts;
  }

  function takeState(given, fromAction) {
    state = given;
    drag = rules.dragOnState(dragging !== null, drag, fromAction);
    const parts = applySide();
    const opened = rules.sectionOnState(showSectionOnOpen, parts.panel);
    showSectionOnOpen = opened.pending;
    if (opened.show) showSection();
  }

  function sizeSide() {
    sideSizer.style.height = Math.ceil((sideContent.offsetHeight * zoom) / K) + "px";
  }

  function showSection() {
    const head = sectionHeads[section];
    if (head) panel.scrollTop += head.getBoundingClientRect().top - panel.getBoundingClientRect().top;
  }

  function topOf(element) {
    return element.getBoundingClientRect().top - scroll.getBoundingClientRect().top + scroll.scrollTop;
  }

  function measureHeadings() {
    tops = headings.map(function (heading) {
      return heading ? topOf(heading) : null;
    });
    markCurrent();
  }

  function markCurrent() {
    current = rules.currentSection(tops, scroll.scrollTop, scroll.clientHeight, scroll.scrollHeight, zoom);
    entries.forEach(function (entry, index) {
      entry.classList.toggle("current", index === current);
    });
    const lit = rules.strip(fieldCount, outline, current).lit;
    ticks.forEach(function (tick) {
      tick.element.classList.toggle("lit", tick.index === lit);
    });
  }

  function goTo(index) {
    measureHeadings();
    const target = rules.scrollTarget(tops[index], scroll.clientHeight, scroll.scrollHeight, zoom);
    if (target !== null) scroll.scrollTop = target;
  }

  function div(className, text) {
    const element = createElement("div");
    element.className = className;
    if (text !== undefined) element.textContent = text;
    return element;
  }

  function onClick(element, handler) {
    element.addEventListener("click", handler);
    return element;
  }

  // The outline icon is three bars the template draws: a glyph of them
  // blurs into one block at a 1× zoom.
  const iconGlyphs = { fields: "{}", outline: "" };

  const titles = { fields: "FRONT MATTER", outline: "OUTLINE" };

  function fieldRow(field) {
    const row = div("doc-field");
    row.append(div("doc-field-key", field[0]));
    const value = div("doc-field-value");
    if (Array.isArray(field[1])) {
      field[1].forEach(function (item) {
        value.append(div("doc-chip", item));
      });
    } else {
      value.textContent = field[1];
    }
    row.append(value);
    return row;
  }

  // The panel's sections are the strip's icons, in order; the first header
  // holds the close button.
  function buildSide(fields) {
    const shape = rules.strip(fieldCount, outline, -1);
    sectionHeads = {};
    entries = [];
    const panelParts = [];
    shape.icons.forEach(function (name, index) {
      const head = div("doc-side-head");
      head.append(div("doc-side-title", titles[name]));
      if (index === 0) {
        head.append(onClick(div("doc-side-close", "\u21e4"), function () {
          report({ action: "close" });
        }));
      }
      sectionHeads[name] = head;
      panelParts.push(head);
      if (name === "fields") panelParts.push(...fields.map(fieldRow));
      if (name === "outline") {
        entries = outline.map(function (item, entryIndex) {
          const entry = onClick(div("doc-entry", item.text), function () {
            goTo(entryIndex);
          });
          entry.setAttribute("data-depth", String(item.depth));
          return entry;
        });
        panelParts.push(...entries);
      }
    });
    sideContent.replaceChildren(...panelParts);

    section = shape.section;
    icons = {};
    shape.icons.forEach(function (name) {
      const icon = onClick(div("doc-icon doc-icon-" + name, iconGlyphs[name]), function () {
        const click = rules.iconClick(shownMode(), section, name);
        section = click.section;
        showSectionOnOpen = click.scroll === "onOpen";
        if (click.post) report({ action: click.post });
        if (click.scroll === "now") showSection();
        applySide();
      });
      icons[name] = icon;
    });
    const tickBox = div("doc-ticks");
    ticks = shape.ticks.map(function (index) {
      const element = onClick(div("doc-tick"), function () {
        goTo(index);
      });
      element.setAttribute("data-depth", String(outline[index].depth));
      tickBox.append(element);
      return { index, element };
    });
    stripContent.replaceChildren(...Object.values(icons), tickBox);
  }

  // The headings this render marked: a doc's raw HTML cannot know the mark.
  // Nothing is called on an element the doc wrote, whose own names can hide
  // a method (a form's input named `getAttribute`).
  function markedHeadings(mark) {
    return outline.map(function (_, index) {
      return prose.querySelector('[data-outline="' + mark + "-" + index + '"]');
    });
  }

  // Where the doc is scrolled to, for the card's scroll thumb.
  function reportScroll() {
    webkit.messageHandlers.docScroll.postMessage({
      offset: scroll.scrollTop,
      visible: scroll.clientHeight,
      total: scroll.scrollHeight,
    });
  }

  function relayout() {
    sizer.style.height = Math.ceil((proseHeight * zoom) / K) + "px";
    sizeSide();
    if (scroll.scrollHeight > scroll.clientHeight) {
      scroll.scrollTop = scrollFraction * scroll.scrollHeight;
    }
    measureHeadings();
    reportScroll();
  }

  // The zoom and the new viewport size arrive one after the other. In between,
  // the content and its viewport disagree and the browser clamps the scroll;
  // that is not the reader moving, so it is not recorded.
  function viewportSettled() {
    return viewportHeight === null || Math.abs(scroll.clientHeight - viewportHeight) < 1;
  }

  scroll.addEventListener("scroll", function () {
    reportScroll();
    markCurrent();
    if (!viewportSettled()) return;
    scrollFraction = scroll.scrollHeight > scroll.clientHeight ? scroll.scrollTop / scroll.scrollHeight : 0;
  });

  window.addEventListener("resize", relayout);

  function remeasure() {
    proseHeight = prose.offsetHeight;
    relayout();
  }

  // A card resize re-wraps the prose; a zoom does not.
  new ResizeObserver(remeasure).observe(prose);
  new ResizeObserver(sizeSide).observe(sideContent);

  scroll.addEventListener("mousedown", function () {
    const post = rules.pressOnText(shownMode());
    if (post) report({ action: post });
  });

  // The drag's moves and release are heard on the window: the pointer can
  // leave the grip, and the web view, while the press is held.
  grip.addEventListener("mousedown", function (event) {
    if (event.button !== 0 || !state) return;
    event.preventDefault();
    dragging = { x: event.clientX, delta: 0, moved: false };
    window.addEventListener("mousemove", dragMoved);
    window.addEventListener("mouseup", dragEnded);
    window.addEventListener("blur", dragEnded);
  });

  function dragMoved(event) {
    dragging.delta = event.clientX - dragging.x;
    dragging.moved = true;
    drag = rules.dragWidth(state.width, dragging.delta, zoom, rules.direction(state.side), state.minWidth, state.maxWidth);
    applySide();
  }

  // A release, or the window losing the pointer (a mouseup that never
  // comes) at the last place the pointer was seen.
  function dragEnded(event) {
    window.removeEventListener("mousemove", dragMoved);
    window.removeEventListener("mouseup", dragEnded);
    window.removeEventListener("blur", dragEnded);
    if (event.type === "mouseup") dragging.delta = event.clientX - dragging.x;
    const ended = rules.dragEnd(dragging.moved, dragging.delta, drag);
    dragging = null;
    drag = ended.drag;
    if (ended.report) report(ended.report);
    applySide();
  }

  grip.addEventListener("dblclick", function () {
    report({ action: "reset" });
  });

  // A re-render measures the prose before its images have loaded. When they
  // load within the same frame the prose is back at the height the observer
  // last reported, and it reports nothing.
  prose.addEventListener("load", remeasure, true);
  prose.addEventListener("error", remeasure, true);

  function anchorOf(event) {
    return event.target instanceof Element ? closest(event.target, "a") : null;
  }

  // The page never follows a link. The app opens it, judging the href as the
  // doc wrote it: resolved, a <base> in the doc would point it anywhere.
  prose.addEventListener("click", function (event) {
    const anchor = anchorOf(event);
    if (!anchor) return;
    event.preventDefault();
    webkit.messageHandlers.docLink.postMessage(anchor.getAttribute("href") || "");
  });

  // A press on a link does not select the card. The app decides that as it
  // catches the press, before the press is dispatched: all it has then is the
  // web view under the pointer, and it cannot ask this page what is there and
  // wait for the answer. So the page says ahead of any press whether the
  // pointer is on a link.
  let overLink = false;
  function pointerIs(onLink) {
    if (onLink === overLink) return;
    overLink = onLink;
    webkit.messageHandlers.docOverLink.postMessage(onLink);
  }
  function pointerMoved(event) {
    pointerIs(anchorOf(event) !== null);
  }
  // Heard on the whole page: below a short doc the pointer is outside the
  // prose, and off the link it came from.
  document.addEventListener("mouseover", pointerMoved);
  // A re-render puts new elements under a pointer at rest, and nothing says
  // what they are until it moves.
  document.addEventListener("mousemove", pointerMoved);
  root.addEventListener("mouseleave", function () {
    pointerIs(false);
  });

  // Raw HTML can hold a text control. Return typed into one is the control's,
  // not the app's, so the app is told when one has the focus.
  let editing = false;
  function focusMoved() {
    const active = activeElement();
    const now = active !== null && closest(active, "button, input, textarea, [contenteditable]") !== null;
    if (now === editing) return;
    editing = now;
    webkit.messageHandlers.docEditing.postMessage(now);
  }
  document.addEventListener("focusin", focusMoved);
  document.addEventListener("focusout", focusMoved);

  window.tarmacDoc = {
    // `fields` are [key, value] pairs, a value a string or an array of
    // strings. The new content is laid out by the last state: the page alone
    // decides that one with no fields and no outline shows no sidebar.
    async render(markdown, fields) {
      const render = ++renders;
      const mark = "m" + render + "-" + Math.random().toString(36).slice(2);
      const parsed = rules.parse(markdown, mark);
      // A template has no browsing context, so no image is fetched before its
      // src is re-addressed.
      const template = createElement("template");
      template.innerHTML = parsed.html;
      const images = Array.from(template.content.querySelectorAll("img[src]"));
      if (images.length > 0) {
        const sources = await webkit.messageHandlers.docImages.postMessage(
          images.map(function (image) {
            return image.getAttribute("src") || "";
          }),
        );
        if (render !== renders) return;
        images.forEach(function (image, index) {
          image.setAttribute("src", sources[index]);
        });
      }
      prose.replaceChildren(template.content);
      fieldCount = fields.length;
      outline = parsed.outline;
      headings = markedHeadings(mark);
      buildSide(fields);
      // With no state yet there is nothing to lay out by.
      if (state !== null) applySide();
      remeasure();
      // What was focused or under the pointer was just replaced, with no
      // event to say so.
      focusMoved();
      pointerIs(false);
    },

    // Called before the web view takes its new size.
    layout(boardZoom, width, height, given) {
      zoom = boardZoom;
      viewportHeight = height;
      cardWidth = width;
      root.style.setProperty("--zoom", String(zoom));
      px("--card-w", cardWidth);
      takeState(given, false);
      relayout();
    },

    // The app's state after an action of the sidebar's.
    sidebar(given) {
      takeState(given, true);
    },

    // The chosen fonts: two font-family values and the prose's size, a
    // length. A new face or size moves the prose's line breaks.
    fonts(chromeFamily, proseFamily, proseSize) {
      root.style.setProperty("--chrome-font", chromeFamily);
      root.style.setProperty("--prose-font", proseFamily);
      root.style.setProperty("--prose-size", proseSize);
      remeasure();
    },

    // The theme's declarations, as [name, value] pairs: the colours and the
    // colour scheme. No line break moves.
    theme(properties) {
      properties.forEach(function (pair) {
        root.style.setProperty(pair[0], pair[1]);
      });
    },

    // The card's scroll thumb is being dragged; the scroll listener reports
    // where this lands.
    scrollTo(y) {
      if (typeof y === "number" && isFinite(y)) scroll.scrollTop = y;
    },
  };
})();
