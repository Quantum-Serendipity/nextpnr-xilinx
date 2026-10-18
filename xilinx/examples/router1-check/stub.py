target = None
for name, net in ctx.nets:
    drv = net.driver
    if drv.cell is None or drv.cell.type != "SLICE_FFX" or len(net.users) == 0:
        continue
    target = (name, net)
    break
if target is None:
    raise RuntimeError("stub.py: no flip-flop driven net")
name, net = target
bound = None
for pip in ctx.getPips():
    src = ctx.getPipSrcWire(pip)
    dst = ctx.getPipDstWire(pip)
    if pip.startswith("NULL_") or "PSEUDO" in pip:
        continue
    if ctx.checkPipAvail(pip) and ctx.checkWireAvail(src) and ctx.checkWireAvail(dst):
        ctx.bindPip(pip, net, STRENGTH_LOCKED)
        bound = pip
        break
if bound is None:
    raise RuntimeError("stub.py: no free pip")
print("stub.py: bound pip %s to net %s" % (bound, name))
