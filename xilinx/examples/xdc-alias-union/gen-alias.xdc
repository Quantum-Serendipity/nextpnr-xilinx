create_clock -period 10.0 -name sys [get_nets ddr_sys_clk]
create_generated_clock -name g -source [get_nets u_ddr3.sys_clk] -divide_by 2 [get_nets {r[0]}]
