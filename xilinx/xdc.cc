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

#include <cmath>
#include <cstring>
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
        IdString cellname = id(strip_quotes(split_name));
        if (!cells.count(cellname)) {
            std::string base = debus_zero(strip_quotes(split_name));
            if (!base.empty() && cells.count(id(base)))
                cellname = id(base);
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
                                              split.front().c_str(), cellname.c_str(this)));
            else if (getCtx()->verbose)
                log_info("%s: no cell named '%s' (on line %d) - this target is ignored\n", split.front().c_str(),
                         cellname.c_str(this), lineno);
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
        IdString netname = id(strip_quotes(split_name));
        NetInfo *maybe_net = getNetByAlias(netname);
        if (maybe_net == nullptr) {
            std::string base = debus_zero(strip_quotes(split_name));
            if (!base.empty())
                maybe_net = getNetByAlias(id(base));
        }
        if (maybe_net != nullptr)
            tgt_nets.push_back(maybe_net);
        else {
            missing_targets++;
            if (xdc_strict)
                xdc_dropped.push_back(stringf("%s line %d: %s: no net or port named '%s'", xdc_file.c_str(), lineno,
                                              split.front().c_str(), netname.c_str(this)));
            else if (getCtx()->verbose)
                log_info("%s: no net or port named '%s' (on line %d) - this target is ignored\n",
                         split.front().c_str(), netname.c_str(this), lineno);
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
        if (idstring_str_to_idx->count("X_LUT_AS_DRAM") && ci->attrs.count(id("X_LUT_AS_DRAM")))
            return false;
        for (auto &pre : prefixes)
            if (t.compare(0, pre.size(), pre) == 0)
                return true;
        return false;
    };

    auto is_clocky = [&](const NetInfo *ni) {
        if (ni->clkconstr != nullptr)
            return true;
        if (ni->driver.cell == nullptr)
            return false;
        const std::string &dt = ni->driver.cell->type.str(this);
        return dt.find("BUF") != std::string::npos || dt.find("PLL") != std::string::npos ||
               dt.find("MMCM") != std::string::npos;
    };

    auto clock_known = [&](const std::string &pat) {
        for (auto &n : nets) {
            const NetInfo *ni = n.second.get();
            if (!is_clocky(ni))
                continue;
            if (glob_match(n.first.str(this), pat))
                return true;
            if (ni->clkconstr != nullptr && !ni->clkconstr->name.empty() && glob_match(ni->clkconstr->name, pat))
                return true;
        }
        for (auto &gc : generated_clocks)
            if (glob_match(gc.name, pat) || glob_match(gc.target.str(this), pat))
                return true;
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
                NetInfo *exact = getNetByAlias(id(p));
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

    int refused = 0;
    auto refuse_at = [&](const std::string &where, const std::string &what, const std::string &why) {
        if (xdc_strict)
            xdc_dropped.push_back(
                    stringf("%s: %s: %s (constraint not applied)", where.c_str(), what.c_str(), why.c_str()));
        else {
            ++refused;
            log_warning("%s: %s, constraint not applied (%s)\n", what.c_str(), why.c_str(), where.c_str());
        }
    };
    auto refuse = [&](const std::string &what, const std::string &why) {
        if (xdc_strict)
            xdc_dropped.push_back(stringf("%s line %d: %s: %s (constraint not applied)", xdc_file.c_str(), lineno,
                                          what.c_str(), why.c_str()));
        else {
            ++refused;
            log_warning("%s: %s, constraint not applied (on line %d)\n", what.c_str(), why.c_str(), lineno);
        }
    };

    auto stamp = [&](CellInfo *ci, const char *attr, const std::string &entry) {
        IdString a = id(attr);
        std::string v = ci->attrs.count(a) ? ci->attrs.at(a).as_string() : std::string();
        v += (v.empty() ? "" : ",") + entry;
        ci->attrs[a] = v;
    };

    auto parse_exception = [&](const std::vector<std::string> &args, bool is_max) {
        const std::string &what = args.front();
        TimingException exc;
        exc.kind = is_max ? TimingException::MAX_DELAY : TimingException::FALSE_PATH;
        exc.source = stringf("%s line %d", xdc_file.c_str(), lineno);
        Selection from, to, through;
        bool got_from = false, got_to = false, got_through = false, got_value = false;
        bool setup_only = false, hold_only = false;
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
            else if (is_max && !got_value && !a.empty() && a.front() != '-') {
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
        if (setup_only != hold_only) {
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
        log_info("%s: exception #%d, from %d cell(s) %d clock pattern(s), to %d cell(s) %d pin(s) %d clock "
                 "pattern(s)%s (on line %d)\n",
                 what.c_str(), idx, int(from.cells.size()), int(from.clocks.size()), int(to.cells.size()),
                 int(to.pins.size()), int(to.clocks.size()),
                 is_max ? stringf(", max %.3f ns", getDelayNS(exc.value)).c_str() : "", lineno);
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

    auto parse_number = [](const std::string &str, double &out) {
        try {
            size_t used = 0;
            out = std::stod(str, &used);
            return used == str.size() && std::isfinite(out);
        } catch (std::exception &) {
            return false;
        }
    };

    auto parse_count = [](const std::string &str, int64_t &out) {
        if (str.empty() || str.size() > 9 || !std::all_of(str.begin(), str.end(), ::isdigit))
            return false;
        out = std::stoll(str);
        return out > 0;
    };

    auto is_port = [&](IdString name) {
        if (ports.count(name))
            return true;
        auto pad = cells.find(name);
        return pad != cells.end() && pad->second->type == id_PAD && getNetByAlias(name) != nullptr;
    };

    auto port_type = [&](IdString name) {
        auto fnd = ports.find(name);
        if (fnd != ports.end())
            return fnd->second.type;
        const NetInfo *pn = getNetByAlias(name);
        const CellInfo *pad = cells.at(name).get();
        bool out = pn->driver.cell != nullptr && pn->driver.cell != pad;
        bool in = std::any_of(pn->users.begin(), pn->users.end(), [&](const PortRef &u) { return u.cell != pad; });
        return out && in ? PORT_INOUT : out ? PORT_OUT : PORT_IN;
    };

    auto object_net = [&](const std::string &arg, NetInfo *&out, std::string &err) {
        out = nullptr;
        if (arg.size() < 2 || arg.front() != '[' || arg.back() != ']') {
            err = "'" + arg + "' is not an object query";
            return false;
        }
        std::vector<std::string> toks = split_to_args(arg.substr(1, arg.size() - 2), true);
        if (toks.empty()) {
            err = "empty object query";
            return false;
        }
        const std::string q = toks.front();
        if (q != "get_ports" && q != "get_nets" && q != "get_pins") {
            err = "'" + q + "' is not read here (get_ports, get_nets or get_pins)";
            return false;
        }
        std::vector<std::string> pats;
        for (size_t i = 1; i < toks.size(); i++) {
            if (toks.at(i) == "-quiet")
                continue;
            if (!toks.at(i).empty() && toks.at(i).front() == '-') {
                err = "unsupported option '" + toks.at(i) + "' to " + q;
                return false;
            }
            for (auto &p : expand_list(toks.at(i)))
                pats.push_back(p);
        }
        if (pats.size() != 1) {
            err = q + " must name exactly one object";
            return false;
        }
        const std::string &p = pats.front();
        if (q == "get_pins") {
            size_t slash = p.find_last_of('/');
            if (slash == std::string::npos || slash == 0 || slash + 1 == p.size()) {
                err = "get_pins pattern '" + p + "' has no <cell>/<pin> separator";
                return false;
            }
            std::string cname = p.substr(0, slash), pname = p.substr(slash + 1);
            std::vector<CellInfo *> found;
            for (auto &c : cells)
                for (auto &n : cell_names(c.second.get()))
                    if (name_matches(n, cname, false)) {
                        add_cell(found, c.second.get());
                        break;
                    }
            if (found.size() != 1) {
                err = "get_pins '" + p + "' matched " + std::to_string(found.size()) + " cells, not one";
                return false;
            }
            auto port = found.front()->ports.find(id(pname));
            if (port == found.front()->ports.end() || port->second.net == nullptr) {
                err = "pin '" + p + "' does not exist or is unconnected";
                return false;
            }
            out = port->second.net;
            return true;
        }
        std::string name = p;
        if (q == "get_ports" && !is_port(id(name)) && !debus_zero(name).empty() && is_port(id(debus_zero(name))))
            name = debus_zero(name);
        if (q == "get_ports" && !is_port(id(name))) {
            err = "no port named '" + p + "'";
            return false;
        }
        out = getNetByAlias(id(name));
        if (out == nullptr && q == "get_nets" && !debus_zero(name).empty())
            out = getNetByAlias(id(debus_zero(name)));
        if (out == nullptr) {
            err = "no net named '" + p + "'";
            return false;
        }
        return true;
    };

    auto drives_clock = [&](const NetInfo *ni) {
        if (ni->clkconstr != nullptr)
            return true;
        if (ni->driver.cell == nullptr)
            return false;
        const std::string &dt = ni->driver.cell->type.str(this);
        for (const char *pre : {"BUFG", "BUFH", "BUFR", "BUFIO", "BUFMR"})
            if (dt.compare(0, std::strlen(pre), pre) == 0)
                return true;
        return dt.find("PLL") != std::string::npos || dt.find("MMCM") != std::string::npos;
    };

    auto resolve_clock = [&](const std::string &arg, IdString &out, std::string &err) {
        std::string pat;
        if (!arg.empty() && arg.front() == '[') {
            Selection sel;
            select(arg, sel);
            if (!sel.ok) {
                err = sel.error;
                return false;
            }
            if (sel.has_cells || sel.has_nets || sel.clocks.size() != 1) {
                err = "-clock takes exactly one clock";
                return false;
            }
            pat = sel.clocks.front();
        } else {
            std::vector<std::string> l = expand_list(arg);
            if (l.size() != 1) {
                err = "-clock takes exactly one clock";
                return false;
            }
            pat = l.front();
        }
        std::vector<IdString> found;
        auto add = [&](IdString n) {
            if (std::find(found.begin(), found.end(), n) == found.end())
                found.push_back(n);
        };
        for (auto &gc : generated_clocks)
            if (glob_match(gc.name, pat))
                add(gc.target);
        for (auto &n : nets)
            if (n.second->clkconstr != nullptr && !n.second->clkconstr->name.empty() &&
                glob_match(n.second->clkconstr->name, pat))
                add(n.first);
        if (found.empty()) {
            for (auto &n : nets)
                if (drives_clock(n.second.get()) && glob_match(n.first.str(this), pat))
                    add(n.first);
            for (auto &gc : generated_clocks)
                if (glob_match(gc.target.str(this), pat))
                    add(gc.target);
        }
        if (found.size() != 1) {
            err = found.empty() ? "clock '" + pat + "' matched no clock"
                                : "clock '" + pat + "' matched " + std::to_string(found.size()) + " clocks";
            return false;
        }
        out = found.front();
        return true;
    };

    auto parse_generated_clock = [&](const std::vector<std::string> &args) {
        const std::string &what = args.front();
        GeneratedClock gc;
        gc.origin = stringf("%s line %d", xdc_file.c_str(), lineno);
        std::string source_arg, target_arg;
        int64_t divide = 0, multiply = 0;
        std::vector<int64_t> edges;
        bool got_edges = false;
        for (size_t i = 1; i < args.size(); i++) {
            const std::string &a = args.at(i);
            bool valued = a == "-name" || a == "-source" || a == "-divide_by" || a == "-multiply_by" || a == "-edges";
            if (valued && i + 1 >= args.size())
                return refuse(what, a + " has no value");
            if (a == "-name")
                gc.name = strip_quotes(args.at(++i));
            else if (a == "-source")
                source_arg = args.at(++i);
            else if (a == "-divide_by" || a == "-multiply_by") {
                int64_t &v = a == "-divide_by" ? divide : multiply;
                if (!parse_count(strip_quotes(args.at(++i)), v))
                    return refuse(what, a + " '" + args.at(i) + "' is not a positive integer");
            } else if (a == "-edges") {
                got_edges = true;
                for (auto &t : expand_list(args.at(++i))) {
                    int64_t e;
                    if (!parse_count(t, e))
                        return refuse(what, "-edges entry '" + t + "' is not a positive integer");
                    edges.push_back(e);
                }
            } else if (a == "-quiet")
                ;
            else if (!a.empty() && a.front() == '-')
                return refuse(what, "unsupported argument '" + a + "'");
            else if (target_arg.empty())
                target_arg = a;
            else
                return refuse(what, "more than one target object");
        }
        if (source_arg.empty())
            return refuse(what, "no -source");
        if (target_arg.empty())
            return refuse(what, "no target object");
        if (got_edges && (divide != 0 || multiply != 0))
            return refuse(what, "-edges is not read together with -divide_by or -multiply_by");
        if (got_edges) {
            if (edges.size() != 3 || edges.at(0) >= edges.at(1) || edges.at(1) >= edges.at(2))
                return refuse(what, "-edges must list three increasing source edges");
            if (edges.at(1) - edges.at(0) != edges.at(2) - edges.at(1))
                return refuse(what, "-edges describes a duty cycle other than half the period, which is not read");
            gc.num = 2;
            gc.den = edges.at(2) - edges.at(0);
            gc.shift_num = edges.at(0) - 1;
            gc.shift_den = 2;
        } else if (divide == 0 && multiply == 0) {
            return refuse(what, "no -divide_by, -multiply_by or -edges");
        } else {
            gc.num = multiply == 0 ? 1 : multiply;
            gc.den = divide == 0 ? 1 : divide;
        }
        int64_t g = std::gcd(gc.num, gc.den);
        gc.num /= g;
        gc.den /= g;
        NetInfo *src = nullptr, *tgt = nullptr;
        std::string err;
        if (!object_net(source_arg, src, err))
            return refuse(what, "-source: " + err);
        if (!object_net(target_arg, tgt, err)) {
            if (err.compare(0, 3, "no ") == 0) {
                missing_targets++;
                if (xdc_strict)
                    xdc_dropped.push_back(stringf("%s line %d: %s: %s", xdc_file.c_str(), lineno, what.c_str(),
                                                  err.c_str()));
                else if (getCtx()->verbose)
                    log_info("%s: %s (on line %d) - this target is ignored\n", what.c_str(), err.c_str(), lineno);
                return;
            }
            return refuse(what, "target: " + err);
        }
        if (src == tgt)
            return refuse(what, "the target is the source net '" + src->name.str(this) + "'");
        if (tgt->clkconstr != nullptr)
            return refuse(what, "net '" + tgt->name.str(this) + "' already carries a create_clock");
        if (gc.name.empty())
            gc.name = tgt->name.str(this);
        for (auto &other : generated_clocks) {
            if (other.name == gc.name)
                return refuse(what, "a generated clock named '" + gc.name + "' already exists (" + other.origin + ")");
            if (other.target == tgt->name)
                return refuse(what, "net '" + tgt->name.str(this) + "' is already the target of generated clock '" +
                                            other.name + "'");
        }
        for (auto &n : nets)
            if (n.second->clkconstr != nullptr && n.second->clkconstr->name == gc.name)
                return refuse(what, "a create_clock is already named '" + gc.name + "'");
        gc.source = src->name;
        gc.target = tgt->name;
        log_info("%s: '%s' on net '%s' runs at %lld/%lld of the frequency of net '%s' (on line %d)\n", what.c_str(),
                 gc.name.c_str(), tgt->name.c_str(this), (long long)gc.num, (long long)gc.den, src->name.c_str(this),
                 lineno);
        generated_clocks.push_back(gc);
    };

    auto parse_io_delay = [&](const std::vector<std::string> &args, bool input) {
        const std::string &what = args.front();
        std::string clock_arg, port_arg;
        bool got_value = false, want_max = false, want_min = false, fall = false, add = false;
        double ns = 0;
        for (size_t i = 1; i < args.size(); i++) {
            const std::string &a = args.at(i);
            double v;
            if (a == "-clock") {
                if (i + 1 >= args.size())
                    return refuse(what, "-clock has no value");
                clock_arg = args.at(++i);
            } else if (a == "-max")
                want_max = true;
            else if (a == "-min")
                want_min = true;
            else if (a == "-clock_fall")
                fall = true;
            else if (a == "-add_delay")
                add = true;
            else if (a == "-quiet")
                ;
            else if (parse_number(a, v)) {
                if (got_value)
                    return refuse(what, "more than one delay value");
                ns = v;
                got_value = true;
            } else if (!a.empty() && a.front() == '[') {
                if (!port_arg.empty())
                    return refuse(what, "more than one target object");
                port_arg = a;
            } else
                return refuse(what, "unsupported argument '" + a + "'");
        }
        if (clock_arg.empty())
            return refuse(what, "no -clock (a delay relative to no clock is not read)");
        if (!got_value)
            return refuse(what, "no delay value");
        if (port_arg.empty())
            return refuse(what, "no target port");
        std::vector<std::string> toks = split_to_args(port_arg.substr(1, port_arg.size() - 2), true);
        if (toks.empty() || toks.front() != "get_ports")
            return refuse(what, "the target must be get_ports");
        std::vector<std::string> pats;
        for (size_t i = 1; i < toks.size(); i++) {
            if (toks.at(i) == "-quiet")
                continue;
            if (!toks.at(i).empty() && toks.at(i).front() == '-')
                return refuse(what, "unsupported option '" + toks.at(i) + "' to get_ports");
            for (auto &p : expand_list(toks.at(i)))
                pats.push_back(p);
        }
        if (pats.empty())
            return refuse(what, "get_ports with no pattern");
        IdString clock;
        std::string err;
        if (!resolve_clock(clock_arg, clock, err))
            return refuse(what, "-clock: " + err);
        std::vector<IdString> matched;
        for (auto &p : pats) {
            size_t before = matched.size();
            auto consider = [&](IdString name) {
                const std::string pn = name.str(this);
                if (!glob_match(pn, p) && !(!debus_zero(p).empty() && glob_match(pn, debus_zero(p))))
                    return;
                if (std::find(matched.begin(), matched.end(), name) == matched.end())
                    matched.push_back(name);
            };
            for (auto &port : ports)
                consider(port.first);
            for (auto &c : cells)
                if (c.second->type == id_PAD && is_port(c.first))
                    consider(c.first);
            if (matched.size() == before) {
                missing_targets++;
                if (xdc_strict)
                    xdc_dropped.push_back(stringf("%s line %d: %s: no port named '%s'", xdc_file.c_str(), lineno,
                                                  what.c_str(), p.c_str()));
                else if (getCtx()->verbose)
                    log_info("%s: no port named '%s' (on line %d) - this target is ignored\n", what.c_str(), p.c_str(),
                             lineno);
            }
        }
        std::sort(matched.begin(), matched.end(),
                  [&](IdString a, IdString b) { return a.str(this) < b.str(this); });
        for (auto pn : matched) {
            PortType t = port_type(pn);
            if ((input && t == PORT_OUT) || (!input && t == PORT_IN))
                return refuse(what, "port '" + pn.str(this) + "' is an " + (t == PORT_OUT ? "output" : "input"));
        }
        bool set_max = want_max || !want_min, set_min = want_min || !want_max;
        ClockEdge edge = fall ? FALLING_EDGE : RISING_EDGE;
        delay_t value = getDelayFromNS(ns).maxDelay();
        std::string where = stringf("%s line %d", xdc_file.c_str(), lineno);
        for (auto pn : matched) {
            auto &v = timing_io_delays;
            if (!add)
                v.erase(std::remove_if(v.begin(), v.end(),
                                       [&](const TimingIoDelay &d) {
                                           return d.port == pn && d.input == input &&
                                                  (d.clock != clock || d.edge != edge);
                                       }),
                        v.end());
            auto fnd = std::find_if(v.begin(), v.end(), [&](const TimingIoDelay &d) {
                return d.port == pn && d.input == input && d.clock == clock && d.edge == edge;
            });
            if (fnd == v.end()) {
                TimingIoDelay d;
                d.port = pn;
                d.input = input;
                d.clock = clock;
                d.edge = edge;
                v.push_back(d);
                fnd = std::prev(v.end());
            }
            if (set_max) {
                fnd->max_delay = (add && fnd->has_max) ? std::max(fnd->max_delay, value) : value;
                fnd->has_max = true;
            }
            if (set_min) {
                fnd->min_delay = (add && fnd->has_min) ? std::min(fnd->min_delay, value) : value;
                fnd->has_min = true;
            }
            fnd->source = where;
        }
        if (!matched.empty())
            log_info("%s: %s%s%.3f ns on %d port(s) relative to %s of clock net '%s' (on line %d)\n", what.c_str(),
                     set_max ? "max " : "", set_min ? "min " : "", ns, int(matched.size()),
                     fall ? "the falling edge" : "the rising edge", clock.c_str(this), lineno);
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
            std::string clock_name;
            int cursor = 1;
            for (cursor = 1; cursor < int(arguments.size()); cursor++) {
                std::string opt = arguments.at(cursor);
                if (opt == "-add")
                    ;
                else if (opt == "-name") {
                    cursor++;
                    if (cursor < int(arguments.size()))
                        clock_name = strip_quotes(arguments.at(cursor));
                } else if (opt == "-waveform")
                    cursor++;
                else if (opt == "-period") {
                    cursor++;
                    period = std::stod(arguments.at(cursor));
                    got_period = true;
                } else
                    break;
            }
            if (!got_period)
                log_error("found create_clock without period (on line %d)", lineno);
            if (cursor >= int(arguments.size())) {
                // virtual clock (no target ports/nets): not supported; skip it
                // instead of crashing with std::out_of_range
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
                n->clkconstr->high.delay = n->clkconstr->period.delay / 2;
                n->clkconstr->low.delay = n->clkconstr->period.delay / 2;
                n->clkconstr->name = clock_name;
            }
        } else if (cmd == "set_multicycle_path") {
            // set_multicycle_path <N> [-setup|-hold] -from [<sel>] -to [<sel>]
            // Tags the destination (capture) cells with a multicycle factor so the
            // timing engine can relax the setup requirement on those endpoints.
            // Previously this command was silently ignored. Supports a NAME glob in the
            // -to selector, e.g. -to [get_cells -hier -filter {NAME =~ *rf_reg*}]
            // group_brackets=true keeps a whole "[get_cells ... {NAME =~ *pat*}]" as ONE argument.
            int mcp = 1; bool is_hold = false;
            std::string to_sel;
            for (int c = 1; c < int(arguments.size()); c++) {
                const std::string &a = arguments.at(c);
                if (a == "-hold") is_hold = true;
                else if (a == "-to" && c + 1 < int(arguments.size())) to_sel = arguments.at(c + 1);
                else if (!a.empty() && std::all_of(a.begin(), a.end(), ::isdigit)) mcp = std::stoi(a);
            }
            // extract the NAME glob from the -to selector (substring after "=~")
            std::string to_pat;
            size_t eq = to_sel.find("=~");
            if (eq != std::string::npos) to_pat = to_sel.substr(eq + 2);
            // trim whitespace and any leftover braces/brackets around the pattern
            auto clean = [](std::string s) {
                std::string o;
                for (char ch : s) if (ch != '{' && ch != '}' && ch != ']' && ch != '[' && !std::isspace(ch)) o += ch;
                return o;
            };
            to_pat = clean(to_pat);
            if (!is_hold && !to_pat.empty()) {
                int tagged = 0;
                for (auto &kv : cells) {
                    std::string cn = kv.first.str(this);
                    if (glob_match(cn, to_pat)) {
                        kv.second->attrs[id("NEXTPNR_MCP_SETUP")] = std::to_string(mcp);
                        ++tagged;
                    }
                }
                log_info("set_multicycle_path: setup multicycle %d tagged on %d cells matching '%s' (on line %d)\n",
                         mcp, tagged, to_pat.c_str(), lineno);
            } else {
                log_info("set_multicycle_path: parsed (hold or no -to glob) — no setup tag (on line %d)\n", lineno);
            }
        } else if (cmd == "set_false_path" || cmd == "set_max_delay") {
            parse_exception(arguments, cmd == "set_max_delay");
        } else if (cmd == "set_clock_groups") {
            parse_clock_groups(arguments);
        } else if (cmd == "create_generated_clock") {
            parse_generated_clock(arguments);
        } else if (cmd == "set_input_delay" || cmd == "set_output_delay") {
            parse_io_delay(arguments, cmd == "set_input_delay");
        } else {
            log_info("ignoring unsupported XDC command '%s' (on line %d)\n", cmd.c_str(), lineno);
        }
    }
    if (!isempty(linebuf))
        log_error("unexpected end of XDC file\n");
    for (auto it = timing_io_delays.begin(); it != timing_io_delays.end();) {
        if (it->has_max) {
            ++it;
            continue;
        }
        refuse_at(it->source, it->input ? "set_input_delay" : "set_output_delay",
                  "port '" + it->port.str(this) + "' has a -min delay and no -max delay for the same clock edge");
        it = timing_io_delays.erase(it);
    }
    if (refused > 0)
        log_warning("%d XDC constraint(s) in '%s' were refused and not applied, each warned about above "
                    "(--xdc-strict makes this an error)\n",
                    refused, xdc_file.c_str());
    if (missing_targets > 0 && !xdc_strict)
        log_warning("%d XDC constraint target(s) reference ports or nets that are not in this design and were "
                    "ignored, counting any create_clock target warned about above (a board-level XDC normally "
                    "constrains more pins than a design uses; --verbose itemises them, --xdc-strict makes this "
                    "an error)\n",
                    missing_targets);
}

NEXTPNR_NAMESPACE_END
