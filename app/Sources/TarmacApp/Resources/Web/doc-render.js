// The markdown doc card's page script. It runs in the app's own content world,
// after marked: the page's policy forbids script, so nothing a doc carries can
// reach this or the message handler it posts to.
(function () {
  const root = document.documentElement;
  const scroll = document.getElementById("scroll");
  const sizer = document.getElementById("sizer");
  const prose = document.getElementById("prose");
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

  window.tarmacDoc = {
    async render(markdown) {
      const render = ++renders;
      // A template has no browsing context, so no image is fetched before its
      // src is re-addressed.
      const template = document.createElement("template");
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
