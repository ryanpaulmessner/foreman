import hashlib
import importlib.util
import re
import os
from pathlib import Path
import tempfile
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("foreman_devserve", ROOT / "bin/devserve.py")
preview = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preview)


def database_url(root):
    slug = re.sub('[^a-z0-9]+', '_', root.name.lower()).strip('_')[:20] or 'tree'
    suffix = hashlib.sha256(str(root).encode()).hexdigest()[:12]
    return f"postgresql://localhost/foreman_preview_{slug}_{suffix}"


class DevserveTest(unittest.TestCase):
    def test_agent_commands_refuse_instead_of_launching(self):
        for agent in ("claude", "pi"):
            with self.subTest(agent=agent):
                result = subprocess.run([str(ROOT / "bin/preview-stubs" / agent), "--version"],
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stderr, "Agent execution disabled in foreman preview.\n")

    def test_refuses_non_devserve_targets_before_creating_files(self):
        for changes in ({"DATABASE_URL": ""}, {"DATABASE_URL": "postgresql://localhost/foreman_dev"},
                        {"DATABASE_URL": "postgresql://localhost/foreman_preview_other_123456789012"},
                        {"PORT": "4747"}, {"PREVIEW": "0"}):
            with self.subTest(changes=changes), tempfile.TemporaryDirectory() as directory:
                root = Path(directory).resolve()
                source = dict(PORT="4840", PREVIEW="1", DATABASE_URL=database_url(root))
                source.update(changes)
                with self.assertRaises(ValueError):
                    preview.environment(source, root)
                self.assertFalse((root / "tmp").exists())

    def test_preview_overrides_live_environment(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            suffix = hashlib.sha256(str(root).encode()).hexdigest()[:12]
            source = dict(os.environ, PORT="4840", PREVIEW="1",
                          DATABASE_URL=database_url(root),
                          FOREMAN_ROLE="all", FOREMAN_CONFIG_DIR="/live/config",
                          FOREMAN_PLANNING_TMUX_SOCKET="foreman",
                          FOREMAN_EXTERNAL_TMUX_SOCKET="default",
                          FOREMAN_URL="http://localhost:4747", FOREMAN_TOKEN="secret",
                          FOREMAN_DATABASE_URL="postgresql://localhost/foreman_dev",
                          TMUX="/live/socket,1,0", MIX_ENV="prod")
            env = preview.environment(source, root)
            self.assertEqual(env["FOREMAN_ROLE"], "web")
            self.assertEqual(env["PREVIEW"], "0")
            self.assertEqual(env["MIX_ENV"], "dev")
            self.assertEqual(env["DATABASE_URL"], source["DATABASE_URL"])
            self.assertEqual(env["PATH"].split(":")[0], str(root / "bin/preview-stubs"))
            self.assertEqual(env["FOREMAN_PLANNING_TMUX_SOCKET"], "fm-preview-" + suffix)
            self.assertEqual(env["FOREMAN_EXTERNAL_TMUX_SOCKET"], "fm-preview-" + suffix)
            self.assertEqual(env["FOREMAN_CONFIG_DIR"], str(root / "tmp/devserve/config"))
            self.assertTrue(Path(env["FOREMAN_CONFIG_DIR"]).is_dir())
            for key in ("FOREMAN_URL", "FOREMAN_TOKEN", "FOREMAN_DATABASE_URL", "TMUX"):
                self.assertNotIn(key, env)
