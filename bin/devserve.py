#!/usr/bin/env python3
"""Run devserve preparation and the web role without the operator's board environment."""

import hashlib
import os
from pathlib import Path
import re
import sys
from urllib.parse import urlsplit


def environment(source, root):
    root = root.resolve()
    suffix = hashlib.sha256(str(root).encode()).hexdigest()[:12]
    slug = re.sub('[^a-z0-9]+', '_', root.name.lower()).strip('_')[:20] or 'tree'
    database = f"foreman_preview_{slug}_{suffix}"
    url = urlsplit(source.get("DATABASE_URL", ""))
    if (source.get("PREVIEW") != "1"
            or not source.get("PORT", "").isdigit()
            or not 4840 <= int(source["PORT"]) <= 4899
            or url.scheme not in ("postgresql", "postgres", "ecto")
            or url.hostname not in ("localhost", "127.0.0.1")
            or url.path != "/" + database or url.query or url.fragment):
        raise ValueError("requires devserve's local foreman database and port 4840–4899")
    scratch = root / "tmp/devserve"
    for name in ("config", "discovery", "sessions"):
        (scratch / name).mkdir(parents=True, exist_ok=True)
    env = {key: source[key] for key in ("HOME", "LANG", "TERM", "TMPDIR") if key in source}
    env.update(
        DATABASE_URL=source["DATABASE_URL"], PORT=source["PORT"],
        MIX_ENV="dev", PREVIEW="0", FOREMAN_ROLE="web",
        PATH=":".join([str(root / "bin/preview-stubs"),
                       str(Path.home() / ".asdf/shims"),
                       "/opt/homebrew/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]),
        FOREMAN_CONFIG_DIR=str(scratch / "config"),
        FOREMAN_DISCOVERY_ROOT=str(scratch / "discovery"),
        FOREMAN_COORDINATOR_WORKDIR=str(scratch),
        PI_CODING_AGENT_SESSION_DIR=str(scratch / "sessions"),
        FOREMAN_PLANNING_TMUX_SOCKET="fm-preview-" + suffix,
        FOREMAN_EXTERNAL_TMUX_SOCKET="fm-preview-" + suffix,
    )
    return env


COMMANDS = {
    "start": ["mix", "phx.server"],
    "migrate": ["mix", "do", "compile", "+", "ecto.migrate"],
    "seed": ["mix", "run", "priv/repo/seeds.exs"],
}


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in COMMANDS:
        sys.exit("usage: python3 bin/devserve.py start|migrate|seed")
    root = Path(__file__).resolve().parent.parent
    os.chdir(root)
    try:
        env = environment(os.environ, root)
    except ValueError:
        sys.exit("refused: requires devserve's local foreman database and port 4840–4899")
    command = COMMANDS[sys.argv[1]]
    os.execvpe(command[0], command, env)


if __name__ == "__main__":
    main()
