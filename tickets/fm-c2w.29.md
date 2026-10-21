---
id: fm-c2w.29
title: "Board home sections by ticket kind (break-fix, mapping, access, feature, internal)"
type: feature
status: closed
priority: 0
parent: fm-c2w
blocked_by: []
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-10-21
closed: 2026-10-21
close_reason: "ad75ba2 on main: kind field + CLI --kind, repo default_kind, kind sections on the home (Parked, Break-fix, Mapping, Access, Feature, Internal, Unsorted), kind filter; 124 focused tests; live board checked"
---

Ryan 2026-10-20: replace the epics / standalone / unplanned split on the board home with sections that follow the ReportSystem Support Board ticket types (ReportSystem lib/report_system/tickets/ticket.ex:22: break_fix feature mapping access), plus internal for tooling work. Epics live under Feature (Ryan's choice). Parked (fm-c2w.28) stays on top across kinds. New optional ticket field kind (break_fix|mapping|access|feature|internal); CLI new/update --kind; a ticket without kind inherits its nearest epic's kind, else the repo's default_kind from foreman.toml, else Unsorted. Each section shows its epics as trees and its loose tickets as rows. Kind filter.
