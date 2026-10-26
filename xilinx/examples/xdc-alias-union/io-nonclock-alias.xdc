create_clock -period 10.0 [get_nets ddr_sys_clk]
set_input_delay -clock u_ddr3.clk_in -max 2.0 [get_ports btn]
