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

struct Router2Cfg
{
    Router2Cfg(Context *ctx);

    // Maximum iterations for backwards routing attempt
    int backwards_max_iter;
    // Maximum iterations for backwards routing attempt for global nets
    int global_backwards_max_iter;
    // Padding added to bounding boxes to account for imperfect routing,
    // congestion, etc
    int bb_margin_x, bb_margin_y;
    // Cost factor added to input pin wires; effectively reduces the
    // benefit of sharing interconnect
    float ipin_cost_adder;
    // Cost factor for "bias" towards center location of net
    float bias_cost_factor;
    // Starting current and historical congestion cost factor
    float init_curr_cong_weight, hist_cong_weight;
    // Current congestion cost multiplier
    float curr_cong_mult;

    // Weight given to delay estimate in A*. Higher values
    // mean faster and more directed routing, at the risk
    // of choosing a less congestion/delay-optimal route
    float estimate_weight;

    // Print additional performance profiling information
    bool perf_profile = false;

    // ---- partition containment (Unit 7.4) ----------------------------------
    // A partial-reconfiguration build confines the reconfigurable module's nets
    // to a fixed tile rectangle. The arch fills these in; every field has an
    // in-class default so the three arches that construct Router2Cfg and pass
    // it straight through (generic, ice40, ecp5) are unaffected and keep
    // compiling. When partition_active is false this costs one predictable
    // branch per net, taken once in setup_nets().
    //
    // The net MAP is passed in rather than derived here on purpose: the same
    // nets are validated by the invariant-P gate before placement finishes, so
    // the clamp governs exactly the nets the gate proved are containable. A
    // router-side re-derivation could disagree with the gate, and a net the
    // gate blessed but the clamp missed is a silent hole.
    //
    // N RECTANGLES, NOT ONE, and the map says which net goes in which. Rectangle
    // 0 is the partition this run is building -- the one that also confined
    // placement. partition_siblings are the OTHER regions on the device, already
    // placed and routed by an earlier run of a chained replay; without them the
    // router treats an earlier region's nets as ordinary static logic and
    // re-routes them out of their own frames the moment they contend for a wire.
    bool partition_active = false;
    int partition_x0 = 0, partition_y0 = 0, partition_x1 = 0, partition_y1 = 0;
    struct PartitionRect
    {
        int x0 = 0, y0 = 0, x1 = 0, y1 = 0;
    };
    std::vector<PartitionRect> partition_siblings;
    // net name -> rectangle index: 0 is the rectangle above, i >= 1 is
    // partition_siblings[i - 1].
    std::unordered_map<IdString, int> partition_nets;

    // ---- static keepout, the clamp's complement ----------------------------
    // The clamp answers "may this net LEAVE its rectangle". It says nothing
    // about a net that belongs to no rectangle passing THROUGH one, and a
    // rectangle crossed by static routing cannot be byte-identical to a
    // rectangle crossed differently -- which is what relocating one partial
    // bitstream to several slots by rewriting its FAR word requires.
    //
    // Same rectangles, same census discipline, its own switch: a run with the
    // clamp off is still a legitimate keepout run and the reverse holds too, so
    // neither flag implies the other.
    //
    // The exempt set is supplied rather than derived here for the reason the
    // net map above is: the arch already owns "which nets are none of the
    // rectangle's business", and a second answer to that question in router2
    // could disagree with the first. The DERIVED half of the exemption -- a net
    // whose driver sits on a global clock buffer -- is the one thing router2
    // can ask the arch directly through getBelGlobalBuf(), and it is asked
    // per net in setup_nets() rather than pre-computed into this set.
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
};

void router2(Context *ctx, const Router2Cfg &cfg);

NEXTPNR_NAMESPACE_END