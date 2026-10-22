"""Synthetic selftest portability contracts; no server, model or network."""
import importlib.util
from pathlib import Path
import tempfile
import types
import shutil
import unittest

HERE = Path(__file__).resolve().parent
def load(name):
    spec = importlib.util.spec_from_file_location(name, HERE / (name + ".py"))
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module

class PortabilityTests(unittest.TestCase):
    def test_labels_are_short_safe_and_collision_resistant(self):
        module = load("selftest")
        labels = ["kv: kill-rank1: Unicode 中文", "kv/kill-rank1", "x" * 300]
        names = [module.log_filename(x) for x in labels]
        self.assertEqual(len(set(names)), len(labels))
        for name in names:
            self.assertNotRegex(name, r'[<>:"/\\|?*]')
            self.assertLessEqual(len(name), 77)
    def test_fake_disk_free_uses_portable_stdlib(self):
        module = load("fake_server")
        with tempfile.TemporaryDirectory() as root:
            fake = types.SimpleNamespace(a=types.SimpleNamespace(disk_free_bytes=0), roots=[root], stored=[0])
            actual = module.Fake.free_bytes(fake)
            self.assertGreater(actual, 0)
            self.assertLessEqual(abs(actual - shutil.disk_usage(root).free), 4 * 1024 * 1024)
            fake.a.disk_free_bytes = 100; fake.stored[0] = 40
            self.assertEqual(module.Fake.free_bytes(fake), 60)

if __name__ == "__main__":
    unittest.main()
