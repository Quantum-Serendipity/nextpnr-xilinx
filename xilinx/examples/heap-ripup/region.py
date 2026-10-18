import os
x0, y0, x1, y1 = [int(v) for v in os.environ["RIPUP_REGION"].split(",")]
ctx.createRectangularRegion("ripup_box", x0, y0, x1, y1)
n = 0
for name, cell in ctx.cells:
    if cell.type.startswith("SLICE_") or cell.type == "CARRY4":
        ctx.constrainCellToRegion(name, "ripup_box")
        n += 1
print("region.py: constrained %d cell(s) to %d,%d..%d,%d" % (n, x0, y0, x1, y1))
