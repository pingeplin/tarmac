/**
 * A list of exceptions that a check keeps beside itself: a JSON array of
 * entries, each with the given fields as texts that are not empty. `text` is
 * the file's content, or null when there is no file. Returns `{ list }`, or
 * `{ bad }` with what is wrong, worded after the file's path.
 */
export function parseList(text, path, fields) {
  const bad = (why) => ({ bad: `${path} ${why}` });
  if (text === null) return bad("is missing");
  let list;
  try {
    list = JSON.parse(text);
  } catch {
    return bad("is not valid JSON");
  }
  if (!Array.isArray(list)) return bad("is not a list");
  const at = list.findIndex((entry) => fields.some((field) => typeof entry?.[field] !== "string" || entry[field] === ""));
  return at === -1 ? { list } : bad(`entry ${at + 1} needs ${fields.join(", ")}, each a text that is not empty`);
}
