for name, net in ctx.nets:
    n = 0
    for w, pm in net.wires:
        if pm.strength >= STRENGTH_LOCKED:
            n += 1
    if n:
        print("locked.py: net %s locked %d wire(s)" % (name, n))
