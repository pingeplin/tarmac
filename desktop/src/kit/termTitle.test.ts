import { describe, it, expect } from "vitest";
import { isActive, displayLabel, isLive } from "./termTitle";

// Port of TermTitleTests.swift: the OSC-title vs process-name precedence rule
// and the "live" predicate. Swift's nil maps to `undefined`; an empty string is
// treated like nil wherever Swift's `.isEmpty` guards fire.
describe("TermTitle", () => {
  // MARK: displayLabel

  // A non-empty OSC title wins over the foreground process name (Ghostty
  // semantics): the program is showing what it wants shown.
  it("OSC title wins over proc name", () => {
    expect(displayLabel("claude", "node", "zsh")).toBe("claude");
  });

  // An empty OSC title (cleared, surfaced as nil/undefined) reverts the label
  // to the foreground process name.
  it("empty OSC reverts to proc name", () => {
    expect(displayLabel(undefined, "vim", "zsh")).toBe("vim");
  });

  // No OSC title and no process name yet falls back to the shell basename.
  it("nil OSC + nil proc falls back to shell", () => {
    expect(displayLabel(undefined, undefined, "zsh")).toBe("zsh");
  });

  // An empty process name (the daemon's idle signal) also falls back to shell.
  it("empty proc falls back to shell", () => {
    expect(displayLabel(undefined, "", "fish")).toBe("fish");
  });

  // The OSC title wins even when there is no process name yet — a program can
  // set a title before the daemon's first `term_proc`.
  it("OSC title wins with no proc", () => {
    expect(displayLabel("build", undefined, "zsh")).toBe("build");
  });

  // MARK: isActive

  it("isActive grid", () => {
    expect(isActive(undefined)).toBe(false);
    expect(isActive("")).toBe(false);
    expect(isActive("anything")).toBe(true);
  });

  // MARK: isLive

  // A program that set its own OSC title reads as live (agent-active), even when
  // the foreground process is the bare shell.
  it("OSC title counts as live", () => {
    expect(isLive("claude", "zsh", "zsh")).toBe(true);
  });

  // Without an OSC title, live falls back to the process heuristic: a non-shell
  // foreground process is live, the bare shell is idle.
  it("proc heuristic when no OSC", () => {
    expect(isLive(undefined, "node", "zsh")).toBe(true);
    expect(isLive(undefined, "zsh", "zsh")).toBe(false);
    expect(isLive(undefined, undefined, "zsh")).toBe(false);
    expect(isLive(undefined, "", "zsh")).toBe(false);
  });

  // MARK: precedence interaction (mirrors the AppController plumbing)

  // A `term_proc` update does NOT override an active OSC title: with `oscTitle`
  // set, the displayed label stays the OSC title regardless of which process
  // name arrives — but the process name is still tracked, so clearing the OSC
  // title later reverts to it.
  it("proc update does not override active OSC", () => {
    const osc = "claude";
    // term_proc says "node" — label stays the OSC title.
    expect(displayLabel(osc, "node", "zsh")).toBe("claude");
    // Then the program clears its title (osc -> nil): revert to the tracked proc.
    expect(displayLabel(undefined, "node", "zsh")).toBe("node");
  });
});
