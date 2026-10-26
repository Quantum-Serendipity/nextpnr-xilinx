# Partition keepout licence and verdict

`nextpnr-xilinx --chipdb <db> --test-keepout` runs the unit tests of `partition_keepout_licence` and
`partition_keepout_verdict` in-process against the chipdb and exits; no design is loaded. `run.sh`
turns each `keepout-test:` line into a `PASS` or `FAIL` line and fails if the binary exits non-zero.

```
CHIPDB=/path/to/xc7a100tfgg484.bin NEXTPNR=/path/to/nextpnr-xilinx ./run.sh
```

| test | passes when |
|---|---|
| verdict truth table | every combination of narrow bit, locked pip, check flag and allow bit, in rectangles 0 to 2, gives the tabulated verdict, and a pip outside every rectangle is OUTSIDE |
| named exemption admits every rectangle | a net in the keepout exemption set has no check and is admitted to both rectangles |
| unplaced PSEUDO_GND driver is a constant exemption | constant, not buffer, admitted everywhere |
| PSEUDO_VCC on a global-buffer bel is counted constant, not buffer | the PSEUDO_VCC bel is a global buffer to `getBelGlobalBuf`, and the licence still says constant |
| placed BUFGCTRL driver is a buffer exemption | admitted to both rectangles |
| unplaced BUFGCTRL driver is no exemption | an unplaced buffer is licensed by its anchors like any net |
| a net anchored in both of two rectangles is unchecked | anchored and allowed in both, no check, OUTSIDE outside both |
| the same net under three rectangles is vetoed from the third | checked, and the third rectangle is VETO_RECT |
| a user anchors its rectangle and no other | a user cell inside rectangle 0 admits rectangle 0 and vetoes rectangle 1 |
| a governed net is admitted to its own rectangle only | a net the partition census governs in rectangle 1 is admitted there and vetoed from rectangle 0 |
| an unanchored net is vetoed from every rectangle | allow is empty and both rectangles are VETO_RECT |
| narrow keepout: a locked pip in an anchored rectangle is the only pip admitted there | the locked pip is ADMIT, another pip in that rectangle VETO_NARROW, and a locked pip in an unanchored rectangle narrows nothing |
| narrow keepout: a pip bound below LOCKED does not narrow its rectangle | STRONG binds are not taken |
| narrow keepout off: a locked pip narrows nothing | with narrowing off the locked pip is ignored |
| a licence pip narrows its anchored rectangle, and one in an unanchored rectangle is ignored | the licence pip is taken unbound and is the only pip admitted in rectangle 0 |
