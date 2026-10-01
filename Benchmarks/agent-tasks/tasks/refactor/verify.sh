#!/bin/sh
cd "$1" || exit 2
git diff --quiet -- tests/ || { echo "tests were modified"; exit 1; }
if grep -rqE "def calc(_with_discount)?\b|calc_with_discount|\bcalc\(" billing; then echo "old functions remain"; exit 1; fi
grep -q "VAT_RATES" billing/invoice.py || { echo "no VAT_RATES table"; exit 1; }
python3 -m unittest discover -s tests -t . 2>&1 | tail -3
python3 -m unittest discover -s tests -t . >/dev/null 2>&1
