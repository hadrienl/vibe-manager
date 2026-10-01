"""inventory list | inventory add NAME QUANTITY [--location L]"""
import argparse

from inventory import store
from inventory.models import Item


def main(argv, path="inventory.json", out=print):
    parser = argparse.ArgumentParser(prog="inventory")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("list")
    add = commands.add_parser("add")
    add.add_argument("name")
    add.add_argument("quantity", type=int)
    add.add_argument("--location", default="shelf")
    args = parser.parse_args(argv)

    items = store.load(path)
    if args.command == "list":
        for item in items:
            out(f"{item.name}\t{item.quantity}\t{item.location}")
    elif args.command == "add":
        items.append(Item(args.name, args.quantity, args.location))
        store.save(path, items)
        out(f"added {args.name}")
    return 0
