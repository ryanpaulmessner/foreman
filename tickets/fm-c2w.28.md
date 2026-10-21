---
id: fm-c2w.28
title: "Parked: a status and board section for worked tickets that wait on someone other than Ryan"
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
close_reason: "79be572 on main: parked status with required reason and date, Parked board section, epic badge, not stale, filter; 103 tests"
---

Ryan 2026-10-20: add a 'parked' category for things that have been worked but wait on approval or input from someone or something other than Ryan (a teammate, IT, a vendor, a merge order). Proposed shape: (1) new file ticket status parked in TicketStatusMachine (event :park, from any) with a required reason saying who or what it waits on, stored on the ticket (parked_on / parked_reason, parked date); foreman update <id> --status parked --reason '...' and a 'foreman park <id> --reason' shorthand if cheap; open/in_progress un-parks. (2) Board home: a 'Parked' section (with count) that collects parked tickets from every epic and from parentless work, each row showing the reason and how long it has been parked (age like fm-c2w.25). Parked tickets leave Unplanned and Standalone; inside their epic they keep their row with a Parked badge. Not stale (stale? ignores parked). (3) Ticket side panel shows the reason and a Unpark action. (4) The status filter offers parked. LiveView + CLI tests. Distinct from Needs you (that is waiting on Ryan) and from deferred (not worked, put off).
