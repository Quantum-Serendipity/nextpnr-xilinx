set_max_delay 30 -from [get_cells src_slow*] -to [get_cells dst_slow*]
set_false_path -to [get_cells dst_slow*]
