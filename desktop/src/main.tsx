import ReactDOM from "react-dom/client";
import "@xterm/xterm/css/xterm.css";
import "./theme.css";
import App from "./App";

// No StrictMode: it double-invokes effects in dev, which would mount xterm twice
// and cold-spawn the boot PTY twice for the same term_id. The terminal lifecycle
// is imperative and owns real OS resources, so we mount it once.
ReactDOM.createRoot(document.getElementById("root") as HTMLElement).render(<App />);
