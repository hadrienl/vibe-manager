import tempfile
import unittest
from pathlib import Path

from inventory import store
from inventory.cli import main
from inventory.models import Item


class FeatureTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.path = Path(self.folder.name) / "inv.json"
        store.save(self.path, [Item("bolt", 12), Item("nut", 3, "bin"), Item("gear", 7, "bin")])

    def tearDown(self):
        self.folder.cleanup()

    def run_cli(self, *argv):
        lines = []
        self.assertEqual(main(list(argv), path=self.path, out=lines.append), 0)
        return lines

    def test_list_filters_by_minimum_quantity(self):
        self.assertEqual(self.run_cli("list", "--min-quantity", "5"), ["bolt\t12\tshelf", "gear\t7\tbin"])

    def test_total_sums_quantities(self):
        self.assertEqual(self.run_cli("total"), ["22"])

    def test_total_by_location(self):
        self.assertEqual(self.run_cli("total", "--location", "bin"), ["10"])

    def test_item_knows_if_it_is_low(self):
        self.assertTrue(Item("nut", 3).is_low(threshold=5))
        self.assertFalse(Item("bolt", 12).is_low(threshold=5))


if __name__ == "__main__":
    unittest.main()
