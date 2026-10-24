/*
 *  nextpnr -- Next Generation Place and Route
 *
 *  Copyright (C) 2019  David Shah <dave@ds0.me>
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

#include <unordered_set>
#include "nextpnr.h"

NEXTPNR_NAMESPACE_BEGIN

struct PartitionRouteCfg
{
    bool partition_active = false;
    int partition_x0 = 0, partition_y0 = 0, partition_x1 = 0, partition_y1 = 0;
    struct PartitionRect
    {
        int x0 = 0, y0 = 0, x1 = 0, y1 = 0;
    };
    std::vector<PartitionRect> partition_siblings;
    std::unordered_map<IdString, int> partition_nets;

    bool keepout_active = false;
    std::unordered_set<IdString> keepout_exempt_nets;
    bool keepout_narrow = false;
    std::unordered_map<IdString, std::vector<PipId>> keepout_licence_pips;

    PartitionRect partition_rect(int i) const
    {
        if (i == 0)
            return PartitionRect{partition_x0, partition_y0, partition_x1, partition_y1};
        return partition_siblings.at(i - 1);
    }

    int partition_rect_count() const { return 1 + int(partition_siblings.size()); }
};

struct PartitionKeepoutLicence
{
    bool exempt_named = false;
    bool exempt_buf = false;
    bool exempt_const = false;
    int governed = -1;
    uint64_t anchored = 0;
    uint64_t allow = 0;
    bool check = false;
    uint64_t narrow = 0;
    std::unordered_set<PipId> locked;
    std::vector<std::pair<PipId, bool>> locked_taken;
};

enum PartitionKeepoutVerdict
{
    KEEPOUT_OUTSIDE,
    KEEPOUT_ADMIT,
    KEEPOUT_VETO_RECT,
    KEEPOUT_VETO_NARROW,
};

int partition_keepout_rect(const PartitionRouteCfg &cfg, Loc l);
PartitionKeepoutLicence partition_keepout_licence(const Context *ctx, const PartitionRouteCfg &cfg, const NetInfo *ni);
PartitionKeepoutVerdict partition_keepout_verdict(const PartitionKeepoutLicence &lic, PipId pip, int kr);

struct Router2Cfg : PartitionRouteCfg
{
    Router2Cfg(Context *ctx);

    int backwards_max_iter;
    int global_backwards_max_iter;
    int bb_margin_x, bb_margin_y;
    float ipin_cost_adder;
    float bias_cost_factor;
    float init_curr_cong_weight, hist_cong_weight;
    float curr_cong_mult;

    float estimate_weight;

    bool perf_profile = false;
};

void router2(Context *ctx, const Router2Cfg &cfg);

NEXTPNR_NAMESPACE_END