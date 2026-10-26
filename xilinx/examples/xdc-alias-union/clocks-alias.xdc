create_clock -period 10.0 -name sys [get_nets ddr_sys_clk]
set_false_path -from [get_clocks u_ddr3.sys_clk] -to [get_clocks u_ddr3.sys_clk]
