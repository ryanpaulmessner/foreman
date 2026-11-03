---
id: fm-zgd.16
title: "PR evidence images on cards: copy or drag them into the GitHub PR description"
type: feature
status: open
priority: 2
parent: fm-zgd
blocked_by: []
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-10-30
closed: null
close_reason: null
---

User request 2026-10-29 (Ryan): getting PR screenshots into GitHub PR descriptions takes too many manual steps. Today the coordinator writes the images to slices/evidence/<slice>/, and Ryan must find them in Finder and drag each one into the PR. GitHub has no API or gh command for these image uploads.

Constraints found:
- GitHub refuses to load in an iframe, so the board cannot embed the PR editor.
- GitHub uploads an image that is pasted (Cmd+V) into the PR description editor, the same as a dragged file. Clipboard writes work on localhost (a secure context).
- Dragging an <img> from the board tab into the GitHub tab usually gives Chrome a file. This is not yet tested with GitHub.
- Do not commit images to ReportSystem: about 125 KB per PNG, 13 MB already against a 60 MB pack, permanent in history, and company data. Gists and outside image hosts are public by link: no.

Behaviour:
- foreman ask decision / push / open_pr gain a repeatable --image <path> (PNG/JPEG/WebP, repo-relative or absolute under a configured repo; refuse other paths at ask time, like --doc). Store as {repo, path} in the request facts.
- The card shows an Evidence strip: a thumbnail of each image (click to see it full size), a Copy button that writes the image/png to the clipboard (navigator.clipboard.write with ClipboardItem), and draggable images.
- When an open_pr request is done (and on push cards whose PR exists), the card shows an "Edit PR description" link to the PR in a new tab.
- Evidence Markdown passed with --doc shows its embedded images in the document viewer (check: it may already work).
- Works on Needs you, the drawer and Recent outcomes.
- Update the slice-loop skill (gate 3 UI evidence) and the foreman skill: pass --image for the screenshots on the look-right card and on open_pr.

Acceptance: from an open_pr card, Ryan gets the image into the PR with Copy, switch tab, Cmd+V, save, and does not open Finder. Test the drag path with GitHub and record whether it works.
