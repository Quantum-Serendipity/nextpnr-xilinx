set_multicycle_path 2 -setup -from [get_cells a_q*] -to [get_cells -hier -filter {NAME =~ bff*}]
set_multicycle_path 1 -hold -from [get_cells a_q*] -to [get_cells -hier -filter {NAME =~ bff*}]
