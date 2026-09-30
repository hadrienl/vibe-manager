#!/bin/sh
# Hidden acceptance tests, copied in only now.
cd "$1" || exit 2
cp "$(dirname "$0")/hidden/test_feature.py" tests/zz_hidden_test_feature.py
python3 -m unittest discover -s tests -t . 2>&1 | tail -3
python3 -m unittest discover -s tests -t . >/dev/null 2>&1
