# Theme fixture

A doc for the live checks of the theme setting (spec 2610.0007, S33 and
S34). It is long enough to scroll. The parts that a theme must reach are in
the middle, so that a card scrolled to its middle shows them all.

Paragraph 1. The board is a flat sheet, and each card on it is a window to
one thing: a shell, a page, a doc. This text has no purpose but its length.

Paragraph 2. A card keeps its place on the board. The board moves under the
window, and the cards move with it. This text has no purpose but its length.

Paragraph 3. A doc card shows a file. When the file changes, the card shows
the new text. This text has no purpose but its length.

Paragraph 4. A terminal card shows a shell. The shell runs in a daemon, so
it lives on when the app stops. This text has no purpose but its length.

Paragraph 5. An HTML card shows a page in a closed frame. The page cannot
reach the network. This text has no purpose but its length.

Paragraph 6. The theme sets the colours of all of these. A change of the
theme must reach each one. This text has no purpose but its length.

## The parts

Prose with `inline code` in it, and [a link](https://example.com/) after it.

> A blockquote. The template does not style it, so its look comes from the
> page's `color-scheme`.

| Token | Dark | Light |
| --- | --- | --- |
| page | `2b3036` | `eff0f1` |
| code block | `31363b` | `fcfcfc` |

---

```sh
# a code block: its fill is the terminal background
printf 'theme\n'
```

SELECTME is a word to select with a double click.

## After the parts

Paragraph 7. The text below gives the card room to scroll past the parts.
This text has no purpose but its length.

Paragraph 8. A scroll position is a number of pixels from the top of the
page. A change of the theme must not move it. This text has no purpose but
its length.

Paragraph 9. The page is not loaded again when the theme changes. Only its
colour properties are set. This text has no purpose but its length.

Paragraph 10. A page that is hidden gets the same properties as a page that
shows. This text has no purpose but its length.

Paragraph 11. A page made after the change is drawn in the new theme from
its first paint. This text has no purpose but its length.

Paragraph 12. The last paragraph. This text has no purpose but its length.
