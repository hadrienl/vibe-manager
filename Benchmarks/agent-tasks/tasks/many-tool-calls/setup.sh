#!/bin/sh
# 25 handlers, each serving the route named in its ROUTE constant.
cd "$1" || exit 2
mkdir -p handlers tests
: > handlers/__init__.py
i=1
while [ $i -le 25 ]; do
  cat > "handlers/handler_$i.py" <<PY
ROUTE = "/api/v1/resource-$i"


def handle(request):
    return {"route": ROUTE, "id": request.get("id"), "n": $i}
PY
  i=$((i + 1))
done
cat > tests/test_handlers.py <<'PY'
import importlib
import unittest


class HandlersTests(unittest.TestCase):
    def test_every_handler_answers(self):
        for i in range(1, 26):
            module = importlib.import_module(f"handlers.handler_{i}")
            self.assertEqual(module.handle({"id": 7})["n"], i)


if __name__ == "__main__":
    unittest.main()
PY
