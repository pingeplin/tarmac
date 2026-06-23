// The bottom-right toast stack (port of Toasts.swift). The container + cards are
// click-through (pointer-events:none); only the kbd chips take clicks. Newest
// renders at the BOTTOM (the array is oldest→newest; the column is bottom-anchored).
// Pure render over the toast list + an onChipClick callback; App owns the lifecycle
// (kit/toasts) and the chip action closures.

import type { Toast } from "../kit/toasts";

interface ToastOverlayProps {
  toasts: Toast[];
  onChipClick: (toastId: string, chipIndex: number) => void;
}

export function ToastOverlay({ toasts, onChipClick }: ToastOverlayProps) {
  if (toasts.length === 0) return null;
  return (
    <div className="toast-stack">
      {toasts.map((t) => (
        <div key={t.id} className="tm-toast">
          <span className="tm-toast-icon">{t.icon}</span>
          <span className="tm-toast-text">
            <span className="tm-toast-title">{t.title}</span>
            {t.body && <span className="tm-toast-body">{t.body}</span>}
          </span>
          {t.chips.length > 0 && (
            <span className="tm-toast-keys">
              {t.chips.map((c, i) => (
                // preventDefault on mousedown keeps focus on the prime terminal.
                <button
                  key={i}
                  className="tm-toast-key"
                  onClick={() => onChipClick(t.id, i)}
                  onMouseDown={(e) => e.preventDefault()}
                  tabIndex={-1}
                >
                  {c.label}
                </button>
              ))}
            </span>
          )}
        </div>
      ))}
    </div>
  );
}
