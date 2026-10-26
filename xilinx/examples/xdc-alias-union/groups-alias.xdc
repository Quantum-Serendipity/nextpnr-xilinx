create_clock -period 10.0 -name sys [get_nets ddr_sys_clk]
create_generated_clock -name g -source [get_nets ddr_sys_clk] -divide_by 2 [get_nets {r[0]}]
set_clock_groups -asynchronous -group [get_clocks u_ddr3.sys_clk] -group [get_clocks g]
