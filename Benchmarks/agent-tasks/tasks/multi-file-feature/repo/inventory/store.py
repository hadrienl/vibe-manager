"""The inventory, kept as a JSON file."""
import json
from pathlib import Path

from inventory.models import Item


def load(path):
    path = Path(path)
    if not path.exists():
        return []
    return [Item(**raw) for raw in json.loads(path.read_text())]


def save(path, items):
    Path(path).write_text(json.dumps([item.__dict__ for item in items], indent=2))
