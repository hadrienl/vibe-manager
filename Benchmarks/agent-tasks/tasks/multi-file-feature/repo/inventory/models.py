from dataclasses import dataclass


@dataclass
class Item:
    name: str
    quantity: int
    location: str = "shelf"
