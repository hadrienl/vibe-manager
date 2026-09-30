"""Recognises ticket keys such as ABC-123 in free text."""
import re

_KEY = re.compile(r"\b([A-Z]{2,}[A-Z0-9]*)-(\d+)\b")


def find_keys(text):
    """Every ticket key in `text`, in order of appearance, without duplicates."""
    seen = []
    for match in _KEY.finditer(text):
        key = f"{match.group(1)}-{match.group(2)}"
        if key not in seen:
            seen.append(key)
    return seen
