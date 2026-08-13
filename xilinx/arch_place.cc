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

#include <boost/algorithm/string.hpp>
#include <queue>
#include "design_utils.h"
#include "log.h"
#include "nextpnr.h"
#include "timing.h"
#include "util.h"
NEXTPNR_NAMESPACE_BEGIN

inline NetInfo *port_or_nullptr(const CellInfo *cell, IdString name)
{
    auto found = cell->ports.find(name);
    if (found == cell->ports.end())
        return nullptr;
    return found->second.net;
}

//#define DEBUG_VALIDITY
// Initialised from the environment here rather than in a placer: placer1
// already sets it, but the default xc7 flow uses HeAP, whose strict
// legaliser is precisely the caller one needs to observe when a placement
// refuses to legalise.
bool dbg_validity_runtime = getenv("NEXTPNR_DUMP_INVALID_TILE") != nullptr;
static bool packing_oracle();
#define DBG_RT()                                                                                                       \
    do {                                                                                                               \
        if (dbg_validity_runtime)                                                                                      \
            log_info("invalid-arm: line %d\n", __LINE__);                                                             \
    } while (0)
#ifdef DEBUG_VALIDITY
#define DBG() log_info("invalid: %s %d\n", __FILE__, __LINE__)
#else
#define DBG() DBG_RT()
#endif

bool Arch::xcu_logic_tile_valid(IdString tileType, LogicTileStatus &lts) const
{
    bool is_slicem = (tileType == id_CLEM) || (tileType == id_CLEM_R);
    bool tile_is_memory = false;
    if (lts.cells[(7 << 4) | BEL_6LUT] != nullptr && lts.cells[(7 << 4) | BEL_6LUT]->lutInfo.is_memory)
        tile_is_memory = true;
    bool small_memory = false;
    if (lts.cells[(7 << 4) | BEL_5LUT] != nullptr && lts.cells[(7 << 4) | BEL_5LUT]->lutInfo.is_memory)
        small_memory = true;
    // Check eight-tiles (mostly LUT-related validity)
    for (int i = 0; i < 8; i++) {
        if (lts.eights[i].dirty) {
            lts.eights[i].dirty = false;
            lts.eights[i].valid = false;

            CellInfo *lut6 = lts.cells[(i << 4) | BEL_6LUT];
            CellInfo *lut5 = lts.cells[(i << 4) | BEL_5LUT];

            // Check 6LUT
            if (lut6 != nullptr) {
                if (!is_slicem && (lut6->lutInfo.is_memory || lut6->lutInfo.is_srl))
                    return false; // Memory and SRLs only valid in SLICEMs
                if (lut5 != nullptr) {
                    // Can't mix memory and non-memory
                    if (lut6->lutInfo.is_memory != lut5->lutInfo.is_memory ||
                        lut6->lutInfo.is_srl != lut5->lutInfo.is_srl)
                        return false;
                    // If all 6 inputs or 2 outputs are used, 5LUT can't also be present
                    if (lut6->lutInfo.input_count == 6 || lut6->lutInfo.output_count == 2)
                        return false;
                    // If more than 5 total inputs are used, need to check number of shared input
                    if ((lut6->lutInfo.input_count + lut5->lutInfo.input_count) > 5) {
                        int shared = 0, need_shared = (lut6->lutInfo.input_count + lut5->lutInfo.input_count - 5);
                        for (int j = 0; j < lut6->lutInfo.input_count; j++) {
                            for (int k = 0; k < lut5->lutInfo.input_count; k++) {
                                if (lut6->lutInfo.input_sigs[j] == lut5->lutInfo.input_sigs[k])
                                    shared++;
                                if (shared >= need_shared)
                                    break;
                            }
                        }
                        if (shared < need_shared) {
                            // Imported (Vivado/golden) CARRY4 slot: the operand LUT
                            // (O6->S) and the DI feed-through (O5->DI) are ONE
                            // dual-output LUT on real hardware -- O5 and O6 of the
                            // same 5-input LUT -- so they share all physical inputs
                            // by construction.  SVS/pack represents that as two cells
                            // whose lone feed-through input is a renamed net copy, so
                            // input_sigs no longer match by identity (shared=0 here)
                            // even though the placement is physically legal (golden
                            // uses it and runs).  When the slot's 6LUT is BEL-pinned
                            // (imported) and the 5LUT only drives the carry, trust the
                            // import instead of rejecting a valid slot.
                            bool imported_carry_feedthrough =
                                lut6->attrs.count(id_BEL) && lut5->lutInfo.only_drives_carry;
                            if (!imported_carry_feedthrough) {
                                DBG();
                                return false;
                            }
                        }
                    }
                }
            }
            if (lut5 != nullptr) {
                if (!is_slicem && (lut5->lutInfo.is_memory || lut5->lutInfo.is_srl)) {
                    DBG();
                    return false; // Memory and SRLs only valid in SLICEMs
                }
                // 5LUT can use at most 5 inputs and 1 output
                if (lut5->lutInfo.input_count > 5 || lut5->lutInfo.output_count == 2) {
                    DBG();
                    return false; // Memory and SRLs only valid in SLICEMs
                }
            }

            // Check (over)usage of DI and X inputs
            NetInfo *i_net = nullptr, *x_net = nullptr;
            if (lut6 != nullptr) {
                i_net = lut6->lutInfo.di1_net;
                x_net = lut6->lutInfo.di2_net;
            }
            if (lut5 != nullptr) {
                if (lut5->lutInfo.di1_net != nullptr) {
                    if (i_net == nullptr)
                        i_net = lut5->lutInfo.di1_net;
                    else if (i_net != lut5->lutInfo.di1_net) {
                        DBG();
                        return false; // Memory and SRLs only valid in SLICEMs
                    }
                }
                // DI2 not available for 5LUT
                if (lut5->lutInfo.di2_net != nullptr) {
                    DBG();
                    return false; // Memory and SRLs only valid in SLICEMs
                }
            }

            CellInfo *mux = nullptr;
            // Eights A, C, E, G: F7MUX uses X input
            if (i == 0 || i == 2 || i == 4 || i == 6)
                mux = lts.cells[i << 4 | BEL_F7MUX];
            // Eights B, F: F8MUX uses X input
            if (i == 1 || i == 5)
                mux = lts.cells[(i - 1) << 4 | BEL_F8MUX];
            // Eights D: F9MUX uses X input
            if (i == 3)
                mux = lts.cells[BEL_F9MUX];

            if (mux != nullptr) {
                if (x_net == nullptr)
                    x_net = mux->muxInfo.sel;
                else if (x_net != mux->muxInfo.sel) {
                    DBG();
                    return false; // Memory and SRLs only valid in SLICEMs
                }
            }

            CellInfo *out_fmux = nullptr;
            // Eights B, D, F, H: F7MUX connects to F7F8 out
            if (i == 1 || i == 3 || i == 5 || i == 7)
                out_fmux = lts.cells[(i - 1) << 4 | BEL_F7MUX];
            // Eights C, G: F8MUX connects to F7F8 out
            if (i == 2 || i == 6)
                out_fmux = lts.cells[(i - 2) << 4 | BEL_F8MUX];
            // Eights E: F9MUX connects to F7F8 out
            if (i == 4)
                out_fmux = lts.cells[BEL_F9MUX];

            CellInfo *carry8 = lts.cells[BEL_CARRY8];
            // CARRY8 might use X
            if (carry8 != nullptr && carry8->carryInfo.x_sigs[i] != nullptr) {
                if (x_net == nullptr)
                    x_net = carry8->carryInfo.x_sigs[i];
                else if (x_net != carry8->carryInfo.x_sigs[i]) {
                    DBG();
                    return false; // Memory and SRLs only valid in SLICEMs
                }
            }

            // FF1 might use X, if it isn't driven directly
            CellInfo *ff1 = lts.cells[i << 4 | BEL_FF];
            if (ff1 != nullptr && ff1->ffInfo.d != nullptr && ff1->ffInfo.d->driver.cell != nullptr) {
                auto &drv = ff1->ffInfo.d->driver;
                if ((drv.cell == lut6 && drv.port != id_MC31) || drv.cell == lut5 || drv.cell == out_fmux) {
                    // Direct, OK
                    // FIXME: CARRY8 direct
                } else {
                    // Indirect, must use X input
                    if (x_net == nullptr)
                        x_net = ff1->ffInfo.d;
                    else if (x_net != ff1->ffInfo.d) {
                        DBG();
                        return false; // Memory and SRLs only valid in SLICEMs
                    }
                }
            }

            // FF2 might use I, if it isn't driven directly
            CellInfo *ff2 = lts.cells[i << 4 | BEL_FF2];
            if (ff2 != nullptr && ff2->ffInfo.d != nullptr && ff2->ffInfo.d->driver.cell != nullptr) {
                auto &drv = ff2->ffInfo.d->driver;
                if ((drv.cell == lut6 && drv.port != id_MC31) || drv.cell == lut5 || drv.cell == out_fmux) {
                    // Direct, OK
                    // FIXME: CARRY8 direct
                } else {
                    // Indirect, must use X input
                    if (i_net == nullptr)
                        i_net = ff2->ffInfo.d;
                    else if (i_net != ff2->ffInfo.d) {
                        DBG();
                        return false; // Memory and SRLs only valid in SLICEMs
                    }
                }
            }

            // Collision with top address bits
            if (tile_is_memory && !small_memory) {
                CellInfo *top_lut = lts.cells[(7 << 4) | BEL_6LUT];
                if (top_lut != nullptr) {
                    if ((i == 6) && x_net != top_lut->lutInfo.address_msb[0])
                        return false;
                    if ((i == 5) && x_net != top_lut->lutInfo.address_msb[1])
                        return false;
                    if ((i == 3) && x_net != top_lut->lutInfo.address_msb[2])
                        return false;
                }
            }

            bool mux_output_used = false;
            NetInfo *out5 = nullptr;
            if (lut6 != nullptr && lut6->lutInfo.output_count == 2)
                out5 = lut6->lutInfo.output_sigs[1];
            else if (lut5 != nullptr && !lut5->lutInfo.only_drives_carry)
                out5 = lut5->lutInfo.output_sigs[0];
            if (out5 != nullptr && (out5->users.size() > 1 || ((ff1 == nullptr || out5 != ff1->ffInfo.d) &&
                                                               (ff2 == nullptr || out5 != ff2->ffInfo.d)))) {
                mux_output_used = true;
            }

            if (carry8 != nullptr && carry8->carryInfo.out_sigs[i] != nullptr) {
                // FIXME: direct connections to FF
                if (mux_output_used) {
                    DBG();
                    return false; // Memory and SRLs only valid in SLICEMs
                }
                mux_output_used = true;
            }
            if (out_fmux != nullptr) {
                NetInfo *f7f8 = out_fmux->muxInfo.out;
                if (f7f8 != nullptr && (f7f8->users.size() > 1 || ((ff1 == nullptr || f7f8 != ff1->ffInfo.d) &&
                                                                   (ff2 == nullptr || f7f8 != ff2->ffInfo.d)))) {
                    if (mux_output_used) {
                        DBG();
                        return false; // Memory and SRLs only valid in SLICEMs
                    }
                    mux_output_used = true;
                }
            }

            lts.eights[i].valid = true;
        } else if (!lts.eights[i].valid) {
            return false;
        }
    }
    // Check half-tiles
    for (int i = 0; i < 2; i++) {
        if (lts.halfs[i].dirty) {
            lts.halfs[i].valid = false;
            bool found_ff[2] = {false, false};
            NetInfo *clk = nullptr, *sr = nullptr, *ce[2] = {nullptr};
            bool clkinv = false, srinv = false, islatch = false;
            for (int z = 4 * i; z < 4 * (i + 1); z++) {
                for (int k = 0; k < 2; k++) {
                    CellInfo *ff = lts.cells[z << 4 | (BEL_FF + k)];
                    if (ff == nullptr)
                        continue;
                    if (found_ff[0] || found_ff[1]) {
                        if (ff->ffInfo.clk != clk)
                            return false;
                        if (ff->ffInfo.sr != sr)
                            return false;
                        if (ff->ffInfo.is_clkinv != clkinv)
                            return false;
                        if (ff->ffInfo.is_srinv != srinv)
                            return false;
                        if (ff->ffInfo.is_latch != islatch)
                            return false;
                    } else {
                        clk = ff->ffInfo.clk;
                        sr = ff->ffInfo.sr;
                        clkinv = ff->ffInfo.is_clkinv;
                        srinv = ff->ffInfo.is_srinv;
                        islatch = ff->ffInfo.is_latch;
                    }
                    if (found_ff[k]) {
                        if (ff->ffInfo.ce != ce[k])
                            return false;
                    } else {
                        ce[k] = ff->ffInfo.ce;
                    }
                    found_ff[k] = true;
                }
            }
            lts.halfs[i].valid = true;
        } else if (!lts.halfs[i].valid) {
            return false;
        }
    }
    return true;
}

bool Arch::xc7_logic_tile_valid(IdString tileType, LogicTileStatus &lts) const
{
    // Fully-frozen tile fast-path: if every occupied BEL holds a cell that is
    // still BEL-pinned (imported from a proven Vivado placement), the tile is
    // legal by construction -- Vivado already validated it on silicon.  The
    // downstream heuristics (LUT input/output packing, X-input usage, control
    // sets) model nextpnr's OWN packer and cannot see Vivado's input-pin
    // permutation / shared-IMUX packing, so they reject legal frozen tiles.
    // The bbox exclusion keeps user (non-imported) cells out of macro tiles,
    // so a tile is either all-imported (trust) or contains user logic (full
    // checks).  Any cell WITHOUT a BEL attr forces the full validation.
    {
        bool any = false, all_frozen = true;
        for (int z = 0; z < 128; z++) {
            CellInfo *c = lts.cells[z];
            if (c == nullptr)
                continue;
            any = true;
            // frozen == stamped: bound STRENGTH_USER by the BEL-attr placer.
            // (A BEL *attribute* is NOT a reliable marker -- place_initial
            //  back-annotates one onto every nextpnr-placed user cell too.)
            //
            // The bar is USER, not STRONG.  STRENGTH_STRONG is what nextpnr's
            // OWN machinery binds at for cells IT constrains: HeAP's strict
            // legaliser binds every chain it places STRONG and calls
            // isBelLocationValid() right after (placer_heap.cc,
            // legalise_placement_strict), placer1 binds cluster children the
            // same way, and place_common.cc place_macro binds macro members
            // STRONG.  Accepting STRONG let a self-placed macro count as
            // "imported, trust it", which made the legaliser's own validity
            // query vacuous.  Two measured consequences: illegal LUT pairings
            // (two LUTs whose logical inputs need more distinct physical pins
            // than the slice has) survived to the router as one overused
            // SITEWIRE contended by two nets; and a dist-RAM macro landing in
            // a tile whose FFs were stamped by place_lef skipped every
            // control-set check -- RAMD64E on one clock co-packed with FDREs on
            // another in a slice with ONE CLK pin, surfacing as permanently
            // skipped clock arcs (eth-arp: 4 slices of the txf CDC FIFO,
            // u_txf_wr WCLK vs u_txf_rd CK).
            //
            // USER rather than LOCKED: imported placements bind USER
            // (attributesToArchInfo defaults to STRENGTH_USER, nextpnr.cc), and
            // nothing in this tree ever binds a BEL at LOCKED or FIXED, so the
            // two bars select the same cells on any netlist this flow produces.
            // USER is chosen because it is the strictest -- it can only ever
            // add validation, never skip it -- and because the sibling
            // "is this an imported placement" test below already reads
            // `belStrength >= STRENGTH_USER`.
            if (c->belStrength < STRENGTH_USER) {
                all_frozen = false;
                break;
            }
        }
        if (any && all_frozen)
            return true;
    }
    bool is_slicem = (tileType == id_CLBLM_L) || (tileType == id_CLBLM_R);
    // SLICEM-only guard, run UNCONDITIONALLY (not behind the per-eight dirty
    // cache in the loop below).  A distributed-RAM / SRL LUT (is_memory /
    // is_srl) is legal only in a SLICEM.  The dirty-gated loop leaves this
    // unchecked whenever a tile is validated while clean, so SA / legalisation
    // can strand a memory/SRL LUT in a SLICEL -- surfacing much later as an
    // unroutable "Pin 'DI1'/'WE' of bel ... has no associated wire".  A cheap
    // O(16) scan here closes that hole for both the 6LUT and 5LUT bels.
    if (!is_slicem) {
        for (int i = 0; i < 8; i++) {
            CellInfo *l6 = lts.cells[(i << 4) | BEL_6LUT];
            CellInfo *l5 = lts.cells[(i << 4) | BEL_5LUT];
            if ((l6 != nullptr && (l6->lutInfo.is_memory || l6->lutInfo.is_srl)) ||
                (l5 != nullptr && (l5->lutInfo.is_memory || l5->lutInfo.is_srl)))
                return false;
        }
    }
    // A 5LUT bel has neither an A6 input nor an O6 output wire; a cell there
    // must not use either.  Enforce UNCONDITIONALLY -- the dirty-gated loop
    // below caches past this, letting legalisation strand a 6-input LUT on a
    // 5LUT ("No wire found for port A6/O6").  CRUCIAL: at placement time an
    // ABC-mapped LUT still carries LOGICAL pin names (I0..I5), so neither a
    // physical id_A6 lookup nor lutInfo.input_count (which scans A1..A6) sees
    // its 6th input -- we must COUNT connected input ports, exactly as
    // isValidBelForCell does.
    for (int i = 0; i < 8; i++) {
        CellInfo *l5 = lts.cells[(i << 4) | BEL_5LUT];
        if (l5 == nullptr)
            continue;
        // Memory/SRL LUTs legitimately draw many ports (address + DI + WE) and
        // are packed to specific 5LUT bels -- the SLICEM guard above already
        // constrains them, so the plain-LUT input-count rule must not apply.
        if (l5->lutInfo.is_memory || l5->lutInfo.is_srl)
            continue;
        int in_used = 0;
        for (auto &port : l5->ports) {
            if (port.second.net == nullptr)
                continue;
            if (port.second.type == PORT_IN)
                ++in_used;
        }
        // Reject only what the 5LUT bel PHYSICALLY cannot provide: a 6th
        // input (in_used / A6) or a second output.  A single-output cell
        // whose port happens to be NAMED O6 is NOT invalid here: that is the
        // documented pre-fixup state of every carry DI feed-through --
        // pack_carry_xc7 constrains them to the 5LUT bel with the output
        // still called O6, and fixupPlacement() renames it to O5 after
        // placement ("the cell at the 5LUT bel still drives O5, not O6",
        // below).  Rejecting on the port NAME made every carry chain with
        // DI feed-throughs impossible to legalise: the condition travels
        // with the chain, so no location could ever pass, and HeAP's strict
        // legaliser span forever.
        if (in_used > 5 || l5->lutInfo.output_count == 2 ||
            get_net_or_empty(l5, id_A6) != nullptr)
            return false;
    }
    // Per-position site-exit (OUTMUX) budget, run UNCONDITIONALLY.  Each
    // letter position has exactly ONE selectable output pin ([A-D]MUX: O5,
    // XOR=carry O, CY=carry CO, A5Q, ...) besides the dedicated O6 pin and
    // the FF's Q.  The packer/legaliser could co-locate a 5LUT with fabric
    // consumers, a carry whose O feeds an off-position FF (or fabric), and
    // more -- each needing that one pin.  The router then inherits an
    // unroutable site: "Failed to route arc ... CARRY4_O3 to AFFMUX_OUT"
    // (litex deephier @ seed 4), and the same shape breaks silicon in the
    // O+CO fanout case (#134).  Reject any position with more than one
    // OUTMUX claimant so the legaliser keeps searching instead.
    for (int h = 0; h < 2; h++) {
        CellInfo *cy = lts.cells[(h << 6) | BEL_CARRY4];
        for (int k = 0; k < 4; k++) {
            int eighth = h * 4 + k;
            CellInfo *l6 = lts.cells[(eighth << 4) | BEL_6LUT];
            CellInfo *l5 = lts.cells[(eighth << 4) | BEL_5LUT];
            CellInfo *ff1 = lts.cells[(eighth << 4) | BEL_FF];
            CellInfo *ff2 = lts.cells[(eighth << 4) | BEL_FF2];
            // in-position sinks that do NOT need the OUTMUX
            auto is_local_sink = [&](const PortRef &usr, NetInfo *net) {
                if (usr.cell == ff1 && ff1 != nullptr && ff1->ffInfo.d == net)
                    return true; // main FF via xFFMUX
                if (usr.cell == ff2 && ff2 != nullptr && ff2->ffInfo.d == net)
                    return true; // 5FF via xFF5MUX
                if (usr.cell == cy)
                    return true; // carry S/DI/CIN feed
                if (usr.cell == l6 || usr.cell == l5)
                    return true; // intra-position feed (routethru cases)
                return false;
            };
            auto has_external_user = [&](NetInfo *net) {
                if (net == nullptr)
                    return false;
                for (auto &usr : net->users)
                    if (!is_local_sink(usr, net))
                        return true;
                return false;
            };
            int claims = 0;
            // O5 of a used 5LUT (O6 has its own pin; DI feed-throughs and
            // in-position FF feeds are local)
            const bool o5_needs_outmux = l5 != nullptr && !l5->lutInfo.only_drives_carry &&
                                         !l5->lutInfo.is_memory && !l5->lutInfo.is_srl &&
                                         has_external_user(l5->lutInfo.output_sigs[0]);
            if (o5_needs_outmux)
                claims++;
            const bool position_has_carry = cy != nullptr;
            if (position_has_carry) {
                // carry sum O_k beyond the in-position FF
                const bool carry_o_needs_outmux = has_external_user(cy->carryInfo.out_sigs[k]);
                if (carry_o_needs_outmux)
                    claims++;
                // carry CO_k beyond the chain continuation
                NetInfo *co = cy->carryInfo.cout_sigs[k];
                const bool co_is_used = co != nullptr; // an unused CO claims nothing
                if (co_is_used) {
                    for (auto &usr : co->users) {
                        // the chain continuation (k==3) uses the dedicated COUT
                        const bool is_chain_continuation =
                                usr.cell != nullptr && usr.cell->type == id_CARRY4 && usr.port == id_CIN;
                        if (is_chain_continuation)
                            continue;
                        if (is_local_sink(usr, co))
                            continue;
                        claims++;
                        break;
                    }
                }
            }
            // 5FF Q has no dedicated pin: fabric consumers go through OUTMUX
            const bool position_has_5ff = ff2 != nullptr;
            if (position_has_5ff) {
                NetInfo *q2 = get_net_or_empty(ff2, id_Q);
                const bool ff2_q_reaches_fabric = q2 != nullptr && q2->users.size() > 0;
                if (ff2_q_reaches_fabric)
                    claims++;
            }
            if (claims > 1) {
                DBG();
                return false;
            }
        }
    }
    bool tile_is_memory = false;
    if (lts.cells[(3 << 4) | BEL_6LUT] != nullptr && lts.cells[(3 << 4) | BEL_6LUT]->lutInfo.is_memory)
        tile_is_memory = true;
    bool small_memory = false;
    if (lts.cells[(3 << 4) | BEL_5LUT] != nullptr && lts.cells[(3 << 4) | BEL_5LUT]->lutInfo.is_memory)
        small_memory = true;
    NetInfo *wclk = nullptr;
    // Check eight-tiles (mostly LUT-related validity)
    for (int i = 0; i < 8; i++) {
        if (lts.eights[i].dirty) {
            lts.eights[i].dirty = false;
            lts.eights[i].valid = false;

            CellInfo *lut6 = lts.cells[(i << 4) | BEL_6LUT];
            CellInfo *lut5 = lts.cells[(i << 4) | BEL_5LUT];

            // Check 6LUT
            if (lut6 != nullptr) {
                if (!is_slicem && (lut6->lutInfo.is_memory || lut6->lutInfo.is_srl)) {
                    DBG_RT();
                    return false; // Memory and SRLs only valid in SLICEMs
                }
                if (lut6->lutInfo.is_srl && (i >= 4)) {
                    DBG_RT();
                    return false;
                }
                if (lut6->lutInfo.is_memory || lut6->lutInfo.is_srl) {
                    if (wclk == nullptr)
                        wclk = lut6->lutInfo.wclk;
                    else if (lut6->lutInfo.wclk != wclk) {
                        DBG();
                        return false;
                    }
                }
                if (lut5 != nullptr) {
                    // Can't mix memory and non-memory
                    if (lut6->lutInfo.is_memory != lut5->lutInfo.is_memory ||
                        lut6->lutInfo.is_srl != lut5->lutInfo.is_srl) {
                        DBG();
                        return false;
                    }
                    bool srl_pair = lut6->lutInfo.is_srl && lut5->lutInfo.is_srl;
                    // Imported (Vivado/golden) CARRY4 slot: a full 6-input
                    // operand LUT (O6->S) coexisting with a DI feed-through LUT
                    // (O5->DI, only_drives_carry) is physically legal on silicon
                    // -- golden uses it and runs.  Trust a BEL-pinned (imported)
                    // 6LUT whose companion 5LUT only drives the carry, for BOTH
                    // the all-inputs/two-outputs check here and the shared-inputs
                    // check below (the operand often uses all 6 inputs, so the
                    // input_count==6 arm fires first and must honour the same
                    // exemption).
                    bool imported_carry_feedthrough =
                            lut6->attrs.count(id_BEL) && lut5->lutInfo.only_drives_carry;
                    // General imported-slot trust: BOTH LUTs BEL-pinned means a
                    // frozen Vivado placement that already runs on silicon.
                    // The LUT-pack heuristics below (6-input coexistence,
                    // shared-input count) cannot see Vivado's input-pin
                    // permutation / shared-IMUX packing and would reject legal
                    // slots.  Trust the import; only user (non-BEL) cells get
                    // the full checks.  (Frozen macros come from a proven bit,
                    // so no illegal slot can enter this way.)
                    bool imported_slot =
                            lut6->attrs.count(id_BEL) && lut5->attrs.count(id_BEL);
                    // If all 6 inputs or 2 outputs are used, 5LUT can't also be
                    // present.  SRL16E pairs are exempt: their address pins are
                    // constant-tied and shared by construction (Vivado packs
                    // two SRL16Es per slot routinely).
                    if (!srl_pair && !imported_carry_feedthrough && !imported_slot &&
                        (lut6->lutInfo.input_count == 6 || lut6->lutInfo.output_count == 2)) {
                        if (dbg_validity_runtime)
                            log_info("  invalid-arm-387: lut6=%s(BEL=%d) in=%d out=%d lut5=%s(BEL=%d) imported_slot=%d\n",
                                     nameOf(lut6), int(lut6->attrs.count(id_BEL)), lut6->lutInfo.input_count,
                                     lut6->lutInfo.output_count, nameOf(lut5), int(lut5->attrs.count(id_BEL)),
                                     int(imported_slot));
                        DBG();
                        return false;
                    }
                    // If more than 5 total inputs are used, need to check number of shared input
                    if (!srl_pair && (lut6->lutInfo.input_count + lut5->lutInfo.input_count) > 5) {
                        int shared = 0, need_shared = (lut6->lutInfo.input_count + lut5->lutInfo.input_count - 5);
                        for (int j = 0; j < lut6->lutInfo.input_count; j++) {
                            for (int k = 0; k < lut5->lutInfo.input_count; k++) {
                                if (lut6->lutInfo.input_sigs[j] == lut5->lutInfo.input_sigs[k])
                                    shared++;
                                if (shared >= need_shared)
                                    break;
                            }
                        }
                        if (shared < need_shared) {
                            // Imported (Vivado/golden) CARRY4 slot: the operand LUT
                            // (O6->S) and the DI feed-through (O5->DI) are ONE
                            // dual-output LUT on real hardware -- O5 and O6 of the
                            // same 5-input LUT -- so they share all physical inputs
                            // by construction.  SVS/pack represents that as two cells
                            // whose lone feed-through input is a renamed net copy, so
                            // input_sigs no longer match by identity (shared=0 here)
                            // even though the placement is physically legal (golden
                            // uses it and runs).  When the slot's 6LUT is BEL-pinned
                            // (imported) and the 5LUT only drives the carry, trust the
                            // import instead of rejecting a valid slot.
                            bool imported_carry_feedthrough =
                                lut6->attrs.count(id_BEL) && lut5->lutInfo.only_drives_carry;
                            // General imported-slot trust: when BOTH LUTs are
                            // BEL-pinned (a frozen Vivado placement), Vivado has
                            // already proven the slot legal on silicon.  The
                            // shared-input heuristic under-counts when the two
                            // logical LUT inputs are distinct nets that Vivado
                            // routes to the SAME physical A-pin (LUT input-pin
                            // permutation / shared IMUX), which our net-identity
                            // comparison cannot see.  Trust the import rather
                            // than reject a placement that demonstrably works.
                            if (!imported_carry_feedthrough && !imported_slot) {
                                DBG();
                                return false;
                            }
                        }
                    }
                }
            }
            if (lut5 != nullptr) {
                if (!is_slicem && (lut5->lutInfo.is_memory || lut5->lutInfo.is_srl)) {
                    DBG();
                    return false; // Memory and SRLs only valid in SLICEMs
                }
                if (lut5->lutInfo.is_srl) {
                    if (wclk == nullptr)
                        wclk = lut5->lutInfo.wclk;
                    else if (lut5->lutInfo.wclk != wclk) {
                        DBG();
                        return false;
                    }
                }
                // 5LUT can use at most 5 inputs and 1 output
                if (lut5->lutInfo.input_count > 5 || lut5->lutInfo.output_count == 2) {
                    DBG();
                    return false; // Memory and SRLs only valid in SLICEMs
                }
                // The 5LUT bel has no A6 input: a cell occupying it must not
                // draw one.  The output side is NOT checked by port name --
                // a single-output cell whose port is still called O6 is the
                // legal pre-fixup state of a carry DI feed-through
                // (pack_carry_xc7 constrains them to the 5LUT bel;
                // fixupPlacement() renames O6->O5 after placement).  What the
                // bel physically cannot provide -- a second output -- is
                // already rejected by the output_count check above.
                if (get_net_or_empty(lut5, id_A6) != nullptr) {
                    DBG();
                    return false;
                }
            }

            // Check (over)usage ofX inputs
            NetInfo *x_net = nullptr;
            if (lut6 != nullptr) {
                x_net = lut6->lutInfo.di2_net;
            }

            CellInfo *mux = nullptr;
            // Eights A, C, E, G: F7MUX uses X input
            if (i == 0 || i == 2 || i == 4 || i == 6)
                mux = lts.cells[i << 4 | BEL_F7MUX];
            // Eights B, F: F8MUX uses X input
            if (i == 1 || i == 5)
                mux = lts.cells[(i - 1) << 4 | BEL_F8MUX];

            if (mux != nullptr) {
                if (x_net == nullptr)
                    x_net = mux->muxInfo.sel;
                else if (x_net != mux->muxInfo.sel) {
                    DBG();
                    return false; // Memory and SRLs only valid in SLICEMs
                }
            }

            CellInfo *out_fmux = nullptr;
            // Subslices A, C: F7MUX connects to F7F8 out
            if (i == 0 || i == 2 || i == 4 || i == 6)
                out_fmux = lts.cells[(i << 4) | BEL_F7MUX];
            // Subslices B: F8MUX connects to F7F8 out
            if (i == 1 || i == 5)
                out_fmux = lts.cells[(i - 1) << 4 | BEL_F8MUX];

            CellInfo *carry4 = lts.cells[((i / 4) << 6) | BEL_CARRY4];

            if (carry4 != nullptr && carry4->carryInfo.x_sigs[i % 4] != nullptr) {
                if (x_net == nullptr)
                    x_net = carry4->carryInfo.x_sigs[i % 4];
                else if (x_net != carry4->carryInfo.x_sigs[i % 4]) {
                    DBG();
                    return false;
                }
            }

            // FF1 might use X, if it isn't driven directly
            CellInfo *ff1 = lts.cells[i << 4 | BEL_FF];
            bool ff1_uses_x = false;
            if (ff1 != nullptr && ff1->ffInfo.d != nullptr && ff1->ffInfo.d->driver.cell != nullptr) {
                auto &drv = ff1->ffInfo.d->driver;
                // Two feed shapes reach the main FF without the X pin; they
                // are legal as-is, and accepting them means exactly "leave
                // ff1_uses_x false and account nothing":
                //
                // direct_feed: LUT O6/O5, F7/F8 mux out, or THIS position's
                // CARRY4 O/CO via the XOR/CY xFFMUX paths.  The position
                // check matters: an FF fed by another position's carry
                // output used to pass as "direct" here, but position A's
                // FFMUX cannot see O3.
                const bool direct_feed =
                        (drv.cell == lut6 && drv.port != id_MC31) || drv.cell == lut5 || drv.cell == out_fmux ||
                        (carry4 != nullptr && drv.cell == carry4 &&
                         (carry4->carryInfo.out_sigs[i % 4] == ff1->ffInfo.d ||
                          carry4->carryInfo.cout_sigs[i % 4] == ff1->ffInfo.d));
                // lut_routethru_feed: imported (Vivado-placed) FF with a
                // free LUT position in the slot.  Vivado feeds the main FF
                // through a LUT routethru (free 6LUT: INIT buffer +
                // xFFMUX.O6; free 5LUT: lower-half INIT buffer + xFFMUX.O5)
                // and leaves the X bypass for the 5FF -- no X usage.  The
                // router realises this via the route-thru pseudo pip.
                const bool lut_routethru_feed =
                        ff1->attrs.count(id_BEL) && (lut6 == nullptr || lut5 == nullptr);
                if (!direct_feed && !lut_routethru_feed) {
                    // With direct_feed excluded, a carry driver can only be
                    // ANOTHER position's output of this very slice's carry
                    // (the matching-position case is direct_feed above).
                    const bool cross_position_carry_feed = carry4 != nullptr && drv.cell == carry4;
                    if (cross_position_carry_feed) {
                        // There is no
                        // realizable path: this position's xFFMUX sees only
                        // its own O/CO, and the X input comes from the
                        // fabric -- whose source would be this same site, an
                        // exit-and-reenter the router does not model for
                        // intra-site arcs ("Failed to route arc ...
                        // CARRY4_O2 to AFFMUX_OUT", litex-ddr-qmtech-kintex7
                        // on the demos CI).  Flat reject; the FF is
                        // placeable in any OTHER slice via a normal fabric
                        // route.
                        DBG();
                        return false;
                    }
                    // Indirect, must use X input
                    ff1_uses_x = true;
                    if (x_net == nullptr)
                        x_net = ff1->ffInfo.d;
                    else if (x_net != ff1->ffInfo.d) {
                        DBG();
                        return false;
                    }
                }
            }

            // FF2 might use X, if it isn't driven directly
            CellInfo *ff2 = lts.cells[i << 4 | BEL_FF2];
            if (ff2 != nullptr && ff2->ffInfo.d != nullptr && ff2->ffInfo.d->driver.cell != nullptr) {
                auto &drv = ff2->ffInfo.d->driver;
                // The 5FF's only X-free feed is its own position's O5:
                // legal as-is, nothing to account.
                const bool direct_o5_feed = drv.cell == lut5;
                const bool fed_by_own_slice_carry = carry4 != nullptr && drv.cell == carry4;
                if (!direct_o5_feed) {
                    if (fed_by_own_slice_carry) {
                        // The 5FF's D mux sees only O5 and the X bypass -- a
                        // carry output can NEVER reach it directly, at any
                        // position, and via X it would need the same
                        // exit-and-reenter the router does not model.  Flat
                        // reject (same class as the main-FF case above).
                        DBG();
                        return false;
                    }
                    // Indirect, must use X input
                    if (x_net == nullptr)
                        x_net = ff2->ffInfo.d;
                    else if (x_net != ff2->ffInfo.d) {
#ifdef DEBUG_VALIDITY
                        log_info("%s %s %s %s %s\n", nameOf(lut6), nameOf(ff1), nameOf(lut5), nameOf(ff2),
                                 nameOf(drv.cell));
#endif
                        DBG();
                        return false;
                    }
                }
            }

            // Legalisation fix (xc7): when the main FF (BEL_FF) takes its D from
            // the X bypass (indirect) AND the column's secondary "5" FF (BEL_FF2)
            // is also placed, nextpnr's router fails to bind the main FF's input
            // MUX (xFFMUX) from X — it silently leaves the main FF's D floating
            // (observed via physical sim: the bypass-fed AFF's D = X, corrupting
            // an LFSR).  Forbid that co-pack so the placer separates the two FFs.
            // Exception: when BOTH FFs carry absolute BEL pins (imported
            // Vivado placement), trust the import -- Vivado co-packs this
            // legally, and the route-only flow cannot separate them.  Any
            // residual xFFMUX emission bug then shows up as a bit-level
            // diff against the golden bitstream instead of a place error.
            if (ff1_uses_x && ff2 != nullptr &&
                !(ff1->attrs.count(id_BEL) && ff2->attrs.count(id_BEL))) {
                DBG();
                return false;
            }

            // collision with top address bits
            if (tile_is_memory && !small_memory) {
                CellInfo *top_lut = lts.cells[(3 << 4) | BEL_6LUT];
                if (top_lut != nullptr) {
                    if ((i == 2) && x_net != top_lut->lutInfo.address_msb[0]) {
                        DBG();
                        return false;
                    }
                    if ((i == 1) && x_net != top_lut->lutInfo.address_msb[1]) {
                        DBG();
                        return false;
                    }
                }
            }

            bool mux_output_used = false;
            NetInfo *out5 = nullptr;
            if (lut6 != nullptr && lut6->lutInfo.output_count == 2)
                out5 = lut6->lutInfo.output_sigs[1];
            else if (lut5 != nullptr && !lut5->lutInfo.only_drives_carry)
                out5 = lut5->lutInfo.output_sigs[0];
            if (out5 != nullptr && (out5->users.size() > 1 || ((ff1 == nullptr || out5 != ff1->ffInfo.d) &&
                                                               (ff2 == nullptr || out5 != ff2->ffInfo.d)))) {
                mux_output_used = true;
            }

            if (carry4 != nullptr && carry4->carryInfo.out_sigs[i % 4] != nullptr) {
                // The carry O output reaches the main FF directly through
                // the XOR path of xFFMUX; only fabric fanout (or feeding
                // anything else) needs this subslice's output mux.
                NetInfo *o = carry4->carryInfo.out_sigs[i % 4];
                // Only fabric fanout (or a single non-local-FF user) needs the
                // subslice output mux.  A carry O with NO users (yosys keeps
                // dead sum bits of an ALU chain, e.g. comparison-only $alu
                // where only CO propagates) needs no mux at all -- claiming it
                // made every such tile invalid when the LUT in the same
                // subslice also used O5 (mux_output_used), so ALU chains with
                // dropped sums could never be placed.
                // The subslice's FF may live in either eighth of the pair
                // (the check iterates both: i and i^4); accept either.
                CellInfo *pair_ff1 = lts.cells[((i ^ 4) << 4) | BEL_FF];
                bool o_ff_local = (ff1 != nullptr && o == ff1->ffInfo.d) ||
                                  (pair_ff1 != nullptr && o == pair_ff1->ffInfo.d);
                bool o_uses_mux = !o->users.empty() && !o_ff_local &&
                                  (o->users.size() > 1 || ff1 == nullptr || o != ff1->ffInfo.d);
                if (o_uses_mux) {
                    if (mux_output_used) {
                        DBG();
                        return false;
                    }
                    mux_output_used = true;
                }
            }
            // This CO-fabric vs output-mux contention check stops nextpnr's own
            // placer from co-locating a CARRY4 CO and a 5FF into an unroutable
            // slot.  A *stamped* vendor placement (hybrid R0 flow: Vivado places,
            // nextpnr only routes) can legally co-locate them via muxing nextpnr
            // doesn't model, so let that flow opt out -- a wrong guess fails
            // loudly in the router, it can't produce a silently-bad bitstream.
            static const bool allow_co_5ff_contention =
                    getenv("NEXTPNR_ALLOW_CO_5FF_CONTENTION") != nullptr;
            if (!allow_co_5ff_contention && carry4 != nullptr && carry4->carryInfo.cout_sigs[i % 4] != nullptr) {
                NetInfo *co = carry4->carryInfo.cout_sigs[i % 4];
                bool co_uses_mux = false;
                if ((i % 4) == 3) {
                    // CO3 leaves on the dedicated COUT->CIN spine; only other
                    // (fabric) users need this subslice's output mux
                    for (auto &usr : co->users)
                        if (usr.port != id_CIN)
                            co_uses_mux = true;
                } else {
                    // CO0..CO2 can only reach the fabric through the output mux
                    co_uses_mux = !co->users.empty();
                }
                if (co_uses_mux) {
                    if (mux_output_used) {
                        DBG();
                        return false;
                    }
                    mux_output_used = true;
                }
            }
            if (out_fmux != nullptr) {
                NetInfo *f7f8 = out_fmux->muxInfo.out;
                if (f7f8 != nullptr && (f7f8->users.size() > 1 || ((ff1 == nullptr || f7f8 != ff1->ffInfo.d)))) {
                    if (mux_output_used) {
                        DBG();
                        return false; // Memory and SRLs only valid in SLICEMs
                    }
                    mux_output_used = true;
                }
            }
            if (ff2 != nullptr) {
                if (mux_output_used) {
                    DBG();
                    return false; // Memory and SRLs only valid in SLICEMs
                }
                mux_output_used = true;
            }

            lts.eights[i].valid = true;
        } else if (!lts.eights[i].valid) {
            if (dbg_validity_runtime)
                log_info("  invalid-arm: cached eights[%d].valid=false\n", i);
            return false;
        }
    }
    // Check half-tiles
    for (int i = 0; i < 2; i++) {
        if (lts.halfs[i].dirty) {
            lts.halfs[i].valid = false;
            bool found_ff[2] = {false, false};
            if (i == 0 && wclk == nullptr) {
                // Need to check wclk too
                for (int z = 4 * i; z < 4 * (i + 1); z++) {
                    for (int k = 0; k < 2; k++) {
                        CellInfo *lut = lts.cells[z << 4 | (BEL_6LUT + k)];
                        if (lut == nullptr)
                            continue;
                        if (!lut->lutInfo.is_memory && !lut->lutInfo.is_srl)
                            continue;
                        if (lut->lutInfo.wclk != nullptr) {
                            wclk = lut->lutInfo.wclk;
                            break;
                        }
                    }
                }
            }
            NetInfo *clk = nullptr, *sr = nullptr, *ce = nullptr;
            bool clkinv = false, srinv = false, islatch = false, ffsync = false;
            for (int z = 4 * i; z < 4 * (i + 1); z++) {
                for (int k = 0; k < 2; k++) {
                    CellInfo *ff = lts.cells[z << 4 | (BEL_FF + k)];
                    if (ff == nullptr)
                        continue;
                    if (ff->ffInfo.is_latch && k == 1) {
                        DBG_RT();
                        return false;
                    }
                    if (found_ff[0] || found_ff[1]) {
                        if (ff->ffInfo.clk != clk) {
                            if (dbg_validity_runtime)
                                log_info("  invalid-arm: ctrlset clk %s: %s vs %s\n", nameOf(ff),
                                         ff->ffInfo.clk ? nameOf(ff->ffInfo.clk) : "-", clk ? nameOf(clk) : "-");
                            return false;
                        }
                        if (ff->ffInfo.sr != sr) {
                            if (dbg_validity_runtime)
                                log_info("  invalid-arm: ctrlset sr %s @%s: %s vs %s\n", nameOf(ff),
                                         getBelName(ff->bel).c_str(getCtx()),
                                         ff->ffInfo.sr ? nameOf(ff->ffInfo.sr) : "-", sr ? nameOf(sr) : "-");
                            return false;
                        }
                        if (ff->ffInfo.ce != ce) {
                            if (dbg_validity_runtime)
                                log_info("  invalid-arm: ctrlset ce %s: %s vs %s\n", nameOf(ff),
                                         ff->ffInfo.ce ? nameOf(ff->ffInfo.ce) : "-", ce ? nameOf(ce) : "-");
                            return false;
                        }
                        if (ff->ffInfo.is_clkinv != clkinv) {
                            DBG_RT();
                            return false;
                        }
                        if (ff->ffInfo.is_srinv != srinv) {
                            DBG_RT();
                            return false;
                        }
                        if (ff->ffInfo.is_latch != islatch) {
                            DBG_RT();
                            return false;
                        }
                        if (ff->ffInfo.ffsync != ffsync) {
                            DBG_RT();
                            return false;
                        }
                    } else {
                        clk = ff->ffInfo.clk;
                        if (i == 0 && wclk != nullptr && clk != wclk) {
                            if (dbg_validity_runtime)
                                log_info("  invalid-arm: wclk %s: clk %s vs wclk %s\n", nameOf(ff),
                                         clk ? nameOf(clk) : "-", wclk ? nameOf(wclk) : "-");
                            return false;
                        }
                        sr = ff->ffInfo.sr;
                        ce = ff->ffInfo.ce;
                        clkinv = ff->ffInfo.is_clkinv;
                        srinv = ff->ffInfo.is_srinv;
                        islatch = ff->ffInfo.is_latch;
                        ffsync = ff->ffInfo.ffsync;
                    }
                    found_ff[k] = true;
                }
            }
            lts.halfs[i].valid = true;
        } else if (!lts.halfs[i].valid) {
            if (dbg_validity_runtime)
                log_info("  invalid-arm: cached halfs[%d].valid=false\n", i);
            return false;
        }
    }
    return true;
}

void Arch::dumpTileStatus(BelId bel) const
{
    if (!isLogicTile(bel) || !tileStatus[bel.tile].lts)
        return;
    LogicTileStatus &lts = *(tileStatus[bel.tile].lts);
    for (int z = 0; z < 128; z++) {
        if (lts.cells[z] == nullptr)
            continue;
        CellInfo *c = lts.cells[z];
        const char *stale = (c->bel == BelId() || c->bel.tile != bel.tile) ? " [STALE: cell not bound here]" : "";
        log_info("  lts[z=%d eighth=%d slot=%d]: %s (%s)%s\n", z, z >> 4, z & 0xf, nameOf(c), c->type.c_str(this),
                 stale);
    }
    // force a full re-evaluation so the failing arm prints (cached verdicts
    // from the SA phase were computed with the runtime debug flag off)
    for (int i = 0; i < 8; i++)
        lts.eights[i].dirty = true;
    for (int i = 0; i < 2; i++)
        lts.halfs[i].dirty = true;
    log_info("  revalidating tile with arms visible:\n");
    (void)isBelLocationValid(bel);
}

// PACKING ORACLE (NEXTPNR_PACKING_ORACLE=1) ---------------------------------
// Treat an EXTERNALLY STAMPED placement as authoritative and skip our own slice
// legality check for it.
//
// The case this exists for: replaying a Vivado placement.  Vivado packs ~5.16
// primitives per slice where our recognition packer averages 1.82, and it uses
// intra-slice combinations our checker rejects outright -- e.g. an A5FF whose
// partner LUT our model does not expect ("post-placement validity check failed
// for Bel 'SLICE_X210Y29/A5FF' (no cell)").  Those placements are not illegal;
// they are legal silicon that our model is too conservative to describe, and
// the design they came from answers ARP on hardware.
//
// This is NOT --force.  --force downgrades the check globally, including for
// cells WE placed, and the result was 12306 violations and a scrambled
// placement timing 3x worse than Vivado's on the same input.  Here the check is
// waived ONLY for a tile whose every occupant carries a BEL attribute, i.e. one
// placed entirely by the external tool; any tile we have touched is still
// checked exactly as before.
static bool packing_oracle()
{
    static int cached = -1;
    if (cached < 0) {
        const char *e = getenv("NEXTPNR_PACKING_ORACLE");
        cached = (e && *e && *e != '0') ? 1 : 0;
    }
    return cached == 1;
}

// The oracle does TWO separable things: it WAIVES our slice check for a fully
// stamped tile (above), and it EXCLUDES our own cells from such tiles (below).
// Both are right for a WHOLE-DESIGN replay.  In a PARTIAL one -- place_lef
// stamps the fabric, and nextpnr's packer then invents feedthrough and constant
// LUTs -- nearly every occupied tile is fully stamped, so the exclusion pushes
// those invented cells out to distant empty tiles and the routes to reach them
// do not close: measured on ethmin, SKIPS=150 with the exclusion against a
// placement that is otherwise legal.  NEXTPNR_ORACLE_EXCLUDE=0 keeps the waiver
// and drops the exclusion.  Default stays ON so the replay flow is unchanged.
static bool packing_oracle_exclude()
{
    static int cached = -1;
    if (cached < 0) {
        const char *e = getenv("NEXTPNR_ORACLE_EXCLUDE");
        cached = (e == nullptr) ? 1 : ((*e && *e != '0') ? 1 : 0);
    }
    return cached == 1;
}

// A tile counts as externally packed if the cells that came from the DESIGN are
// all stamped.  Cells the PACKER INVENTED are ignored, because they are exactly
// the ones that must be allowed into such a tile: GND/VCC const drivers have to
// sit beside their loads, and route-through LUTs are created for carry S-pins.
// Requiring a literally untouched tile is the wrong test -- measured, it left
// one CLBLL_L rejected for holding $PACKER_GND_NET$LUT$106/$108 and a
// wr_addr[4]$LUT$104 alongside six stamped cells, and that single tile failed
// the whole run.
static bool is_packer_invented(const BaseCtx *ctx, const CellInfo *ci)
{
    std::string n = ci->name.str(ctx);
    return n.find("$PACKER_") != std::string::npos || n.find("$LUT$") != std::string::npos ||
           n.find("$intcell$") != std::string::npos;
}

bool Arch::tileIsFullyStamped(int tile) const
{
    if (!tileStatus[tile].lts)
        return false;
    const LogicTileStatus &lts = *(tileStatus[tile].lts);
    bool any_stamped = false;
    for (int z = 0; z < 128; z++) {
        const CellInfo *ci = lts.cells[z];
        if (ci == nullptr)
            continue;
        if (ci->attrs.count(id("BEL"))) {
            any_stamped = true;
            continue;
        }
        // A cell CONSTRAINED to a stamped one belongs to the imported
        // placement too: repacking a macro (RAM256X1S -> 4 x RAMS64E + a
        // MUXF7/F8 tree) creates children that carry no BEL of their own but
        // are constr_abs_z children of a base that does.  Treating them as
        // foreign would make every repacked tile fail the waiver.
        bool derived = false;
        for (const CellInfo *p = ci->constr_parent; p != nullptr; p = p->constr_parent)
            if (p->attrs.count(id("BEL"))) {
                derived = true;
                break;
            }
        if (derived) {
            any_stamped = true;
            continue;
        }
        if (is_packer_invented(this, ci))
            continue; // ours by necessity, not a foreign packing decision
        return false; // a real design cell we placed -- check the tile normally
    }
    return any_stamped;
}

bool Arch::isBelLocationValid(BelId bel) const
{
    // Partition ROI, enforcement point 3 of 3: the post-bind catch.
    //
    // This MUST be here, above the isLogicTile dispatch, and not folded into
    // usp_bel_hard_unavail. The only usp_bel_hard_unavail sweep in this function
    // is in the terminal else-branch below, which a CLB/CLBLM bel never reaches
    // -- so on exactly the tile class an RM occupies, this function is blind to
    // the hard-unavail mechanism.
    //
    // ONE live path binds an out-of-rectangle bel and relies on this check to
    // undo it -- placer1's SA move path.  Its fast_bels is built unfiltered
    // (common/placer1.cc:89-105, in deliberate contrast to HeAP's :473/:492)
    // and random_bel_for_cell (:846-894) gates only on force_z /
    // check_cell_bel_region / bel_excluded / locked_bels, of which the last two
    // are DEAD in refinement mode -- setup_exclusion_bbox() and the locked_bels
    // insert both sit inside the `if (!refine)` arm.  try_swap_position binds
    // at :619 and validates here at :634; try_swap_chain at :768/:771.  This is
    // not a --placer sa curiosity: HeAP runs it by default via placer1_refine
    // (common/placer_heap.cc:316), so on the default flow this check is the
    // SOLE barrier on that path.
    //
    // HeAP's own legaliser is NOT such a path, though it looks like one.  Its
    // ripup escape (common/placer_heap.cc:1027, `checkBelAvail(sz) || (radius >
    // ripup_radius || rng(20000) < 10)`) does override a false from
    // checkBelAvail -- but the candidate `sz` is drawn from fast_bels, which was
    // built WITH the rectangle applied, so a false there means "occupied" or
    // "hard-unavail", never "outside the rectangle".  The escape cannot reach a
    // bel the rectangle excluded.  That neutralisation is a consequence of the
    // ordering invariant noted at checkBelAvail in arch.h, not of this check.
    //
    // Cell-aware via the bound cell, because a static cell legitimately sits
    // outside the rectangle and must stay valid there.
    if (roi_active() && bel_outside_roi(bel)) {
        CellInfo *bc = getBoundBelCell(bel);
        if (bc != nullptr && is_rm_cell(bc)) {
            ++roi_veto_loc;
            return false;
        }
    }
    IdString belTileType = getBelTileType(bel);
    if (isLogicTile(bel)) {
        // Logic Tile
        if (!tileStatus[bel.tile].lts)
            return true;
        if (packing_oracle() && tileIsFullyStamped(bel.tile))
            return true;
        LogicTileStatus &lts = *(tileStatus[bel.tile].lts);
        if (xc7) {
            bool v = xc7_logic_tile_valid(belTileType, lts);
            if (!v && dbg_validity_runtime)
                log_info("  invalid-check: xc7_logic_tile_valid=false (type %s)\n", belTileType.c_str(this));
            return v;
        } else
            return xcu_logic_tile_valid(belTileType, lts);
    } else if (belTileType == id_BRAM || belTileType == id_BRAM_L || belTileType == id_BRAM_R) {
        if (!tileStatus[bel.tile].bts)
            return true;
        BRAMTileStatus *bts = tileStatus[bel.tile].bts;
        auto onehot = [&](CellInfo *a, CellInfo *b, CellInfo *c) {
            return (((a != nullptr) ? 1 : 0) + ((b != nullptr) ? 1 : 0) + ((c != nullptr) ? 1 : 0)) <= 1;
        };
        // Only one type of BRAM cell at any given location
        if (!onehot(bts->cells[BEL_RAMFIFO36], bts->cells[BEL_RAM36], bts->cells[BEL_FIFO36])) {
            DBG();
            return false;
        }
        if (!onehot(bts->cells[BEL_RAMFIFO18_L], bts->cells[BEL_RAM18_L], bts->cells[BEL_FIFO18_L])) {
            DBG();
            return false;
        }
        // 18-bit BRAMs cannot be used whilst 36-bit is used
        if (bts->cells[BEL_RAMFIFO36] || bts->cells[BEL_RAM36] || bts->cells[BEL_FIFO36]) {
            for (int i = 4; i < 12; i++)
                if (bts->cells[i]) {
                    DBG();
                    return false;
                }
        }
    } else {
        for (auto bel : getBelsByTile(bel.tile % chip_info->width, bel.tile / chip_info->width))
            if (getBoundBelCell(bel) != nullptr && usp_bel_hard_unavail(bel))
                return false;
    }
    return true;
}

bool Arch::isValidBelForCell(CellInfo *cell, BelId bel) const
{
    if (usp_bel_hard_unavail(bel))
        return false;
    // Partition ROI, enforcement point 2 of 3: the per-cell gate.
    //
    // Cell-AWARE, unlike checkBelAvail, and that asymmetry is load-bearing. A
    // static cell sits at whatever bel the import bound it to, which is
    // legitimately outside the rectangle. If this test were bel-only, every
    // static cell would become invalid at its own bel, fixupPlacement would
    // classify the entire locked design as stranded at the strand test below
    // (the `isValidBelForCell(m, m->bel)` sweep in fixupPlacement) -- it does
    // NOT skip them, because its `attrs.count(id("BEL"))` guard is itself inert
    // on a round-tripped netlist -- and the repair loop would try to relocate
    // the static region. The rectangle would destroy the thing it exists to
    // protect.
    //
    // The asymmetry has a cost worth stating: checkBelAvail's rectangle test IS
    // bel-only, so a static cell that somehow becomes stranded cannot be
    // repaired back to its own out-of-rectangle bel (fixupPlacement's restore
    // path re-checks checkBelAvail), and the ring search could relocate it
    // INSIDE the rectangle.  Measured on the adversarial round trip: 16082
    // static cells, 0 moved, 0 entered the rectangle, 0 left unbound.  Latent,
    // not live -- and asserted as such by scripts/partition-roi-evidence.sh,
    // because the RM-side containment check would not notice either failure.
    if (roi_active() && is_rm_cell(cell) && bel_outside_roi(bel)) {
        ++roi_veto_cell;
        return false;
    }
    // A distributed-RAM / SRL LUT (is_memory / is_srl) is only legal in a
    // SLICEM.  Like the 6LUT-on-5LUT gate below, this MUST be enforced at
    // candidate-selection time: the tile-level isBelLocationValid() rejects
    // it only post-hoc, and legalisation can slip a memory/SRL LUT onto a
    // SLICEL bel that the cached tile check then misses -- surfacing much
    // later as an unroutable "Pin 'DI1'/'WE' of bel ... has no associated
    // wire".  This is exactly what happens to the RAMD32/RAMD64 sub-cells
    // pack_dram splits out of a RAM32X1D/RAM64M: they are created UNSTAMPED
    // (no BEL attr), so the placer chooses their bels here.  A cell already
    // carrying a BEL attr is trusted (Vivado/SVS-stamped to a proven SLICEM).
    if (xc7 && cell->type == id_SLICE_LUTX &&
        (cell->lutInfo.is_memory || cell->lutInfo.is_srl) &&
        !cell->attrs.count(id("BEL"))) {
        IdString tt = getBelTileType(bel);
        if (tt != id_CLBLM_L && tt != id_CLBLM_R)
            return false;
    }
    // A LUT that uses any 6LUT-only physical pin -- the A6 input or the O6
    // output -- cannot sit on a 5LUT bel, which has neither (a 5LUT bel is
    // A1..A5 in, O5 out).  The tile-level isBelLocationValid() also rejects the
    // A6 case, but only post-hoc; the placer uses THIS per-candidate gate to
    // choose bels, and legalisation can slip such a LUT onto a 5LUT bel that
    // the cached tile check then misses -- surfacing much later as an
    // unroutable "No wire found for port A6/O6".  A 5LUT bel is identified by
    // the absence of an A6 pin.  The cell needs a 6LUT bel if it draws 6
    // inputs, drives both outputs, or has a connected A6/O6 physical port
    // (the latter covers a LUT whose output was mapped to O6 while at a 6LUT
    // bel and then relocated).
    // (Only gates USER cells: an imported BEL-pinned cell is fixed at a
    // Vivado-proven bel -- e.g. a $trt routethru LUT1 deliberately placed at a
    // free 5LUT -- so it is trusted, not re-validated by this heuristic.)
    // Marker note: at candidate-selection time a STAMPED cell already carries
    // its JSON BEL attr (but isn't bound yet, so belStrength is still NONE),
    // whereas a nextpnr-placed USER cell has no BEL attr until place_initial
    // back-annotates it post-bind.  So the BEL attr is the correct
    // "is-this-a-frozen-cell" test HERE (unlike the post-placement fast-path,
    // which must use belStrength because back-annotation pollutes the attr).
    if (cell->type == id_SLICE_LUTX && !cell->attrs.count(id("BEL")) &&
        getBelPinWire(bel, id_A6) == WireId()) {
        // Count CONNECTED input ports directly rather than lutInfo.input_count:
        // ABC-mapped LUTs still carry logical pin names (I0..I5) at placement
        // time, for which lutInfo (which scans A1..A6) reports 0 -- so an
        // input_count test silently misses them and the placer drops a
        // 6-input LUT onto a 5LUT bel nondeterministically.
        int in_used = 0;
        bool drives_o6 = false;
        for (auto &p : cell->ports) {
            if (p.second.net == nullptr)
                continue;
            if (p.second.type == PORT_IN)
                ++in_used;
            else if (p.first == id_O6)
                drives_o6 = true;
        }
        if (getenv("NEXTPNR_DBG_LUTGATE") && cell->name.str(this).find("47890") != std::string::npos) {
            log_info("LUTGATE %s at 5LUT bel: in_used=%d drives_o6=%d out_count=%d in_count=%d\n",
                     cell->name.c_str(this), in_used, int(drives_o6), cell->lutInfo.output_count,
                     cell->lutInfo.input_count);
            for (auto &p : cell->ports)
                log_info("   port %s type=%d net=%d\n", p.first.c_str(this), int(p.second.type),
                         int(p.second.net != nullptr));
        }
        if (in_used == 6 || cell->lutInfo.output_count == 2 || drives_o6 ||
            get_net_or_empty(cell, id_A6) != nullptr)
            return false;
    }
    // NEXTPNR_PACKING_ORACLE: keep OUR cells out of a tile the external tool
    // has already packed.  The oracle waives our slice check for a fully
    // stamped tile, but only while it STAYS fully stamped -- drop one of our
    // own cells into a Vivado-packed slice and the tile is mixed, the waiver
    // correctly no longer applies, and the run dies on that single tile
    // ("post-placement validity check failed for Bel 'SLICE_X206Y21/A5FF'").
    // The bbox exclusion above cannot do this job here: in a whole-design
    // replay the stamped cells span the entire die, so its bounding box leaves
    // nowhere at all for the handful of cells the packer invents.  This is
    // per-TILE instead, which leaves every untouched tile free.
    if (packing_oracle() && packing_oracle_exclude() && !cell->attrs.count(id("BEL")) &&
        cell->name.str(this).find("$PACKER_") == std::string::npos) {
        // packer const drivers must stay placeable beside their loads
        if (isLogicTile(bel) && tileIsFullyStamped(bel.tile))
            return false;
    }
    // NEXTPNR_EXCLUDE_STAMPED_BBOX was here, and is RETIRED rather than
    // repaired.  Unit 7.6 step 3 scoped a repair -- swap its attrs["BEL"]
    // predicate for the RM snapshot, swap its derived bbox for the partition
    // rectangle, invert the sense -- but carrying that out produces:
    //
    //     if (is_rm_cell(cell) && bel_outside_roi(bel)) return false;
    //
    // which is token-identical to the partition check at the head of this same
    // function (:1073-1076), including the $PACKER_ carve-out, because
    // snapshot_rm_cells() already drops $PACKER_* names.  Sitting ~75 lines
    // BELOW it, the repaired knob could never fire: the earlier check has
    // already returned.  A repair whose product is unreachable code is not a
    // repair, and shipping it would have added a fifth mechanism that looks
    // live and is not.
    //
    // The knob was also inert as written -- it gated on attrs["BEL"], which
    // archInfoToAttributes() erases in favour of NEXTPNR_BEL, so on the
    // round-tripped netlist a DPR static import IS it saw zero stamped cells
    // and derived an empty bbox.  Its sense was inverted from what containment
    // needs, too: it rejected bels INSIDE its box.
    return true;
}

void Arch::fixupPlacement()
{
    if (getenv("DBG_SFEED")) {
        for (auto cell : sorted(cells)) {
            CellInfo *ci = cell.second;
            std::string nm = ci->name.str(this);
            if (nm.find("$LUT$24") != std::string::npos || nm.find("$LUT$26") != std::string::npos)
                log_info("FEEDPOS %s bel=%s strength=%d constr_parent=%s\n", nm.c_str(),
                         ci->bel == BelId() ? "UNBOUND" : getBelName(ci->bel).c_str(this),
                         int(ci->belStrength),
                         ci->constr_parent ? ci->constr_parent->name.c_str(this) : "none");
        }
    }
    log_info("Running post-placement legalisation...\n");
    // Validity-repair pass: some bind paths (heap solution-apply, detailed
    // refine) strand a cell at an invalid bel -- a LUT6 on a 5LUT (its 6th
    // input is invisible at bind time because ABC LUTs carry logical I0..I5
    // pins) or a memory/SRL LUT in a SLICEL.  Relocate each such standalone,
    // non-stamped cell to the nearest valid free bel of its type before the
    // pin-merge fixup below (which assumes a legal placement) runs.
    {
        int gw = chip_info->width, gh = chip_info->height;
        // Collect stranded cluster roots / standalone cells (a LUT+FF pair has
        // the LUT as root and the FF as a constr_z child; the placer can leave
        // the LUT6 root on a 5LUT).  A cell is a root here if it has no parent.
        std::vector<CellInfo *> roots;
        for (auto &cp : cells) {
            CellInfo *ci = cp.second.get();
            if (ci->bel == BelId() || ci->constr_parent != nullptr)
                continue; // only cluster roots / standalone
            if (ci->attrs.count(id("BEL")))
                continue; // stamped: trusted at a proven bel
            // gather the full cluster tree (root + all transitive children)
            std::vector<CellInfo *> tree;
            tree.push_back(ci);
            for (size_t i = 0; i < tree.size(); i++)
                for (auto c : tree[i]->constr_children)
                    tree.push_back(c);
            // CARRY chains span multiple slices/tiles: nextpnr's dedicated carry
            // placer handles them, and this single-tile repair would corrupt
            // their multi-tile geometry -- leave them entirely alone.
            bool has_carry = false;
            for (auto m : tree)
                if (m->type == id_CARRY4) {
                    has_carry = true;
                    break;
                }
            if (has_carry)
                continue;
            bool invalid = false;
            for (auto m : tree)
                if (m->bel != BelId() && !isValidBelForCell(m, m->bel))
                    invalid = true;
            if (invalid)
                roots.push_back(ci);
        }
        int fixed = 0;
        for (CellInfo *root : roots) {
            const bool abs_z = root->constr_abs_z;
            // Full cluster tree (root + all transitive constr_children), root first.
            std::vector<CellInfo *> members;
            members.push_back(root);
            for (size_t i = 0; i < members.size(); i++)
                for (auto c : members[i]->constr_children)
                    members.push_back(c);
            // Compute the bel of every member for a chosen root bel rb, mirroring
            // the placer's cluster BFS: a child's z is abs (constr_z) or relative
            // to its IMMEDIATE parent (parent_z + constr_z) -- this handles nested
            // MUXF7/MUXF8 trees, not just single-level LUT+FF / DRAM clusters.
            auto cluster_bels = [&](BelId rb, std::vector<BelId> &out) -> bool {
                std::vector<std::pair<CellInfo *, Loc>> work;
                work.emplace_back(root, getBelLocation(rb));
                out.clear();
                for (size_t i = 0; i < work.size(); i++) {
                    CellInfo *vc = work[i].first;
                    Loc ploc = work[i].second;
                    BelId tb = getBelByLocation(ploc);
                    if (tb == BelId() || !checkBelAvail(tb) || getBelType(tb) != vc->type ||
                        !isValidBelForCell(vc, tb))
                        return false;
                    out.push_back(tb);
                    for (auto child : vc->constr_children) {
                        Loc cloc = ploc;
                        if (child->constr_z != child->UNCONSTR)
                            cloc.z = child->constr_abs_z ? child->constr_z : (ploc.z + child->constr_z);
                        work.emplace_back(child, cloc);
                    }
                }
                return out.size() == members.size();
            };
            Loc oloc = getBelLocation(root->bel);
            for (auto m : members)
                if (m->bel != BelId())
                    unbindBel(m->bel);
            bool placed = false;
            std::vector<BelId> mbels;
            for (int r = 0; r <= std::max(gw, gh) && !placed; r++)
                for (int dx = -r; dx <= r && !placed; dx++)
                    for (int dy = -r; dy <= r && !placed; dy++) {
                        if (std::max(std::abs(dx), std::abs(dy)) != r)
                            continue;
                        int x = oloc.x + dx, y = oloc.y + dy;
                        if (x < 0 || y < 0 || x >= gw || y >= gh)
                            continue;
                        for (BelId rb : getBelsByTile(x, y)) {
                            if (abs_z && getBelLocation(rb).z != root->constr_z)
                                continue; // abs-z root must sit at its fixed z
                            if (getBelType(rb) != root->type || !checkBelAvail(rb) ||
                                !isValidBelForCell(root, rb))
                                continue;
                            if (!cluster_bels(rb, mbels))
                                continue;
                            for (size_t i = 0; i < members.size(); i++)
                                bindBel(mbels[i], members[i], STRENGTH_STRONG);
                            bool allok = true;
                            for (BelId b : mbels)
                                if (!isBelLocationValid(b)) {
                                    allok = false;
                                    break;
                                }
                            if (allok) {
                                placed = true;
                                break;
                            }
                            for (size_t i = 0; i < members.size(); i++)
                                unbindBel(mbels[i]);
                        }
                    }
            if (!placed) {
                // give up: restore members at their original positions
                std::vector<BelId> obels;
                if (cluster_bels(getBelByLocation(oloc), obels))
                    for (size_t i = 0; i < members.size(); i++) {
                        if (checkBelAvail(obels[i]))
                            bindBel(obels[i], members[i], STRENGTH_WEAK);
                    }
                log_warning("post-place repair: no valid placement for '%s'\n", root->name.c_str(this));
            } else
                ++fixed;
        }
        if (fixed)
            log_info("post-place repair: relocated %d stranded cluster(s)/cell(s) to valid bels\n", fixed);
    }
    // The input remerge below normalises which physical A-pin each net sits on.
    // It used to re-derive the LOGICAL port label from the pin's compacted
    // ordinal in lutInfo.input_sigs -- "I" + to_string(slot).  That is only
    // correct when the incoming pins are already A1..An with no gaps, which is
    // true of nextpnr's own packing and false of any netlist whose pins have
    // been permuted before import: a --no-pack replay of a routed design, i.e.
    // every DPR RM rebuild.  assignCellInfo() COMPACTS the connected pins
    // (pack.cc:1436-1441), so the ordinal is neither the logical index nor the
    // physical one.  On a LUT2 imported as A3<-I1, A5<-I0, A6<-VCC tie, the
    // three occupied pins compact to slots 0,1,2 and the labels come out
    // I0,I1,I2: the "I2" is a port the cell does not have -- fasm.cc's
    // get_lut_init() refuses it -- and, silently, the two real inputs SWAP,
    // which is a wrong truth table with no error at all.
    //
    // The logical identity of a net is a property of the CELL, not of the pin
    // it happens to occupy, so snapshot the labels by net and carry them
    // across.  A pin with no label (a VCC tie has no logical counterpart) stays
    // unlabelled, exactly as it arrived.
    auto snapshot_orig_ports = [&](CellInfo *c, std::unordered_map<IdString, std::string> &out) {
        if (c == nullptr)
            return;
        for (IdString a : {id_A1, id_A2, id_A3, id_A4, id_A5, id_A6}) {
            NetInfo *pn = get_net_or_empty(c, a);
            if (pn == nullptr)
                continue;
            IdString ak = id("X_ORIG_PORT_" + a.str(this));
            if (!c->attrs.count(ak))
                continue;
            std::string tok = c->attrs.at(ak).as_string();
            if (tok.empty())
                continue;
            auto &slot = out[pn->name];
            slot += (slot.empty() ? "" : " ") + tok;
        }
    };
    // Census: measured, not predicted.  `relabel_wrong` is how many labels the
    // old ordinal rule would have got wrong on THIS design -- the size of the
    // defect, reported by the build that would have suffered it.
    int remerged = 0, relabel_kept = 0, relabel_ordinal = 0, relabel_wrong = 0;
    for (auto &ts : tileStatus) {
        if (ts.lts == nullptr)
            continue;
        auto &lt = *(ts.lts);
        for (int z = 0; z < 8; z++) {
            // Fixup LUT connectivity - applies whenever a LUT5 is used
            CellInfo *lut5 = lt.cells[z << 4 | BEL_5LUT];
            if (lut5 == nullptr)
                continue;
            // Skip imported (BEL-pinned) LUT slots: this fixup re-merges the
            // 5LUT/6LUT inputs into <=6 shared physical pins assuming nextpnr's
            // own packing.  Vivado-frozen LUTs route distinct nets to shared
            // A-pins (input-pin permutation), so the by-net unique-input set can
            // exceed 6 and overrun the 6-entry ports[] array (garbage IdString
            // -> out_of_range).  Their pin mapping is already correct from the
            // import; leave it untouched.
            {
                CellInfo *l6 = lt.cells[z << 4 | BEL_6LUT];
                // "Imported" must mean STRENGTH_USER (the strength the
                // BEL-attr placer binds with), NOT STRENGTH_STRONG: that is
                // how HeAP's legaliser binds every chain it places, so at
                // STRENGTH_STRONG this skipped the remerge for every carry
                // chain and mux tree nextpnr itself placed -- leaving the
                // 5LUT and 6LUT of a slot with uncoordinated default pin
                // assignments, i.e. two different nets on the same physical
                // A-pin, which the router reports as one overused SITEWIRE
                // contended by two nets.
                if (lut5->belStrength >= STRENGTH_USER || (l6 && l6->belStrength >= STRENGTH_USER)) {
                    // Skip the INPUT remerge (it would overwrite Vivado's
                    // input-pin permutation), but the cell at the 5LUT bel
                    // still drives O5, not O6: if the imported netlist named
                    // its output O6, rename it to O5 to match the bel, else the
                    // router fails with "No wire found for port O6".
                    if (lut5->ports.count(id_O6)) {
                        rename_port(getCtx(), lut5, id_O6, id_O5);
                        std::string orig = lut5->attrs.count(id("X_ORIG_PORT_O6"))
                                                   ? lut5->attrs.at(id("X_ORIG_PORT_O6")).as_string()
                                                   : std::string("O");
                        lut5->attrs.erase(id("X_ORIG_PORT_O6"));
                        lut5->attrs[id("X_ORIG_PORT_O5")] = orig;
                    }
                    continue;
                }
            }
            std::unordered_map<IdString, std::vector<int>> lut5Inputs, lut6Inputs;
            for (int i = 0; i < lut5->lutInfo.input_count; i++)
                if (lut5->lutInfo.input_sigs[i])
                    lut5Inputs[lut5->lutInfo.input_sigs[i]->name].push_back(i);
            CellInfo *lut6 = lt.cells[z << 4 | BEL_6LUT];
            if (lut6) {
                for (int i = 0; i < lut6->lutInfo.input_count; i++)
                    if (lut6->lutInfo.input_sigs[i])
                        lut6Inputs[lut6->lutInfo.input_sigs[i]->name].push_back(i);
            }
            if (lut5->lutInfo.is_memory || lut5->lutInfo.is_srl) {
                if (lut6) {
                    if (!lut6->ports.count(id_A6)) {
                        lut6->ports[id_A6].name = id_A6;
                        lut6->ports[id_A6].type = PORT_IN;
                    }
                    // pack_srls already ties A6 for 6LUT SRLs -- only
                    // connect when still floating (connect_port asserts
                    // on an already-driven port)
                    if (lut6->ports.at(id_A6).net == nullptr)
                        connect_port(getCtx(), nets[id("$PACKER_VCC_NET")].get(), lut6, id_A6);
                }
                continue;
            }
            std::set<IdString> uniqueInputs;
            for (auto i5 : lut5Inputs)
                uniqueInputs.insert(i5.first);
            for (auto i6 : lut6Inputs)
                uniqueInputs.insert(i6.first);
            // A slot cannot hold more than 6 distinct inputs; if it does the
            // input-remerge below would overrun ports[6] (garbage IdString ->
            // out_of_range).  Never legal for a properly-packed slot, so log
            // the offenders and skip rather than crash.
            if (uniqueInputs.size() > 6) {
                CellInfo *l6 = lt.cells[z << 4 | BEL_6LUT];
                log_warning("fixupPlacement: slot with %d unique inputs (>6): lut5=%s(str%d) lut6=%s(str%d); skip\n",
                            int(uniqueInputs.size()), nameOf(lut5), int(lut5->belStrength),
                            l6 ? nameOf(l6) : "-", l6 ? int(l6->belStrength) : -1);
                continue;
            }
            std::unordered_map<IdString, std::string> lut5_orig, lut6_orig;
            snapshot_orig_ports(lut5, lut5_orig);
            snapshot_orig_ports(lut6, lut6_orig);
            ++remerged;
            // Write the logical label for `net` at `port`, carrying it over from
            // the snapshot.  Falls back to the historic ordinal derivation only
            // for a cell that arrived with no labels at all, so a netlist this
            // pass has always been the sole labeller of is untouched.
            auto write_orig = [&](CellInfo *c, IdString port, IdString net,
                                  const std::unordered_map<IdString, std::string> &snap,
                                  const std::unordered_map<IdString, std::vector<int>> &slots) {
                IdString ak = id("X_ORIG_PORT_" + port.str(this));
                std::string ordinal;
                if (slots.count(net)) {
                    bool first = true;
                    for (auto inp : slots.at(net)) {
                        ordinal += (first ? "I" : " I") + std::to_string(inp);
                        first = false;
                    }
                }
                auto it = snap.find(net);
                if (it == snap.end()) {
                    if (snap.empty()) {
                        c->attrs[ak] = ordinal;
                        ++relabel_ordinal;
                    } else {
                        // An unlabelled pin -- a constant tie -- has no logical
                        // counterpart and must not acquire one.
                        c->attrs.erase(ak);
                        if (!ordinal.empty())
                            ++relabel_wrong;
                    }
                    return;
                }
                c->attrs[ak] = it->second;
                ++relabel_kept;
                if (it->second != ordinal)
                    ++relabel_wrong;
            };
            // Disconnect LUT inputs, and re-connect them to not overlap
            IdString ports[6] = {id_A1, id_A2, id_A3, id_A4, id_A5, id_A6};
            for (auto p : ports) {
                disconnect_port(getCtx(), lut5, p);
                lut5->attrs.erase(id("X_ORIG_PORT_" + p.str(this)));
                if (lut6) {
                    lut6->attrs.erase(id("X_ORIG_PORT_" + p.str(this)));
                    disconnect_port(getCtx(), lut6, p);
                }
            }
            int index = 0;
            for (auto i : uniqueInputs) {
                if (lut5Inputs.count(i)) {
                    if (!lut5->ports.count(ports[index])) {
                        lut5->ports[ports[index]].name = ports[index];
                        lut5->ports[ports[index]].type = PORT_IN;
                    }
                    connect_port(getCtx(), nets.at(i).get(), lut5, ports[index]);
                    write_orig(lut5, ports[index], i, lut5_orig, lut5Inputs);
                }
                if (lut6 && lut6Inputs.count(i)) {
                    if (!lut6->ports.count(ports[index])) {
                        lut6->ports[ports[index]].name = ports[index];
                        lut6->ports[ports[index]].type = PORT_IN;
                    }
                    connect_port(getCtx(), nets.at(i).get(), lut6, ports[index]);
                    write_orig(lut6, ports[index], i, lut6_orig, lut6Inputs);
                }
                ++index;
            }
            rename_port(getCtx(), lut5, id_O6, id_O5);
            lut5->attrs.erase(id("X_ORIG_PORT_O6"));
            lut5->attrs[id("X_ORIG_PORT_O5")] = std::string("O");

            if (lut6) {
                if (!lut6->ports.count(id_A6)) {
                    lut6->ports[id_A6].name = id_A6;
                    lut6->ports[id_A6].type = PORT_IN;
                }
                // Only tie A6 to VCC when still floating: the input de-dup above
                // may already have routed a shared input onto A6 (connect_port
                // asserts on an already-driven port -- same guard as the SRL A6 tie).
                if (lut6->ports.at(id_A6).net == nullptr)
                    connect_port(getCtx(), nets[id("$PACKER_VCC_NET")].get(), lut6, id_A6);
            }
        }
    }
    if (remerged)
        log_info("LUT input remerge: %d slot(s); labels carried %d, ordinal-derived %d, "
                 "corrected %d\n",
                 remerged, relabel_kept, relabel_ordinal, relabel_wrong);
    for (auto cell : sorted(cells)) {
        CellInfo *ci = cell.second;
        if (ci->type == id("PSS_ALTO_CORE")) {
            log_info("Tieing unused PSS inputs to constants...\n");
            for (IdString pname : getBelPins(ci->bel)) {
                if (ci->ports.count(pname) && ci->ports.at(pname).net != nullptr &&
                    ci->ports.at(pname).net->driver.cell != nullptr)
                    continue;
                if (getBelPinType(ci->bel, pname) == PORT_OUT)
                    continue;
                std::string name = pname.str(this);
                if (name.find("_PAD_") != std::string::npos)
                    continue;
                if (name.find("PSVERSION") != std::string::npos || name.find("PSSGTS") != std::string::npos ||
                    name == "PSSGPWRDWNB" || name == "PSSGHIGHB" || name == "PSSFSTCFGB" || name == "PSSCFGRESETB" ||
                    name == "PCFGPORB" || name.find("IDCODE") != std::string::npos ||
                    name.find("BSCAN") != std::string::npos)
                    continue;
                bool constval = false;
                if (name == "NIRQ1LPDRPU" || name == "NIRQ0LPDRPU" || name == "NFIQ1LPDRPU" || name == "NFIQ0LPDRPU")
                    constval = true;
                if (boost::ends_with(name, "SSIN") || name == "EMIOSDIO1WP" || name == "EMIOSDIO0WP" ||
                    boost::ends_with(name, "RSOP") || boost::ends_with(name, "REOP") ||
                    boost::ends_with(name, "GMIITXCLK") || name == "DPVIDEOINCLK" || name == "DPSAXISAUDIOCLK")
                    constval = true;
                ci->ports[pname].name = pname;
                ci->ports[pname].type = PORT_IN;
                if (ci->ports[pname].net != nullptr) {
                    disconnect_port(getCtx(), ci, pname);
                    ci->attrs.erase(id("X_ORIG_PORT_" + name));
                }
                connect_port(getCtx(), nets[constval ? id("$PACKER_VCC_NET") : id("$PACKER_GND_NET")].get(), ci, pname);
            }
        } else if (ci->type == id_PS7_PS7) {
            log_info("Tieing unused PS7 inputs to constants...\n");
            for (IdString pname : getBelPins(ci->bel)) {
                if (ci->ports.count(pname) && ci->ports.at(pname).net != nullptr &&
                    ci->ports.at(pname).net->driver.cell != nullptr)
                    continue;
                if (getBelPinType(ci->bel, pname) != PORT_IN)
                    continue;
                std::string name = pname.str(this);
                if (name.find("_PAD_") != std::string::npos)
                    continue;
                if (boost::starts_with(name, "TEST") || boost::starts_with(name, "DEBUGSELECT") ||
                    boost::starts_with(name, "MIO") || boost::starts_with(name, "DDR"))
                    continue;
                bool constval = false;
                ci->ports[pname].name = pname;
                ci->ports[pname].type = PORT_IN;
                if (ci->ports[pname].net != nullptr) {
                    disconnect_port(getCtx(), ci, pname);
                    ci->attrs.erase(id("X_ORIG_PORT_" + name));
                }
                connect_port(getCtx(), nets[constval ? id("$PACKER_VCC_NET") : id("$PACKER_GND_NET")].get(), ci, pname);
            }
        } else if (ci->type == id("BITSLICE_CONTROL_BEL")) {
            std::unordered_map<IdString, bool> constpins;
            constpins[id("EN_VTC")] = true;
            constpins[id("DLY_TEST_IN")] = false;
            constpins[id("RIU_NIBBLE_SEL")] = false;
            constpins[id("TBYTE_IN0")] = false;
            constpins[id("TBYTE_IN1")] = false;
            constpins[id("TBYTE_IN2")] = false;
            constpins[id("TBYTE_IN3")] = false;

            for (auto p : constpins) {
                if (get_net_or_empty(ci, p.first) != nullptr)
                    continue;
                ci->ports[p.first].name = p.first;
                ci->ports[p.first].type = PORT_IN;
                connect_port(getCtx(), nets[p.second ? id("$PACKER_VCC_NET") : id("$PACKER_GND_NET")].get(), ci,
                             p.first);
            }
        }
    }
    // Update the set of reserved wires
    reserved_wires.clear();

    auto get_bouncewire = [&](int tile, IdString swname) {
        auto &td = chip_info->tile_types[chip_info->tile_insts[tile].type];
        WireId sitewire;
        for (int i = 0; i < td.num_wires; i++) {
            auto &w = td.wire_data[i];
            if (w.site != -1 && w.name == swname.index) {
                sitewire.tile = tile;
                sitewire.index = i;
                break;
            }
        }
        NPNR_ASSERT(sitewire != WireId());
        WireId cursor = sitewire;
        while (wireIntent(cursor) != ID_NODE_PINBOUNCE) {
            auto uh = getPipsUphill(cursor);
            NPNR_ASSERT(uh.begin() != uh.end());
            cursor = getPipSrcWire(*(uh.begin()));
        }
        return cursor;
    };
    if (!xc7) {
        for (int tile = 0; tile < chip_info->num_tiles; ++tile) {
            auto &ts = tileStatus[tile];
            if (ts.lts == nullptr)
                continue;
            auto &lts = *(ts.lts);
            for (int z = 0; z < 8; z++) {
                CellInfo *lut5 = lts.cells[z << 4 | BEL_5LUT];
                CellInfo *lut6 = lts.cells[z << 4 | BEL_6LUT];
                NetInfo *i_net = nullptr, *x_net = nullptr;
                // Check usage of DI and X inputs
                if (lut6 != nullptr) {
                    i_net = lut6->lutInfo.di1_net;
                    x_net = lut6->lutInfo.di2_net;
                }
                if (lut5 != nullptr) {
                    if (lut5->lutInfo.di1_net != nullptr)
                        i_net = lut5->lutInfo.di1_net;
                }

                CellInfo *mux = nullptr;
                // Eights A, C, E, G: F7MUX uses X input
                if (z == 0 || z == 2 || z == 4 || z == 6)
                    mux = lts.cells[z << 4 | BEL_F7MUX];
                // Eights B, F: F8MUX uses X input
                if (z == 1 || z == 5)
                    mux = lts.cells[(z - 1) << 4 | BEL_F8MUX];
                // Eights D: F9MUX uses X input
                if (z == 3)
                    mux = lts.cells[BEL_F9MUX];

                if (mux != nullptr)
                    if (x_net == nullptr)
                        x_net = mux->muxInfo.sel;

                CellInfo *carry8 = lts.cells[BEL_CARRY8];
                // CARRY8 might use X
                if (carry8 != nullptr && carry8->carryInfo.x_sigs[z] != nullptr) {
                    if (x_net == nullptr)
                        x_net = carry8->carryInfo.x_sigs[z];
                }

                CellInfo *out_fmux = nullptr;
                // Eights B, D, F, H: F7MUX connects to F7F8 out
                if (z == 1 || z == 3 || z == 5 || z == 7)
                    out_fmux = lts.cells[(z - 1) << 4 | BEL_F7MUX];
                // Eights C, G: F8MUX connects to F7F8 out
                if (z == 2 || z == 6)
                    out_fmux = lts.cells[(z - 2) << 4 | BEL_F8MUX];
                // Eights E: F9MUX connects to F7F8 out
                if (z == 4)
                    out_fmux = lts.cells[BEL_F9MUX];

                // FF1 might use X, if it isn't driven directly
                CellInfo *ff1 = lts.cells[z << 4 | BEL_FF];
                if (ff1 != nullptr && ff1->ffInfo.d != nullptr && ff1->ffInfo.d->driver.cell != nullptr) {
                    auto &drv = ff1->ffInfo.d->driver;
                    if ((drv.cell == lut6 && drv.port != id_MC31) || drv.cell == lut5 || drv.cell == out_fmux) {
                        // Direct, OK
                    } else {
                        // Indirect, must use X input
                        x_net = ff1->ffInfo.d;
                    }
                }

                // FF2 might use I, if it isn't driven directly
                CellInfo *ff2 = lts.cells[z << 4 | BEL_FF2];
                if (ff2 != nullptr && ff2->ffInfo.d != nullptr && ff2->ffInfo.d->driver.cell != nullptr) {
                    auto &drv = ff2->ffInfo.d->driver;
                    if ((drv.cell == lut6 && drv.port != id_MC31) || drv.cell == lut5 || drv.cell == out_fmux) {
                        // Direct, OK
                    } else {
                        // Indirect, must use X input
                        i_net = ff2->ffInfo.d;
                    }
                }

                if (x_net != nullptr) {
                    WireId x_wire = get_bouncewire(tile, id(std::string("") + char('A' + z) + std::string("X")));
                    reserved_wires[x_wire] = x_net;
                }
                if (i_net != nullptr) {
                    WireId i_wire = get_bouncewire(tile, id(std::string("") + char('A' + z) + std::string("_I")));
                    reserved_wires[i_wire] = i_net;
                }
            }
        }
    }
}

void Arch::bindDedicatedPads()
{
    // DEDICATED PAD CONNECTIONS ARE IMPLICIT -- recognise them from the routing
    // graph, not from a list of cell or pin names.
    //
    // A transceiver's serial pins (GTXRXP/N, GTXTXP/N) and its refclk pair reach
    // the package directly: there is no fabric path between the GT site wire and
    // the IPAD/OPAD site wire, so the chipdb gives those wires NO PIPS AT ALL,
    // uphill or downhill.  A wire outside the routing graph cannot be routed to,
    // and the router should not try -- left alone it burns a full search and then
    // reports
    //   SKIP_FAILED_ARCS: failed to route arc 0 of net 'sgmii_txn'
    //     (SITEWIRE/GTXE2_CHANNEL_X1Y1/GTXTXN -> SITEWIRE/OPAD_X1Y2/OPAD_O)
    // which is noise that raises the floor under NEXTPNR_SKIP_FAILED_ARCS and
    // makes a REAL failure easy to miss.
    //
    // "No pips on the wire" is the device model stating the connection is
    // dedicated, so bind it at STRENGTH_LOCKED.  router2 already honours that:
    // its "arcs that were pre-routed strongly (e.g. clocks)" test returns
    // ARC_SUCCESS for a sink wire bound above STRENGTH_STRONG.
    auto wire_is_dedicated = [&](WireId w) {
        if (w == WireId())
            return false;
        // Uphill/DownhillPipRange are iterator ranges, not containers.
        for (auto p : getPipsUphill(w)) {
            (void)p;
            return false;
        }
        for (auto p : getPipsDownhill(w)) {
            (void)p;
            return false;
        }
        return true;
    };
    int n_implicit = 0;
    for (auto cell : sorted(cells)) {
        CellInfo *ci = cell.second;
        if (ci->type != id("PAD") && ci->type != id("IOB_PAD"))
            continue;
        if (ci->bel == BelId())
            continue;
        WireId pad_wire = getBelPinWire(ci->bel, id("PAD"));
        if (!wire_is_dedicated(pad_wire))
            continue;               // ordinary IOB: fall through to the BFS below
        NetInfo *pad_net = ci->ports.count(id("PAD")) ? ci->ports[id("PAD")].net : nullptr;
        if (pad_net == nullptr)
            continue;
        if (!getBoundWireNet(pad_wire))
            bindWire(pad_wire, pad_net, STRENGTH_LOCKED);
        // and the far end, so the arc in EITHER direction counts as pre-routed
        if (pad_net->driver.cell != nullptr) {
            WireId drv = getCtx()->getNetinfoSourceWire(pad_net);
            if (drv != WireId() && drv != pad_wire && !getBoundWireNet(drv))
                bindWire(drv, pad_net, STRENGTH_LOCKED);
        }
        for (auto &usr : pad_net->users) {
            WireId snk = getCtx()->getNetinfoSinkWire(pad_net, usr);
            if (snk != WireId() && snk != pad_wire && !getBoundWireNet(snk))
                bindWire(snk, pad_net, STRENGTH_LOCKED);
        }
        ++n_implicit;
    }
    if (n_implicit > 0)
        log_info("    %d dedicated pad net(s) pre-bound as implicit (no pips on the pad wire)\n", n_implicit);
}

void Arch::fixupRouting()
{
    log_info("Running post-routing legalisation...\n");
    /*
     * Convert LUT permutation into correct physical connections (i.e. effectively eliminating the permutation pips),
     * then specifying the permutation as a new physical-to-logical mapping using X_ORIG_PORT. This keeps RapidWright
     * and Vivado happy, preserving the original logical netlist
     */
    std::unordered_map<int, std::vector<int>> used_perm_pips; // tile -> [extra_data] for LUT perm pips
    // Accounting for the two ways this rewrite can silently damage the netlist it
    // is meant to relabel.  Both were found by comparing a route-lock replay's
    // written JSON against the reference build's: the FASM was identical and the
    // netlist was not, which is invisible to a FASM gate and fatal to the next
    // build that re-imports the JSON.
    int perm_label_no_net = 0; // X_ORIG_PORT suppressed because connect_port() had a null net
    int perm_dropped_nets = 0; // input connections this pass removed and did not put back
    std::string perm_dropped_first;

    for (auto net : sorted(nets)) {
        NetInfo *ni = net.second;
        for (auto &wire : ni->wires) {
            PipId pip = wire.second.pip;
            if (pip == PipId())
                continue;
            auto &pd = locInfo(pip).pip_data[pip.index];
            if (pd.flags != PIP_LUT_PERMUTATION)
                continue;
            used_perm_pips[pip.tile].push_back(pd.extra_data);
        }
    }

    for (size_t ti = 0; ti < tileStatus.size(); ti++) {
        if (!used_perm_pips.count(int(ti)))
            continue;
        auto &ts = tileStatus.at(ti);
        if (ts.lts == nullptr)
            continue;

        auto &lt = *(ts.lts);
        for (int z = 0; z < 8; z++) {
            CellInfo *lut5 = lt.cells[z << 4 | BEL_5LUT];
            CellInfo *lut6 = lt.cells[z << 4 | BEL_6LUT];
            if (lut5 == nullptr && lut6 == nullptr)
                continue;
            auto &pp = used_perm_pips.at(ti);
            // from -> to
            std::unordered_map<IdString, std::vector<IdString>> new_connections;
            IdString ports[6] = {id_A1, id_A2, id_A3, id_A4, id_A5, id_A6};
            for (auto pip : pp) {
                if (((pip >> 8) & 0xF) != z)
                    continue;
                new_connections[ports[(pip >> 4) & 0xF]].push_back(ports[pip & 0xF]);
            }
            std::unordered_map<IdString, NetInfo *> orig_nets;
            std::unordered_map<IdString, std::string> orig_ports_l6, orig_ports_l5;
            for (int i = 0; i < 6; i++) {
                NetInfo *l6net = lut6 ? get_net_or_empty(lut6, ports[i]) : nullptr;
                NetInfo *l5net = lut5 ? get_net_or_empty(lut5, ports[i]) : nullptr;
                orig_nets[ports[i]] = (l6net ? l6net : l5net);
                if (lut6)
                    orig_ports_l6[ports[i]] = str_or_default(lut6->attrs, id("X_ORIG_PORT_" + ports[i].str(this)));
                if (lut5)
                    orig_ports_l5[ports[i]] = str_or_default(lut5->attrs, id("X_ORIG_PORT_" + ports[i].str(this)));
            }
            // Per-CELL snapshot, unlike orig_nets above, which merges the pair.
            // Used only to check afterwards that nothing was lost.
            NetInfo *l6_before[6] = {nullptr, nullptr, nullptr, nullptr, nullptr, nullptr};
            NetInfo *l5_before[6] = {nullptr, nullptr, nullptr, nullptr, nullptr, nullptr};
            for (int i = 0; i < 6; i++) {
                l6_before[i] = lut6 ? get_net_or_empty(lut6, ports[i]) : nullptr;
                l5_before[i] = lut5 ? get_net_or_empty(lut5, ports[i]) : nullptr;
            }
            for (auto &nc : new_connections) {
                if (lut6)
                    disconnect_port(getCtx(), lut6, nc.first);
                if (lut5)
                    disconnect_port(getCtx(), lut5, nc.first);
                for (auto &dst : nc.second) {
                    if (lut6)
                        disconnect_port(getCtx(), lut6, dst);
                    if (lut5)
                        disconnect_port(getCtx(), lut5, dst);
                }
            }
            for (int i = 0; i < 6; i++) {
                if (lut6)
                    lut6->attrs.erase(id("X_ORIG_PORT_" + ports[i].str(this)));
                if (lut5)
                    lut5->attrs.erase(id("X_ORIG_PORT_" + ports[i].str(this)));
            }
            for (int i = 0; i < 6; i++) {
                auto p = ports[i];
                if (!new_connections.count(p) || new_connections.at(p).empty())
                    continue;
                // Only a pin the cell's OWN bel actually has may be connected.
                // The two LUTs of a slot share the slice's A1..A6 SITE wires, so
                // a permutation pip recorded for the slot was applied to BOTH
                // cells -- but the 5LUT BEL has no A6 pin at all, so the 5LUT
                // cell acquired an A6 port whose bel pin does not exist.
                // Harmless while it lasts (fixupRouting runs after routing, and
                // the FASM writer ignores a pin with no X_ORIG_PORT), but it is
                // written into the JSON, and re-importing that JSON aborts in
                // router2's setup_nets with "No wire found for port A6 on
                // destination cell ..." -- the R2 static-import blocker.  It is
                // also the exact state xc7_logic_tile_valid() already rejects
                // (get_net_or_empty(lut5, id_A6) != nullptr); only the frozen-
                // tile fast path stops that check from firing on an import.
                if (lut6 && getBelPinWire(lut6->bel, p) != WireId()) {
                    if (!lut6->ports.count(p)) {
                        lut6->ports[p].name = p;
                        lut6->ports[p].type = PORT_IN;
                    }
                    NetInfo *newnet = orig_nets[new_connections.at(p).front()];
                    connect_port(getCtx(), newnet, lut6, p);
                    // connect_port() RETURNS SILENTLY on a null net
                    // (common/design_utils.cc), so writing the label
                    // unconditionally manufactured an X_ORIG_PORT on a pin with
                    // no net at all -- 1,641 cells' worth in a route-lock replay,
                    // and a self-inconsistency in every consumer of the JSON.
                    // A pin with no net has no label.
                    if (newnet == nullptr) {
                        perm_label_no_net++;
                    } else {
                        lut6->attrs[id("X_ORIG_PORT_" + p.str(this))] = std::string("");
                        auto &orig_attr = lut6->attrs[id("X_ORIG_PORT_" + p.str(this))].str;
                        bool first = true;
                        for (auto &nc : new_connections.at(p)) {
                            // Separator goes BETWEEN labels, not after each one:
                            // suffixing fused the pins into "I0I1 ", which Vivado
                            // rejects on import as "InstTerm I0I1 does not exist".
                            //
                            // An EMPTY label is skipped rather than emitted, and
                            // skipping it does not consume the first-element slot.
                            // A label-before separator alone still renders
                            // {"", "I1"} as " I1", and a reader that splits on " "
                            // sees a leading empty token.  The consumer in
                            // xilinx/fasm.cc scans I<digits> instead of splitting
                            // on the delimiter, so it cannot alias an empty token
                            // onto logical input I0 either -- both halves refusing
                            // empties is what makes the property hold without
                            // depending on the other half.
                            const std::string &lbl = orig_ports_l6[nc];
                            if (lbl.empty())
                                continue;
                            if (!first)
                                orig_attr += " ";
                            orig_attr += lbl;
                            first = false;
                        }
                        if (orig_attr.empty())
                            lut6->attrs.erase(id("X_ORIG_PORT_" + p.str(this)));
                    }
                }
                // Same bel-pin guard as the LUT6 block above.  This is the one
                // that matters in practice: p == A6 on a 5LUT bel.
                if (lut5 && getBelPinWire(lut5->bel, p) != WireId()) {
                    if (!lut5->ports.count(p)) {
                        lut5->ports[p].name = p;
                        lut5->ports[p].type = PORT_IN;
                    }
                    NetInfo *newnet = orig_nets[new_connections.at(p).front()];
                    connect_port(getCtx(), newnet, lut5, p);
                    if (newnet == nullptr) {
                        // Same suppression as the LUT6 block above.
                        perm_label_no_net++;
                    } else {
                        lut5->attrs[id("X_ORIG_PORT_" + p.str(this))] = std::string("");
                        auto &orig_attr = lut5->attrs[id("X_ORIG_PORT_" + p.str(this))].str;
                        bool first = true;
                        for (auto &nc : new_connections.at(p)) {
                            // Same fix as the LUT6 block above.
                            const std::string &lbl = orig_ports_l5[nc];
                            if (lbl.empty())
                                continue;
                            if (!first)
                                orig_attr += " ";
                            orig_attr += lbl;
                            first = false;
                        }
                        if (orig_attr.empty())
                            lut5->attrs.erase(id("X_ORIG_PORT_" + p.str(this)));
                    }
                }
            }
            // A permutation is a RELABELLING: every net on the slot's inputs
            // before this rewrite must still be on one of them after it.  The
            // disconnect phase above clears both the source and the destination
            // of every permutation pip but the reconnect phase only refills
            // destinations, so a net sitting on a port that is neither -- which
            // is what an imprecise route-lock pin alignment produces -- is
            // DELETED, silently, with the FASM unaffected.  Count it; a netlist
            // defect that costs nothing to detect must not be silent again.
            for (int c = 0; c < 2; c++) {
                CellInfo *cc = (c == 0) ? lut6 : lut5;
                NetInfo **before = (c == 0) ? l6_before : l5_before;
                if (cc == nullptr)
                    continue;
                for (int i = 0; i < 6; i++) {
                    if (before[i] == nullptr)
                        continue;
                    bool still = false;
                    for (int k = 0; k < 6; k++)
                        if (get_net_or_empty(cc, ports[k]) == before[i])
                            still = true;
                    if (still)
                        continue;
                    if (perm_dropped_nets++ == 0)
                        perm_dropped_first = std::string(nameOf(cc)) + "/" + ports[i].str(this) + " ('" +
                                             nameOf(before[i]) + "')";
                }
            }
        }
    }
    if (perm_label_no_net > 0)
        log_info("LUT permutation rewrite: %d X_ORIG_PORT label(s) suppressed on pins left with no net\n",
                 perm_label_no_net);
    if (perm_dropped_nets > 0)
        log_warning("LUT permutation rewrite DROPPED %d LUT input connection(s) (first: %s). The written "
                    "netlist no longer matches the design; the FASM is unaffected, so this is invisible to a "
                    "FASM comparison and fatal to anything that re-imports the JSON.\n",
                    perm_dropped_nets, perm_dropped_first.c_str());
    /*
     * Route PAD nets which won't have been routed due to inout issues
     */
    auto route_bfs = [&](NetInfo *net, WireId src, WireId dst) {
        if (src == dst)
            return;
        std::queue<WireId> visit;
        std::unordered_map<WireId, PipId> backtrace;
        visit.push(dst);
        WireId cursor;
        while (!visit.empty()) {
            WireId curr = visit.front();
            visit.pop();
            for (auto uh : getPipsUphill(curr)) {
                if (!checkPipAvail(uh))
                    continue;
                WireId pip_src = getPipSrcWire(uh);
                if (pip_src == src) {
                    cursor = curr;
                    break;
                }
                if (backtrace.count(pip_src))
                    continue;
                if (!checkWireAvail(pip_src))
                    continue;
                backtrace[pip_src] = uh;
                visit.push(pip_src);
            }
        }
        NPNR_ASSERT(cursor != WireId());
        while (backtrace.count(cursor)) {
            auto uh = backtrace[cursor];
            cursor = getPipDstWire(uh);
            if (!getBoundWireNet(cursor))
                bindWire(cursor, net, STRENGTH_STRONG);
            bindPip(uh, net, STRENGTH_STRONG);
        }
    };

    for (auto cell : sorted(cells)) {
        CellInfo *ci = cell.second;
        if (ci->type == id("IOB_PAD")) {
            NetInfo *pad_net = ci->ports[id("PAD")].net;
            NPNR_ASSERT(pad_net != nullptr && nets.count(pad_net->name));
            std::vector<WireId> unbind;
            for (auto w : pad_net->wires)
                if (getBoundWireNet(w.first))
                    unbind.push_back(w.first);
            for (auto w : unbind)
                unbindWire(w);
            WireId pad_wire = getBelPinWire(ci->bel, id("PAD"));
            bindWire(pad_wire, pad_net, STRENGTH_LOCKED);
            if (pad_net->driver.cell != nullptr) {
                WireId drv_wire = getCtx()->getNetinfoSourceWire(pad_net);
                if (drv_wire != pad_wire)
                    bindWire(drv_wire, pad_net, STRENGTH_LOCKED);
                route_bfs(pad_net, drv_wire, pad_wire);
            }
            for (auto &usr : pad_net->users) {
                if (usr.cell == ci)
                    continue;
                route_bfs(pad_net, pad_wire, getCtx()->getNetinfoSinkWire(pad_net, usr));
            }
        }
    }

    /*
     * Legalise route through OSERDESE3s
     */
    for (auto cell : sorted(cells)) {
        CellInfo *ci = cell.second;
        if (ci->type == id("OSERDESE3")) {
            if (get_net_or_empty(ci, id("T_OUT")) != nullptr)
                continue;
            ci->params[id("OSERDES_T_BYPASS")] = std::string("TRUE");
        }
    }
}

NEXTPNR_NAMESPACE_END
