#!/bin/sh
# About 4 MB of logs: far more than any context window, if read whole. The expected answer goes
# to the private folder ($2), out of the agent's reach.
cd "$1" || exit 2
python3 - "$2/expected" <<'PY'
import random
import sys
from pathlib import Path
random.seed(107)
components = ["auth", "billing", "search", "upload", "notify"]
weights = {"auth": 3, "billing": 11, "search": 5, "upload": 2, "notify": 1}
logs = Path("logs"); logs.mkdir()
errors = {c: 0 for c in components}
for day in range(1, 41):
    lines = []
    for n in range(1100):
        c = random.choice(components)
        if random.random() < 0.004 * weights[c]:
            errors[c] += 1
            lines.append(f"2026-09-{day:02d}T10:{n % 60:02d}:00Z ERROR {c}: request failed (code {random.randint(500, 599)})")
        else:
            lines.append(f"2026-09-{day:02d}T10:{n % 60:02d}:00Z INFO {c}: handled request {random.getrandbits(64):016x} in {random.randint(3, 900)}ms")
    (logs / f"app-2026-09-{day:02d}.log").write_text("\n".join(lines) + "\n")
Path(sys.argv[1] if len(sys.argv) > 1 else ".expected").write_text(max(errors, key=errors.get) + " " + str(sum(errors.values())) + "\n")
PY
