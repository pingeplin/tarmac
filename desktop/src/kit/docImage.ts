// Doc-card <img src> resolution (spec 2609.0014). Markdown renders into the app's
// own document, so a doc-relative src would resolve against the app origin and hit
// the SPA fallback; a local src is re-addressed to the tarmac-card://img/ host
// instead. The DOM walk that applies this stays in DocCard as wiring.

/** Absolute on-disk path a doc image `src` names, or undefined when `src` is not
 *  a local file reference (the caller leaves it unchanged). `docPath` is the
 *  doc's absolute path (DocCardModel.path). Never throws. */
export function localImagePath(src: string, docPath: string): string | undefined {
  const ref = localRef(src.replace(ASCII_WHITESPACE_ENDS, ""));
  if (ref === undefined) return undefined;
  // Strip before decoding, so %23 and %3F survive as a literal # or ? in the name.
  const cut = ref.path.search(/[?#]/);
  const local = cut < 0 ? ref.path : ref.path.slice(0, cut);
  if (local === "") return undefined;
  const decoded = decodeOrKeep(local);
  // The doc's directory is a real path, not URL text: joined literally, never decoded.
  return normalize(ref.relative ? docPath.slice(0, docPath.lastIndexOf("/") + 1) + decoded : decoded);
}

/** The src a doc-card <img> should carry. Local → tarmac-card://img/ URL;
 *  otherwise `src` itself, returned unchanged. Pure. */
export function docImageSrc(src: string, docPath: string, mtimeMs: number | undefined): string {
  const path = localImagePath(src, docPath);
  // Mirrors cardSrcUrl: ?v= only busts the cache; the handler serves current bytes.
  return path === undefined ? src : `tarmac-card://img/${encodeURIComponent(path)}?v=${mtimeMs ?? 0}`;
}

interface LocalRef {
  path: string;
  relative: boolean;
}

// The HTML/URL-standard set; String.prototype.trim would also strip VT and Unicode spaces.
const ASCII_WHITESPACE_ENDS = /^[\t\n\f\r ]+|[\t\n\f\r ]+$/g;
const SCHEME = /^([A-Za-z][A-Za-z0-9+.-]*):/;
const FILE_URL = /^file:\/\//i;

function localRef(src: string): LocalRef | undefined {
  const scheme = SCHEME.exec(src)?.[1];
  if (scheme !== undefined && scheme.toLowerCase() !== "file") return undefined;
  if (src.startsWith("//")) return undefined;
  if (FILE_URL.test(src)) {
    const slash = src.indexOf("/", "file://".length);
    const host = slash < 0 ? src.slice("file://".length) : src.slice("file://".length, slash);
    if (host !== "" && host !== "localhost") return undefined;
    return { path: slash < 0 ? "" : src.slice(slash), relative: false };
  }
  if (scheme !== undefined) return undefined;
  return { path: src, relative: !src.startsWith("/") };
}

function decodeOrKeep(path: string): string {
  try {
    return decodeURIComponent(path);
  } catch {
    return path;
  }
}

function normalize(path: string): string {
  const out: string[] = [];
  for (const seg of path.slice(1).split("/")) {
    if (seg === ".") continue;
    if (seg === "..") out.pop();
    else out.push(seg);
  }
  return "/" + out.join("/");
}
