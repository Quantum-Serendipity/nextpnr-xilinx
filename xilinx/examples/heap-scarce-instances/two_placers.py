import os

os.environ.pop("NEXTPNR_PARTITION_ROI", None)
ctx.place()
print("two-placers: first placement done")
args = ArchArgs()
args.chipdb = os.environ["TWO_PLACERS_CHIPDB"]
second = load_design(os.environ["TWO_PLACERS_JSON"], args)
second.place()
print("two-placers: second placement done")
