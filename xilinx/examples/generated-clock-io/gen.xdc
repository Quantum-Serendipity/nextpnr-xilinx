create_generated_clock -name div2 -source [get_pins gsys/O] -divide_by 2 [get_nets div]
create_generated_clock -name sck -source [get_pins gsys/O] -divide_by 2 [get_ports sd_clk]
