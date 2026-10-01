Add three things to this inventory tool, keeping the existing behaviour and tests passing:

1. `inventory list --min-quantity N` lists only the items whose quantity is at least N.
2. `inventory total [--location L]` prints the total quantity of all items (or of those at location L) as a bare number.
3. `Item.is_low(threshold)` returns whether the item's quantity is below the threshold.

Add tests for what you add. Run them with `python3 -m unittest discover -s tests -t .`.
