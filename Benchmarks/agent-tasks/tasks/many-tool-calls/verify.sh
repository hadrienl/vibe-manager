#!/bin/sh
cd "$1" || exit 2
python3 - <<'PY' || exit 1
import importlib, sys
sys.path.insert(0, ".")
for i in range(1, 26):
    module = importlib.import_module(f"handlers.handler_{i}")
    doc = (module.handle.__doc__ or "").strip().splitlines()
    expected = f"Serves {module.ROUTE}."
    if not doc or doc[0].strip() != expected:
        print(f"handler_{i}: {doc[:1]!r} != {expected!r}")
        sys.exit(1)
PY
python3 -m unittest discover -s tests -t . >/dev/null 2>&1
