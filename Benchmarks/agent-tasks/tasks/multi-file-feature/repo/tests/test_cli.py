import tempfile
import unittest
from pathlib import Path

from inventory.cli import main


class CliTests(unittest.TestCase):
    def test_add_then_list(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "inv.json"
            lines = []
            main(["add", "bolt", "12"], path=path, out=lines.append)
            main(["list"], path=path, out=lines.append)
            self.assertEqual(lines, ["added bolt", "bolt\t12\tshelf"])


if __name__ == "__main__":
    unittest.main()
