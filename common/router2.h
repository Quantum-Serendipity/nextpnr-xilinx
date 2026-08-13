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
    // The net SET is passed in rather than derived here on purpose: the same
    // set is validated by the invariant-P gate before placement finishes, so
    // the clamp governs exactly the nets the gate proved are containable. A
    // router-side re-derivation could disagree with the gate, and a net the
    // gate blessed but the clamp missed is a silent hole.
    bool partition_active = false;
    int partition_x0 = 0, partition_y0 = 0, partition_x1 = 0, partition_y1 = 0;
    std::unordered_set<IdString> partition_nets;
};

void router2(Context *ctx, const Router2Cfg &cfg);

NEXTPNR_NAMESPACE_END