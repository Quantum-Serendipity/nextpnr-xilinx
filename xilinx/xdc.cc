/*
 *  nextpnr -- Next Generation Place and Route
 *
 *  Copyright (C) 2019  David Shah <david@symbioticeda.com>
 *
 *  Permission to use, copy, modify, and/or distribute this software for any
 *  purpose with or without fee is hereby granted, provided that the above
 *  copyright notice and this permission notice appear in all copies.
 *
 *  THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 *  WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 *  MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 *  ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 *  WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 *  ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 *  OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *
 */

#include <functional>
#include <numeric>
#include "log.h"
#include "nextpnr.h"
NEXTPNR_NAMESPACE_BEGIN

void Arch::parseXdc(std::istream &in)
{

    if (!in)
        log_error("failed to open LPF file\n");
    std::string line;
    std::string linebuf;
    int lineno = 0;
    int missing_targets = 0;

    auto isempty = [](const std::string &str) {
        return std::all_of(str.begin(), str.end(), [](char c) { return std::isspace(c); });
    };
    auto strip_quotes = [](const std::string &str) {
        if (str.empty())
            return str;
        if (str.front() == '"') {
            if (str.back() == '"' && str.size() >= 2)
                return str.substr(1, str.size() - 2);
            return str;
        } else if (str.front() == '{') {
            if (str.back() == '}' && str.size() >= 2)
                return str.substr(1, str.size() - 2);
            return str;
        } else {
            return str;
        }
    };
    auto split_to_args = [](const std::string &str, bool group_brackets) {
        std::vector<std::string> split_args;
        std::string buffer;
        auto flush = [&]() {
            if (!buffer.empty())
                split_args.push_back(buffer);
            buffer.clear();
        };
        int brcount = 0;
        for (char c : str) {
            if ((c == '[' || c == '{') && group_brackets) {
                ++brcount;
            }
            if ((c == ']' || c == '}') && group_brackets) {
                --brcount;
                buffer += c;
                if (brcount == 0)
                    flush();
                continue;
            }
            if (std::isspace(c)) {
                if (brcount == 0) {
                    flush();
                    continue;
                }
            }
            buffer += c;
        }
        flush();
        return split_args;
    };

    auto trim_all = [](std::string s) {
        s.erase(std::remove_if(s.begin(), s.end(), [](unsigned char c) {
            return c == ' ' || c == '\t';
        }), s.end());
        return s;
    };
    // Vivado calls a one-bit vector port "a[0]", but the JSON frontend collapses a
    // width-1, offset-0 vector to the bare name "a" (get_bit_name(),
    // frontend/frontend_base.h:367) because yosys' JSON carries nothing that tells
    // `wire [0:0] a` apart from `wire a`. An XDC written against Vivado names
    // therefore misses such a port, the constraint is dropped, and the design dies
    // later with "port a of type PAD has no IOSTANDARD property" -- a message that
    // points nowhere near the cause.  Strip a trailing "[0]" so the lookup can retry.
    auto debus_zero = [](const std::string &str) {
        if (str.size() > 3 && str.compare(str.size() - 3, 3, "[0]") == 0)
            return str.substr(0, str.size() - 3);
        return std::string();
    };
    auto get_cells = [&](std::string str) {
        std::vector<CellInfo *> tgt_cells;
        if (str.empty() || str.front() != '[')
            log_error("failed to parse target (on line %d)\n", lineno);
        str = str.substr(1, str.size() - 2);
        auto split = split_to_args(str, false);
        auto split_name = trim_all(str.substr(split.at(0).length()));
        if (split.size() < 1)
            log_error("failed to parse target (on line %d)\n", lineno);
        if (split.front() != "get_ports")
            log_warning("set_property: target %s not supported (on line %d)\n", split.front().c_str(), lineno);
        if (split.size() < 2)
            log_error("failed to parse target (on line %d)\n", lineno);
        const std::string target_name = strip_quotes(split_name);
        IdString cellname = id_if_interned(target_name);
        if (!cells.count(cellname)) {
            std::string base = debus_zero(target_name);
            if (!base.empty() && cells.count(id_if_interned(base)))
                cellname = id_if_interned(base);
        }
        if (cells.count(cellname))
            tgt_cells.push_back(cells.at(cellname).get());
        else {
            // A board-level XDC legitimately constrains every pin of the
            // board while a design uses a subset (the standard apio/PCF
            // practice), so these are not reportable events: stay silent
            // like the ice40 flow does, and itemise only in verbose mode.
            missing_targets++;
            if (xdc_strict)
                xdc_dropped.push_back(stringf("%s line %d: %s: no cell named '%s'", xdc_file.c_str(), lineno,
                                              split.front().c_str(), target_name.c_str()));
            else if (getCtx()->verbose)
                log_info("%s: no cell named '%s' (on line %d) - this target is ignored\n", split.front().c_str(),
                         target_name.c_str(), lineno);
        }
        return tgt_cells;
    };

    auto get_nets = [&](std::string str) {
        std::vector<NetInfo *> tgt_nets;
        if (str.empty() || str.front() != '[')
            log_error("failed to parse target (on line %d)\n", lineno);
        str = str.substr(1, str.size() - 2);
        auto split = split_to_args(str, false);
        auto split_name = trim_all(str.substr(split.at(0).length()));
        if (split.size() < 1)
            log_error("failed to parse target (on line %d)\n", lineno);
        if (split.front() != "get_ports" && split.front() != "get_nets")
            log_error("targets other than 'get_ports' or 'get_nets' are not supported (on line %d)\n", lineno);
        if (split.size() < 2)
            log_error("failed to parse target (on line %d)\n", lineno);
        const std::string target_name = strip_quotes(split_name);
        NetInfo *maybe_net = getNetByAlias(id_if_interned(target_name));
        if (maybe_net == nullptr) {
            std::string base = debus_zero(target_name);
            if (!base.empty())
                maybe_net = getNetByAlias(id_if_interned(base));
        }
        if (maybe_net != nullptr)
            tgt_nets.push_back(maybe_net);
        else {
            missing_targets++;
            if (xdc_strict)
                xdc_dropped.push_back(stringf("%s line %d: %s: no net or port named '%s'", xdc_file.c_str(), lineno,
                                              split.front().c_str(), target_name.c_str()));
            else if (getCtx()->verbose)
                log_info("%s: no net or port named '%s' (on line %d) - this target is ignored\n",
                         split.front().c_str(), target_name.c_str(), lineno);
        }
        return tgt_nets;
    };

    auto glob_match = [](const std::string &name, const std::string &pat) {
        size_t n = 0, p = 0, star = std::string::npos, mark = 0;
        while (n < name.size()) {
            if (p < pat.size() && (pat[p] == name[n] || pat[p] == '?')) { ++n; ++p; }
            else if (p < pat.size() && pat[p] == '*') { star = p++; mark = n; }
            else if (star != std::string::npos) { p = star + 1; n = ++mark; }
            else return false;
        }
        while (p < pat.size() && pat[p] == '*') ++p;
        return p == pat.size();
    };

    struct Selection
    {
        bool ok = true;
        std::string error;
        std::vector<CellInfo *> cells;
        std::vector<NetInfo *> nets;
        std::vector<std::string> clocks;
        std::vector<std::pair<CellInfo *, std::string>> pins;
        bool has_cells = false, has_nets = false, has_clocks = false;
    };

    auto is_ff = [&](const CellInfo *ci) {
        static const std::vector<std::string> ff_types{"FDRE",   "FDSE",   "FDCE",   "FDPE",     "FDRE_1",
                                                       "FDSE_1", "FDCE_1", "FDPE_1", "SLICE_FFX"};
        const std::string &t = ci->type.str(this);
        return std::find(ff_types.begin(), ff_types.end(), t) != ff_types.end();
    };

    auto ff_pin = [&](const CellInfo *ci, const std::string &port) -> std::string {
        if (ci->type.str(this) == "SLICE_FFX")
            return port;
        if (port == "C")
            return xc7 ? "CK" : "CLK";
        if (port == "R" || port == "S" || port == "CLR" || port == "PRE")
            return "SR";
        return port;
    };

    auto is_combinational = [&](const CellInfo *ci) {
        static const std::vector<std::string> prefixes{"LUT", "SLICE_LUTX", "CARRY4", "MUXF", "F7MUX", "F8MUX",
                                                       "F9MUX", "SELMUX2_1", "INV", "VCC", "GND", "PSEUDO_"};
        const std::string &t = ci->type.str(this);
        if (ci->attrs.count(id_X_LUT_AS_DRAM) || ci->attrs.count(id_X_LUT_AS_SRL))
            return false;
        for (auto &pre : prefixes)
            if (t.compare(0, pre.size(), pre) == 0)
                return true;
        return false;
    };

    auto clock_known = [&](const std::string &pat) {
        for (auto &n : nets) {
            const NetInfo *ni = n.second.get();
            bool clocky = ni->clkconstr != nullptr;
            if (!clocky && ni->driver.cell != nullptr) {
                const std::string &dt = ni->driver.cell->type.str(this);
                clocky = dt.find("BUF") != std::string::npos || dt.find("PLL") != std::string::npos ||
                         dt.find("MMCM") != std::string::npos;
            }
            if (!clocky)
                continue;
            if (glob_match(n.first.str(this), pat))
                return true;
            if (ni->clkconstr != nullptr && !ni->clkconstr->name.empty() && glob_match(ni->clkconstr->name, pat))
                return true;
        }
        return false;
    };

    auto expand_list = [&](const std::string &tok) {
        std::vector<std::string> out;
        if (!tok.empty() && (tok.front() == '{' || tok.front() == '"'))
            for (auto &t : split_to_args(strip_quotes(tok), false))
                out.push_back(strip_quotes(t));
        else
            out.push_back(tok);
        for (auto &o : out)
            o.erase(std::remove(o.begin(), o.end(), '\\'), o.end());
        return out;
    };

    auto cell_names = [&](CellInfo *ci) {
        std::vector<std::string> names{ci->name.str(this)};
        if (!names.front().empty() && names.front().front() == '$') {
            auto q = ci->ports.find(id("Q"));
            if (q != ci->ports.end() && q->second.net != nullptr && q->second.type == PORT_OUT) {
                names.push_back(q->second.net->name.str(this));
                for (auto alias : q->second.net->aliases)
                    if (alias != q->second.net->name)
                        names.push_back(alias.str(this));
            }
        }
        return names;
    };

    auto name_matches = [&](const std::string &name, const std::string &pat, bool hier) {
        std::string dotted = pat;
        std::replace(dotted.begin(), dotted.end(), '/', '.');
        auto one = [&](const std::string &n) { return glob_match(n, pat) || (dotted != pat && glob_match(n, dotted)); };
        if (one(name))
            return true;
        if (hier)
            for (size_t i = 0; i < name.size(); i++)
                if ((name[i] == '.' || name[i] == '/') && one(name.substr(i + 1)))
                    return true;
        return false;
    };

    auto parse_filter = [&](const std::string &expr, std::string &pat) {
        std::string e = strip_quotes(expr);
        size_t op = e.find("=~");
        if (op == std::string::npos)
            op = e.find("==");
        if (op == std::string::npos)
            return false;
        std::string lhs = trim_all(e.substr(0, op));
        if (lhs != "NAME" && lhs != "name")
            return false;
        pat = strip_quotes(trim_all(e.substr(op + 2)));
        pat.erase(std::remove(pat.begin(), pat.end(), '\\'), pat.end());
        return !pat.empty();
    };

    auto add_cell = [](std::vector<CellInfo *> &v, CellInfo *ci) {
        if (ci != nullptr && std::find(v.begin(), v.end(), ci) == v.end())
            v.push_back(ci);
    };

    std::function<void(const std::string &, Selection &)> select;
    select = [&](const std::string &arg, Selection &sel) {
        if (arg.size() < 2 || arg.front() != '[' || arg.back() != ']') {
            sel.has_clocks = true;
            for (auto &t : expand_list(arg))
                sel.clocks.push_back(t);
            return;
        }
        std::vector<std::string> toks = split_to_args(arg.substr(1, arg.size() - 2), true);
        if (toks.empty()) {
            sel.ok = false;
            sel.error = "empty object query";
            return;
        }
        const std::string qcmd = toks.front();
        if (qcmd == "list" || qcmd == "concat") {
            for (size_t i = 1; i < toks.size(); i++)
                select(toks.at(i), sel);
            return;
        }
        bool hier = false;
        std::vector<std::string> pats;
        for (size_t i = 1; i < toks.size(); i++) {
            const std::string &t = toks.at(i);
            if (t == "-hier" || t == "-hierarchical")
                hier = true;
            else if (t == "-quiet" || t == "-nocase")
                ;
            else if (t == "-filter" && i + 1 < toks.size()) {
                std::string fp;
                if (!parse_filter(toks.at(++i), fp)) {
                    sel.ok = false;
                    sel.error = "unsupported -filter '" + toks.at(i) + "' (only NAME =~ <glob> is read)";
                    return;
                }
                pats.push_back(fp);
            } else if (!t.empty() && t.front() == '-') {
                sel.ok = false;
                sel.error = "unsupported option '" + t + "' to " + qcmd;
                return;
            } else
                for (auto &p : expand_list(t))
                    pats.push_back(p);
        }
        if (pats.empty()) {
            sel.ok = false;
            sel.error = qcmd + " with no pattern";
            return;
        }
        if (qcmd == "get_clocks") {
            sel.has_clocks = true;
            for (auto &p : pats)
                sel.clocks.push_back(p);
        } else if (qcmd == "get_pins") {
            sel.has_cells = true;
            for (auto &p : pats) {
                size_t slash = p.find_last_of('/');
                if (slash == std::string::npos || slash == 0 || slash + 1 == p.size()) {
                    sel.ok = false;
                    sel.error = "get_pins pattern '" + p + "' has no <cell>/<pin> separator";
                    return;
                }
                std::string cpat = p.substr(0, slash), ppat = p.substr(slash + 1);
                for (auto &c : cells) {
                    CellInfo *ci = c.second.get();
                    bool named = false;
                    for (auto &n : cell_names(ci))
                        if (name_matches(n, cpat, hier)) {
                            named = true;
                            break;
                        }
                    if (!named)
                        continue;
                    for (auto &port : ci->ports) {
                        std::string pn = port.first.str(this);
                        if (!glob_match(pn, ppat))
                            continue;
                        if (!is_ff(ci)) {
                            sel.ok = false;
                            sel.error = "get_pins is read only on flip-flop pins, and '" + ci->name.str(this) + "/" +
                                        pn + "' is a pin of a " + ci->type.str(this);
                            return;
                        }
                        std::pair<CellInfo *, std::string> entry{ci, pn};
                        if (std::find(sel.pins.begin(), sel.pins.end(), entry) == sel.pins.end())
                            sel.pins.push_back(entry);
                    }
                }
            }
        } else if (qcmd == "get_cells") {
            sel.has_cells = true;
            for (auto &p : pats) {
                for (auto &c : cells)
                    for (auto &n : cell_names(c.second.get()))
                        if (name_matches(n, p, hier)) {
                            add_cell(sel.cells, c.second.get());
                            break;
                        }
            }
        } else if (qcmd == "get_ports") {
            sel.has_cells = true;
            for (auto &p : pats)
                for (auto &port : ports) {
                    std::string pn = port.first.str(this);
                    if (!glob_match(pn, p) && !(debus_zero(p) != "" && glob_match(pn, debus_zero(p))))
                        continue;
                    auto pad = cells.find(port.first);
                    if (pad == cells.end())
                        continue;
                    add_cell(sel.cells, pad->second.get());
                    for (auto &pp : pad->second->ports) {
                        NetInfo *pnet = pp.second.net;
                        if (pnet == nullptr)
                            continue;
                        add_cell(sel.cells, pnet->driver.cell);
                        for (auto &u : pnet->users)
                            add_cell(sel.cells, u.cell);
                    }
                }
        } else if (qcmd == "get_nets") {
            sel.has_nets = true;
            for (auto &p : pats) {
                NetInfo *exact = getNetByAlias(id_if_interned(p));
                if (exact != nullptr) {
                    if (std::find(sel.nets.begin(), sel.nets.end(), exact) == sel.nets.end())
                        sel.nets.push_back(exact);
                    continue;
                }
                for (auto &n : nets)
                    if (name_matches(n.first.str(this), p, hier) &&
                        std::find(sel.nets.begin(), sel.nets.end(), n.second.get()) == sel.nets.end())
                        sel.nets.push_back(n.second.get());
            }
        } else {
            sel.ok = false;
            sel.error = "unsupported object query '" + qcmd + "'";
        }
    };

    auto refuse = [&](const std::string &what, const std::string &why) {
        if (xdc_strict)
            xdc_dropped.push_back(stringf("%s line %d: %s: %s (constraint not applied)", xdc_file.c_str(), lineno,
                                          what.c_str(), why.c_str()));
        else
            log_warning("%s: %s, constraint not applied (on line %d)\n", what.c_str(), why.c_str(), lineno);
    };

    auto stamp = [&](CellInfo *ci, const char *attr, const std::string &entry) {
        IdString a = id(attr);
        std::string v = ci->attrs.count(a) ? ci->attrs.at(a).as_string() : std::string();
        v += (v.empty() ? "" : ",") + entry;
        ci->attrs[a] = v;
    };

    auto parse_exception = [&](const std::vector<std::string> &args, TimingException::Kind kind) {
        const std::string &what = args.front();
        const bool is_max = kind == TimingException::MAX_DELAY, is_mcp = kind == TimingException::MULTICYCLE;
        TimingException exc;
        exc.kind = kind;
        exc.source = stringf("%s line %d", xdc_file.c_str(), lineno);
        Selection from, to, through;
        bool got_from = false, got_to = false, got_through = false, got_value = false;
        bool setup_only = false, hold_only = false, got_start = false, got_end = false;
        for (size_t i = 1; i < args.size(); i++) {
            const std::string &a = args.at(i);
            if ((a == "-from" || a == "-to" || a == "-through") && i + 1 < args.size()) {
                Selection &s = a == "-from" ? from : a == "-to" ? to : through;
                (a == "-from" ? got_from : a == "-to" ? got_to : got_through) = true;
                select(args.at(++i), s);
                if (!s.ok)
                    return refuse(what, a + ": " + s.error);
            } else if (a == "-setup")
                setup_only = true;
            else if (a == "-hold")
                hold_only = true;
            else if (a == "-datapath_only")
                exc.datapath_only = true;
            else if (a == "-quiet" || a == "-reset_path")
                ;
            else if (is_mcp && a == "-start")
                got_start = true;
            else if (is_mcp && a == "-end")
                got_end = true;
            else if (is_mcp && !got_value && !a.empty() && a.front() != '-') {
                if (!std::all_of(a.begin(), a.end(), ::isdigit) || a.size() > 6)
                    return refuse(what, "cannot read path multiplier '" + a + "'");
                exc.multiplier = std::stoi(a);
                got_value = true;
            } else if (is_max && !got_value && !a.empty() && a.front() != '-') {
                try {
                    size_t used = 0;
                    double ns = std::stod(a, &used);
                    if (used != a.size())
                        throw std::invalid_argument(a);
                    exc.value = getDelayFromNS(ns).maxDelay();
                    got_value = true;
                } catch (std::exception &) {
                    return refuse(what, "cannot read delay value '" + a + "'");
                }
            } else
                return refuse(what, "unsupported argument '" + a + "'");
        }
        if (is_max && !got_value)
            return refuse(what, "no delay value");
        if (is_max && (setup_only || hold_only))
            return refuse(what, "-setup/-hold are not read for set_max_delay");
        if (is_mcp) {
            if (!got_value)
                return refuse(what, "no path multiplier");
            if (setup_only && hold_only)
                return refuse(what, "-setup and -hold together; give each its own set_multicycle_path");
            if (got_start && got_end)
                return refuse(what, "-start and -end together");
            if (exc.datapath_only)
                return refuse(what, "-datapath_only is not read for set_multicycle_path");
            if (exc.multiplier < (hold_only ? 0 : 1))
                return refuse(what, stringf("a %s multiplier of %d", hold_only ? "hold" : "setup", exc.multiplier));
            if (got_through)
                return refuse(what, "-through is not read for set_multicycle_path");
            exc.setup = !hold_only;
            exc.hold = hold_only;
            exc.launch_period = hold_only ? !got_end : got_start;
        } else if (got_start || got_end)
            return refuse(what, "-start/-end are read only for set_multicycle_path");
        else if (setup_only != hold_only) {
            exc.setup = setup_only;
            exc.hold = hold_only;
        }
        if (is_max)
            exc.hold = !exc.datapath_only;
        if (got_through) {
            if (got_from || got_to || is_max || !exc.setup || !exc.hold)
                return refuse(what, "-through is read only as a bare 'set_false_path -through [get_nets ...]'");
            if (through.has_cells || through.has_clocks || !through.has_nets)
                return refuse(what, "-through takes get_nets only");
            if (through.nets.empty())
                return refuse(what, "-through matched no net");
            for (auto n : through.nets)
                n->attrs[id("NEXTPNR_TIMING_IGNORE")] = std::string("1");
            timing_ignore_nets = true;
            log_info("%s: timing ignored on %d net(s) (on line %d)\n", what.c_str(), int(through.nets.size()),
                     lineno);
            return;
        }
        if (!got_from && !got_to)
            return refuse(what, "neither -from nor -to given");
        for (Selection *s : {&from, &to})
            if (s->has_nets)
                return refuse(what, "-from/-to take get_cells, get_pins, get_ports or get_clocks, not get_nets");
        for (Selection *s : {&from, &to})
            for (auto &clk : s->clocks)
                if (!clock_known(clk))
                    return refuse(what, std::string(s == &from ? "-from" : "-to") + " clock '" + clk +
                                                "' matched no clock");
        bool from_had_cells = !from.cells.empty(), to_had_cells = !to.cells.empty();
        for (Selection *s : {&from, &to})
            s->cells.erase(std::remove_if(s->cells.begin(), s->cells.end(), is_combinational), s->cells.end());
        std::vector<CellInfo *> from_pin_cells;
        for (auto &pin : from.pins) {
            std::string pn = ff_pin(pin.first, pin.second);
            if (pn != "Q" && pn != "CK" && pn != "CLK")
                return refuse(what, "-from pin '" + pin.first->name.str(this) + "/" + pin.second +
                                            "' is not a startpoint (only the clock or Q pin of a flip-flop)");
            add_cell(from_pin_cells, pin.first);
        }
        for (auto &pin : to.pins) {
            std::string pn = ff_pin(pin.first, pin.second);
            if (pn != "D" && pn != "CE" && pn != "SR")
                return refuse(what, "-to pin '" + pin.first->name.str(this) + "/" + pin.second +
                                            "' is not a timed data pin (only D, CE or R/S/CLR/PRE of a flip-flop)");
        }
        for (auto ci : from_pin_cells)
            add_cell(from.cells, ci);
        if (got_from && from.cells.empty() && from.clocks.empty())
            return refuse(what, from_had_cells ? "-from matched no timing startpoint" : "-from matched nothing");
        if (got_to && to.cells.empty() && to.pins.empty() && to.clocks.empty())
            return refuse(what, to_had_cells ? "-to matched no timing endpoint" : "-to matched nothing");
        exc.from_cells = !from.cells.empty();
        exc.to_cells = !to.cells.empty() || !to.pins.empty();
        exc.from_clocks = from.clocks;
        exc.to_clocks = to.clocks;
        int idx = int(timing_exceptions.size());
        for (auto ci : from.cells)
            stamp(ci, "NEXTPNR_TEXC_FROM", std::to_string(idx));
        for (auto ci : to.cells)
            stamp(ci, "NEXTPNR_TEXC_TO", std::to_string(idx));
        for (auto &pin : to.pins)
            stamp(pin.first, "NEXTPNR_TEXC_TO", std::to_string(idx) + ":" + ff_pin(pin.first, pin.second));
        timing_exceptions.push_back(exc);
        std::string detail;
        if (is_max)
            detail = stringf(", max %.3f ns", getDelayNS(exc.value));
        else if (is_mcp)
            detail = stringf(", %s multiplier %d in %s clock periods", exc.setup ? "setup" : "hold", exc.multiplier,
                             exc.launch_period ? "launch" : "capture");
        log_info("%s: exception #%d, from %d cell(s) %d clock pattern(s), to %d cell(s) %d pin(s) %d clock "
                 "pattern(s)%s (on line %d)\n",
                 what.c_str(), idx, int(from.cells.size()), int(from.clocks.size()), int(to.cells.size()),
                 int(to.pins.size()), int(to.clocks.size()), detail.c_str(), lineno);
    };

    auto parse_clock_groups = [&](const std::vector<std::string> &args) {
        const std::string &what = args.front();
        TimingClockGroups grp;
        grp.source = stringf("%s line %d", xdc_file.c_str(), lineno);
        for (size_t i = 1; i < args.size(); i++) {
            const std::string &a = args.at(i);
            if (a == "-group" && i + 1 < args.size()) {
                Selection s;
                select(args.at(++i), s);
                if (!s.ok)
                    return refuse(what, "-group: " + s.error);
                if (s.has_cells || s.has_nets || s.clocks.empty())
                    return refuse(what, "-group takes clocks");
                for (auto &clk : s.clocks)
                    if (!clock_known(clk))
                        return refuse(what, "-group clock '" + clk + "' matched no clock");
                grp.groups.push_back(s.clocks);
            } else if (a == "-name" && i + 1 < args.size())
                ++i;
            else if (a == "-asynchronous" || a == "-physically_exclusive" || a == "-logically_exclusive" ||
                     a == "-quiet")
                ;
            else if (a == "-include_generated_clocks")
                grp.include_generated = true;
            else
                return refuse(what, "unsupported argument '" + a + "'");
        }
        if (grp.groups.empty())
            return refuse(what, "no -group given");
        log_info("%s: %d clock group(s) (on line %d)\n", what.c_str(), int(grp.groups.size()), lineno);
        timing_clock_groups.push_back(grp);
    };

    while (std::getline(in, line)) {
        ++lineno;
        // Trim comments, from # until end of the line
        size_t cstart = line.find('#');
        if (cstart != std::string::npos)
            line = line.substr(0, cstart);
        while (!line.empty() && std::isspace(line.back()))
            line.pop_back();
        if (!line.empty() && line.back() == ';')
            line.pop_back();
        if (isempty(line))
            continue;

        std::vector<std::string> arguments = split_to_args(line, true);
        if (arguments.empty())
            continue;
        std::string &cmd = arguments.front();
        if (cmd == "set_property") {
            std::vector<std::pair<std::string, std::string>> arg_pairs;
            // COPIED BEFORE THE std::move BELOW. The INTERNAL_VREF test used to
            // read arguments.at(1) after that element had been moved into
            // arg_pairs, so it compared against a moved-from string and the
            // branch was unreachable; the property fell through to get_cells()
            // and surfaced as "target get_iobanks not supported".
            const std::string property = arguments.size() > 1 ? arguments.at(1) : std::string();
            if (arguments.size() != 4)
                log_error("expected four arguments to 'set_property' (on line %d)\n", lineno);
            else if (arguments.at(1) == "-dict") {
                std::vector<std::string> dict_args = split_to_args(strip_quotes(arguments.at(2)), false);
                if ((dict_args.size() % 2) != 0)
                    log_error("expected an even number of argument for dictionary (on line %d)\n", lineno);
                arg_pairs.reserve(dict_args.size() / 2);
                for (int cursor = 0; cursor + 1 < int(dict_args.size()); cursor += 2) {
                    arg_pairs.emplace_back(std::move(dict_args.at(cursor)), std::move(dict_args.at(cursor + 1)));
                }
            } else
                arg_pairs.emplace_back(std::move(arguments.at(1)), std::move(arguments.at(2)));
            // NOT SILENTLY. The VREF level is not read from the XDC at all: it is
            // derived from the bank's IOSTANDARD -- any single-ended SSTL input
            // sets the HCLK row's vref flag (fasm.cc:1467) -- and then written as
            // the fixed level VREF.V_675_MV (fasm.cc:1845). 0.675 V is VCCO/2 for
            // SSTL135 and so happens to be right for DDR3L; an SSTL15 design
            // needs 0.75 V and would be given 0.675 V regardless of what this
            // property asks for. Saying so is the difference between a design
            // that is correct and a design that is correct by luck.
            if (property == "INTERNAL_VREF") {
                log_warning("INTERNAL_VREF is not read from the XDC; the VREF level is derived from the bank's "
                            "IOSTANDARD and fixed at 0.675 V (on line %d)\n",
                            lineno);
                continue;
            }
            if (arguments.at(3).size() > 2 && (arguments.at(3) == "[current_design]" || arguments.at(3) == "[current_project]")) {
                log_warning("[current_design] isn't supported, ignoring (on line %d)\n", lineno);
                continue;
            }
            std::vector<CellInfo *> dest = get_cells(arguments.at(3));
            for (auto c : dest)
                for (const auto &pair : arg_pairs)
                    c->attrs[id(pair.first)] = std::string(pair.second);
        } else if (cmd == "create_clock") {
            double period = 0;
            bool got_period = false;
            std::string clock_name, waveform;
            bool got_waveform = false;
            int cursor = 1;
            for (cursor = 1; cursor < int(arguments.size()); cursor++) {
                std::string opt = arguments.at(cursor);
                if (opt == "-add")
                    ;
                else if (opt == "-name") {
                    cursor++;
                    if (cursor < int(arguments.size()))
                        clock_name = strip_quotes(arguments.at(cursor));
                } else if (opt == "-waveform") {
                    cursor++;
                    got_waveform = cursor < int(arguments.size());
                    if (got_waveform)
                        waveform = arguments.at(cursor);
                } else if (opt == "-period") {
                    cursor++;
                    period = std::stod(arguments.at(cursor));
                    got_period = true;
                } else
                    break;
            }
            if (!got_period)
                log_error("found create_clock without period (on line %d)", lineno);
            delay_t period_ps = getDelayFromNS(period).maxDelay(), high_ps = period_ps / 2;
            int64_t high_num = 1, high_den = 2;
            if (got_waveform) {
                std::vector<double> edges;
                bool readable = true;
                for (auto &t : split_to_args(strip_quotes(waveform), false)) {
                    try {
                        size_t used = 0;
                        edges.push_back(std::stod(t, &used));
                        readable = readable && used == t.size();
                    } catch (std::exception &) {
                        readable = false;
                    }
                }
                std::string why;
                if (!readable || edges.size() != 2)
                    why = "-waveform '" + waveform + "' is not two edge times";
                else if (edges.at(0) < 0 || edges.at(1) <= edges.at(0) || edges.at(1) - edges.at(0) >= period)
                    why = "-waveform '" + waveform + "' does not give a rising edge before a falling edge less than "
                                                     "one period later";
                if (!why.empty()) {
                    got_waveform = false;
                    if (xdc_strict)
                        xdc_dropped.push_back(stringf("%s line %d: create_clock: %s (not applied)", xdc_file.c_str(),
                                                      lineno, why.c_str()));
                    else
                        log_warning("create_clock: %s; the clock is timed at a 50%% duty cycle (on line %d)\n",
                                    why.c_str(), lineno);
                } else {
                    if (edges.at(0) != 0) {
                        if (xdc_strict)
                            xdc_dropped.push_back(stringf("%s line %d: create_clock: -waveform '%s' puts the rising "
                                                          "edge at %g ns, and a rising-edge offset is not read (not "
                                                          "applied)",
                                                          xdc_file.c_str(), lineno, waveform.c_str(), edges.at(0)));
                        else
                            log_warning("create_clock: -waveform '%s' puts the rising edge at %g ns; the offset is "
                                        "not read and the clock rises at 0 with its high time kept (on line %d)\n",
                                        waveform.c_str(), edges.at(0), lineno);
                    }
                    high_ps = getDelayFromNS(edges.at(1) - edges.at(0)).maxDelay();
                    int64_t g = std::gcd(int64_t(high_ps), int64_t(period_ps));
                    if (high_ps > 0 && period_ps > 0 && g > 0) {
                        high_num = high_ps / g;
                        high_den = period_ps / g;
                    }
                }
            }
            if (cursor >= int(arguments.size())) {
                if (xdc_strict)
                    xdc_dropped.push_back(stringf("%s line %d: create_clock: a virtual clock has no target (not "
                                                  "applied)",
                                                  xdc_file.c_str(), lineno));
                else
                    log_warning("ignoring virtual clock (unsupported, on line %d)\n", lineno);
                continue;
            }
            std::vector<NetInfo *> dest = get_nets(arguments.at(cursor));
            if (dest.empty() && xdc_strict)
                xdc_dropped.back() += " (create_clock target; the clock constraint is not applied)";
            else if (dest.empty())
                log_warning("create_clock target '%s' matched no net, constraint dropped (on line %d)\n",
                            arguments.at(cursor).c_str(), lineno);
            for (auto n : dest) {
                n->clkconstr = std::unique_ptr<ClockConstraint>(new ClockConstraint);
                n->clkconstr->period = getDelayFromNS(period);
                n->clkconstr->high.delay = high_ps;
                n->clkconstr->low.delay = got_waveform ? n->clkconstr->period.delay - high_ps : high_ps;
                n->clkconstr->high_num = high_num;
                n->clkconstr->high_den = high_den;
                n->clkconstr->name = clock_name;
            }
        } else if (cmd == "set_multicycle_path") {
            parse_exception(arguments, TimingException::MULTICYCLE);
        } else if (cmd == "set_false_path" || cmd == "set_max_delay") {
            parse_exception(arguments, cmd == "set_max_delay" ? TimingException::MAX_DELAY
                                                              : TimingException::FALSE_PATH);
        } else if (cmd == "set_clock_groups") {
            parse_clock_groups(arguments);
        } else if (xdc_strict) {
            xdc_dropped.push_back(
                    stringf("%s line %d: unsupported XDC command '%s' (not applied)", xdc_file.c_str(), lineno, cmd.c_str()));
        } else {
            log_info("ignoring unsupported XDC command '%s' (on line %d)\n", cmd.c_str(), lineno);
        }
    }
    if (!isempty(linebuf))
        log_error("unexpected end of XDC file\n");
    if (missing_targets > 0 && !xdc_strict)
        log_warning("%d XDC constraint target(s) reference ports or nets that are not in this design and were "
                    "ignored, counting any create_clock target warned about above (a board-level XDC normally "
                    "constrains more pins than a design uses; --verbose itemises them, --xdc-strict makes this "
                    "an error)\n",
                    missing_targets);
}

NEXTPNR_NAMESPACE_END
