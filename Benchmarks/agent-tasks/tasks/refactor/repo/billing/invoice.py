def calc(lines, country):
    # lines: list of (label, unit_price, quantity)
    t = 0
    for l in lines:
        t = t + l[1] * l[2]
    if country == "FR":
        v = t * 0.2
    elif country == "DE":
        v = t * 0.19
    elif country == "ES":
        v = t * 0.21
    else:
        v = 0
    return round(t + v, 2)


def calc_with_discount(lines, country, discount):
    t = 0
    for l in lines:
        t = t + l[1] * l[2]
    t = t * (1 - discount)
    if country == "FR":
        v = t * 0.2
    elif country == "DE":
        v = t * 0.19
    elif country == "ES":
        v = t * 0.21
    else:
        v = 0
    return round(t + v, 2)
