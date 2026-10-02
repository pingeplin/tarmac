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
  const K = Number(getComputedStyle(root).getPropertyValue("--oversample-k"));

  let zoom = 1;
  // The prose's height in its own K-times layout, before the scale.
  let proseHeight = 0;
  // Reading position as scrollTop / scrollHeight, so it survives a re-render,
  // a zoom and a card resize alike.
  let scrollFraction = 0;
  // The viewport height the app last said this page is laid out for.
  let viewportHeight = null;
  let renders = 0;

  function relayout() {
    sizer.style.height = Math.ceil((proseHeight * zoom) / K) + "px";
    if (scroll.scrollHeight > scroll.clientHeight) {
      scroll.scrollTop = scrollFraction * scroll.scrollHeight;
    }
  }

  // The zoom and the new viewport size arrive one after the other. In between,
  // the content and its viewport disagree and the browser clamps the scroll;
  // that is not the reader moving, so it is not recorded.
  function viewportSettled() {
    return viewportHeight === null || Math.abs(scroll.clientHeight - viewportHeight) < 1;
  }

  scroll.addEventListener("scroll", function () {
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

  // A press on a link does not select the card, and the app decides that
  // before the press reaches this page: so it is told when the pointer is on
  // one.
  let overLink = false;
  function pointerIs(onLink) {
    if (onLink === overLink) return;
    overLink = onLink;
    webkit.messageHandlers.docOverLink.postMessage(onLink);
  }
  prose.addEventListener("mouseover", function (event) {
    pointerIs(anchorOf(event) !== null);
  });
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
    async render(markdown) {
      const render = ++renders;
      // A template has no browsing context, so no image is fetched before its
      // src is re-addressed.
      const template = createElement("template");
      template.innerHTML = marked.parse(markdown, { async: false });
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
      remeasure();
      // What was focused or under the pointer was just replaced, with no
      // event to say so.
      focusMoved();
      pointerIs(false);
    },

    // Called before the web view takes its new size.
    layout(boardZoom, cardWidth, height) {
      zoom = boardZoom;
      viewportHeight = height;
      root.style.setProperty("--zoom", String(zoom));
      root.style.setProperty("--card-w", cardWidth + "px");
      relayout();
    },
  };
})();
