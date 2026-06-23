// The session chip (port of TitleBarChip.swift): "▞ <board>" whose glyph + label
// color signals attached/detached, dimmed while the ⌘K switcher is open. The Tauri
// window keeps its native titlebar, so this renders as a top-center overlay (the
// native title string can't carry the agent-cyan glyph / liveness color / dim).

interface TitleBarChipProps {
  name: string;
  attached: boolean;
  dim?: boolean;
}

export function TitleBarChip({ name, attached, dim = false }: TitleBarChipProps) {
  const cls = ["title-chip"];
  if (!attached) cls.push("detached");
  if (dim) cls.push("dim");
  return (
    <div className={cls.join(" ")}>
      <span className="glyph">▞</span>
      <span className="label">{name}</span>
    </div>
  );
}
