/*
 *  nextpnr -- Next Generation Place and Route
 *
 *  Copyright (C) 2018  David Shah <david@symbioticeda.com>
 *  Copyright (C) 2018  Eddie Hung <eddieh@ece.ubc.ca>
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

#include "timing.h"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <boost/range/adaptor/reversed.hpp>
#include <cstdlib>
#include <deque>
#include <fstream>
#include <map>
#include <numeric>
#include <sstream>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include "log.h"
#include "util.h"

NEXTPNR_NAMESPACE_BEGIN

namespace {
struct ClockEvent
{
    IdString clock;
    ClockEdge edge;
    int tag = 0;

    bool operator==(const ClockEvent &other) const
    {
        return clock == other.clock && edge == other.edge && tag == other.tag;
    }
};

struct ClockPair
{
    ClockEvent start, end;

    bool operator==(const ClockPair &other) const { return start == other.start && end == other.end; }
};

__int128 floor_div(__int128 a, __int128 b)
{
    if (b < 0) {
        a = -a;
        b = -b;
    }
    __int128 q = a / b;
    if (a % b != 0 && a < 0)
        --q;
    return q;
}

struct Frac
{
    __int128 n = 0, d = 1;

    static Frac of(__int128 n, __int128 d)
    {
        if (d < 0) {
            n = -n;
            d = -d;
        }
        __int128 a = n < 0 ? -n : n, b = d;
        while (b != 0) {
            __int128 t = a % b;
            a = b;
            b = t;
        }
        Frac f;
        f.n = n / a;
        f.d = d / a;
        return f;
    }
    Frac operator+(const Frac &o) const { return of(n * o.d + o.n * d, d * o.d); }
    Frac operator-(const Frac &o) const { return of(n * o.d - o.n * d, d * o.d); }
    Frac operator*(const Frac &o) const { return of(n * o.n, d * o.d); }
};
} // namespace

NEXTPNR_NAMESPACE_END
namespace std {

template <> struct hash<NEXTPNR_NAMESPACE_PREFIX ClockEvent>
{
    std::size_t operator()(const NEXTPNR_NAMESPACE_PREFIX ClockEvent &obj) const noexcept
    {
        std::size_t seed = 0;
        boost::hash_combine(seed, hash<NEXTPNR_NAMESPACE_PREFIX IdString>()(obj.clock));
        boost::hash_combine(seed, hash<int>()(int(obj.edge)));
        if (obj.tag != 0)
            boost::hash_combine(seed, hash<int>()(obj.tag));
        return seed;
    }
};

template <> struct hash<NEXTPNR_NAMESPACE_PREFIX ClockPair>
{
    std::size_t operator()(const NEXTPNR_NAMESPACE_PREFIX ClockPair &obj) const noexcept
    {
        std::size_t seed = 0;
        boost::hash_combine(seed, hash<NEXTPNR_NAMESPACE_PREFIX ClockEvent>()(obj.start));
        boost::hash_combine(seed, hash<NEXTPNR_NAMESPACE_PREFIX ClockEvent>()(obj.start));
        return seed;
    }
};

} // namespace std
NEXTPNR_NAMESPACE_BEGIN

typedef std::vector<const PortRef *> PortRefVector;
typedef std::map<int, unsigned> DelayFrequency;

struct CriticalPath
{
    PortRefVector ports;
    delay_t path_delay;
    delay_t path_period;
    double mcp = 1.0;
    bool by_exception = false;
};

typedef std::unordered_map<ClockPair, CriticalPath> CriticalPathMap;
typedef std::unordered_map<IdString, NetCriticalityInfo> NetCriticalityMap;

struct Timing
{
    Context *ctx;
    bool net_delays;
    bool update;
    delay_t min_slack;
    delay_t worst_hold_slack = std::numeric_limits<delay_t>::max() / 4;
    struct HoldEndpoint
    {
        IdString cell, port;
        delay_t slack;
    };
    std::vector<HoldEndpoint> hold_endpoints;
    std::ofstream setup_export;
    std::vector<std::pair<delay_t, std::string>> setup_rows;
    std::unordered_map<std::string, size_t> setup_row_index;
    CriticalPathMap *crit_path;
    DelayFrequency *slack_histogram;
    NetCriticalityMap *net_crit;
    IdString async_clock;

    // Async clock-group exclusion (nextpnr-xilinx has no set_clock_groups): a
    // setup path from a launch clock in one group to a capture clock in another
    // is a CDC false path (synchroniser) and must NOT be timed -- otherwise a
    // 61 ns cpu->eth synchroniser wire reads as a "16 MHz" failure and misleads
    // the timing-driven router.  Loaded from NEXTPNR_ASYNC_GROUPS: one group per
    // line, each a whitespace-separated list of substrings; a clock net joins
    // the first group whose substring its name contains.
    std::vector<std::vector<std::string>> async_groups;
    int clock_group(IdString clk) const
    {
        if (async_groups.empty())
            return -1;
        std::string n = clk.c_str(ctx);
        for (size_t g = 0; g < async_groups.size(); g++)
            for (const auto &sub : async_groups[g])
                if (n.find(sub) != std::string::npos)
                    return int(g);
        return -1;
    }

    bool have_exceptions = false;
    IdString texc_from_attr, texc_to_attr, ignore_attr;
    std::vector<std::vector<int>> tag_sets{{}};
    std::unordered_map<std::string, int> tag_index;
    std::unordered_map<const CellInfo *, std::vector<std::pair<int, IdString>>> to_ids;
    std::unordered_map<ClockEvent, delay_t> domain_raw_max;
    std::unordered_map<IdString, std::vector<std::vector<std::string>>> clock_names, clock_names_gen;
    int exc_setup_skipped = 0, exc_hold_skipped = 0, exc_max_delay = 0, exc_multicycle = 0;
    std::ofstream hold_export;
    std::vector<std::pair<delay_t, std::string>> hold_rows;
    std::unordered_map<std::string, size_t> hold_row_index;

    struct ExceptionResult
    {
        bool skip_setup = false, skip_hold = false, has_max = false;
        delay_t max_value = 0;
        int mcp_setup = 1, mcp_hold = 0;
        int max_index = -1, mcp_setup_index = -1, mcp_hold_index = -1;
        bool mcp_setup_launch = false, mcp_hold_launch = true;
    };

    std::vector<int> parse_ids(const std::string &str) const
    {
        std::vector<int> ids;
        std::istringstream iss(str);
        std::string tok;
        while (std::getline(iss, tok, ',')) {
            if (tok.empty() || !std::all_of(tok.begin(), tok.end(), ::isdigit))
                continue;
            int v = std::atoi(tok.c_str());
            if (v >= 0 && v < int(ctx->timing_exceptions.size()))
                ids.push_back(v);
        }
        std::sort(ids.begin(), ids.end());
        ids.erase(std::unique(ids.begin(), ids.end()), ids.end());
        return ids;
    }

    int start_tag(const CellInfo *ci)
    {
        if (!have_exceptions || ci == nullptr)
            return 0;
        auto fnd = ci->attrs.find(texc_from_attr);
        if (fnd == ci->attrs.end())
            return 0;
        const std::string &str = fnd->second.as_string();
        auto ti = tag_index.find(str);
        if (ti != tag_index.end())
            return ti->second;
        std::vector<int> ids = parse_ids(str);
        int tag = 0;
        if (!ids.empty()) {
            tag = int(tag_sets.size());
            tag_sets.push_back(ids);
        }
        tag_index[str] = tag;
        return tag;
    }

    const std::vector<std::pair<int, IdString>> &end_ids(const CellInfo *ci)
    {
        auto fnd = to_ids.find(ci);
        if (fnd != to_ids.end())
            return fnd->second;
        auto &ids = to_ids[ci];
        auto attr = ci->attrs.find(texc_to_attr);
        if (attr == ci->attrs.end())
            return ids;
        std::istringstream iss(attr->second.as_string());
        std::string tok;
        while (std::getline(iss, tok, ',')) {
            size_t colon = tok.find(':');
            std::string num = tok.substr(0, colon);
            if (num.empty() || !std::all_of(num.begin(), num.end(), ::isdigit))
                continue;
            int v = std::atoi(num.c_str());
            if (v < 0 || v >= int(ctx->timing_exceptions.size()))
                continue;
            IdString port;
            if (colon != std::string::npos) {
                if (colon + 1 == tok.size())
                    continue;
                port = ctx->id(tok.substr(colon + 1));
            }
            ids.emplace_back(v, port);
        }
        return ids;
    }

    static bool ends_at(const std::vector<std::pair<int, IdString>> &ids, int idx, IdString port)
    {
        for (auto &e : ids)
            if (e.first == idx && (e.second == IdString() || e.second == port))
                return true;
        return false;
    }

    void add_clock_names(const NetInfo *net, std::vector<std::string> &names) const
    {
        names.push_back(net->name.str(ctx));
        if (net->clkconstr && !net->clkconstr->name.empty())
            names.push_back(net->clkconstr->name);
    }

    void collect_identities(const NetInfo *net, bool include_generated, std::vector<std::string> &names, int depth,
                            std::vector<std::vector<std::string>> &out) const
    {
        size_t mark = names.size();
        add_clock_names(net, names);
        std::vector<const NetInfo *> sources;
        if (depth + 1 < 16)
            sources = ctx->getClockSources(net, include_generated);
        if (sources.empty())
            out.push_back(names);
        for (auto src : sources)
            collect_identities(src, include_generated, names, depth + 1, out);
        names.resize(mark);
    }

    const std::vector<std::vector<std::string>> &clock_identities(IdString clk, bool include_generated)
    {
        auto &cache = include_generated ? clock_names_gen : clock_names;
        auto fnd = cache.find(clk);
        if (fnd != cache.end())
            return fnd->second;
        std::vector<std::vector<std::string>> identities;
        auto ni = ctx->nets.find(clk);
        if (ni == ctx->nets.end()) {
            identities.push_back({clk.str(ctx)});
        } else {
            std::vector<std::string> names;
            collect_identities(ni->second.get(), include_generated, names, 0, identities);
        }
        return cache.emplace(clk, std::move(identities)).first->second;
    }

    static bool identity_matches(const std::vector<std::string> &identity, const std::vector<std::string> &pats)
    {
        for (auto &pat : pats)
            for (auto &n : identity)
                if (glob_match(n, pat))
                    return true;
        return false;
    }

    bool clock_matches(IdString clk, const std::vector<std::string> &pats, bool include_generated)
    {
        if (clk == async_clock || pats.empty())
            return false;
        for (auto &identity : clock_identities(clk, include_generated))
            if (!identity_matches(identity, pats))
                return false;
        return true;
    }

    bool groups_exclude(IdString launch, IdString capture)
    {
        if (launch == async_clock || capture == async_clock)
            return false;
        for (auto &grp : ctx->timing_clock_groups) {
            auto group_of = [&](const std::vector<std::string> &identity) {
                for (int i = 0; i < int(grp.groups.size()); i++)
                    if (identity_matches(identity, grp.groups.at(i)))
                        return i;
                return -1;
            };
            bool all_excluded = true;
            for (auto &li : clock_identities(launch, grp.include_generated)) {
                int gl = group_of(li);
                for (auto &ci : clock_identities(capture, grp.include_generated)) {
                    int gc = group_of(ci);
                    bool excluded = (grp.groups.size() == 1) ? ((gl == 0) != (gc == 0))
                                                             : (gl >= 0 && gc >= 0 && gl != gc);
                    if (!excluded)
                        all_excluded = false;
                }
            }
            if (all_excluded)
                return true;
        }
        return false;
    }

    ExceptionResult match_exceptions(const ClockEvent &start, IdString capture, const CellInfo *endcell,
                                     IdString endport)
    {
        ExceptionResult res;
        if (!have_exceptions)
            return res;
        if (groups_exclude(start.clock, capture)) {
            res.skip_setup = res.skip_hold = true;
            return res;
        }
        const std::vector<int> &start_ids = tag_sets.at(start.tag);
        const std::vector<std::pair<int, IdString>> &stop_ids = end_ids(endcell);
        for (int i = 0; i < int(ctx->timing_exceptions.size()); i++) {
            const TimingException &e = ctx->timing_exceptions.at(i);
            bool from_any = !e.from_cells && e.from_clocks.empty();
            bool to_any = !e.to_cells && e.to_clocks.empty();
            bool from_ok = from_any ||
                           (e.from_cells && std::binary_search(start_ids.begin(), start_ids.end(), i)) ||
                           clock_matches(start.clock, e.from_clocks, false);
            if (!from_ok)
                continue;
            bool to_ok = to_any || (e.to_cells && ends_at(stop_ids, i, endport)) ||
                         clock_matches(capture, e.to_clocks, false);
            if (!to_ok)
                continue;
            if (e.kind == TimingException::FALSE_PATH) {
                res.skip_setup |= e.setup;
                res.skip_hold |= e.hold;
            } else if (e.kind == TimingException::MULTICYCLE) {
                if (e.setup) {
                    res.mcp_setup = e.multiplier;
                    res.mcp_setup_launch = e.launch_period;
                    res.mcp_setup_index = i;
                } else {
                    res.mcp_hold = e.multiplier;
                    res.mcp_hold_launch = e.launch_period;
                    res.mcp_hold_index = i;
                }
            } else {
                if (!res.has_max || e.value < res.max_value) {
                    res.max_value = e.value;
                    res.max_index = i;
                }
                res.has_max = true;
                res.skip_hold |= !e.hold;
            }
        }
        if (res.skip_setup)
            res.has_max = false;
        return res;
    }

    bool related_requirement(IdString launch, ClockEdge launch_edge, IdString capture, ClockEdge capture_edge,
                             delay_t &setup_req, delay_t &hold_req, IdString *source = nullptr) const
    {
        if (launch == capture || launch == async_clock || capture == async_clock)
            return false;
        auto li = ctx->nets.find(launch), ci = ctx->nets.find(capture);
        if (li == ctx->nets.end() || ci == ctx->nets.end())
            return false;
        const ClockConstraint *lc = li->second->clkconstr.get(), *cc = ci->second->clkconstr.get();
        if (lc == nullptr || cc == nullptr || lc->source == IdString() || lc->source != cc->source ||
            lc->source_num <= 0 || lc->source_den <= 0 || cc->source_num <= 0 || cc->source_den <= 0)
            return false;
        auto si = ctx->nets.find(lc->source);
        if (si == ctx->nets.end() || si->second->clkconstr == nullptr)
            return false;
        const ClockConstraint &sc = *si->second->clkconstr;
        if (sc.period.delay <= 0 || lc->offset_den <= 0 || cc->offset_den <= 0 || sc.high_den <= 0 ||
            lc->high_den <= 0 || cc->high_den <= 0)
            return false;
        int64_t n = std::lcm(lc->source_num, cc->source_num);
        int64_t pl = lc->source_den * (n / lc->source_num), pc = cc->source_den * (n / cc->source_num);
        const Frac grid = Frac::of(std::gcd(pl, pc), n);
        auto edge_offset = [&](IdString net, const ClockConstraint *c, ClockEdge edge) {
            Frac off = Frac::of(c->offset_num, c->offset_den);
            if (edge != FALLING_EDGE)
                return off;
            if (net == c->source)
                return off + Frac::of(sc.high_num, sc.high_den);
            return off + Frac::of(__int128(c->high_num) * c->source_den, __int128(c->high_den) * c->source_num);
        };
        Frac diff = edge_offset(capture, cc, capture_edge) - edge_offset(launch, lc, launch_edge);
        Frac sep = diff - grid * Frac::of(floor_div(diff.n * grid.d, diff.d * grid.n), 1);
        if (sep.n == 0)
            sep = grid;
        Frac hold = sep - grid;
        setup_req = delay_t(floor_div(sep.n * sc.period.delay, sep.d));
        hold_req = delay_t(-floor_div(-hold.n * sc.period.delay, hold.d));
        if (source != nullptr)
            *source = lc->source;
        return true;
    }

    delay_t setup_requirement(const ClockEvent &launch, IdString capture, ClockEdge edge, delay_t clk_period,
                              delay_t *hold_req = nullptr) const
    {
        delay_t related_setup, related_hold;
        if (related_requirement(launch.clock, launch.edge, capture, edge, related_setup, related_hold)) {
            if (hold_req != nullptr)
                *hold_req = related_hold;
            return related_setup;
        }
        if (hold_req != nullptr)
            *hold_req = 0;
        delay_t period = (edge == launch.edge) ? clk_period : clk_period / 2;
        if (capture != async_clock && ctx->nets.at(capture)->clkconstr) {
            const ClockConstraint &cc = *ctx->nets.at(capture)->clkconstr;
            if (edge == launch.edge)
                period = cc.period.minDelay();
            else if (edge == RISING_EDGE)
                period = cc.low.minDelay();
            else if (edge == FALLING_EDGE)
                period = cc.high.minDelay();
            const ClockConstraint *lc = unrelated_launch(launch.clock, capture);
            if (lc != nullptr)
                period = std::min(period, (edge == launch.edge)          ? lc->period.minDelay()
                                          : (launch.edge == RISING_EDGE) ? lc->high.minDelay()
                                                                         : lc->low.minDelay());
        }
        return period;
    }

    std::string base_requirement_source(const ClockEvent &launch, IdString capture, ClockEdge edge) const
    {
        delay_t s, h;
        if (related_requirement(launch.clock, launch.edge, capture, edge, s, h))
            return "related";
        if (capture == async_clock || !ctx->nets.at(capture)->clkconstr)
            return "default";
        if (launch.clock == capture)
            return edge == launch.edge ? "same" : "same-half";
        return unrelated_launch(launch.clock, capture) != nullptr ? "unrelated-min" : "capture-only";
    }

    static std::string setup_source(const ExceptionResult &exc, const std::string &base)
    {
        if (exc.has_max)
            return "max_delay#" + std::to_string(exc.max_index);
        if (exc.mcp_setup != 1)
            return "multicycle#" + std::to_string(exc.mcp_setup_index) + "+" + base;
        return base;
    }

    static std::string hold_source(const ExceptionResult &exc, const std::string &base)
    {
        if (exc.has_max || (exc.mcp_setup == 1 && exc.mcp_hold == 0))
            return base;
        std::string ids;
        if (exc.mcp_setup != 1)
            ids = std::to_string(exc.mcp_setup_index);
        if (exc.mcp_hold != 0)
            ids += (ids.empty() ? "" : ",") + std::to_string(exc.mcp_hold_index);
        return "multicycle#" + ids + "+" + base;
    }

    const ClockConstraint *unrelated_launch(IdString launch, IdString capture) const
    {
        if (launch == capture || launch == async_clock || capture == async_clock)
            return nullptr;
        auto li = ctx->nets.find(launch), ci = ctx->nets.find(capture);
        if (li == ctx->nets.end() || ci == ctx->nets.end() || ci->second->clkconstr == nullptr)
            return nullptr;
        return li->second->clkconstr.get();
    }

    bool timing_ignored(const NetInfo *net) const
    {
        return ignore_attr != IdString() && net->attrs.count(ignore_attr);
    }

    struct PinKeyHash
    {
        std::size_t operator()(const std::pair<const CellInfo *, IdString> &k) const noexcept
        {
            std::size_t seed = std::hash<const CellInfo *>()(k.first);
            boost::hash_combine(seed, std::hash<IdString>()(k.second));
            return seed;
        }
    };
    std::unordered_map<const NetInfo *,
                       std::unordered_map<std::pair<const CellInfo *, IdString>, delay_t, PinKeyHash>>
            clock_pin_delays;

    delay_t clock_pin_delay(const CellInfo *cell, IdString clock_port)
    {
        delay_t d = 0;
        if (!net_delays)
            return d;
        const NetInfo *clk = get_net_or_empty(cell, clock_port);
        if (clk == nullptr || clk->wires.empty())
            return d;
        auto fnd = clock_pin_delays.find(clk);
        if (fnd == clock_pin_delays.end()) {
            auto &pins = clock_pin_delays[clk];
            for (auto &usr : clk->users)
                pins[std::make_pair(static_cast<const CellInfo *>(usr.cell), usr.port)] =
                        ctx->getNetinfoRouteDelay(clk, usr);
            fnd = clock_pin_delays.find(clk);
        }
        auto pin = fnd->second.find(std::make_pair(cell, clock_port));
        return pin == fnd->second.end() ? d : pin->second;
    }

    struct ClockPathStep
    {
        WireId wire;
        delay_t max_up, min_up;
    };
    std::unordered_map<std::pair<const CellInfo *, IdString>, std::vector<ClockPathStep>, PinKeyHash> clock_paths;

    const std::vector<ClockPathStep> &clock_path(const CellInfo *cell, IdString clock_port)
    {
        auto key = std::make_pair(cell, clock_port);
        auto fnd = clock_paths.find(key);
        if (fnd != clock_paths.end())
            return fnd->second;
        auto &path = clock_paths[key];
        const NetInfo *clk = get_net_or_empty(cell, clock_port);
        if (!net_delays || clk == nullptr || clk->wires.empty())
            return path;
        const PortRef *usr = nullptr;
        for (auto &u : clk->users)
            if (u.cell == cell && u.port == clock_port) {
                usr = &u;
                break;
            }
        WireId src = ctx->getNetinfoSourceWire(clk);
        if (usr == nullptr || src == WireId())
            return path;
        std::vector<std::pair<WireId, std::pair<delay_t, delay_t>>> steps;
        WireId cursor = ctx->getNetinfoSinkWire(clk, *usr);
        size_t hops = 0;
        while (cursor != WireId() && cursor != src && hops++ <= clk->wires.size()) {
            auto it = clk->wires.find(cursor);
            if (it == clk->wires.end() || it->second.pip == PipId())
                return path;
            PipId pip = it->second.pip;
            steps.emplace_back(cursor, std::make_pair(ctx->getPipDelay(pip).maxDelay() + ctx->getWireDelay(cursor).maxDelay(),
                                                      ctx->getPipDelay(pip).minDelay() + ctx->getWireDelay(cursor).minDelay()));
            cursor = ctx->getPipSrcWire(pip);
        }
        if (cursor != src)
            return path;
        steps.emplace_back(src, std::make_pair(ctx->getWireDelay(src).maxDelay(), ctx->getWireDelay(src).minDelay()));
        delay_t up_max = 0, up_min = 0;
        path.resize(steps.size());
        for (size_t i = steps.size(); i-- > 0;) {
            up_max += steps.at(i).second.first;
            up_min += steps.at(i).second.second;
            path.at(i) = ClockPathStep{steps.at(i).first, up_max, up_min};
        }
        return path;
    }

    delay_t clock_pessimism_removal(const CellInfo *launch_cell, IdString launch_port, const CellInfo *capture_cell,
                                    IdString capture_port)
    {
        if (launch_cell == nullptr || capture_cell == nullptr)
            return 0;
        if (get_net_or_empty(launch_cell, launch_port) != get_net_or_empty(capture_cell, capture_port))
            return 0;
        const auto &lp = clock_path(launch_cell, launch_port);
        const auto &cp = clock_path(capture_cell, capture_port);
        if (lp.empty() || cp.empty())
            return 0;
        std::unordered_set<WireId> on_capture;
        for (auto &st : cp)
            on_capture.insert(st.wire);
        for (auto &st : lp)
            if (on_capture.count(st.wire))
                return st.max_up - st.min_up;
        return 0;
    }

    delay_t clock_pin_delay_min(const CellInfo *cell, IdString clock_port)
    {
        const auto &p = clock_path(cell, clock_port);
        return p.empty() ? clock_pin_delay(cell, clock_port) : p.front().min_up;
    }

    delay_t clock_period_of(IdString clk, delay_t clk_period) const
    {
        if (clk == async_clock)
            return clk_period;
        auto fnd = ctx->nets.find(clk);
        if (fnd == ctx->nets.end() || fnd->second->clkconstr == nullptr)
            return clk_period;
        return fnd->second->clkconstr->period.maxDelay();
    }

    void apply_multicycle(const ExceptionResult &exc, IdString launch, IdString capture, delay_t clk_period,
                          delay_t *setup_req, delay_t *hold_req) const
    {
        if (exc.has_max)
            return;
        delay_t ts = clock_period_of(exc.mcp_setup_launch ? launch : capture, clk_period);
        delay_t th = clock_period_of(exc.mcp_hold_launch ? launch : capture, clk_period);
        delay_t setup_shift = delay_t(exc.mcp_setup - 1) * ts;
        if (setup_req != nullptr)
            *setup_req += setup_shift;
        if (hold_req != nullptr)
            *hold_req += setup_shift - delay_t(exc.mcp_hold) * th;
    }

    struct TimingData
    {
        TimingData() : max_arrival(), max_path_length(), min_remaining_budget() {}
        TimingData(delay_t max_arrival) : max_arrival(max_arrival), max_path_length(), min_remaining_budget() {}
        delay_t max_arrival;
        // earliest arrival (hold pass); large default so std::min accumulates.
        delay_t min_arrival = std::numeric_limits<delay_t>::max() / 4;
        unsigned max_path_length = 0;
        delay_t min_remaining_budget;
        bool false_startpoint = false;
        bool estimated = false;
        delay_t launch_delay = 0, min_launch_delay = 0;
        const CellInfo *min_launch_cell = nullptr;
        IdString min_launch_port;
        std::vector<delay_t> min_required;
        std::unordered_map<ClockEvent, delay_t> arrival_time;
    };

    Timing(Context *ctx, bool net_delays, bool update, CriticalPathMap *crit_path = nullptr,
           DelayFrequency *slack_histogram = nullptr, NetCriticalityMap *net_crit = nullptr, bool export_setup = false)
            : ctx(ctx), net_delays(net_delays), update(update), min_slack(1.0e12 / ctx->setting<float>("target_freq")),
              crit_path(crit_path), slack_histogram(slack_histogram), net_crit(net_crit),
              async_clock(ctx->id("$async$"))
    {
        have_exceptions = !ctx->timing_exceptions.empty() || !ctx->timing_clock_groups.empty();
        if (have_exceptions) {
            texc_from_attr = ctx->id("NEXTPNR_TEXC_FROM");
            texc_to_attr = ctx->id("NEXTPNR_TEXC_TO");
        }
        if (ctx->timing_ignore_nets)
            ignore_attr = ctx->id("NEXTPNR_TIMING_IGNORE");
        if (const char *fn = getenv("NEXTPNR_ASYNC_GROUPS")) {
            std::ifstream in(fn);
            std::string line;
            while (std::getline(in, line)) {
                std::istringstream iss(line);
                std::vector<std::string> grp;
                std::string tok;
                while (iss >> tok)
                    grp.push_back(tok);
                if (!grp.empty())
                    async_groups.push_back(std::move(grp));
            }
            if (!async_groups.empty())
                log_info("timing: loaded %zu async clock group(s) from %s\n", async_groups.size(), fn);
        }
        if (export_setup) {
            if (const char *sf = getenv("NEXTPNR_SETUP_EXPORT")) {
                setup_export.open(sf);
                if (!setup_export)
                    log_error("cannot open NEXTPNR_SETUP_EXPORT file '%s' for writing\n", sf);
                setup_export << "cell\tport\tslack_ns\tnet\tnet_delay_ns\tdriver_arrival_ns\tsetup_ns\tperiod_ns\tlaunch_"
                                "clk\tcapture_clk\tpath_len\tdelay_source\tlaunch_clk_delay_ns\tcapture_clk_delay_"
                                "ns\trequirement_source\n";
            }
            if (const char *hf = getenv("NEXTPNR_HOLD_EXPORT")) {
                hold_export.open(hf);
                if (!hold_export)
                    log_error("cannot open NEXTPNR_HOLD_EXPORT file '%s' for writing\n", hf);
                hold_export << "cell\tport\thold_slack_ns\tnet\tnet_delay_min_ns\tdriver_min_arrival_ns\thold_ns\thold_"
                               "req_ns\tcapture_clk_delay_ns\tlaunch_clk\tcapture_clk\tdelay_"
                               "source\tlaunch_clk_delay_ns\trequirement_source\tcppr_ns\n";
            }
        }
    }

    delay_t walk_paths()
    {
        const auto clk_period = ctx->getDelayFromNS(1.0e9 / ctx->setting<float>("target_freq")).maxDelay();

        std::vector<NetInfo *> topographical_order;
        std::unordered_map<const NetInfo *, std::unordered_map<ClockEvent, TimingData>> net_data;
        // In lieu of deleting edges from the graph, simply count the number of fanins to each output port
        std::unordered_map<const PortInfo *, unsigned> port_fanin;

        std::vector<IdString> input_ports;
        std::vector<const PortInfo *> output_ports;
        for (auto &cell : ctx->cells) {
            input_ports.clear();
            output_ports.clear();
            for (auto &port : cell.second->ports) {
                if (!port.second.net)
                    continue;
                if (port.second.type == PORT_OUT)
                    output_ports.push_back(&port.second);
                else
                    input_ports.push_back(port.first);
            }

            for (auto o : output_ports) {
                int clocks = 0;
                TimingPortClass portClass = ctx->getPortTimingClass(cell.second.get(), o->name, clocks);
                // If output port is influenced by a clock (e.g. FF output) then add it to the ordering as a timing
                // start-point
                if (portClass == TMG_REGISTER_OUTPUT) {
                    topographical_order.emplace_back(o->net);
                    for (int i = 0; i < clocks; i++) {
                        TimingClockingInfo clkInfo = ctx->getPortClockingInfo(cell.second.get(), o->name, i);
                        const NetInfo *clknet = get_net_or_empty(cell.second.get(), clkInfo.clock_port);
                        IdString clksig = clknet ? clknet->name : async_clock;
                        auto &sd = net_data[o->net][ClockEvent{clksig, clknet ? clkInfo.edge : RISING_EDGE,
                                                               start_tag(cell.second.get())}];
                        delay_t launch = clock_pin_delay(cell.second.get(), clkInfo.clock_port);
                        sd = TimingData{clkInfo.clockToQ.maxDelay() + launch};
                        const delay_t launch_min = clock_pin_delay_min(cell.second.get(), clkInfo.clock_port);
                        sd.min_arrival = clkInfo.clockToQ.minDelay() + launch_min;
                        sd.launch_delay = launch;
                        sd.min_launch_delay = launch_min;
                        sd.min_launch_cell = cell.second.get();
                        sd.min_launch_port = clkInfo.clock_port;
                    }

                } else {
                    if (portClass == TMG_STARTPOINT || portClass == TMG_GEN_CLOCK || portClass == TMG_IGNORE) {
                        topographical_order.emplace_back(o->net);
                        TimingData td;
                        td.false_startpoint = (portClass == TMG_GEN_CLOCK || portClass == TMG_IGNORE);
                        td.max_arrival = 0;
                        net_data[o->net][ClockEvent{async_clock, RISING_EDGE, start_tag(cell.second.get())}] = td;
                    }

                    // Don't analyse paths from a clock input to other pins - they will be considered by the
                    // special-case handling register input/output class ports
                    if (portClass == TMG_CLOCK_INPUT)
                        continue;

                    // Otherwise, for all driven input ports on this cell, if a timing arc exists between the input and
                    // the current output port, increment fanin counter
                    const bool source =
                            portClass == TMG_STARTPOINT || portClass == TMG_GEN_CLOCK || portClass == TMG_IGNORE;
                    for (auto i : input_ports) {
                        if (source)
                            break;
                        // A cell input pin can end up bound to the cell's own
                        // output net (e.g. the xc7 post-route LUT pin fixup
                        // when the router feeds the output back through an
                        // unused input pin of the same site). Such an arc can
                        // never be a real timing path, but counting it here
                        // deadlocks the topological sort below as a false
                        // combinational loop.
                        if (cell.second->ports.at(i).net == o->net)
                            continue;
                        DelayInfo comb_delay;
                        bool is_path = ctx->getCellDelay(cell.second.get(), i, o->name, comb_delay);
                        if (!is_path)
                            continue;
                        int in_clocks;
                        TimingPortClass inClass = ctx->getPortTimingClass(cell.second.get(), i, in_clocks);
                        if (inClass != TMG_IGNORE && inClass != TMG_CLOCK_INPUT)
                            port_fanin[o]++;
                    }
                    if (portClass == TMG_COMB_OUTPUT && clocks > 0) {
                        for (int i = 0; i < clocks; i++) {
                            TimingClockingInfo clkInfo = ctx->getPortClockingInfo(cell.second.get(), o->name, i);
                            const NetInfo *clknet = get_net_or_empty(cell.second.get(), clkInfo.clock_port);
                            IdString clksig = clknet ? clknet->name : async_clock;
                            auto &sd = net_data[o->net][ClockEvent{clksig, clknet ? clkInfo.edge : RISING_EDGE,
                                                                   start_tag(cell.second.get())}];
                            delay_t launch = clock_pin_delay(cell.second.get(), clkInfo.clock_port);
                            sd = TimingData{clkInfo.clockToQ.maxDelay() + launch};
                            const delay_t launch_min = clock_pin_delay_min(cell.second.get(), clkInfo.clock_port);
                            sd.min_arrival = clkInfo.clockToQ.minDelay() + launch_min;
                            sd.launch_delay = launch;
                            sd.min_launch_delay = launch_min;
                            sd.min_launch_cell = cell.second.get();
                            sd.min_launch_port = clkInfo.clock_port;
                        }
                        if (!port_fanin.count(o))
                            topographical_order.emplace_back(o->net);
                    }
                    // If there is no fanin, add the port as a false startpoint
                    if (!port_fanin.count(o) && !net_data.count(o->net)) {
                        topographical_order.emplace_back(o->net);
                        TimingData td;
                        td.false_startpoint = true;
                        td.max_arrival = 0;
                        net_data[o->net][ClockEvent{async_clock, RISING_EDGE}] = td;
                    }
                }
            }
        }

        // In out-of-context mode, handle top-level ports correctly
        if (bool_or_default(ctx->settings, ctx->id("arch.ooc"))) {
            for (auto &p : ctx->ports) {
                if (p.second.type != PORT_IN || p.second.net == nullptr)
                    continue;
                topographical_order.emplace_back(p.second.net);
            }
        }

        std::deque<NetInfo *> queue(topographical_order.begin(), topographical_order.end());
        std::unordered_set<const PortInfo *> cut_ports;
        auto follows_arc = [&](const PortRef &usr) {
            int user_clocks;
            TimingPortClass usrClass = ctx->getPortTimingClass(usr.cell, usr.port, user_clocks);
            return usrClass != TMG_IGNORE && usrClass != TMG_CLOCK_INPUT;
        };
        auto comb_successor = [&](const NetInfo *net, const PortRef &usr, const std::pair<const IdString, PortInfo> &port) {
            if (port.second.type != PORT_OUT || !port.second.net)
                return false;
            int port_clocks;
            TimingPortClass portClass = ctx->getPortTimingClass(usr.cell, port.first, port_clocks);
            if (portClass == TMG_REGISTER_OUTPUT || portClass == TMG_STARTPOINT || portClass == TMG_IGNORE ||
                portClass == TMG_GEN_CLOCK)
                return false;
            if (port.second.net == net)
                return false;
            DelayInfo comb_delay;
            return ctx->getCellDelay(usr.cell, usr.port, port.first, comb_delay);
        };
        auto drain = [&]() {
            while (!queue.empty()) {
                const auto net = queue.front();
                queue.pop_front();

                for (auto &usr : net->users) {
                    if (!follows_arc(usr))
                        continue;
                    for (auto &port : usr.cell->ports) {
                        if (!comb_successor(net, usr, port))
                            continue;
                        auto it = port_fanin.find(&port.second);
                        if (it == port_fanin.end()) {
                            if (cut_ports.count(&port.second))
                                continue;
                            log_error("Internal timing error (negative fanin count) for %s.%s\n",
                                      ctx->nameOf(usr.cell), ctx->nameOf(port.first));
                        }
                        if (--it->second == 0) {
                            topographical_order.emplace_back(port.second.net);
                            queue.emplace_back(port.second.net);
                            port_fanin.erase(it);
                        }
                    }
                }
            }
        };
        drain();

        int loop_count = 0, loop_cuts = 0, unfed_cuts = 0, stranded_ports = int(port_fanin.size()),
            stranded_endpoints = 0;
        auto port_key = [&](const PortInfo *p) {
            return std::make_pair(std::string(p->net->driver.cell->name.c_str(ctx)), std::string(p->name.c_str(ctx)));
        };
        bool first_round = true;
        while (!port_fanin.empty()) {
            std::vector<const PortInfo *> nodes;
            for (auto &pf : port_fanin)
                nodes.push_back(pf.first);
            std::sort(nodes.begin(), nodes.end(),
                      [&](const PortInfo *a, const PortInfo *b) { return port_key(a) < port_key(b); });
            std::unordered_map<const PortInfo *, int> index;
            for (int i = 0; i < int(nodes.size()); i++)
                index[nodes.at(i)] = i;
            std::vector<std::vector<int>> succ(nodes.size());
            std::vector<int> indegree(nodes.size(), 0);
            for (int i = 0; i < int(nodes.size()); i++) {
                const NetInfo *net = nodes.at(i)->net;
                for (auto &usr : net->users) {
                    if (first_round) {
                        int user_clocks;
                        TimingPortClass usrClass = ctx->getPortTimingClass(usr.cell, usr.port, user_clocks);
                        if (usrClass == TMG_REGISTER_INPUT || usrClass == TMG_ENDPOINT)
                            ++stranded_endpoints;
                    }
                    if (!follows_arc(usr))
                        continue;
                    for (auto &port : usr.cell->ports) {
                        auto fnd = index.find(&port.second);
                        if (fnd == index.end() || !comb_successor(net, usr, port))
                            continue;
                        succ.at(i).push_back(fnd->second);
                        ++indegree.at(fnd->second);
                    }
                }
            }

            std::vector<int> scc_of(nodes.size(), -1), low(nodes.size(), 0), order(nodes.size(), -1);
            std::vector<bool> on_stack(nodes.size(), false);
            std::vector<int> stack, scc_size;
            int next_order = 0;
            for (int root = 0; root < int(nodes.size()); root++) {
                if (order.at(root) >= 0)
                    continue;
                std::vector<std::pair<int, size_t>> work{{root, 0}};
                order.at(root) = low.at(root) = next_order++;
                stack.push_back(root);
                on_stack.at(root) = true;
                while (!work.empty()) {
                    int v = work.back().first;
                    size_t &edge = work.back().second;
                    if (edge < succ.at(v).size()) {
                        int w = succ.at(v).at(edge++);
                        if (order.at(w) < 0) {
                            order.at(w) = low.at(w) = next_order++;
                            stack.push_back(w);
                            on_stack.at(w) = true;
                            work.emplace_back(w, 0);
                        } else if (on_stack.at(w)) {
                            low.at(v) = std::min(low.at(v), order.at(w));
                        }
                        continue;
                    }
                    if (low.at(v) == order.at(v)) {
                        int id = int(scc_size.size());
                        scc_size.push_back(0);
                        int w;
                        do {
                            w = stack.back();
                            stack.pop_back();
                            on_stack.at(w) = false;
                            scc_of.at(w) = id;
                            ++scc_size.at(id);
                        } while (w != v);
                    }
                    work.pop_back();
                    if (!work.empty())
                        low.at(work.back().first) = std::min(low.at(work.back().first), low.at(v));
                }
            }

            std::vector<int> cuts;
            std::vector<bool> scc_cut(scc_size.size(), false);
            for (int i = 0; i < int(nodes.size()); i++) {
                int id = scc_of.at(i);
                if (scc_size.at(id) > 1 && !scc_cut.at(id)) {
                    scc_cut.at(id) = true;
                    cuts.push_back(i);
                }
            }
            if (first_round) {
                loop_count = int(cuts.size());
                bool ignore_loops = bool_or_default(ctx->settings, ctx->id("timing/ignoreLoops"), true);
                if (!ignore_loops) {
                    std::vector<int> loop_number(scc_size.size(), 0);
                    for (size_t c = 0; c < cuts.size(); c++)
                        loop_number.at(scc_of.at(cuts.at(c))) = int(c) + 1;
                    for (int i = 0; i < int(nodes.size()); i++) {
                        if (scc_size.at(scc_of.at(i)) < 2)
                            continue;
                        const PortInfo *p = nodes.at(i);
                        log_info("   loop %d: %s.%s (net %s)\n", loop_number.at(scc_of.at(i)),
                                 ctx->nameOf(p->net->driver.cell), p->name.c_str(ctx), p->net->name.c_str(ctx));
                    }
                    if (ctx->force)
                        log_warning("timing analysis: %d combinational loop(s) through %d output port(s), %d "
                                    "output port(s) stranded in all\n",
                                    loop_count, int(std::count_if(nodes.begin(), nodes.end(), [&](const PortInfo *p) {
                                        return scc_size.at(scc_of.at(index.at(p))) > 1;
                                    })),
                                    stranded_ports);
                    else
                        log_error("timing analysis: %d combinational loop(s) through %d output port(s), %d output "
                                  "port(s) stranded in all\n",
                                  loop_count, int(std::count_if(nodes.begin(), nodes.end(), [&](const PortInfo *p) {
                                      return scc_size.at(scc_of.at(index.at(p))) > 1;
                                  })),
                                  stranded_ports);
                }
                first_round = false;
            }
            if (cuts.empty()) {
                for (int i = 0; i < int(nodes.size()); i++)
                    if (indegree.at(i) == 0)
                        cuts.push_back(i);
                unfed_cuts += int(cuts.size());
            } else {
                loop_cuts += int(cuts.size());
            }
            NPNR_ASSERT(!cuts.empty());
            for (int i : cuts) {
                const PortInfo *p = nodes.at(i);
                port_fanin.erase(p);
                cut_ports.insert(p);
                topographical_order.emplace_back(p->net);
                queue.emplace_back(p->net);
            }
            drain();
        }
        if (loop_cuts > 0)
            log_warning("timing analysis: %d combinational loop(s) cut at %d output port(s); %d output port(s) were "
                        "stranded by them, feeding %d endpoint pin(s), and are timed through the cut. A loop is a "
                        "design error unless it is deliberate; --no-ignore-loops makes it fatal.\n",
                        loop_count, loop_cuts, stranded_ports, stranded_endpoints);
        if (unfed_cuts > 0)
            log_warning("timing analysis: %d output port(s) have a timing arc from a net that never receives an "
                        "arrival, and were cut there so their fanout is still timed\n",
                        unfed_cuts);

        std::unordered_map<const NetInfo *, size_t> order_index;
        if (!cut_ports.empty())
            for (size_t i = 0; i < topographical_order.size(); i++)
                order_index.emplace(topographical_order.at(i), i);
        auto cut_arc = [&](const NetInfo *from, const CellInfo *cell, IdString out_port) {
            if (cut_ports.empty())
                return false;
            const PortInfo &out = cell->ports.at(out_port);
            if (!cut_ports.count(&out))
                return false;
            auto f = order_index.find(from), t = order_index.find(out.net);
            return f == order_index.end() || t == order_index.end() || f->second >= t->second;
        };

        // Go forwards topographically to find the maximum arrival time and max path length for each net
        for (auto net : topographical_order) {
            if (!net_data.count(net))
                continue;
            auto &nd_map = net_data.at(net);
            for (auto &startdomain : nd_map) {
                ClockEvent start_clk = startdomain.first;
                auto &nd = startdomain.second;
                if (nd.false_startpoint)
                    continue;
                const auto net_arrival = nd.max_arrival;
                const auto net_min_arrival = nd.min_arrival;
                const auto net_length_plus_one = nd.max_path_length + 1;
                nd.min_remaining_budget = clk_period;
                if (timing_ignored(net))
                    continue;
                for (auto &usr : net->users) {
                    int port_clocks;
                    TimingPortClass portClass = ctx->getPortTimingClass(usr.cell, usr.port, port_clocks);
                    auto net_delay = net_delays ? ctx->getNetinfoRouteDelay(net, usr) : delay_t();
                    auto net_delay_min = net_delays ? ctx->getNetinfoRouteDelay(net, usr, true) : delay_t();
                    auto usr_arrival = net_arrival + net_delay;
                    auto usr_min_arrival = net_min_arrival + net_delay_min;

                    if (portClass == TMG_ENDPOINT || portClass == TMG_IGNORE || portClass == TMG_CLOCK_INPUT) {
                        // Skip
                    } else {
                        auto budget_override = ctx->getBudgetOverride(net, usr, net_delay);
                        // Iterate over all output ports on the same cell as the sink
                        for (auto port : usr.cell->ports) {
                            if (port.second.type != PORT_OUT || !port.second.net)
                                continue;
                            DelayInfo comb_delay;
                            // Look up delay through this path
                            bool is_path = ctx->getCellDelay(usr.cell, usr.port, port.first, comb_delay);
                            if (!is_path || cut_arc(net, usr.cell, port.first))
                                continue;
                            auto &data = net_data[port.second.net][start_clk];
                            data.estimated = data.estimated || nd.estimated || (net_delays && net->wires.empty());
                            auto &arrival = data.max_arrival;
                            const delay_t cand = usr_arrival + comb_delay.maxDelay();
                            if (cand > arrival) {
                                arrival = cand;
                                data.launch_delay = nd.launch_delay;
                            }
                            const delay_t min_cand = usr_min_arrival + comb_delay.minDelay();
                            if (min_cand < data.min_arrival) {
                                data.min_arrival = min_cand;
                                data.min_launch_delay = nd.min_launch_delay;
                                data.min_launch_cell = nd.min_launch_cell;
                                data.min_launch_port = nd.min_launch_port;
                            }
                            if (!budget_override) { // Do not increment path length if budget overriden since it doesn't
                                // require a share of the slack
                                auto &path_length = data.max_path_length;
                                path_length = std::max(path_length, net_length_plus_one);
                            }
                        }
                    }
                }
            }
        }

        std::unordered_map<ClockPair, std::pair<double, NetInfo *>> crit_nets;

        // Now go backwards topographically to determine the minimum path slack, and to distribute all path slack evenly
        // between all nets on the path
        for (auto net : boost::adaptors::reverse(topographical_order)) {
            if (!net_data.count(net))
                continue;
            auto &nd_map = net_data.at(net);
            for (auto &startdomain : nd_map) {
                auto &nd = startdomain.second;
                // Ignore false startpoints
                if (nd.false_startpoint)
                    continue;
                const delay_t net_length_plus_one = nd.max_path_length + 1;
                auto &net_min_remaining_budget = nd.min_remaining_budget;
                if (timing_ignored(net))
                    continue;
                for (auto &usr : net->users) {
                    auto net_delay = net_delays ? ctx->getNetinfoRouteDelay(net, usr) : delay_t();
                    auto net_delay_min = net_delays ? ctx->getNetinfoRouteDelay(net, usr, true) : delay_t();
                    auto budget_override = ctx->getBudgetOverride(net, usr, net_delay);
                    int port_clocks;
                    TimingPortClass portClass = ctx->getPortTimingClass(usr.cell, usr.port, port_clocks);
                    if (portClass == TMG_REGISTER_INPUT || portClass == TMG_ENDPOINT) {
                        auto process_endpoint = [&](IdString clksig, ClockEdge edge, delay_t setup,
                                                    const ExceptionResult &exc, delay_t capture_delay) {
                            if (exc.skip_setup) {
                                if (crit_path && !update)
                                    ++exc_setup_skipped;
                                return;
                            }
                            // Async clock-group exclusion: a launch->capture path
                            // crossing two different async groups is a CDC false
                            // path -- skip it entirely (no slack/budget/crit).
                            {
                                IdString launch_clk = startdomain.first.clock;
                                if (launch_clk != async_clock && clksig != async_clock) {
                                    int gl = clock_group(launch_clk), gc = clock_group(clksig);
                                    if (gl >= 0 && gc >= 0 && gl != gc)
                                        return;
                                }
                            }
                            const auto net_arrival = nd.max_arrival;
                            const auto endpoint_arrival = net_arrival + net_delay + setup - capture_delay;
                            delay_t period = setup_requirement(startdomain.first, clksig, edge, clk_period);
                            double this_mcp = 1.0;
                            if (exc.has_max) {
                                if (crit_path && !update)
                                    ++exc_max_delay;
                                this_mcp = period > 0 ? std::max(1e-6, double(exc.max_value) / double(period)) : 1.0;
                                period = exc.max_value;
                            } else if (exc.mcp_setup != 1) {
                                delay_t base = period;
                                apply_multicycle(exc, startdomain.first.clock, clksig, clk_period, &period, nullptr);
                                if (crit_path && !update)
                                    ++exc_multicycle;
                                this_mcp = base > 0 ? std::max(1e-6, double(period) / double(base)) : 1.0;
                            }
                            auto path_budget = period - endpoint_arrival;

                            if (update) {
                                auto budget_share = budget_override ? 0 : path_budget / net_length_plus_one;
                                usr.budget = std::min(usr.budget, net_delay + budget_share);
                                net_min_remaining_budget =
                                        std::min(net_min_remaining_budget, path_budget - budget_share);
                            }

                            if (path_budget < min_slack)
                                min_slack = path_budget;

                            if (slack_histogram) {
                                int slack_ps = ctx->getDelayNS(path_budget) * 1000;
                                (*slack_histogram)[slack_ps]++;
                            }
                            if (setup_export.is_open()) {
                                std::ostringstream row;
                                row << usr.cell->name.c_str(ctx) << '\t' << usr.port.c_str(ctx) << '\t'
                                    << ctx->getDelayNS(path_budget) << '\t' << net->name.c_str(ctx) << '\t'
                                    << ctx->getDelayNS(net_delay) << '\t' << ctx->getDelayNS(net_arrival) << '\t'
                                    << ctx->getDelayNS(setup) << '\t' << ctx->getDelayNS(period) << '\t'
                                    << startdomain.first.clock.c_str(ctx) << '\t' << clksig.c_str(ctx) << '\t'
                                    << nd.max_path_length << '\t'
                                    << ((nd.estimated || (net_delays && net->wires.empty())) ? "estimate" : "routed")
                                    << '\t' << ctx->getDelayNS(nd.launch_delay) << '\t'
                                    << ctx->getDelayNS(capture_delay) << '\t'
                                    << setup_source(exc, base_requirement_source(startdomain.first, clksig, edge))
                                    << '\n';
                                std::string key = std::string(usr.cell->name.c_str(ctx)) + '\t' + usr.port.c_str(ctx) +
                                                  '\t' + startdomain.first.clock.c_str(ctx) + '\t' +
                                                  std::to_string(int(startdomain.first.edge)) + '\t' +
                                                  clksig.c_str(ctx) + '\t' + std::to_string(int(edge));
                                auto fnd = setup_row_index.find(key);
                                if (fnd == setup_row_index.end()) {
                                    setup_row_index.emplace(key, setup_rows.size());
                                    setup_rows.emplace_back(path_budget, row.str());
                                } else if (path_budget < setup_rows.at(fnd->second).first) {
                                    setup_rows.at(fnd->second) = std::make_pair(path_budget, row.str());
                                }
                            }
                            ClockEvent dest_ev{clksig, edge, startdomain.first.tag};
                            ClockPair clockPair{startdomain.first, dest_ev};
                            nd.arrival_time[dest_ev] = std::max(nd.arrival_time[dest_ev], endpoint_arrival);

                            if (crit_path) {
                                if (startdomain.first.clock == clksig && startdomain.first.edge == edge) {
                                    ClockEvent domain{clksig, edge};
                                    auto raw = domain_raw_max.find(domain);
                                    if (raw == domain_raw_max.end())
                                        domain_raw_max.emplace(domain, endpoint_arrival);
                                    else if (raw->second < endpoint_arrival)
                                        raw->second = endpoint_arrival;
                                }
                                double norm_arrival = double(endpoint_arrival) / this_mcp;
                                if (!crit_nets.count(clockPair) || crit_nets.at(clockPair).first < norm_arrival) {
                                    crit_nets[clockPair] = std::make_pair(norm_arrival, net);
                                    (*crit_path)[clockPair].path_delay = endpoint_arrival;
                                    (*crit_path)[clockPair].path_period = period;
                                    (*crit_path)[clockPair].mcp = this_mcp;
                                    (*crit_path)[clockPair].by_exception = exc.has_max || this_mcp != 1.0;
                                    (*crit_path)[clockPair].ports.clear();
                                    (*crit_path)[clockPair].ports.push_back(&usr);
                                }
                            }
                        };
                        if (portClass == TMG_REGISTER_INPUT) {
                            for (int i = 0; i < port_clocks; i++) {
                                TimingClockingInfo clkInfo = ctx->getPortClockingInfo(usr.cell, usr.port, i);
                                const NetInfo *clknet = get_net_or_empty(usr.cell, clkInfo.clock_port);
                                IdString clksig = clknet ? clknet->name : async_clock;
                                ExceptionResult exc = match_exceptions(startdomain.first, clksig, usr.cell, usr.port);
                                delay_t capture = clock_pin_delay(usr.cell, clkInfo.clock_port);
                                process_endpoint(clksig, clknet ? clkInfo.edge : RISING_EDGE, clkInfo.setup.maxDelay(),
                                                 exc, capture);
                                if (exc.skip_hold && crit_path && !update)
                                    ++exc_hold_skipped;
                                if (!exc.skip_hold && nd.min_arrival < (std::numeric_limits<delay_t>::max() / 8)) {
                                    delay_t hold_req;
                                    setup_requirement(startdomain.first, clksig, clknet ? clkInfo.edge : RISING_EDGE,
                                                      clk_period, &hold_req);
                                    apply_multicycle(exc, startdomain.first.clock, clksig, clk_period, nullptr,
                                                     &hold_req);
                                    const delay_t cppr = clock_pessimism_removal(
                                            nd.min_launch_cell, nd.min_launch_port, usr.cell, clkInfo.clock_port);
                                    delay_t hold_slack = nd.min_arrival + net_delay_min - clkInfo.hold.maxDelay() -
                                                         hold_req - capture + cppr;
                                    worst_hold_slack = std::min(worst_hold_slack, hold_slack);
                                    if (crit_path)
                                        hold_endpoints.push_back({usr.cell->name, usr.port, hold_slack});
                                    if (hold_export.is_open()) {
                                        std::ostringstream row;
                                        row << usr.cell->name.c_str(ctx) << '\t' << usr.port.c_str(ctx) << '\t'
                                            << ctx->getDelayNS(hold_slack) << '\t' << net->name.c_str(ctx) << '\t'
                                            << ctx->getDelayNS(net_delay_min) << '\t'
                                            << ctx->getDelayNS(nd.min_arrival) << '\t'
                                            << ctx->getDelayNS(clkInfo.hold.maxDelay()) << '\t'
                                            << ctx->getDelayNS(hold_req) << '\t' << ctx->getDelayNS(capture) << '\t'
                                            << startdomain.first.clock.c_str(ctx) << '\t' << clksig.c_str(ctx)
                                            << '\t'
                                            << ((nd.estimated || (net_delays && net->wires.empty())) ? "estimate"
                                                                                                     : "routed")
                                            << '\t' << ctx->getDelayNS(nd.min_launch_delay) << '\t'
                                            << hold_source(exc, base_requirement_source(
                                                                        startdomain.first, clksig,
                                                                        clknet ? clkInfo.edge : RISING_EDGE))
                                            << '\t' << ctx->getDelayNS(cppr) << '\n';
                                        std::string key = std::string(usr.cell->name.c_str(ctx)) + '\t' +
                                                          usr.port.c_str(ctx) + '\t' +
                                                          startdomain.first.clock.c_str(ctx) + '\t' +
                                                          std::to_string(int(startdomain.first.edge)) + '\t' +
                                                          clksig.c_str(ctx) + '\t' + std::to_string(int(clkInfo.edge));
                                        auto fnd = hold_row_index.find(key);
                                        if (fnd == hold_row_index.end()) {
                                            hold_row_index.emplace(key, hold_rows.size());
                                            hold_rows.emplace_back(hold_slack, row.str());
                                        } else if (hold_slack < hold_rows.at(fnd->second).first) {
                                            hold_rows.at(fnd->second) = std::make_pair(hold_slack, row.str());
                                        }
                                    }
                                }
                            }
                        } else {
                            process_endpoint(async_clock, RISING_EDGE, 0,
                                             match_exceptions(startdomain.first, async_clock, usr.cell, usr.port), 0);
                        }

                    } else if (update) {

                        // Iterate over all output ports on the same cell as the sink
                        for (const auto &port : usr.cell->ports) {
                            if (port.second.type != PORT_OUT || !port.second.net)
                                continue;
                            DelayInfo comb_delay;
                            bool is_path = ctx->getCellDelay(usr.cell, usr.port, port.first, comb_delay);
                            if (!is_path || cut_arc(net, usr.cell, port.first))
                                continue;
                            if (net_data.count(port.second.net) &&
                                net_data.at(port.second.net).count(startdomain.first)) {
                                auto path_budget =
                                        net_data.at(port.second.net).at(startdomain.first).min_remaining_budget;
                                auto budget_share = budget_override ? 0 : path_budget / net_length_plus_one;
                                usr.budget = std::min(usr.budget, net_delay + budget_share);
                                net_min_remaining_budget =
                                        std::min(net_min_remaining_budget, path_budget - budget_share);
                            }
                        }
                    }
                }
            }
        }

        if (crit_path) {
            // Walk backwards from the most critical net
            for (auto crit_pair : crit_nets) {
                NetInfo *crit_net = crit_pair.second.second;
                auto &cp_ports = (*crit_path)[crit_pair.first].ports;
                while (crit_net) {
                    const PortInfo *crit_ipin = nullptr;
                    delay_t max_arrival = std::numeric_limits<delay_t>::min();
                    delay_t launch_arrival = std::numeric_limits<delay_t>::min();
                    {
                        int drv_clocks = 0;
                        TimingPortClass drv_class = ctx->getPortTimingClass(crit_net->driver.cell,
                                                                            crit_net->driver.port, drv_clocks);
                        if (drv_class == TMG_COMB_OUTPUT) {
                            for (int i = 0; i < drv_clocks; i++) {
                                TimingClockingInfo ci =
                                        ctx->getPortClockingInfo(crit_net->driver.cell, crit_net->driver.port, i);
                                const NetInfo *clknet = get_net_or_empty(crit_net->driver.cell, ci.clock_port);
                                if (clknet != nullptr && clknet->name == crit_pair.first.start.clock &&
                                    ci.edge == crit_pair.first.start.edge)
                                    launch_arrival = std::max(
                                            launch_arrival,
                                            ci.clockToQ.maxDelay() +
                                                    clock_pin_delay(crit_net->driver.cell, ci.clock_port));
                            }
                        }
                    }
                    // Look at all input ports on its driving cell
                    for (const auto &port : crit_net->driver.cell->ports) {
                        if (port.second.type != PORT_IN || !port.second.net)
                            continue;
                        DelayInfo comb_delay;
                        bool is_path =
                                ctx->getCellDelay(crit_net->driver.cell, port.first, crit_net->driver.port, comb_delay);
                        if (!is_path)
                            continue;
                        // If input port is influenced by a clock, skip
                        int port_clocks;
                        TimingPortClass portClass =
                                ctx->getPortTimingClass(crit_net->driver.cell, port.first, port_clocks);
                        if (portClass == TMG_CLOCK_INPUT || portClass == TMG_ENDPOINT || portClass == TMG_IGNORE)
                            continue;
                        if (timing_ignored(port.second.net) ||
                            cut_arc(port.second.net, crit_net->driver.cell, crit_net->driver.port))
                            continue;
                        // And find the fanin net with the latest arrival time
                        if (net_data.count(port.second.net) &&
                            net_data.at(port.second.net).count(crit_pair.first.start)) {
                            auto net_arrival = net_data.at(port.second.net).at(crit_pair.first.start).max_arrival;
                            if (net_delays) {
                                for (auto &user : port.second.net->users)
                                    if (user.port == port.first && user.cell == crit_net->driver.cell) {
                                        net_arrival += ctx->getNetinfoRouteDelay(port.second.net, user);
                                        break;
                                    }
                            }
                            net_arrival += comb_delay.maxDelay();
                            if (net_arrival > max_arrival) {
                                max_arrival = net_arrival;
                                crit_ipin = &port.second;
                            }
                        }
                    }

                    if (!crit_ipin || launch_arrival >= max_arrival)
                        break;
                    // Now convert PortInfo* into a PortRef*
                    for (auto &usr : crit_ipin->net->users) {
                        if (usr.cell->name == crit_net->driver.cell->name && usr.port == crit_ipin->name) {
                            cp_ports.push_back(&usr);
                            break;
                        }
                    }
                    crit_net = crit_ipin->net;
                }
                std::reverse(cp_ports.begin(), cp_ports.end());
            }
        }

        if (net_crit) {
            NPNR_ASSERT(crit_path);
            // Go through in reverse topographical order to set required times
            for (auto net : boost::adaptors::reverse(topographical_order)) {
                if (!net_data.count(net))
                    continue;
                auto &nd_map = net_data.at(net);
                for (auto &startdomain : nd_map) {
                    auto &nd = startdomain.second;
                    if (nd.false_startpoint)
                        continue;
                    if (startdomain.first.clock == async_clock)
                        continue;
                    if (nd.min_required.empty())
                        nd.min_required.resize(net->users.size(), std::numeric_limits<delay_t>::max());
                    delay_t net_min_required = std::numeric_limits<delay_t>::max();
                    const bool net_ignored = timing_ignored(net);
                    for (size_t i = 0; i < net->users.size(); i++) {
                        auto &usr = net->users.at(i);
                        auto net_delay = ctx->getNetinfoRouteDelay(net, usr);
                        if (net_ignored)
                            continue;
                        int port_clocks;
                        TimingPortClass portClass = ctx->getPortTimingClass(usr.cell, usr.port, port_clocks);
                        if (portClass == TMG_REGISTER_INPUT || portClass == TMG_ENDPOINT) {
                            auto process_endpoint = [&](IdString clksig, ClockEdge edge, delay_t setup) {
                                ExceptionResult exc = match_exceptions(startdomain.first, clksig, usr.cell, usr.port);
                                if (exc.skip_setup)
                                    return;
                                delay_t period = setup_requirement(startdomain.first, clksig, edge, clk_period);
                                if (exc.has_max)
                                    period = exc.max_value;
                                else
                                    apply_multicycle(exc, startdomain.first.clock, clksig, clk_period, &period,
                                                     nullptr);
                                nd.min_required.at(i) = std::min(period - setup, nd.min_required.at(i));
                            };
                            if (portClass == TMG_REGISTER_INPUT) {
                                for (int j = 0; j < port_clocks; j++) {
                                    TimingClockingInfo clkInfo = ctx->getPortClockingInfo(usr.cell, usr.port, j);
                                    const NetInfo *clknet = get_net_or_empty(usr.cell, clkInfo.clock_port);
                                    IdString clksig = clknet ? clknet->name : async_clock;
                                    process_endpoint(clksig, clknet ? clkInfo.edge : RISING_EDGE,
                                                     clkInfo.setup.maxDelay() -
                                                             clock_pin_delay(usr.cell, clkInfo.clock_port));
                                }
                            } else {
                                process_endpoint(async_clock, RISING_EDGE, 0);
                            }
                        }
                        net_min_required = std::min(net_min_required, nd.min_required.at(i) - net_delay);
                    }
                    PortRef &drv = net->driver;
                    if (drv.cell == nullptr)
                        continue;
                    for (const auto &port : drv.cell->ports) {
                        if (port.second.type != PORT_IN || !port.second.net)
                            continue;
                        DelayInfo comb_delay;
                        bool is_path = ctx->getCellDelay(drv.cell, port.first, drv.port, comb_delay);
                        if (!is_path)
                            continue;
                        int cc;
                        auto pclass = ctx->getPortTimingClass(drv.cell, port.first, cc);
                        if (pclass != TMG_COMB_INPUT)
                            continue;
                        NetInfo *sink_net = port.second.net;
                        if (cut_arc(sink_net, drv.cell, drv.port))
                            continue;
                        if (net_data.count(sink_net) && net_data.at(sink_net).count(startdomain.first)) {
                            auto &sink_nd = net_data.at(sink_net).at(startdomain.first);
                            if (sink_nd.min_required.empty())
                                sink_nd.min_required.resize(sink_net->users.size(),
                                                            std::numeric_limits<delay_t>::max());
                            for (size_t i = 0; i < sink_net->users.size(); i++) {
                                auto &user = sink_net->users.at(i);
                                if (user.cell == drv.cell && user.port == port.first) {
                                    sink_nd.min_required.at(i) = std::min(sink_nd.min_required.at(i),
                                                                          net_min_required - comb_delay.maxDelay());
                                    break;
                                }
                            }
                        }
                    }
                }
            }
            std::unordered_map<ClockEvent, delay_t> worst_slack;
            std::unordered_map<const NetInfo *, std::vector<std::pair<ClockEvent, std::vector<delay_t>>>>
                    net_domain_slack;
            std::unordered_map<const NetInfo *, std::unordered_map<ClockEvent, unsigned>> net_domain_length;

            for (auto &net_entry : net_data) {
                const NetInfo *net = net_entry.first;
                std::vector<std::pair<ClockEvent, std::vector<delay_t>>> domain_slack;
                for (auto &startdomain : net_entry.second) {
                    auto &nd = startdomain.second;
                    if (startdomain.first.clock == async_clock)
                        continue;
                    if (nd.min_required.empty())
                        continue;
                    ClockEvent domain{startdomain.first.clock, startdomain.first.edge};
                    auto ds = std::find_if(domain_slack.begin(), domain_slack.end(),
                                           [&](const std::pair<ClockEvent, std::vector<delay_t>> &d) {
                                               return d.first == domain;
                                           });
                    if (ds == domain_slack.end()) {
                        domain_slack.emplace_back(domain, std::vector<delay_t>(net->users.size(),
                                                                               std::numeric_limits<delay_t>::max()));
                        ds = std::prev(domain_slack.end());
                    }
                    auto &len = net_domain_length[net][domain];
                    len = std::max(len, nd.max_path_length);
                    for (size_t i = 0; i < net->users.size(); i++) {
                        delay_t slack = nd.min_required.at(i) -
                                        (nd.max_arrival + ctx->getNetinfoRouteDelay(net, net->users.at(i)));
                        if (worst_slack.count(domain))
                            worst_slack.at(domain) = std::min(worst_slack.at(domain), slack);
                        else
                            worst_slack[domain] = slack;
                        ds->second.at(i) = std::min(ds->second.at(i), slack);
                    }
                }
                if (domain_slack.empty())
                    continue;
                auto &nc = (*net_crit)[net->name];
                nc.slack.assign(net->users.size(), std::numeric_limits<delay_t>::max());
                for (auto &ds : domain_slack)
                    for (size_t i = 0; i < net->users.size(); i++)
                        nc.slack.at(i) = std::min(nc.slack.at(i), ds.second.at(i));
                net_domain_slack.emplace(net, std::move(domain_slack));
            }
            const std::unordered_map<ClockEvent, delay_t> &domain_dmax = domain_raw_max;
            for (auto &entry : net_domain_slack) {
                const NetInfo *net = entry.first;
                auto &nc = (*net_crit)[net->name];
                for (auto &ds : entry.second) {
                    const ClockEvent &domain = ds.first;
                    if (!domain_dmax.count(domain))
                        continue;
                    if (nc.criticality.empty())
                        nc.criticality.resize(net->users.size(), 0);
                    delay_t dmax = domain_dmax.at(domain);
                    for (size_t i = 0; i < net->users.size(); i++) {
                        float criticality =
                                1.0f - ((float(ds.second.at(i)) - float(worst_slack.at(domain))) / dmax);
                        nc.criticality.at(i) =
                                std::max<float>(nc.criticality.at(i), std::min(1.0f, std::max(0.0f, criticality)));
                    }
                    nc.max_path_length = std::max(nc.max_path_length, net_domain_length.at(net).at(domain));
                    nc.cd_worst_slack = std::min(nc.cd_worst_slack, worst_slack.at(domain));
                }
            }
            if (const char *cf = getenv("NEXTPNR_CRIT_EXPORT")) {
                std::map<IdString, float> cell_crit;
                for (auto &nc : *net_crit) {
                    float mx = 0.0f;
                    for (float c : nc.second.criticality)
                        mx = std::max(mx, c);
                    if (mx <= 0.05f)
                        continue;
                    auto it = ctx->nets.find(nc.first);
                    if (it == ctx->nets.end() || it->second->driver.cell == nullptr)
                        continue;
                    IdString dc = it->second->driver.cell->name;
                    auto cur = cell_crit.find(dc);
                    if (cur == cell_crit.end() || cur->second < mx)
                        cell_crit[dc] = mx;
                }
                std::ofstream out(cf);
                if (out)
                    for (auto &cc : cell_crit)
                        out << cc.first.c_str(ctx) << '\t' << cc.second << '\n';
            }
        }
        if (setup_export.is_open()) {
            for (auto &row : setup_rows)
                setup_export << row.second;
            setup_export.flush();
            setup_rows.clear();
            setup_row_index.clear();
        }
        if (hold_export.is_open()) {
            for (auto &row : hold_rows)
                hold_export << row.second;
            hold_export.flush();
            hold_rows.clear();
            hold_row_index.clear();
        }
        return min_slack;
    }

    void assign_budget()
    {
        // Clear delays to a very high value first
        for (auto &net : ctx->nets) {
            for (auto &usr : net.second->users) {
                usr.budget = std::numeric_limits<delay_t>::max();
            }
        }

        walk_paths();
    }
};

void assign_budget(Context *ctx, bool quiet)
{
    if (!quiet) {
        log_break();
        log_info("Annotating ports with timing budgets for target frequency %.2f MHz\n",
                 ctx->setting<float>("target_freq") / 1e6);
    }

    Timing timing(ctx, ctx->setting<int>("slack_redist_iter") > 0 /* net_delays */, true /* update */);
    timing.assign_budget();

    if (!quiet || ctx->verbose) {
        for (auto &net : ctx->nets) {
            for (auto &user : net.second->users) {
                // Post-update check
                if (!ctx->setting<bool>("auto_freq") && user.budget < 0)
                    log_info("port %s.%s, connected to net '%s', has negative "
                             "timing budget of %fns\n",
                             user.cell->name.c_str(ctx), user.port.c_str(ctx), net.first.c_str(ctx),
                             ctx->getDelayNS(user.budget));
                else if (ctx->debug)
                    log_info("port %s.%s, connected to net '%s', has "
                             "timing budget of %fns\n",
                             user.cell->name.c_str(ctx), user.port.c_str(ctx), net.first.c_str(ctx),
                             ctx->getDelayNS(user.budget));
            }
        }
    }

    // For slack redistribution, if user has not specified a frequency dynamically adjust the target frequency to be the
    // currently achieved maximum
    if (ctx->setting<bool>("auto_freq") && ctx->setting<int>("slack_redist_iter") > 0) {
        delay_t default_slack = delay_t((1.0e9 / ctx->getDelayNS(1)) / ctx->setting<float>("target_freq"));
        ctx->settings[ctx->id("target_freq")] =
                std::to_string(1.0e9 / ctx->getDelayNS(default_slack - timing.min_slack));
        if (ctx->verbose)
            log_info("minimum slack for this assign = %.2f ns, target Fmax for next "
                     "update = %.2f MHz\n",
                     ctx->getDelayNS(timing.min_slack), ctx->setting<float>("target_freq") / 1e6);
    }

    if (!quiet)
        log_info("Checksum: 0x%08x\n", ctx->checksum());
}

namespace {
double edge_fraction(const Context *ctx, const ClockEvent &a, const ClockEvent &b)
{
    if (a.edge == b.edge)
        return 1.0;
    double high = 0.5;
    auto fnd = ctx->nets.find(a.clock);
    if (fnd != ctx->nets.end() && fnd->second->clkconstr && fnd->second->clkconstr->high_den > 0)
        high = double(fnd->second->clkconstr->high_num) / double(fnd->second->clkconstr->high_den);
    return a.edge == RISING_EDGE ? high : 1.0 - high;
}

// Per-clock achieved fmax + constraint, keyed by the raw clock net name.
// Empty on a failed timing walk (combinatorial loops, incomplete timing
// ports, ...): a failed report must not kill an already successfully
// routed flow.
std::map<std::string, std::pair<double, double>> compute_clock_fmax(Context *ctx)
{
    std::map<std::string, std::pair<double, double>> out;
    std::map<IdString, double> clock_fmax;
    try {
        CriticalPathMap crit_paths;
        Timing timing(ctx, true /* net_delays */, false /* update */, &crit_paths, nullptr);
        timing.walk_paths();

        for (auto &path : crit_paths) {
            const ClockEvent &a = path.first.start;
            const ClockEvent &b = path.first.end;
            if (a.clock != b.clock || a.clock == ctx->id("$async$"))
                continue;
            double Fmax = path.second.mcp * 1000 * edge_fraction(ctx, a, b) / ctx->getDelayNS(path.second.path_delay);
            if (!clock_fmax.count(a.clock) || Fmax < clock_fmax.at(a.clock))
                clock_fmax[a.clock] = Fmax;
        }
    } catch (log_execution_error_exception &) {
        return out;
    }

    for (auto &clock : clock_fmax) {
        float target = ctx->setting<float>("target_freq") / 1e6;
        auto ni = ctx->nets.find(clock.first);
        if (ni != ctx->nets.end() && ni->second->clkconstr)
            target = 1000 / ctx->getDelayNS(ni->second->clkconstr->period.minDelay());
        out[clock.first.str(ctx)] = {clock.second, target};
    }
    return out;
}

std::string json_escape(const std::string &s)
{
    std::string r;
    for (char c : s) {
        if (c == '"' || c == '\\')
            r += '\\';
        r += c;
    }
    return r;
}
} // namespace

std::string Context::reportClockFmaxJson()
{
    std::string json = "{";
    bool first = true;
    for (auto &clock : compute_clock_fmax(this)) {
        char buf[80];
        snprintf(buf, sizeof(buf), "\": {\"achieved\": %.2f, \"constraint\": %.2f}", clock.second.first,
                 clock.second.second);
        json += (first ? "\"" : ", \"") + json_escape(clock.first) + buf;
        first = false;
    }
    json += "}";
    return json;
}

std::string Context::reportJson()
{
    // The document mirrors mainline nextpnr's --report schema
    // (critical_paths / fmax / utilization), with the clock-name aliasing
    // apio's report formatter expects: '$iopadmap$<port>' (the net yosys
    // inserts for a clock input port) shows the port name itself, other
    // yosys internals show as "(internal) <last-segment>".
    std::string json = "{\n    \"critical_paths\": [],\n    \"fmax\": {";
    bool first = true;
    for (auto &clock : compute_clock_fmax(this)) {
        std::string name = clock.first;
        if (name.rfind("$iopadmap$", 0) == 0)
            name = name.substr(10);
        else if (!name.empty() && name[0] == '$')
            name = "(internal) " + name.substr(name.find_last_of('$') + 1);
        char buf[80];
        snprintf(buf, sizeof(buf), "\": {\"achieved\": %.2f, \"constraint\": %.2f}", clock.second.first,
                 clock.second.second);
        json += (first ? "\"" : ", \"") + json_escape(name) + buf;
        first = false;
    }
    json += "},\n    \"utilization\": {";
    std::map<std::string, int> avail, used;
    for (auto bel : getBels())
        avail[getBelType(bel).str(this)]++;
    for (auto &cell : cells)
        used[cell.second->type.str(this)]++;
    first = true;
    for (auto &kv : avail) {
        char buf[64];
        snprintf(buf, sizeof(buf), "\": {\"available\": %d, \"used\": %d}", kv.second,
                 used.count(kv.first) ? used.at(kv.first) : 0);
        json += (first ? "\"" : ", \"") + json_escape(kv.first) + buf;
        first = false;
    }
    json += "}\n}\n";
    return json;
}

namespace {
void export_cell_arcs(Context *ctx, const char *path)
{
    std::ofstream out(path);
    if (!out)
        log_error("cannot open NEXTPNR_ARC_EXPORT file '%s' for writing\n", path);
    out << "cell\ttype\tbel\tfrom\tto\tmax_ns\tmin_ns\n";
    std::vector<IdString> names;
    for (auto &cell : ctx->cells)
        names.push_back(cell.first);
    std::sort(names.begin(), names.end(),
              [&](IdString a, IdString b) { return std::string(a.c_str(ctx)) < std::string(b.c_str(ctx)); });
    for (auto name : names) {
        const CellInfo *ci = ctx->cells.at(name).get();
        if (ci->bel == BelId())
            continue;
        std::vector<IdString> ins, outs;
        for (auto &port : ci->ports) {
            if (port.second.net == nullptr)
                continue;
            (port.second.type == PORT_OUT ? outs : ins).push_back(port.first);
        }
        auto by_name = [&](IdString a, IdString b) { return std::string(a.c_str(ctx)) < std::string(b.c_str(ctx)); };
        std::sort(ins.begin(), ins.end(), by_name);
        std::sort(outs.begin(), outs.end(), by_name);
        for (auto i : ins)
            for (auto o : outs) {
                DelayInfo d;
                if (!ctx->getCellDelay(ci, i, o, d))
                    continue;
                out << name.c_str(ctx) << '\t' << ci->type.c_str(ctx) << '\t' << ctx->nameOfBel(ci->bel) << '\t'
                    << i.c_str(ctx) << '\t' << o.c_str(ctx) << '\t' << ctx->getDelayNS(d.maxDelay()) << '\t'
                    << ctx->getDelayNS(d.minDelay()) << '\n';
            }
    }
}
}

void timing_analysis(Context *ctx, bool print_histogram, bool print_fmax, bool print_path, bool warn_on_failure)
{
    if (const char *af = getenv("NEXTPNR_ARC_EXPORT"))
        export_cell_arcs(ctx, af);
    auto format_event = [ctx](const ClockEvent &e, int field_width = 0) {
        std::string value;
        if (e.clock == ctx->id("$async$"))
            value = std::string("<async>");
        else
            value = (e.edge == FALLING_EDGE ? std::string("negedge ") : std::string("posedge ")) + e.clock.str(ctx);
        if (int(value.length()) < field_width)
            value.insert(value.length(), field_width - int(value.length()), ' ');
        return value;
    };

    CriticalPathMap crit_paths;
    DelayFrequency slack_histogram;

    Timing timing(ctx, true /* net_delays */, false /* update */, (print_path || print_fmax) ? &crit_paths : nullptr,
                  print_histogram ? &slack_histogram : nullptr, nullptr, true);
    timing.walk_paths();
    if (timing.have_exceptions) {
        CriticalPathMap merged;
        for (auto &path : crit_paths) {
            ClockPair key = path.first;
            key.start.tag = 0;
            key.end.tag = 0;
            auto fnd = merged.find(key);
            if (fnd == merged.end() ||
                fnd->second.path_delay / fnd->second.mcp < path.second.path_delay / path.second.mcp)
                merged[key] = path.second;
        }
        crit_paths.swap(merged);
        if (print_fmax || print_path)
            log_info("Timing exceptions: %zu path exception(s), %zu clock group set(s); %d endpoint check(s) "
                     "excluded from setup, %d from hold, %d graded against set_max_delay, %d relaxed by "
                     "set_multicycle_path\n",
                     ctx->timing_exceptions.size(), ctx->timing_clock_groups.size(), timing.exc_setup_skipped,
                     timing.exc_hold_skipped, timing.exc_max_delay, timing.exc_multicycle);
    }
    if (print_fmax) {
        log_info("Estimated worst hold slack: %.2f ns%s\n", ctx->getDelayNS(timing.worst_hold_slack),
                 timing.worst_hold_slack < 0 ? "  *** HOLD VIOLATION ***" : "");
        auto &he = timing.hold_endpoints;
        std::sort(he.begin(), he.end(), [](const Timing::HoldEndpoint &a, const Timing::HoldEndpoint &b) {
            return a.slack < b.slack;
        });
        int nshow = std::min<int>(5, he.size());
        if (nshow > 0) {
            log_info("Tightest hold endpoints (targets for hold buffering):\n");
            for (int i = 0; i < nshow; i++)
                log_info("    %+.3f ns  %s.%s\n", ctx->getDelayNS(he[i].slack), he[i].cell.c_str(ctx),
                         he[i].port.c_str(ctx));
        }
    }
    std::map<IdString, std::pair<ClockPair, CriticalPath>> clock_reports;
    std::map<IdString, double> clock_fmax;
    std::vector<ClockPair> xclock_paths;
    std::set<IdString> empty_clocks; // set of clocks with no interior paths
    if (print_path || print_fmax) {
        for (auto path : crit_paths) {
            const ClockEvent &a = path.first.start;
            const ClockEvent &b = path.first.end;
            empty_clocks.insert(a.clock);
            empty_clocks.insert(b.clock);
        }
        for (auto path : crit_paths) {
            const ClockEvent &a = path.first.start;
            const ClockEvent &b = path.first.end;
            if (a.clock != b.clock || a.clock == ctx->id("$async$"))
                continue;
            double Fmax;
            empty_clocks.erase(a.clock);
            // A set_multicycle_path -setup N endpoint may take N clock cycles, so its
            // constraining frequency is N/delay (it drops out as the bottleneck).
            double mcp = path.second.mcp;
            Fmax = mcp * 1000 * edge_fraction(ctx, a, b) / ctx->getDelayNS(path.second.path_delay);
            if (!clock_fmax.count(a.clock) || Fmax < clock_fmax.at(a.clock)) {
                clock_reports[a.clock] = path;
                clock_fmax[a.clock] = Fmax;
            }
        }

        for (auto &path : crit_paths) {
            const ClockEvent &a = path.first.start;
            const ClockEvent &b = path.first.end;
            if (a.clock == b.clock && a.clock != ctx->id("$async$"))
                continue;
            xclock_paths.push_back(path.first);
        }

        if (clock_reports.empty()) {
            log_warning("No clocks found in design\n");
        }

        std::sort(xclock_paths.begin(), xclock_paths.end(), [ctx](const ClockPair &a, const ClockPair &b) {
            if (a.start.clock.str(ctx) < b.start.clock.str(ctx))
                return true;
            if (a.start.clock.str(ctx) > b.start.clock.str(ctx))
                return false;
            if (a.start.edge < b.start.edge)
                return true;
            if (a.start.edge > b.start.edge)
                return false;
            if (a.end.clock.str(ctx) < b.end.clock.str(ctx))
                return true;
            if (a.end.clock.str(ctx) > b.end.clock.str(ctx))
                return false;
            if (a.end.edge < b.end.edge)
                return true;
            return false;
        });
    }

    if (print_path) {
        auto print_path_report = [ctx, &timing](ClockPair &clocks, PortRefVector &crit_path) {
            delay_t total = 0, logic_total = 0, route_total = 0;
            auto &front = crit_path.front();
            auto &front_port = front->cell->ports.at(front->port);
            auto &front_driver = front_port.net->driver;

            int port_clocks = 0;
            auto portClass = ctx->getPortTimingClass(front_driver.cell, front_driver.port, port_clocks);
            IdString last_port = front_driver.port;
            int clock_start = -1;
            if (portClass == TMG_REGISTER_OUTPUT || (portClass == TMG_COMB_OUTPUT && port_clocks > 0)) {
                for (int i = 0; i < port_clocks; i++) {
                    TimingClockingInfo clockInfo = ctx->getPortClockingInfo(front_driver.cell, front_driver.port, i);
                    const NetInfo *clknet = get_net_or_empty(front_driver.cell, clockInfo.clock_port);
                    if (clknet != nullptr && clknet->name == clocks.start.clock &&
                        clockInfo.edge == clocks.start.edge) {
                        last_port = clockInfo.clock_port;
                        clock_start = i;
                        break;
                    }
                }
            }

            log_info("curr total\n");
            for (auto sink : crit_path) {
                auto sink_cell = sink->cell;
                auto &port = sink_cell->ports.at(sink->port);
                auto net = port.net;
                auto &driver = net->driver;
                auto driver_cell = driver.cell;
                DelayInfo comb_delay;
                if (clock_start != -1) {
                    auto clockInfo = ctx->getPortClockingInfo(driver_cell, driver.port, clock_start);
                    comb_delay = clockInfo.clockToQ;
                    clock_start = -1;
                    delay_t launch_clk = timing.clock_pin_delay(driver_cell, clockInfo.clock_port);
                    if (launch_clk != 0) {
                        total += launch_clk;
                        route_total += launch_clk;
                        log_info("%4.1f %4.1f  Launch clock %s.%s\n", ctx->getDelayNS(launch_clk),
                                 ctx->getDelayNS(total), driver_cell->name.c_str(ctx),
                                 clockInfo.clock_port.c_str(ctx));
                    }
                } else if (last_port == driver.port) {
                    // Case where we start with a STARTPOINT etc
                    comb_delay = ctx->getDelayFromNS(0);
                } else {
                    ctx->getCellDelay(driver_cell, last_port, driver.port, comb_delay);
                }
                total += comb_delay.maxDelay();
                logic_total += comb_delay.maxDelay();
                log_info("%4.1f %4.1f  Source %s.%s\n", ctx->getDelayNS(comb_delay.maxDelay()), ctx->getDelayNS(total),
                         driver_cell->name.c_str(ctx), driver.port.c_str(ctx));
                auto net_delay = ctx->getNetinfoRouteDelay(net, *sink);
                total += net_delay;
                route_total += net_delay;
                auto driver_loc = ctx->getBelLocation(driver_cell->bel);
                auto sink_loc = ctx->getBelLocation(sink_cell->bel);
                log_info("%4.1f %4.1f    Net %s budget %f ns (%d,%d) -> (%d,%d)\n", ctx->getDelayNS(net_delay),
                         ctx->getDelayNS(total), net->name.c_str(ctx), ctx->getDelayNS(sink->budget), driver_loc.x,
                         driver_loc.y, sink_loc.x, sink_loc.y);
                log_info("               Sink %s.%s\n", sink_cell->name.c_str(ctx), sink->port.c_str(ctx));
                if (ctx->verbose) {
                    auto driver_wire = ctx->getNetinfoSourceWire(net);
                    auto sink_wire = ctx->getNetinfoSinkWire(net, *sink);
                    log_info("                 prediction: %f ns estimate: %f ns\n",
                             ctx->getDelayNS(ctx->predictDelay(net, *sink)),
                             ctx->getDelayNS(ctx->estimateDelay(driver_wire, sink_wire)));
                    auto cursor = sink_wire;
                    delay_t delay;
                    while (driver_wire != cursor) {
#ifdef ARCH_ECP5
                        if (net->is_global)
                            break;
#endif
                        auto it = net->wires.find(cursor);
                        // This runs after placement, before routing, so no net is routed
                        // yet; nets may also use dedicated routing resources that are not
                        // tracked in net->wires. There is no pip breakdown to report in
                        // either case.
                        const bool wire_not_in_route = (it == net->wires.end());
                        if (wire_not_in_route)
                            break;
                        auto pip = it->second.pip;
                        NPNR_ASSERT(pip != PipId());
                        delay = ctx->getPipDelay(pip).maxDelay();
                        log_info("                 %1.3f %s\n", ctx->getDelayNS(delay),
                                 ctx->getPipName(pip).c_str(ctx));
                        cursor = ctx->getPipSrcWire(pip);
                    }
                }
                last_port = sink->port;
            }
            int clockCount = 0;
            auto sinkClass = ctx->getPortTimingClass(crit_path.back()->cell, crit_path.back()->port, clockCount);
            if (sinkClass == TMG_REGISTER_INPUT && clockCount > 0) {
                auto sinkClockInfo = ctx->getPortClockingInfo(crit_path.back()->cell, crit_path.back()->port, 0);
                delay_t setup = sinkClockInfo.setup.maxDelay();
                total += setup;
                logic_total += setup;
                log_info("%4.1f %4.1f  Setup %s.%s\n", ctx->getDelayNS(setup), ctx->getDelayNS(total),
                         crit_path.back()->cell->name.c_str(ctx), crit_path.back()->port.c_str(ctx));
                delay_t capture_clk =
                        timing.clock_pin_delay(crit_path.back()->cell, sinkClockInfo.clock_port);
                if (capture_clk != 0) {
                    total -= capture_clk;
                    route_total -= capture_clk;
                    log_info("%4.1f %4.1f  Capture clock %s.%s\n", -ctx->getDelayNS(capture_clk),
                             ctx->getDelayNS(total), crit_path.back()->cell->name.c_str(ctx),
                             sinkClockInfo.clock_port.c_str(ctx));
                }
            }
            log_info("%.1f ns logic, %.1f ns routing\n", ctx->getDelayNS(logic_total), ctx->getDelayNS(route_total));
        };

        for (auto &clock : clock_reports) {
            log_break();
            std::string start =
                    clock.second.first.start.edge == FALLING_EDGE ? std::string("negedge") : std::string("posedge");
            std::string end =
                    clock.second.first.end.edge == FALLING_EDGE ? std::string("negedge") : std::string("posedge");
            log_info("Critical path report for clock '%s' (%s -> %s):\n", clock.first.c_str(ctx), start.c_str(),
                     end.c_str());
            auto &crit_path = clock.second.second.ports;
            print_path_report(clock.second.first, crit_path);
        }

        for (auto &xclock : xclock_paths) {
            log_break();
            std::string start = format_event(xclock.start);
            std::string end = format_event(xclock.end);
            log_info("Critical path report for cross-domain path '%s' -> '%s':\n", start.c_str(), end.c_str());
            auto &crit_path = crit_paths.at(xclock).ports;
            print_path_report(xclock, crit_path);
        }
    }
    if (print_fmax) {
        log_break();
        unsigned max_width = 0;
        for (auto &clock : clock_reports)
            max_width = std::max<unsigned>(max_width, clock.first.str(ctx).size());
        for (auto &clock : clock_reports) {
            const auto &clock_name = clock.first.str(ctx);
            const int width = max_width - clock_name.size();
            float target = ctx->setting<float>("target_freq") / 1e6;
            if (ctx->nets.at(clock.first)->clkconstr)
                target = 1000 / ctx->getDelayNS(ctx->nets.at(clock.first)->clkconstr->period.minDelay());
            else if (ctx->target_freq_is_default) {
                log_info("Max frequency for clock %*s'%s': %.02f MHz (UNCONSTRAINED: no clock constraint reaches "
                         "it and no --freq was given, so the %.02f MHz default is not a requirement)\n",
                         width, "", clock_name.c_str(), clock_fmax[clock.first], target);
                continue;
            }

            bool passed = target < clock_fmax[clock.first];
            if (!warn_on_failure || passed)
                log_info("Max frequency for clock %*s'%s': %.02f MHz (%s at %.02f MHz)\n", width, "",
                         clock_name.c_str(), clock_fmax[clock.first], passed ? "PASS" : "FAIL", target);
            else if (bool_or_default(ctx->settings, ctx->id("timing/allowFail"), false))
                log_warning("Max frequency for clock %*s'%s': %.02f MHz (%s at %.02f MHz)\n", width, "",
                            clock_name.c_str(), clock_fmax[clock.first], passed ? "PASS" : "FAIL", target);
            else
                log_nonfatal_error("Max frequency for clock %*s'%s': %.02f MHz (%s at %.02f MHz)\n", width, "",
                                   clock_name.c_str(), clock_fmax[clock.first], passed ? "PASS" : "FAIL", target);
        }
        std::set<IdString> ungraded;
        for (auto &eclock : empty_clocks)
            if (eclock != ctx->id("$async$"))
                ungraded.insert(eclock);
        for (auto &net : ctx->nets)
            if (net.second->clkconstr && !clock_reports.count(net.first))
                ungraded.insert(net.first);
        for (auto &uclock : ungraded) {
            auto fnd = ctx->nets.find(uclock);
            const ClockConstraint *cc =
                    (fnd == ctx->nets.end()) ? nullptr : fnd->second->clkconstr.get();
            const char *why = empty_clocks.count(uclock)
                                      ? "reached only by paths from another domain, none interior"
                                      : "no path launches and captures in this domain";
            if (cc != nullptr)
                log_info("Ungraded clock '%s': constrained at %.02f MHz, %s\n", uclock.c_str(ctx),
                         1000 / ctx->getDelayNS(cc->period.minDelay()), why);
            else
                log_info("Ungraded clock '%s': unconstrained, %s\n", uclock.c_str(ctx), why);
        }
        unsigned n_constr = 0, n_constr_graded = 0;
        for (auto &net : ctx->nets) {
            if (!net.second->clkconstr)
                continue;
            ++n_constr;
            if (clock_reports.count(net.first))
                ++n_constr_graded;
        }
        log_info("Clock domain grading: %u constrained, %u of them graded, %u ungraded; %u graded and %u "
                 "ungraded with no create_clock\n",
                 n_constr, n_constr_graded, n_constr - n_constr_graded,
                 unsigned(clock_reports.size()) - n_constr_graded,
                 unsigned(ungraded.size()) - (n_constr - n_constr_graded));
        log_break();

        int start_field_width = 0, end_field_width = 0;
        for (auto &xclock : xclock_paths) {
            start_field_width = std::max((int)format_event(xclock.start).length(), start_field_width);
            end_field_width = std::max((int)format_event(xclock.end).length(), end_field_width);
        }

        for (auto &xclock : xclock_paths) {
            const ClockEvent &a = xclock.start;
            const ClockEvent &b = xclock.end;
            auto &path = crit_paths.at(xclock);
            auto ev_a = format_event(a, start_field_width), ev_b = format_event(b, end_field_width);
            delay_t sep, hold_sep;
            IdString source;
            std::string msg;
            bool passed = path.path_delay <= path.path_period;
            if (timing.related_requirement(a.clock, a.edge, b.clock, b.edge, sep, hold_sep, &source)) {
                std::string what = path.by_exception ? "requirement set by a timing exception" : "edge separation";
                msg = stringf("Max delay %s -> %s: %0.02f ns (%s against a %0.02f ns %s; related through '%s')\n",
                              ev_a.c_str(), ev_b.c_str(), ctx->getDelayNS(path.path_delay), passed ? "PASS" : "FAIL",
                              ctx->getDelayNS(path.path_period), what.c_str(), source.c_str(ctx));
            } else if (timing.unrelated_launch(a.clock, b.clock) != nullptr) {
                std::string what = path.by_exception    ? "requirement set by a timing exception"
                                   : (a.edge == b.edge) ? "shorter of the two periods"
                                                        : "shorter of the two half-cycles";
                msg = stringf("Max delay %s -> %s: %0.02f ns (%s against a %0.02f ns %s; no derived relation)\n",
                              ev_a.c_str(), ev_b.c_str(), ctx->getDelayNS(path.path_delay), passed ? "PASS" : "FAIL",
                              ctx->getDelayNS(path.path_period), what.c_str());
            } else {
                log_info("Max delay %s -> %s: %0.02f ns\n", ev_a.c_str(), ev_b.c_str(),
                         ctx->getDelayNS(path.path_delay));
                continue;
            }
            if (!warn_on_failure || passed)
                log_info("%s", msg.c_str());
            else if (bool_or_default(ctx->settings, ctx->id("timing/allowFail"), false))
                log_warning("%s", msg.c_str());
            else
                log_nonfatal_error("%s", msg.c_str());
        }
        log_break();
    }

    if (print_histogram && slack_histogram.size() > 0) {
        unsigned num_bins = 20;
        unsigned bar_width = 60;
        auto min_slack = slack_histogram.begin()->first;
        auto max_slack = slack_histogram.rbegin()->first;
        auto bin_size = std::max<unsigned>(1, ceil((max_slack - min_slack + 1) / float(num_bins)));
        std::vector<unsigned> bins(num_bins);
        unsigned max_freq = 0;
        for (const auto &i : slack_histogram) {
            auto &bin = bins[(i.first - min_slack) / bin_size];
            bin += i.second;
            max_freq = std::max(max_freq, bin);
        }
        bar_width = std::min(bar_width, max_freq);

        log_break();
        log_info("Slack histogram:\n");
        log_info(" legend: * represents %d endpoint(s)\n", max_freq / bar_width);
        log_info("         + represents [1,%d) endpoint(s)\n", max_freq / bar_width);
        for (unsigned i = 0; i < num_bins; ++i)
            log_info("[%6d, %6d) |%s%c\n", min_slack + bin_size * i, min_slack + bin_size * (i + 1),
                     std::string(bins[i] * bar_width / max_freq, '*').c_str(),
                     (bins[i] * bar_width) % max_freq > 0 ? '+' : ' ');
    }
}

void get_criticalities(Context *ctx, NetCriticalityMap *net_crit)
{
    CriticalPathMap crit_paths;
    net_crit->clear();
    Timing timing(ctx, true, true, &crit_paths, nullptr, net_crit);
    timing.walk_paths();
}

NEXTPNR_NAMESPACE_END
