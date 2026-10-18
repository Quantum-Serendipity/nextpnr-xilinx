set_multicycle_path 2 -setup -from [get_cells a_q*] -to [list [get_cells -hier -filter {NAME =~ bff*}] [get_cells d_q*]]
