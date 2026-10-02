from billing.invoice import calc, calc_with_discount


def summary(orders):
    total = 0
    for order in orders:
        if order.get("discount"):
            total += calc_with_discount(order["lines"], order["country"], order["discount"])
        else:
            total += calc(order["lines"], order["country"])
    return round(total, 2)
