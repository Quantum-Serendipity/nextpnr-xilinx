net = ctx.nets["lfsr[14]"]
cur = ctx.getBelPinWire(net.driver.cell.bel, net.driver.port)
bound = [(w, pm.pip) for w, pm in net.wires]
chain, tile = [], None
while True:
    nxt = [(w, p) for w, p in bound if p is not None and str(ctx.getPipSrcWire(p)) == str(cur)]
    if len(nxt) != 1:
        break
    w, p = nxt[0]
    t = str(w).split("/")[0]
    if tile is not None and t != tile:
        break
    tile = t
    chain.append(w)
    cur = w
for w in chain:
    ctx.unbindWire(w)
print("driver-cut.py: lfsr[14] driver chain of %d wire(s) in %s unbound: %s" % (
    len(chain), tile, " ".join(str(w) for w in chain)))
