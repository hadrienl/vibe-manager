#!/bin/sh
# Passes when the whole suite passes and the test file is untouched.
cd "$1" || exit 2
git diff --quiet -- tests/ || { echo "tests were modified"; exit 1; }
python3 -m unittest discover -s tests -t . 2>&1 | tail -3
python3 -m unittest discover -s tests -t . >/dev/null 2>&1
