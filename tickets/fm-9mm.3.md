---
id: fm-9mm.3
title: "How to show recent pane output read-only on the detail page"
type: decision
status: closed
priority: 2
parent: fm-9mm
blocked_by: []
related: []
supersedes: []
discovered_from: null
labels: ["wayfinder:research"]
created: 2026-11-01
closed: 2026-11-01
close_reason: "Poll capture-pane 1 s / 200 lines for viewed panes only; own ANSI converter; save last capture for the dead view"
---

## Question

Compare ways to show the last part of a live tmux pane's output on a LiveView page, read-only: polling `tmux capture-pane -p -e` on an interval, `pipe-pane` to a file, or tmux control mode. For each: CPU cost with ~20 panes, latency, ANSI colour rendering in HTML, what is kept after the pane closes (for the dead view), and any risk to the running session. Recommend one.

## Notes
- 2026-11-01 user: Resolved 2026-11-01 (research). Use polling: `tmux -N -L default capture-pane -p -e -J -S -200 -t <pane>` every 1 s, 200 lines, only for a pane an open detail page shows; push to the page only when the capture hash changes. It is the only option that changes nothing on the pane or server (the code already uses this call); -e output on 20 real panes had only SGR colours and OSC 8 links, no cursor moves. pipe-pane closes any existing pipe; control mode attaches a client (resize risk unless -r, -A off/pause can stall the pane); both need a terminal emulator (xterm.js). Numbers: one 200-line capture 4.7 ms (≈1 ms server + 3.3 ms process start); 1000 lines 6.3 ms, 5000 lines 11.8 ms; one viewed pane at 1 s ≈0.5% of a core, all 20 ≈9% (do not poll unviewed panes); 200 lines ≈22 KB avg, 38 KB max. ANSI to HTML: ansi_to_html 0.6.0 does not fit (no 39 / 90-97, warns per code, prints OSC 8 as text, wrong 256-colour 0-15); write a ~150-line converter. Dead view: tmux keeps nothing after close; save the last capture on agent exit (launch command), before board Stop/Park, and the latest polled snapshot as a fallback. Findings: research/pane-output branch, docs/research/pane-output.md, commit 8d5990a (worktree ~/dev/foreman-worktrees/research-pane-output, local only).
