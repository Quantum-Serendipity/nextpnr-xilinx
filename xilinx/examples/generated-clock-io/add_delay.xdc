set_input_delay -clock sysclk -max 9.500 [get_ports din_b]
set_input_delay -clock sysclk -max 1.000 -add_delay [get_ports din_b]
set_input_delay -clock sysclk -min 0.500 [get_ports din_b]
set_input_delay -clock sysclk -min 2.000 -add_delay [get_ports din_b]
