// The HTML card host page's script. It only carries: every decision about a
// message is the app's. It runs in the app's own content world, so the card's
// document has no handle on the message handler it posts to.
(function () {
  const card = document.getElementById("card");

  window.addEventListener("message", function (event) {
    // Only this card's own document is heard.
    if (event.source !== card.contentWindow) return;
    try {
      webkit.messageHandlers.card.postMessage(event.data);
    } catch (error) {
      // A payload the bridge cannot carry is not a Tarmac message.
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
