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
};

const KnobDef knob_table[] = {
        {"DBG_CARRYFF", nullptr, false},
        {"DBG_CARRYO", nullptr, false},
        {"DBG_DIFEED", nullptr, false},
        {"NEXTPNR_ALLOW_CO_5FF_CONTENTION", nullptr, false},
        {"NEXTPNR_ALLOW_CONST_HOLDOUTS", nullptr, false},
        {"NEXTPNR_ARC_EXPORT", nullptr, false},
        {"NEXTPNR_ARC_MAX_VISIT", nullptr, false},
        {"NEXTPNR_ASYNC_GROUPS", nullptr, false},
        {"NEXTPNR_BEL_BLACKLIST", nullptr, true},
        {"NEXTPNR_BUFG_CONST_DISCONNECT", nullptr, false},
        {"NEXTPNR_CARRY_COUNTER_FIX", nullptr, false},
        {"NEXTPNR_CONST_FENCE_WALK_BUDGET", nullptr, false},
        {"NEXTPNR_CONST_HOLDOUT_PASSES", nullptr, false},
        {"NEXTPNR_CRIT_EXPORT", nullptr, false},
        {"NEXTPNR_CRIT_PATH_REPORT", nullptr, true},
        {"NEXTPNR_DBG_CONSTR", nullptr, false},
        {"NEXTPNR_DBG_SHORTROUTE", nullptr, false},
        {"NEXTPNR_DUMP_INVALID_TILE", nullptr, false},
        {"NEXTPNR_EXCLUDE_STAMPED_BBOX", nullptr, false},
        {"NEXTPNR_FIXEDROUTES_HOOK", nullptr, false},
        {"NEXTPNR_FIXEDROUTES_NO_PINSWAP", nullptr, false},
        {"NEXTPNR_FIXEDROUTES_NOSWAP", nullptr, false},
        {"NEXTPNR_FIXEDROUTES_PINSWAP", nullptr, false},
        {"NEXTPNR_GND_HOLDOUT_FILE", nullptr, false},
        {"NEXTPNR_GND_NO_RIPUP", nullptr, false},
        {"NEXTPNR_GT_CLK_BODGE", nullptr, false},
        {"NEXTPNR_HOLD_EXPORT", nullptr, false},
        {"NEXTPNR_LUT_PERM_DROP", nullptr, false},
        {"NEXTPNR_NO_CARRY_COUNTER_FIX", nullptr, false},
        {"NEXTPNR_NO_CARRY_O_RELOC", nullptr, false},
        {"NEXTPNR_NO_CONST_LUT_DRIVERS", nullptr, false},
        {"NEXTPNR_NO_LONGLINES", nullptr, false},
        {"NEXTPNR_PARTITION_CLAMP", nullptr, true},
        {"NEXTPNR_PARTITION_EXEMPT_NETS", nullptr, true},
        {"NEXTPNR_PARTITION_KEEPOUT", nullptr, true},
        {"NEXTPNR_PARTITION_KEEPOUT_EXEMPT", nullptr, false},
        {"NEXTPNR_PARTITION_KEEPOUT_LICENCE", nullptr, true},
        {"NEXTPNR_PARTITION_KEEPOUT_NARROW", nullptr, true},
        {"NEXTPNR_PARTITION_NETS", nullptr, true},
        {"NEXTPNR_PARTITION_ROI", nullptr, true},
        {"NEXTPNR_PIP_BLACKLIST", nullptr, false},
        {"NEXTPNR_PIP_BLACKLIST_TILE", nullptr, true},
        {"NEXTPNR_PLACER_ALPHA", "placerHeap/alpha", true},
        {"NEXTPNR_PLACER_BETA", "placerHeap/beta", true},
        {"NEXTPNR_POST_ROUTE_TIMING", nullptr, true},
        {"NEXTPNR_ROUTE_FIXED_ONLY", nullptr, false},
        {"NEXTPNR_ROUTER2_MAX_ITER", nullptr, false},
        {"NEXTPNR_ROUTER2_MAX_STALL", nullptr, false},
        {"NEXTPNR_RX_PLAIN_LVCMOS", nullptr, false},
        {"NEXTPNR_SETUP_EXPORT", nullptr, true},
        {"NEXTPNR_SKIP_FAILED_ARCS", nullptr, false},
        {"NEXTPNR_SPREAD_SCALE_X", "placerHeap/spreadScaleX", true},
        {"NEXTPNR_SPREAD_SCALE_Y", "placerHeap/spreadScaleY", true},
        {"NEXTPNR_TIMING_ONLY", nullptr, true},
        {"NPNR_ROUTER1_RECHECK", nullptr, false},
        {"XC7_LEGACY_CARRY4_SPLIT", nullptr, true},
};

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
};

struct Store
{
    bool initialised = false;
    std::vector<Entry> entries;
    std::map<std::string, std::string> plain_settings;

    Entry *by_name(const char *name)
    {
        for (auto &e : entries)
            if (std::strcmp(e.def->name, name) == 0)
                return &e;
        return nullptr;
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
    }
    s.plain_settings.clear();

    for (const auto &a : assignments) {
        auto eq = a.find('=');
        if (eq == std::string::npos || eq == 0)
            log_error("--set '%s': expected key=value\n", a.c_str());
        std::string key = a.substr(0, eq), value = a.substr(eq + 1);
        if (key == "seed" || key == "seed.arg")
            log_error("--set %s: the seed is read before the netlist; use --seed\n", key.c_str());
        if (value.empty())
            log_error("--set %s=: the value is empty; omit the option instead\n", key.c_str());
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
    }

    for (auto &e : s.entries) {
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
    }

    for (auto &e : s.entries)
        if (e.has_value)
            log_info("knob %s=%s (from %s)\n", e.key.c_str(), e.value.c_str(), e.origin.c_str());
    for (auto &p : s.plain_settings)
        log_info("setting %s=%s (from --set)\n", p.first.c_str(), p.second.c_str());
    s.initialised = true;
}

const char *get(const char *name)
{
    Store &s = store();
    if (!s.initialised)
        init({});
    Entry *e = s.by_name(name);
    if (e == nullptr)
        log_error("internal: knob %s is not registered in common/knobs.cc\n", name);
    return e->has_value ? e->value.c_str() : nullptr;
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

void apply(Context *ctx)
{
    Store &s = store();
    if (!s.initialised)
        init({});
    std::vector<std::string> carried;
    for (auto &e : s.entries) {
        if (e.key.rfind("knob/", 0) != 0)
            continue;
        IdString k = ctx->id(e.key);
        auto found = ctx->settings.find(k);
        if (found != ctx->settings.end() && !e.has_value)
            carried.push_back(e.key);
        if (found != ctx->settings.end())
            ctx->settings.erase(found);
    }
    if (!carried.empty()) {
        std::string list;
        for (auto &c : carried)
            list += (list.empty() ? "" : ", ") + c;
        log_info("knob settings carried by the input netlist are not re-applied (knobs act per invocation): %s\n",
                 list.c_str());
    }
    for (auto &e : s.entries)
        if (e.has_value)
            ctx->settings[ctx->id(e.key)] = e.value;
    for (auto &p : s.plain_settings)
        ctx->settings[ctx->id(p.first)] = p.second;
}

void list()
{
    Store &s = store();
    for (auto &e : s.entries)
        std::cout << e.key << '\t' << e.def->name << '\t'
                  << (e.def->env_alias ? "environment alias read (deprecated)" : "environment not read") << '\n';
}

} // namespace knobs

NEXTPNR_NAMESPACE_END
