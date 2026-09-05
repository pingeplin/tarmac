// Host side of the culled-card scheduler gate (spec 2609.0002): the polarity
// mapping, the host->shim payload, and the listener-map rules. The shim itself
// lives Rust-side (card_shim.js); Board owns the listener map and drives it from
// BoardEngine.onCullChange. Everything here is pure and unit-tested — the React
// shell that calls it is not, which is why the one line that could silently
// invert lives in this module rather than in the glue.

export interface CardCullMessage {
  tarmac: "cull";
  culled: boolean;
}

export type CullListener = (culled: boolean) => void;

/**
 * The host->shim payload for a known cull state.
 *
 * A STATE, not an edge: re-sending the same value is a no-op on both sides,
 * which is what lets the host re-assert (it does, on every `ready`) without
 * tracking what it last sent.
 */
export function cullPayload(culled: boolean): CardCullMessage {
  return { tarmac: "cull", culled };
}

/**
 * `BoardEngine.onCullChange`'s `visible` -> `culled`. The one place the polarity
 * is inverted, so it cannot be inverted twice or not at all.
 */
export function isCulled(visible: boolean): boolean {
  return !visible;
}

/**
 * Register `fn` under `id`, returning its unregister.
 *
 * A repeat register replaces the entry. The unregister removes the entry only
 * while it is still the one this call installed — React runs a remount's new
 * effect before the old cleanup, so an unconditional delete would strand the
 * live listener.
 */
export function registerCullListener(
  map: Map<string, CullListener>,
  id: string,
  fn: CullListener,
): () => void {
  map.set(id, fn);
  return () => {
    if (map.get(id) === fn) map.delete(id);
  };
}
