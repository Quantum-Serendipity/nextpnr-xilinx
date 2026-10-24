import os

out = open(os.environ["CLOCKHOPS_OUT"], "w")
net = ctx.nets[os.environ.get("CLOCKHOPS_NET", "clk")]
for w, pm in net.wires:
    pip = pm.pip
    if pip is None or str(pip) == "":
        out.write("%s\t\t\t\t%s\t0\t0\n" % (w, ctx.getWireType(w)))
        continue
    d = ctx.getPipDelay(pip)
    src = ctx.getPipSrcWire(pip)
    out.write("%s\t%s\t%s\t%s\t%s\t%d\t%d\n" % (w, pip, src, ctx.getWireType(src), ctx.getWireType(w), d.maxDelay(),
                                                d.minDelay()))
out.close()
