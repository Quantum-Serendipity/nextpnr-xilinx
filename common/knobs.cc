/*
 *  nextpnr -- Next Generation Place and Route
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

#include "knobs.h"

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <map>
#include "log.h"
#include "nextpnr.h"

NEXTPNR_NAMESPACE_BEGIN

namespace knobs {

namespace {

struct KnobDef
{
    const char *name;
    const char *key;
    bool env_alias;
    bool in_partition_modes;
};

const KnobDef knob_table[] = {
        {"DBG_CARRYFF", nullptr, false, false},
        {"DBG_CARRYO", nullptr, false, false},
        {"DBG_DIFEED", nullptr, false, false},
        {"NEXTPNR_ALLOW_CO_5FF_CONTENTION", nullptr, false, false},
        {"NEXTPNR_ALLOW_CONST_HOLDOUTS", nullptr, false, false},
        {"NEXTPNR_ARC_EXPORT", nullptr, false, false},
        {"NEXTPNR_ARC_MAX_VISIT", nullptr, false, false},
        {"NEXTPNR_BEL_BLACKLIST", nullptr, true, true},
        {"NEXTPNR_BUFG_CONST_DISCONNECT", nullptr, false, false},
        {"NEXTPNR_CARRY_COUNTER_FIX", nullptr, false, false},
        {"NEXTPNR_CONST_FENCE_WALK_BUDGET", nullptr, false, false},
        {"NEXTPNR_CONST_HOLDOUT_PASSES", nullptr, false, false},
        {"NEXTPNR_CRIT_EXPORT", nullptr, false, false},
        {"NEXTPNR_CRIT_PATH_REPORT", nullptr, true, false},
        {"NEXTPNR_DBG_CONSTR", nullptr, false, false},
        {"NEXTPNR_DBG_SHORTROUTE", nullptr, false, false},
        {nullptr, "knob/dram_tie_unread_di", false, false},
        {"NEXTPNR_DUMP_INVALID_TILE", nullptr, false, false},
        {"NEXTPNR_EXCLUDE_STAMPED_BBOX", nullptr, false, true},
        {"NEXTPNR_FIXEDROUTES_HOOK", nullptr, false, false},
        {"NEXTPNR_FIXEDROUTES_NO_PINSWAP", nullptr, false, false},
        {"NEXTPNR_FIXEDROUTES_NOSWAP", nullptr, false, false},
        {"NEXTPNR_FIXEDROUTES_PINSWAP", nullptr, false, false},
        {"NEXTPNR_GND_HOLDOUT_FILE", nullptr, false, false},
        {"NEXTPNR_GND_NO_RIPUP", nullptr, false, false},
        {"NEXTPNR_GT_CLK_BODGE", nullptr, false, false},
        {"NEXTPNR_HOLD_EXPORT", nullptr, false, false},
        {"NEXTPNR_LUT_PERM_DROP", nullptr, false, true},
        {"NEXTPNR_NO_CARRY_COUNTER_FIX", nullptr, false, false},
        {"NEXTPNR_NO_CARRY_O_RELOC", nullptr, false, false},
        {"NEXTPNR_NO_CONST_LUT_DRIVERS", nullptr, false, false},
        {"NEXTPNR_NO_LONGLINES", nullptr, false, false},
        {"NEXTPNR_PARTITION_CLAMP", nullptr, true, true},
        {"NEXTPNR_PARTITION_EXEMPT_NETS", nullptr, true, true},
        {"NEXTPNR_PARTITION_KEEPOUT", nullptr, true, true},
        {"NEXTPNR_PARTITION_KEEPOUT_EXEMPT", nullptr, false, true},
        {"NEXTPNR_PARTITION_KEEPOUT_LICENCE", nullptr, true, true},
        {"NEXTPNR_PARTITION_KEEPOUT_NARROW", nullptr, true, true},
        {"NEXTPNR_PARTITION_NETS", nullptr, true, true},
        {"NEXTPNR_PARTITION_ROI", nullptr, true, true},
        {"NEXTPNR_PIP_BLACKLIST", nullptr, false, true},
        {"NEXTPNR_PIP_BLACKLIST_TILE", nullptr, true, true},
        {"NEXTPNR_PLACER_ALPHA", "placerHeap/alpha", true, false},
        {"NEXTPNR_PLACER_BETA", "placerHeap/beta", true, false},
        {"NEXTPNR_POST_ROUTE_TIMING", nullptr, true, false},
        {"NEXTPNR_ROUTE_FIXED_ONLY", nullptr, false, false},
        {"NEXTPNR_ROUTER2_MAX_ITER", nullptr, false, false},
        {"NEXTPNR_ROUTER2_MAX_STALL", nullptr, false, false},
        {"NEXTPNR_RX_PLAIN_LVCMOS", nullptr, false, false},
        {"NEXTPNR_SETUP_EXPORT", nullptr, true, false},
        {nullptr, "knob/setup_export_start", false, false},
        {"NEXTPNR_SKIP_FAILED_ARCS", nullptr, false, true},
        {"NEXTPNR_SPREAD_SCALE_X", "placerHeap/spreadScaleX", true, false},
        {"NEXTPNR_SPREAD_SCALE_Y", "placerHeap/spreadScaleY", true, false},
        {"NEXTPNR_TIMING_ONLY", nullptr, true, false},
        {"NPNR_ROUTER1_RECHECK", nullptr, false, false},
        {"XC7_LEGACY_CARRY4_SPLIT", nullptr, true, false},
};

struct RemovedKnob
{
    const char *name;
    const char *instead;
};

const RemovedKnob removed_table[] = {
        {"NEXTPNR_ASYNC_GROUPS", "declare the crossing with set_clock_groups in an XDC"},
        {"NEXTPNR_CARRY_OMIT_GND_DI",
         "the mode was deleted because an omitted GND DI delivers VCC through the bypass mux and corrupts the carry"},
};

struct BannedSetting
{
    const char *key;
    const char *knob;
    const char *unset_values[2];
};

const BannedSetting banned_settings[] = {
        {"router1/skipFailedArcs", "NEXTPNR_SKIP_FAILED_ARCS", {"0", "false"}},
        {"router1/arcMaxVisitCnt", "NEXTPNR_ARC_MAX_VISIT", {"2147483647", "2147483647"}},
};

const char *const per_invocation_prefixes[] = {"knob/", "router2/", "router/"};

std::string derived_key(const char *name)
{
    std::string s = name;
    for (const char *prefix : {"NEXTPNR_", "NPNR_"})
        if (s.rfind(prefix, 0) == 0) {
            s = s.substr(std::strlen(prefix));
            break;
        }
    std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c) { return std::tolower(c); });
    return "knob/" + s;
}

struct Entry
{
    const KnobDef *def;
    std::string key;
    bool has_value = false;
    std::string value;
    std::string origin;
    std::string source;
};

struct Store
{
    bool initialised = false;
    std::vector<Entry> entries;
    std::map<std::string, std::string> plain_settings;
    std::map<std::string, std::string> recorded;

    Entry *by_name(const char *name)
    {
        for (auto &e : entries)
            if (e.def->name != nullptr && std::strcmp(e.def->name, name) == 0)
                return &e;
        return by_key(name);
    }
    Entry *by_key(const std::string &key)
    {
        for (auto &e : entries)
            if (e.key == key)
                return &e;
        return nullptr;
    }
};

Store &store()
{
    static Store s;
    if (s.entries.empty())
        for (const auto &def : knob_table)
            s.entries.push_back(Entry{&def, def.key != nullptr ? std::string(def.key) : derived_key(def.name)});
    return s;
}

} // namespace

void init(const std::vector<std::string> &assignments)
{
    Store &s = store();
    for (auto &e : s.entries) {
        e.has_value = false;
        e.value.clear();
        e.origin.clear();
        e.source.clear();
    }
    s.plain_settings.clear();
    s.recorded.clear();

    for (const auto &r : removed_table)
        if (std::getenv(r.name) != nullptr)
            log_error("%s was removed and is refused: %s\n", r.name, r.instead);

    for (const auto &a : assignments) {
        auto eq = a.find('=');
        if (eq == std::string::npos || eq == 0)
            log_error("--set '%s': expected key=value\n", a.c_str());
        std::string key = a.substr(0, eq), value = a.substr(eq + 1);
        if (key == "seed" || key == "seed.arg")
            log_error("--set %s: the seed is read before the netlist; use --seed\n", key.c_str());
        if (value.empty())
            log_error("--set %s=: the value is empty; omit the option instead\n", key.c_str());
        for (const auto &r : removed_table)
            if (key == derived_key(r.name))
                log_error("--set %s: %s was removed and is refused: %s\n", key.c_str(), r.name, r.instead);
        for (const auto &b : banned_settings)
            if (key == b.key)
                log_error("--set %s is refused: it does what %s (%s) does, and that knob is banned\n", key.c_str(),
                          b.knob, derived_key(b.knob).c_str());
        Entry *e = s.by_key(key);
        if (e == nullptr && key.rfind("knob/", 0) == 0)
            log_error("--set %s: no knob has that key; --list-knobs prints them\n", key.c_str());
        if (e == nullptr) {
            if (s.plain_settings.count(key) && s.plain_settings.at(key) != value)
                log_error("--set %s is given twice with different values\n", key.c_str());
            s.plain_settings[key] = value;
            continue;
        }
        if (e->has_value && e->value != value)
            log_error("--set %s is given twice with different values\n", key.c_str());
        e->has_value = true;
        e->value = value;
        e->origin = "--set";
        e->source = e->key;
    }

    for (auto &e : s.entries) {
        if (e.def->name == nullptr)
            continue;
        const char *env = std::getenv(e.def->name);
        if (env == nullptr)
            continue;
        if (!e.def->env_alias)
            log_error("%s is no longer read from the environment; pass --set %s=<value> instead\n", e.def->name,
                      e.key.c_str());
        if (*env == '\0')
            log_error("%s is set but empty; unset it or give it a value\n", e.def->name);
        if (e.has_value) {
            if (e.value != env)
                log_error("%s=%s and --set %s=%s disagree\n", e.def->name, env, e.key.c_str(), e.value.c_str());
            continue;
        }
        e.has_value = true;
        e.value = env;
        e.origin = std::string("environment ") + e.def->name + ", a deprecated alias";
        e.source = e.def->name;
    }

    for (auto &e : s.entries)
        if (e.has_value)
            log_info("knob %s=%s (from %s)\n", e.key.c_str(), e.value.c_str(), e.origin.c_str());
    for (auto &p : s.plain_settings)
        log_info("setting %s=%s (from --set)\n", p.first.c_str(), p.second.c_str());
    s.initialised = true;
}

static const Entry &registered(const char *name)
{
    Store &s = store();
    if (!s.initialised)
        init({});
    Entry *e = s.by_name(name);
    if (e == nullptr)
        log_error("internal: knob %s is not registered in common/knobs.cc\n", name);
    return *e;
}

const char *get(const char *name)
{
    const Entry &e = registered(name);
    return e.has_value ? e.value.c_str() : nullptr;
}

const char *source(const char *name)
{
    const Entry &e = registered(name);
    return e.has_value ? e.source.c_str() : nullptr;
}

const char *user_setting(const std::string &key)
{
    Store &s = store();
    if (!s.initialised)
        init({});
    auto found = s.plain_settings.find(key);
    if (found != s.plain_settings.end())
        return found->second.c_str();
    Entry *e = s.by_key(key);
    return e != nullptr && e->has_value ? e->value.c_str() : nullptr;
}

void record(const std::string &key, const std::string &value) { store().recorded[key] = value; }

void apply(Context *ctx)
{
    Store &s = store();
    if (!s.initialised)
        init({});
    std::vector<IdString> carried;
    std::string list;
    for (auto &kv : ctx->settings) {
        const std::string &key = kv.first.str(ctx);
        for (const auto &b : banned_settings) {
            if (key != b.key)
                continue;
            const Property &p = kv.second;
            std::string v = p.is_string ? p.as_string() : std::to_string(p.as_int64());
            if (v != b.unset_values[0] && v != b.unset_values[1])
                log_error("the input netlist carries the setting %s=%s, which does what %s (%s) does; that knob is "
                          "banned, so the netlist is refused\n",
                          key.c_str(), v.c_str(), b.knob, derived_key(b.knob).c_str());
        }
        bool per_invocation = false;
        for (const char *prefix : per_invocation_prefixes)
            per_invocation = per_invocation || key.rfind(prefix, 0) == 0;
        if (!per_invocation)
            continue;
        carried.push_back(kv.first);
    }
    std::sort(carried.begin(), carried.end(), [ctx](IdString a, IdString b) { return a.str(ctx) < b.str(ctx); });
    for (IdString k : carried) {
        const std::string &key = k.str(ctx);
        if (!s.plain_settings.count(key))
            list += (list.empty() ? "" : ", ") + key;
        ctx->settings.erase(k);
    }
    if (!list.empty())
        log_info("settings carried by the input netlist under knob/, router2/ and router/ are stripped, not re-applied "
                 "(they act per invocation; pass --set to set them again): %s\n",
                 list.c_str());
    for (auto &p : s.plain_settings)
        ctx->settings[ctx->id(p.first)] = p.second;
}

void echo(Context *ctx)
{
    Store &s = store();
    if (!s.initialised)
        init({});
    for (auto &e : s.entries)
        if (e.has_value && e.key.rfind("knob/", 0) == 0 && !e.def->in_partition_modes)
            ctx->settings[ctx->id(e.key)] = e.value;
    for (auto &r : s.recorded)
        ctx->settings[ctx->id(r.first)] = r.second;
}

void unset(const std::string &key)
{
    Store &s = store();
    if (!s.initialised)
        init({});
    Entry *e = s.by_key(key);
    if (e == nullptr)
        log_error("knob_unset %s: no knob has that key; --list-knobs prints them\n", key.c_str());
    if (e->has_value)
        log_info("knob %s unset (was %s from %s); contexts and passes that read it from now on see it unset\n",
                 key.c_str(), e->value.c_str(), e->origin.c_str());
    e->has_value = false;
    e->value.clear();
    e->origin.clear();
    e->source.clear();
}

void list()
{
    Store &s = store();
    for (auto &e : s.entries)
        std::cout << e.key << '\t' << (e.def->name != nullptr ? e.def->name : "-") << '\t'
                  << (e.def->name == nullptr ? "no environment name"
                      : e.def->env_alias     ? "environment alias read (deprecated)"
                                             : "environment not read")
                  << '\n';
    for (auto &r : removed_table)
        std::cout << derived_key(r.name) << '\t' << r.name << '\t' << "removed, refused from the environment and --set"
                  << '\n';
    for (auto &b : banned_settings)
        std::cout << b.key << '\t' << b.knob << '\t' << "plain setting doing what this banned knob does, refused"
                  << '\n';
}

} // namespace knobs

NEXTPNR_NAMESPACE_END
