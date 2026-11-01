import os

ctx.place()
print("two-placers: first placement done")
knob_unset("knob/partition_roi")
args = ArchArgs()
args.chipdb = os.environ["TWO_PLACERS_CHIPDB"]
second = load_design(os.environ["TWO_PLACERS_JSON"], args)
second.place()
print("two-placers: second placement done")
