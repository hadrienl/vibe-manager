import unittest

from billing import invoice, report

LINES = [("a", 10.0, 2), ("b", 5.5, 4)]


class BillingTests(unittest.TestCase):
    def test_totals(self):
        self.assertEqual(invoice.total_with_vat(LINES, "FR"), 50.4)
        self.assertEqual(invoice.total_with_vat(LINES, "US"), 42.0)
        self.assertEqual(invoice.total_with_vat(LINES, "DE", discount=0.1), 44.98)

    def test_report(self):
        orders = [{"lines": LINES, "country": "ES"}, {"lines": LINES, "country": "FR", "discount": 0.5}]
        self.assertEqual(report.summary(orders), 76.02)


if __name__ == "__main__":
    unittest.main()
