import unittest

from tickets.keys import find_keys


class FindKeysTests(unittest.TestCase):
    def test_finds_keys_in_order(self):
        self.assertEqual(find_keys("Fix ABC-12 then DEF-3"), ["ABC-12", "DEF-3"])

    def test_ignores_duplicates(self):
        self.assertEqual(find_keys("ABC-12, ABC-12"), ["ABC-12"])

    def test_accepts_single_letter_teams(self):
        # Linear teams may have a one-letter key.
        self.assertEqual(find_keys("See A-7 and B2-9"), ["A-7", "B2-9"])


if __name__ == "__main__":
    unittest.main()
