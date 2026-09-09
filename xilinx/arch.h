/*
 *  nextpnr -- Next Generation Place and Route
 *
 *  Copyright (C) 2018  Clifford Wolf <clifford@symbioticeda.com>
 *  Copyright (C) 2018-19  David Shah <david@symbioticeda.com>
 *
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

#ifndef NEXTPNR_H
#error Include "arch.h" via "nextpnr.h" only.
#endif

#include <unordered_set>
#include <boost/iostreams/device/mapped_file.hpp>

#include <iostream>

NEXTPNR_NAMESPACE_BEGIN

/**** Everything in this section must be kept in sync with chipdb.py ****/

template <typename T> struct RelPtr
{
    int32_t offset;

    // void set(const T *ptr) {
    //     offset = reinterpret_cast<const char*>(ptr) -
    //              reinterpret_cast<const char*>(this);
    // }

    const T *get() const
    {
        return reinterpret_cast<const T *>(reinterpret_cast<const char *>(this) + int64_t(offset) * 4);
    }

    const T &operator[](size_t index) const { return get()[index]; }

    const T &operator*() const { return *(get()); }

    const T *operator->() const { return get(); }
};

// Quasi-deduplicated architecture
//
// Stored once per tile type (tile instance is pointer to type)
//  - Pips (referencing tile wire indices)
//  - Bels
//  - Tile-local wires
//
// Stored once per tile instance
//  - Tile wire info
//    - pointer to node for nodal wires
//
// Stored once per unique "node variety"
//  - Pips uphill and downhill (rel coordinate, tile wire index)
//  - Bel ports uphill and downhill (rel coordinate, index in tile, port name constid)
//
// Stored once per node instance
//  - Variety index
//  - List of tile wires
//  - Type information

NPNR_PACKED_STRUCT(struct BelWirePOD {
    int32_t port;       // port name constid
    int32_t type;       // port type (IN/OUT/BIDIR)
    int32_t wire_index; // connected wire index in tile, or -1 if NA
});

// LSnibble of Z: function
// MSnibble of Z: index in CLB (A-H)
enum LogicBelTypeZ
{
    BEL_6LUT = 0x0,
    BEL_5LUT = 0x1,
    BEL_FF = 0x2,
    BEL_FF2 = 0x3,
    BEL_FFMUX1 = 0x4,
    BEL_FFMUX2 = 0x5,
    BEL_OUTMUX = 0x6,
    BEL_F7MUX = 0x7,
    BEL_F8MUX = 0x8,
    BEL_F9MUX = 0x9,
    BEL_CARRY8 = 0xA,
    BEL_CLKINV = 0xB,
    BEL_RSTINV = 0xC,
    BEL_HARD0 = 0xD,
    BEL_CARRY4 = 0xF
};

enum BRAMBelTypeZ
{
    BEL_RAMFIFO36 = 0,
    BEL_RAM36 = 1,
    BEL_FIFO36 = 2,

    BEL_RAM18_U = 5,

    BEL_RAMFIFO18_L = 8,
    BEL_RAM18_L = 9,
    BEL_FIFO18_L = 10,
};

enum DSP48E1BelTypeZ
{
    BEL_LOWER_DSP=6,
    BEL_UPPER_DSP=25,
};

enum DSP48E2BelTypeZ
{
    BEL_DSP_PREADD_DATA = 0,
    BEL_DSP_PREADD = 1,
    BEL_DSP_A_B_DATA = 2,
    BEL_DSP_MULTIPLIER = 3,
    BEL_DSP_C_DATA = 4,
    BEL_DSP_M_DATA = 5,
    BEL_DSP_ALU = 6,
    BEL_DSP_OUTPUT = 7
};

NPNR_PACKED_STRUCT(struct BelInfoPOD {
    int32_t name;        // bel name (in site) constid
    int32_t type;        // compatible type name constid
    int32_t xl_type;     // xilinx type name constid
    int32_t timing_inst; // timing instance index in tile

    int32_t num_bel_wires;
    RelPtr<BelWirePOD> bel_wires;
    int16_t z;
    int16_t site;
    int16_t site_variant; // some sites have alternative types
    int16_t is_routing;
});

NPNR_PACKED_STRUCT(struct BelPortPOD {
    int32_t bel_index;
    int32_t port;
});

enum PipType
{
    PIP_TILE_ROUTING = 0,
    PIP_SITE_ENTRY = 1,
    PIP_SITE_EXIT = 2,
    PIP_SITE_INTERNAL = 3,
    PIP_LUT_PERMUTATION = 4,
    PIP_LUT_ROUTETHRU = 5,
    PIP_CONST_DRIVER = 6,
};

NPNR_PACKED_STRUCT(struct PipInfoPOD {
    int32_t src_index, dst_index;
    int32_t timing_class;
    int16_t padding;
    int16_t flags;

    int32_t bel;          // name of bel containing pip
    int32_t extra_data;   // for special pips like lut permutation
    int16_t site;         // site index in tile
    int16_t site_variant; // site variant index in tile
});

NPNR_PACKED_STRUCT(struct TileWireInfoPOD {
    int32_t name;
    int32_t num_uphill, num_downhill;
    int32_t timing_class;
    // Pip index inside tile
    RelPtr<int32_t> pips_uphill, pips_downhill;
    // Bel index inside tile
    int32_t num_bel_pins;
    RelPtr<BelPortPOD> bel_pins;

    int16_t site; // Site index in tile
    int16_t padding;

    int32_t intent; // xilinx intent constid
});

NPNR_PACKED_STRUCT(struct TileWireRefPOD {
    int32_t tile;
    int32_t index;
});

NPNR_PACKED_STRUCT(struct NodeInfoPOD {
    int32_t num_tile_wires;
    int32_t intent;
    RelPtr<TileWireRefPOD> tile_wires;
});

NPNR_PACKED_STRUCT(struct TileTypeInfoPOD {
    int32_t type;

    int32_t num_bels;
    RelPtr<BelInfoPOD> bel_data;

    int32_t num_wires;
    RelPtr<TileWireInfoPOD> wire_data;

    int32_t num_pips;
    RelPtr<PipInfoPOD> pip_data;

    // Cell timing data index
    int32_t timing_index;
});

NPNR_PACKED_STRUCT(struct SiteInstInfoPOD {
    RelPtr<char> name;
    RelPtr<char> pin;
    int32_t site_x, site_y;
    int32_t rel_x, rel_y;
    int32_t inter_x, inter_y;
});

NPNR_PACKED_STRUCT(struct TileInstInfoPOD {
    RelPtr<char> name;
    int32_t type;
    // Number of tile wires; excluding any site-internal wires
    // which come after general wires and are not stored here
    // as they will never be nodal
    int32_t num_tile_wires;
    // -1 if a tile-local wire; node index if nodal wire
    RelPtr<int32_t> tile_wire_to_node;

    // Site names must be per tile instance,
    // at least for now, due to differing coordinate systems
    int32_t num_sites;
    RelPtr<SiteInstInfoPOD> site_insts;
});

NPNR_PACKED_STRUCT(struct ConstIDDataPOD {
    int32_t known_id_count;
    int32_t bba_id_count;
    RelPtr<RelPtr<char>> bba_ids;
});

NPNR_PACKED_STRUCT(struct CellPropDelayPOD {
    int32_t from_port;
    int32_t to_port;
    int32_t min_delay;
    int32_t max_delay;
});

enum TimingCheckType : int32_t
{
    TIMING_CHECK_SETUP = 0,
    TIMING_CHECK_HOLD = 1,
    TIMING_CHECK_WIDTH = 2,
};

NPNR_PACKED_STRUCT(struct CellTimingCheckPOD {
    int32_t check_type;
    int32_t sig_port;
    int32_t clock_port;
    int32_t min_value;
    int32_t max_value;
});

NPNR_PACKED_STRUCT(struct CellTimingPOD {
    int32_t variant_name;
    int32_t num_delays, num_checks;
    RelPtr<CellPropDelayPOD> delays;
    RelPtr<CellTimingCheckPOD> checks;
});

NPNR_PACKED_STRUCT(struct InstanceTimingPOD {
    // Variants, sorted by name IdString
    int32_t inst_name;
    int32_t num_celltypes;
    RelPtr<CellTimingPOD> celltypes;
});

NPNR_PACKED_STRUCT(struct TileCellTimingPOD {
    int32_t tile_type_name;
    // Instances, sorted by name IdString
    int32_t num_instances;
    RelPtr<InstanceTimingPOD> instances;
});

/*
delay in ps
R in mOhm
C in fF
*/

NPNR_PACKED_STRUCT(struct WireTimingPOD { int32_t resistance, capacitance; });

NPNR_PACKED_STRUCT(struct PipTimingPOD {
    int16_t is_buffered;
    int16_t padding;
    int32_t min_delay, max_delay;
    int32_t resistance, capacitance;
});

NPNR_PACKED_STRUCT(struct TimingDataPOD {
    int32_t num_tile_types, num_wire_classes, num_pip_classes;
    RelPtr<TileCellTimingPOD> tile_cell_timings;
    RelPtr<WireTimingPOD> wire_timing_classes;
    RelPtr<PipTimingPOD> pip_timing_classes;
});

NPNR_PACKED_STRUCT(struct ChipInfoPOD {
    RelPtr<char> name;
    RelPtr<char> generator;

    int32_t version;
    int32_t width, height;
    int32_t num_tiles, num_tiletypes, num_nodes;
    RelPtr<TileTypeInfoPOD> tile_types;
    RelPtr<TileInstInfoPOD> tile_insts;
    RelPtr<NodeInfoPOD> nodes;

    RelPtr<ConstIDDataPOD> extra_constids;

    int32_t num_speed_grades;
    RelPtr<TimingDataPOD> timing_data;
});

/************************ End of chipdb section. ************************/

struct BelIterator
{
    const ChipInfoPOD *chip;
    int cursor_index;
    int cursor_tile;

    BelIterator operator++()
    {
        cursor_index++;
        while (cursor_tile < chip->num_tiles &&
               cursor_index >= chip->tile_types[chip->tile_insts[cursor_tile].type].num_bels) {
            cursor_index = 0;
            cursor_tile++;
        }
        return *this;
    }
    BelIterator operator++(int)
    {
        BelIterator prior(*this);
        ++(*this);
        return prior;
    }

    bool operator!=(const BelIterator &other) const
    {
        return cursor_index != other.cursor_index || cursor_tile != other.cursor_tile;
    }

    bool operator==(const BelIterator &other) const
    {
        return cursor_index == other.cursor_index && cursor_tile == other.cursor_tile;
    }

    BelId operator*() const
    {
        BelId ret;
        ret.tile = cursor_tile;
        ret.index = cursor_index;
        return ret;
    }
};

struct BelRange
{
    BelIterator b, e;
    BelIterator begin() const { return b; }
    BelIterator end() const { return e; }
};

// -----------------------------------------------------------------------

// Iterate over TileWires for a wire (will be more than one if nodal)
struct TileWireIterator
{
    const ChipInfoPOD *chip;
    WireId baseWire;
    int cursor = -1;

    void operator++() { cursor++; }
    bool operator!=(const TileWireIterator &other) const { return cursor != other.cursor; }

    // Returns a *denormalised* identifier always pointing to a tile wire rather than a node
    WireId operator*() const
    {
        if (baseWire.tile == -1) {
            WireId tw;
            const auto &node_wire = chip->nodes[baseWire.index].tile_wires[cursor];
            tw.tile = node_wire.tile;
            tw.index = node_wire.index;
            return tw;
        } else {
            return baseWire;
        }
    }
};

struct TileWireRange
{
    TileWireIterator b, e;
    TileWireIterator begin() const { return b; }
    TileWireIterator end() const { return e; }
};

inline WireId canonicalWireId(const ChipInfoPOD *chip_info, int32_t tile, int32_t wire)
{
    WireId id;

    if (wire >= chip_info->tile_insts[tile].num_tile_wires) {
        // Cannot be a nodal wire
        id.tile = tile;
        id.index = wire;
    } else {
        int32_t node = chip_info->tile_insts[tile].tile_wire_to_node[wire];
        if (node == -1) {
            // Not a nodal wire
            id.tile = tile;
            id.index = wire;
        } else {
            // Is a nodal wire, set tile to -1
            id.tile = -1;
            id.index = node;
        }
    }

    return id;
}

// -----------------------------------------------------------------------

struct WireIterator
{
    const ChipInfoPOD *chip;
    int cursor_index = 0;
    int cursor_tile = -1;

    WireIterator operator++()
    {
        // Iterate over nodes first, then tile wires that aren't nodes
        do {
            cursor_index++;
            if (cursor_tile == -1 && cursor_index >= chip->num_nodes) {
                cursor_tile = 0;
                cursor_index = 0;
            }
            while (cursor_tile != -1 && cursor_tile < chip->num_tiles &&
                   cursor_index >= chip->tile_types[chip->tile_insts[cursor_tile].type].num_wires) {
                cursor_index = 0;
                cursor_tile++;
            }

        } while ((cursor_tile != -1 && cursor_tile < chip->num_tiles &&
                  cursor_index < chip->tile_insts[cursor_tile].num_tile_wires &&
                  chip->tile_insts[cursor_tile].tile_wire_to_node[cursor_index] != -1));

        return *this;
    }
    WireIterator operator++(int)
    {
        WireIterator prior(*this);
        ++(*this);
        return prior;
    }

    bool operator!=(const WireIterator &other) const
    {
        return cursor_index != other.cursor_index || cursor_tile != other.cursor_tile;
    }

    bool operator==(const WireIterator &other) const
    {
        return cursor_index == other.cursor_index && cursor_tile == other.cursor_tile;
    }

    WireId operator*() const
    {
        WireId ret;
        ret.tile = cursor_tile;
        ret.index = cursor_index;
        return ret;
    }
};

struct WireRange
{
    WireIterator b, e;
    WireIterator begin() const { return b; }
    WireIterator end() const { return e; }
};

// -----------------------------------------------------------------------
struct AllPipIterator
{
    const ChipInfoPOD *chip;
    int cursor_index;
    int cursor_tile;

    AllPipIterator operator++()
    {
        cursor_index++;
        while (cursor_tile < chip->num_tiles &&
               cursor_index >= chip->tile_types[chip->tile_insts[cursor_tile].type].num_pips) {
            cursor_index = 0;
            cursor_tile++;
        }
        return *this;
    }
    AllPipIterator operator++(int)
    {
        AllPipIterator prior(*this);
        ++(*this);
        return prior;
    }

    bool operator!=(const AllPipIterator &other) const
    {
        return cursor_index != other.cursor_index || cursor_tile != other.cursor_tile;
    }

    bool operator==(const AllPipIterator &other) const
    {
        return cursor_index == other.cursor_index && cursor_tile == other.cursor_tile;
    }

    PipId operator*() const
    {
        PipId ret;
        ret.tile = cursor_tile;
        ret.index = cursor_index;
        return ret;
    }
};

struct AllPipRange
{
    AllPipIterator b, e;
    AllPipIterator begin() const { return b; }
    AllPipIterator end() const { return e; }
};

// -----------------------------------------------------------------------

struct UphillPipIterator
{
    const ChipInfoPOD *chip;
    TileWireIterator twi, twi_end;
    int cursor = -1;

    void operator++()
    {
        cursor++;
        while (true) {
            if (!(twi != twi_end))
                break;
            WireId w = *twi;
            auto &tile = chip->tile_types[chip->tile_insts[w.tile].type];
            if (cursor < tile.wire_data[w.index].num_uphill)
                break;
            ++twi;
            cursor = 0;
        }
    }
    bool operator!=(const UphillPipIterator &other) const { return twi != other.twi || cursor != other.cursor; }

    PipId operator*() const
    {
        PipId ret;
        WireId w = *twi;
        ret.tile = w.tile;
        ret.index = chip->tile_types[chip->tile_insts[w.tile].type].wire_data[w.index].pips_uphill[cursor];
        return ret;
    }
};

struct UphillPipRange
{
    UphillPipIterator b, e;
    UphillPipIterator begin() const { return b; }
    UphillPipIterator end() const { return e; }
};

struct DownhillPipIterator
{
    const ChipInfoPOD *chip;
    TileWireIterator twi, twi_end;
    int cursor = -1;

    void operator++()
    {
        cursor++;
        while (true) {
            if (!(twi != twi_end))
                break;
            WireId w = *twi;
            auto &tile = chip->tile_types[chip->tile_insts[w.tile].type];
            if (cursor < tile.wire_data[w.index].num_downhill)
                break;
            ++twi;
            cursor = 0;
        }
    }
    bool operator!=(const DownhillPipIterator &other) const { return twi != other.twi || cursor != other.cursor; }

    PipId operator*() const
    {
        PipId ret;
        WireId w = *twi;
        ret.tile = w.tile;
        ret.index = chip->tile_types[chip->tile_insts[w.tile].type].wire_data[w.index].pips_downhill[cursor];
        return ret;
    }
};

struct DownhillPipRange
{
    DownhillPipIterator b, e;
    DownhillPipIterator begin() const { return b; }
    DownhillPipIterator end() const { return e; }
};

struct BelPinIterator
{
    const ChipInfoPOD *chip;
    TileWireIterator twi, twi_end;
    int cursor = -1;

    void operator++()
    {
        cursor++;
        while (true) {
            if (!(twi != twi_end))
                break;
            WireId w = *twi;
            auto &tile = chip->tile_types[chip->tile_insts[w.tile].type];
            if (cursor < tile.wire_data[w.index].num_bel_pins)
                break;
            ++twi;
            cursor = 0;
        }
    }
    bool operator!=(const BelPinIterator &other) const { return twi != other.twi || cursor != other.cursor; }

    BelPin operator*() const
    {
        BelPin ret;
        WireId w = *twi;
        ret.bel.tile = w.tile;
        ret.bel.index = chip->tile_types[chip->tile_insts[w.tile].type].wire_data[w.index].bel_pins[cursor].bel_index;
        ret.pin.index = chip->tile_types[chip->tile_insts[w.tile].type].wire_data[w.index].bel_pins[cursor].port;
        return ret;
    }
};

struct BelPinRange
{
    BelPinIterator b, e;
    BelPinIterator begin() const { return b; }
    BelPinIterator end() const { return e; }
};

struct ArchArgs
{
    std::string chipdb;
};

struct Arch : BaseCtx
{
    boost::iostreams::mapped_file_source blob_file;
    const ChipInfoPOD *chip_info;

    mutable std::unordered_map<std::string, int> tile_by_name;
    mutable std::unordered_map<std::string, std::pair<int, int>> site_by_name;

    dict<WireId, NetInfo *> wire_to_net;
    dict<PipId, NetInfo *> pip_to_net;
    dict<WireId, std::pair<int, int>> driving_pip_loc;
    dict<WireId, NetInfo *> reserved_wires;

    struct LogicTileStatus
    {
        // z -> cell
        CellInfo *cells[128];

        // Eight-tile valid and dirty status
        struct EigthTileStatus
        {
            bool valid = true, dirty = true;
        } eights[8];
        struct HalfTileStatus
        {
            bool valid = true, dirty = true;
        } halfs[8];
    };

    struct BRAMTileStatus
    {
        CellInfo *cells[12] = {nullptr};
    };

    struct TileStatus
    {
        LogicTileStatus *lts = nullptr;
        BRAMTileStatus *bts = nullptr;
        std::vector<CellInfo *> boundcells;
        std::vector<int> sitevariant;

        ~TileStatus()
        {
            delete lts;
            delete bts;
        }
    };

    std::vector<TileStatus> tileStatus;

    ArchArgs args;
    Arch(ArchArgs args);

    bool xc7;

    std::string getChipName() const;

    IdString archId() const { return id("xilinx"); }
    ArchArgs archArgs() const { return args; }
    IdString archArgsToId(ArchArgs args) const;

    // -------------------------------------------------

    int getGridDimX() const { return chip_info->width; }
    int getGridDimY() const { return chip_info->height; }
    int getTileBelDimZ(int, int) const { return 256; }
    int getTilePipDimZ(int, int) const { return 1; }

    // -------------------------------------------------

    void setup_byname() const;

    BelId getBelByName(IdString name) const;

    IdString getBelName(BelId bel) const
    {
        NPNR_ASSERT(bel != BelId());
        int site = locInfo(bel).bel_data[bel.index].site;
        if (site != -1) {
            return id(std::string(chip_info->tile_insts[bel.tile].site_insts[site].name.get()) + "/" +
                      IdString(locInfo(bel).bel_data[bel.index].name).str(this));
        } else {
            return id(std::string(chip_info->tile_insts[bel.tile].name.get()) + "/" +
                      IdString(locInfo(bel).bel_data[bel.index].name).str(this));
        }
    }

    uint32_t getBelChecksum(BelId bel) const { return bel.index; }

    void updateLogicBel(BelId bel, CellInfo *cell)
    {
        int z = locInfo(bel).bel_data[bel.index].z;
        NPNR_ASSERT(z < 128);
        auto &tts = tileStatus[bel.tile];
        if (tts.lts == nullptr)
            tts.lts = new LogicTileStatus();
        auto &ts = *(tts.lts);
        if ((z == (((xc7 ? 3 : 7) << 4) | BEL_6LUT)) || (z == (((xc7 ? 3 : 7) << 4) | BEL_5LUT))) {
            if ((cell != nullptr && cell->lutInfo.is_memory) ||
                (ts.cells[z] != nullptr && ts.cells[z]->lutInfo.is_memory)) {
                // Special case - memory write port invalidates everything
                for (int i = 0; i < 8; i++)
                    ts.eights[i].dirty = true;
                if (xc7)
                    ts.halfs[0].dirty = true; // WCLK and CLK0 shared
            }
        }
        if ((((z & 0xF) == BEL_6LUT) || ((z & 0xF) == BEL_5LUT)) &&
            ((cell != nullptr && cell->lutInfo.is_srl) || (ts.cells[z] != nullptr && ts.cells[z]->lutInfo.is_srl))) {
            // SRLs invalidate everything due to write clock
            for (int i = 0; i < 8; i++)
                ts.eights[i].dirty = true;
            if (xc7)
                ts.halfs[0].dirty = true; // WCLK and CLK0 shared
        }
        ts.cells[z] = cell;
        // determine which sections to mark as dirty
        switch (z & 0xF) {
        case BEL_FF:
        case BEL_FF2:
            ts.halfs[(z >> 4) / 4].dirty = true;
            if ((((z >> 4) / 4) == 0) && xc7)
                ts.eights[3].dirty = true;
        /* fall-through */
        case BEL_6LUT:
        case BEL_5LUT:
            ts.eights[z >> 4].dirty = true;
            break;
        case BEL_F7MUX:
            ts.eights[z >> 4].dirty = true;
            ts.eights[(z >> 4) + 1].dirty = true;
            break;
        case BEL_F8MUX:
            ts.eights[(z >> 4) + 1].dirty = true;
            ts.eights[(z >> 4) + 2].dirty = true;
            break;
        case BEL_F9MUX:
            ts.eights[3].dirty = true;
            ts.eights[4].dirty = true;
            break;
        case BEL_CARRY8:
            for (int i = 0; i < 8; i++)
                ts.eights[i].dirty = true;
            break;
        case BEL_CARRY4:
            for (int i = ((z >> 4) / 4) * 4; i < (((z >> 4) / 4) + 1) * 4; i++)
                ts.eights[i].dirty = true;
            break;
        }
    }

    void updateBramBel(BelId bel, CellInfo *cell)
    {
        IdString type = getBelType(bel);
        if (type != id_RAMBFIFO18E2_RAMBFIFO18E2 && type != id_RAMBFIFO36E2_RAMBFIFO36E2 &&
            type != id_RAMB18E2_RAMB18E2 && type != id_FIFO18E2_FIFO18E2 && type != id_RAMB36E2_RAMB36E2 &&
            type != id_FIFO36E2_FIFO36E2 && type != id_RAMBFIFO36E1_RAMBFIFO36E1 && type != id_RAMB36E1_RAMB36E1 &&
            type != id_RAMB18E1_RAMB18E1)
            return;
        auto &tts = tileStatus[bel.tile];
        if (tts.bts == nullptr)
            tts.bts = new BRAMTileStatus();
        int z = locInfo(bel).bel_data[bel.index].z;
        NPNR_ASSERT(z >= 0 && z < 12);
        tts.bts->cells[z] = cell;
    }

    void bindBel(BelId bel, CellInfo *cell, PlaceStrength strength)
    {
        NPNR_ASSERT(bel != BelId());
        NPNR_ASSERT(tileStatus[bel.tile].boundcells[bel.index] == nullptr);

        tileStatus[bel.tile].boundcells[bel.index] = cell;
        auto &bd = locInfo(bel).bel_data[bel.index];
        int site = bd.site;
        if (site >= 0 && site < int(tileStatus[bel.tile].sitevariant.size()))
            tileStatus[bel.tile].sitevariant.at(site) = bd.site_variant;
        cell->bel = bel;
        cell->belStrength = strength;
        refreshUiBel(bel);

        if (isLogicTile(bel))
            updateLogicBel(bel, cell);
        else if (isBRAMTile(bel))
            updateBramBel(bel, cell);
    }

    void unbindBel(BelId bel)
    {
        NPNR_ASSERT(bel != BelId());
        NPNR_ASSERT(tileStatus[bel.tile].boundcells[bel.index] != nullptr);
        tileStatus[bel.tile].boundcells[bel.index]->bel = BelId();
        tileStatus[bel.tile].boundcells[bel.index]->belStrength = STRENGTH_NONE;
        tileStatus[bel.tile].boundcells[bel.index] = nullptr;
        refreshUiBel(bel);

        if (isLogicTile(bel))
            updateLogicBel(bel, nullptr);
        else if (isBRAMTile(bel))
            updateBramBel(bel, nullptr);
    }

    // NEXTPNR_BEL_BLACKLIST=<file>: reserve individual BELs by name (one
    // "SLICE_X27Y57/A5LUT" per line).  Needed to hand a PARTIALLY pre-placed
    // design to HeAP: the analytic placer happily drops a free cell into a spare
    // bel of a slice that already holds a pinned CARRY4/SRL cluster, which the
    // validity checker then rejects ("constraint satisfaction check failed") --
    // and re-pinning offenders one at a time is whack-a-mole across every carry
    // slice.  Blacklisting the spare bels of cluster slices keeps HeAP out of
    // them entirely.  Lazily loaded on first use (env read once).
    mutable std::unordered_set<int64_t> blacklist_bels;
    mutable bool blacklist_bels_loaded = false;
    void load_bel_blacklist() const;

    bool usp_bel_hard_unavail(BelId bel) const
    {
        if (!blacklist_bels_loaded)
            load_bel_blacklist();
        if (!blacklist_bels.empty() &&
            blacklist_bels.count((int64_t(bel.tile) << 32) | uint32_t(bel.index)))
            return true;
        // if (chip_info->height > 600 && (bel.tile / chip_info->width) < 752) // constrain to SLR0
        //    return true;
        if ((getBelType(bel) == id_PSEUDO_GND || getBelType(bel) == id_PSEUDO_VCC) &&
            ((bel.tile % chip_info->width) != 0))
            return true; // PSEUDO drivers must be at x=0 to have access to the global pseudo-network
        return false;
    }

    // NEXTPNR_PARTITION_ROI=<file>: confine reconfigurable-module (RM) logic to
    // a partition rectangle given in prjxray grid_x/grid_y TILE coordinates.
    //
    // The file is the same prjxray ROI object `fasm2frames --roi` and
    // `--roi-strict` already consume -- {"info": {"GRID_X_MIN": .., "GRID_X_MAX":
    // .., "GRID_Y_MIN": .., "GRID_Y_MAX": ..}} -- so placement, routing and frame
    // emission read ONE rectangle from ONE file instead of three that drift
    // apart.  scripts/roi_snap.py emits exactly this, already snapped to the
    // frame lattice.
    //
    // TILE coordinates, never slice coordinates.  SLICE_X40Y0 and SLICE_X41Y0
    // are both sites of CLBLL_R_X25Y0, so a slice-space boundary can split a CLB
    // tile column -- not a legal DFX partition boundary, and the cause of 250 of
    // the 338 detouring nets in docs/static-lock-convergence.md section 8.2.
    //
    // nextpnr's Loc IS prjxray grid space, so no conversion is needed or wanted:
    // xilinx/python/xilinx_device.py reads grid_x/grid_y straight out of
    // tilegrid.json, xilinx/python/bbaexport.py writes tile_insts row-major over
    // (y, x), and getBelLocation() below recovers them by divmod on
    // chip_info->width.  Note that TILE-NAME X/Y is a different system with the
    // same extents (INT_L_X32Y100 is grid (81,103)); do not mix them.
    mutable int roi_x0 = -1, roi_y0 = -1, roi_x1 = -1, roi_y1 = -1;
    mutable bool roi_loaded = false;
    void load_partition_roi() const;

    // The ROI file's OPTIONAL "siblings" array: the other partitions on this
    // device, which THIS RUN IS NOT BUILDING.  Empty unless the file names them,
    // so a file carrying only "info" is the mechanism it was before this
    // existed.
    //
    // They govern ROUTING ONLY.  Placement, RM steering, --region-only emission
    // and invariant P stay the rectangle above's alone: this run's RM cells
    // belong to it and to no other, and a sibling reserves no bel.
    //
    // WHY THEY HAVE TO EXIST.  In a chained replay each run frees one region and
    // clamps that region's rectangle; every region an earlier run already
    // contained is ordinary static logic to this one, so router2 rips it up
    // under congestion and re-routes it with no rectangle at all.  Measured on
    // the four-region static: RM-net pips outside their own rectangle went
    // 0/133/155/123 after replay 0 to a fixed point of 1/4/11/0 after three full
    // four-run passes -- iterating cannot close it, because every pass re-opens
    // what the previous one contained.  A sibling rectangle re-clamps those nets
    // to the rectangle they are already in.
    struct RoiRect
    {
        int x0, y0, x1, y1;
    };
    mutable std::vector<RoiRect> roi_siblings;

    // Rectangle 0 is the partition; 1..roi_siblings.size() are the siblings in
    // file order.  One numbering shared by the clamp, the route gate and the
    // census, so a rectangle index printed in a log names the same rectangle
    // everywhere.
    RoiRect roi_rect(int i) const
    {
        if (i == 0)
            return RoiRect{roi_x0, roi_y0, roi_x1, roi_y1};
        return roi_siblings.at(i - 1);
    }
    int roi_rect_count() const { return 1 + int(roi_siblings.size()); }
    static bool rect_holds(const RoiRect &r, int x, int y)
    {
        return x >= r.x0 && x <= r.x1 && y >= r.y0 && y <= r.y1;
    }

    // One veto counter per enforcement point, reported at the end of
    // Arch::place().  These exist because "0 RM cells outside the rectangle" is
    // a STATIC observation: it is equally true of a rectangle that refused a
    // thousand escape attempts and of a rectangle that was never consulted.
    // The counters separate "the mechanism held" from "nothing tried to leave",
    // which is the distinction this programme has repeatedly failed to make --
    // most recently when four malformed-rectangle tests passed under --no-place
    // because the lazily-loaded rectangle was never opened.
    mutable int64_t roi_veto_avail = 0; // point 1, checkBelAvail
    mutable int64_t roi_veto_cell = 0;  // point 2, isValidBelForCell
    mutable int64_t roi_veto_loc = 0;   // point 3, isBelLocationValid

    bool roi_active() const
    {
        if (!roi_loaded)
            load_partition_roi();
        return roi_x0 >= 0;
    }

    bool bel_outside_roi(BelId bel) const
    {
        if (bel == BelId() || !roi_active())
            return false;
        int x = bel.tile % chip_info->width, y = bel.tile / chip_info->width;
        return x < roi_x0 || x > roi_x1 || y < roi_y0 || y > roi_y1;
    }

    // The RM cell set, snapshotted at import before anything binds a bel.
    //
    // Deliberately NOT derived from an attribute at the point of use.
    // Arch::place() ends with archInfoToAttributes(), which stamps NEXTPNR_BEL
    // onto EVERY bound cell -- so both "has a bel" and "has NEXTPNR_BEL" are
    // valid static/RM discriminators BEFORE placement and tautologies after it.
    // Three separate places in this tree re-derive the distinction from
    // attrs["BEL"], each with its own type filter, and all three are inert on a
    // round-tripped netlist because archInfoToAttributes erases that attribute.
    // This set is taken once, at customAfterLoad, and is the single answer.
    // std::unordered_set, not hashlib's pool<>: pool requires a T::hash()
    // member and this tree's IdString has none (it is keyed through
    // std::hash<IdString>, which is how ctx->cells works).
    std::unordered_set<IdString> rm_cells;
    bool rm_snapshot_taken = false;
    void snapshot_rm_cells();

    // Set by Arch::pack(). The RM set is snapshotted at customAfterLoad, which
    // runs BEFORE the pack step, so any run that packs invalidates it: every
    // cell the packer creates carries a name the snapshot never saw, and
    // is_rm_cell() fails open on a miss. The DPR flow passes --no-pack, but
    // that pairing was unenforced -- one missing CLI flag from a rectangle that
    // confines a shrinking subset of the RM logic while still reporting
    // non-zero vetoes. check_partition_nets() refuses to run under a stale set.
    bool packed_since_rm_snapshot = false;

    bool is_rm_cell(const CellInfo *ci) const
    {
        return rm_snapshot_taken && ci != nullptr && rm_cells.count(ci->name);
    }

    // NEXTPNR_PARTITION_EXEMPT_NETS=<file>: one net name per line (blank lines
    // and '#' comments ignored), exempt from invariant P below.
    //
    // This file exists because of a gap the source cannot close for us.  P
    // excludes the global clock spine, and this architecture has NO usable
    // predicate for "is a global clock net":
    //
    //   - NetInfo::is_global (xilinx/archdefs.h) is declared and NEVER WRITTEN
    //     on this arch.  Every write in the tree is ecp5/pack.cc or
    //     ice40/arch.cc; every xilinx read would see a permanent false.  It
    //     compiles, it reads naturally, and it would exempt nothing -- exactly
    //     the shape of silently-inert mechanism this programme keeps shipping.
    //   - routeClock()'s `is_global` (xilinx/arch.cc) is a function-LOCAL bool
    //     re-derived from driver/user cell TYPES, shadowing the dead member. It
    //     is not stored, not exported, and not a name test.
    //   - getBelGlobalBuf() is a bel-TYPE test that also matches PSEUDO_GND and
    //     PSEUDO_VCC, so it conflates clocks with the const drivers.
    //
    // A type-based exemption would also widen silently the moment a design uses
    // a buffer type not on the list.  So the exemption is an explicit list of
    // NAMES, supplied per design, counted and logged on every run -- unresolved
    // entries included, because a typo'd exemption that matches no net is
    // indistinguishable from a correct one unless it is reported.
    mutable std::unordered_set<IdString> exempt_nets;
    mutable bool exempt_nets_loaded = false;
    void load_exempt_nets() const;

    // The keepout's escape list, and the reason it is a SECOND file rather than
    // a second use of the one above.  Both sets end up unioned into the set
    // router2 gets, so this changes nothing a run can observe -- what it
    // changes is what a reader can conclude.  The file above says "this net is
    // none of invariant P's business"; this one says "this net may cross a
    // rectangle it does not belong to".  A design can need the second without
    // the first, and folding them would make a keepout escape indistinguishable
    // from a P escape in every log and every audit.
    //
    // It is the LAST resort, not the first: the keepout's own exemption is
    // derived in router2 from getBelGlobalBuf(), so the clock spine needs no
    // entry here.  An entry that names no net is warned about for the same
    // reason load_exempt_nets warns.
    std::unordered_set<IdString> load_keepout_exempt_nets() const;

    std::unordered_map<IdString, std::vector<PipId>> load_keepout_licence_pips() const;

    // Invariant P, asserted at the end of Arch::place().
    //
    //   Every signal net with at least one endpoint on an RM cell has ALL of
    //   its endpoints on cells placed INSIDE the partition rectangle.
    //
    // Equivalently: no signal net crosses the partition boundary.  Each
    // boundary signal is split by an anchor LUT sited inside the rectangle into
    // a static-side net and an RM-side net.  P is a property of the NETLIST,
    // not of the router, so a violation is repaired upstream by adding
    // partition pins -- never by exempting the net here.
    //
    // Why the routing clamp needs this first: a net's router2 bounding box is
    // the union over its arcs, so a net that legitimately crosses already has a
    // box spanning both sides.  Intersecting that box with the rectangle leaves
    // exactly two options and both are failures -- clamp it and a legal design
    // cannot route (with the error naming a pip, pointing at the router when
    // the defect is in the anchoring), or exempt it and the exemption is a
    // per-net hole that pr_verify cannot see because it is intentional.
    //
    // $PACKER_GND_NET and $PACKER_VCC_NET are excluded by exact name equality,
    // never by the find("$PACKER_") substring test snapshot_rm_cells uses on
    // cell names -- a catch-all is how an exemption becomes a hole.  They
    // cannot satisfy P by construction: usp_bel_hard_unavail above pins every
    // PSEUDO_GND/PSEUDO_VCC bel to grid x=0, so unless the rectangle includes
    // column 0 the const drivers are outside it always.  Containing them is
    // Unit 7.5's problem and is a change to route_xilinx_const's
    // "always succeeds" contract, not a bounding-box question.
    void check_partition_nets() const;

    // The single definition of "a net the partition rectangle governs": any net
    // with at least one endpoint on an RM cell, less the two const nets and the
    // explicitly exempted ones. Empty when the rectangle is inactive.
    //
    // TWO CONSUMERS, ONE DEFINITION, AND THAT IS THE POINT.
    // check_partition_nets() asserts invariant P over this set before placement
    // finishes; Arch::route() clamps the router's pip choice over this same set.
    // If the two ever disagreed, a net could satisfy the gate and then route
    // wherever it liked -- a hole of exactly the kind this unit exists to close,
    // and one that no acceptance script could see, because both halves would
    // report success. check_partition_nets() NPNR_ASSERTs the agreement rather
    // than documenting it.
    std::unordered_set<IdString> partition_nets() const;

    // The same question the router and the route gate ask, widened by the
    // sibling rectangles: which rectangle confines this net's pips?  Maps a net
    // name to a roi_rect() index; a net absent from the map is unconfined.
    //
    // Rectangle 0 is partition_nets() unchanged -- the nets P was asserted over.
    // A sibling rectangle takes a net iff EVERY endpoint of that net is placed
    // and inside it, which is the strongest claim placement alone can support.
    // It is not a no-op: a net wholly inside a region can still DETOUR outside
    // it under congestion, and forbidding that detour is the whole point.  What
    // it does not do is constrain a net whose endpoints are not all in one
    // region -- that net is asking to leave, and this says nothing about it.
    // Const nets and listed exemptions are excluded by the same exact names
    // partition_nets() uses.
    //
    // Deliberately NOT a name-prefix or instance-path test.  The rectangle a
    // region's logic occupies is a placement fact this run can read; "which slot
    // is this cell in" is a fact only the build script knows, and encoding it
    // here would make containment depend on a naming convention.
    std::unordered_map<IdString, int> partition_net_rects() const;

    // The DETECTIVE half of route containment. router2's clamp is PREVENTIVE
    // and covers exactly one of the ten paths in this tree that can bind a pip
    // to a net. The others bypass it entirely, and three of them are live:
    //
    //   * attributesToArchInfo() binds every pip in a netlist's ROUTING
    //     attribute at frontend import (frontend_base.h:293) -- five stages
    //     before Arch::route() -- taking the STRENGTH VERBATIM FROM THE FILE.
    //   * routeClock() and applyFixedRoutes() bind at STRENGTH_LOCKED before
    //     router2 runs, with no location test of any kind.
    //   * routeVcc() and fixupRouting() bind AFTER it, so nothing downstream
    //     can reconcile them.
    //
    // Worse, router2 LAUNDERS the imported ones back out: setup_wires() seeds
    // its per-wire state from pre-existing Arch bindings, check_arc_routing()
    // skips any arc already consistently routed so it is never offered to the
    // A* or the backwards BFS, and bind_and_check() then re-binds those exact
    // pips -- with no location test. The ripup filter is
    // `strength <= STRENGTH_STRONG`, so anything LOCKED is exempt even from
    // that. A round-tripped netlist can therefore carry pips anywhere on the
    // die, through router2, and out into the FASM, with the clamp reporting a
    // clean run throughout.
    //
    // So this walks what was ACTUALLY BOUND rather than what was searched.
    // net->wires is the complete record of bound pips -- Arch::bindPip is the
    // single writer, and xilinx/fasm.cc's write_routing() reads that same map
    // and nothing else -- so a pass over it sees every pip feature that can
    // reach the bitstream.
    void check_partition_routing() const;

    bool checkBelAvail(BelId bel) const
    {
        if (usp_bel_hard_unavail(bel))
            return false;
        NPNR_ASSERT(bel != BelId());
        // Partition ROI, enforcement point 1 of 3.  Bel-only and deliberately
        // cell-agnostic: checkBelAvail is consulted BEFORE a bind and never to
        // re-validate one already made, so a static cell the import bound
        // outside the rectangle is untouched by this.  This is the point that
        // keeps out-of-rectangle bels out of HeAP's fast_bels snapshot
        // (common/placer_heap.cc:473, :492), which is the strongest single
        // effect the rectangle has -- but it is a ONE-SHOT snapshot taken in
        // build_fast_bels(), and placer1's fast_bels is not filtered at all, so
        // it cannot be the only enforcement point.  See points 2 and 3 in
        // xilinx/arch_place.cc.
        //
        // ORDERING INVARIANT, load-bearing: build_fast_bels() runs once, at
        // common/placer_heap.cc:151, and the rectangle must already be loaded
        // by then or the snapshot is taken unfiltered.  Arch::place() is far
        // downstream of the eager load in UspCommandHandler::customAfterLoad,
        // so this holds -- but it holds by ordering, not by construction, and
        // reverting the load to lazy would silently reopen HeAP's ripup escape
        // (:1027).  scripts/partition-roi-evidence.sh asserts the ordering
        // directly out of the log.
        if (bel_outside_roi(bel)) {
            ++roi_veto_avail;
            return false;
        }
        return tileStatus[bel.tile].boundcells[bel.index] == nullptr;
    }

    CellInfo *getBoundBelCell(BelId bel) const
    {
        NPNR_ASSERT(bel != BelId());
        return tileStatus[bel.tile].boundcells[bel.index];
    }

    CellInfo *getConflictingBelCell(BelId bel) const
    {
        NPNR_ASSERT(bel != BelId());
        return tileStatus[bel.tile].boundcells[bel.index];
    }

    BelRange getBels() const
    {
        BelRange range;
        range.b.cursor_tile = 0;
        range.b.cursor_index = -1;
        range.b.chip = chip_info;
        ++range.b; //-1 and then ++ deals with the case of no Bels in the first tile
        range.e.cursor_tile = chip_info->width * chip_info->height;
        range.e.cursor_index = 0;
        range.e.chip = chip_info;
        return range;
    }

    Loc getBelLocation(BelId bel) const
    {
        NPNR_ASSERT(bel != BelId());
        Loc loc;
        loc.x = bel.tile % chip_info->width;
        loc.y = bel.tile / chip_info->width;
        loc.z = locInfo(bel).bel_data[bel.index].z;
        return loc;
    }

    BelId getBelByLocation(Loc loc) const;
    BelRange getBelsByTile(int x, int y) const;

    bool getBelGlobalBuf(BelId bel) const
    {
        IdString type = getBelType(bel);
        return (type == id_BUFGCTRL) || (type == id_PSEUDO_GND) || (type == id_PSEUDO_VCC) ||
               (type == id_BUFCE_BUFG_PS) || (type == id_BUFGCE_DIV_BUFGCE_DIV) || (type == id_BUFCE_BUFCE);
    }

    bool getBelHidden(BelId bel) const { return locInfo(bel).bel_data[bel.index].is_routing; }

    IdString getBelType(BelId bel) const
    {
        NPNR_ASSERT(bel != BelId());
        return IdString(locInfo(bel).bel_data[bel.index].type);
    }

    std::vector<std::pair<IdString, std::string>> getBelAttrs(BelId bel) const;

    WireId getBelPinWire(BelId bel, IdString pin) const;
    PortType getBelPinType(BelId bel, IdString pin) const;
    std::vector<IdString> getBelPins(BelId bel) const;

    bool isBelLocked(BelId bel) const;

    // -------------------------------------------------

    mutable std::unordered_map<IdString, WireId> wire_by_name_cache;

    WireId getWireByName(IdString name) const;

    const TileWireInfoPOD &wireInfo(WireId wire) const
    {
        if (wire.tile == -1) {
            const TileWireRefPOD &wr = chip_info->nodes[wire.index].tile_wires[0];
            return chip_info->tile_types[chip_info->tile_insts[wr.tile].type].wire_data[wr.index];
        } else {
            return locInfo(wire).wire_data[wire.index];
        }
    }

    IdString getWireName(WireId wire) const
    {
        NPNR_ASSERT_MSG(wire != WireId(), "uninitialized wire");
        if (wire.tile != -1 && locInfo(wire).wire_data[wire.index].site != -1) {
            return id(std::string("SITEWIRE/") +
                      chip_info->tile_insts[wire.tile].site_insts[locInfo(wire).wire_data[wire.index].site].name.get() +
                      std::string("/") + IdString(locInfo(wire).wire_data[wire.index].name).str(this));
        } else {
            return id(std::string(chip_info
                                          ->tile_insts[wire.tile == -1 ? chip_info->nodes[wire.index].tile_wires[0].tile
                                                                       : wire.tile]
                                          .name.get()) +
                      "/" + IdString(wireInfo(wire).name).c_str(this));
        }
    }

    IdString getWireType(WireId wire) const;
    std::vector<std::pair<IdString, std::string>> getWireAttrs(WireId wire) const;

    uint32_t getWireChecksum(WireId wire) const { return wire.index; }

    void bindWire(WireId wire, NetInfo *net, PlaceStrength strength)
    {
        NPNR_ASSERT(wire != WireId());
        NPNR_ASSERT(wire_to_net[wire] == nullptr);
        wire_to_net[wire] = net;
        net->wires[wire].pip = PipId();
        net->wires[wire].strength = strength;
        refreshUiWire(wire);
    }

    void unbindWire(WireId wire)
    {
        NPNR_ASSERT(wire != WireId());
        NPNR_ASSERT(wire_to_net[wire] != nullptr);

        auto &net_wires = wire_to_net[wire]->wires;
        auto it = net_wires.find(wire);
        NPNR_ASSERT(it != net_wires.end());

        auto pip = it->second.pip;
        if (pip != PipId()) {
            pip_to_net[pip] = nullptr;
        }

        net_wires.erase(it);
        wire_to_net[wire] = nullptr;
        refreshUiWire(wire);
    }

    bool checkWireAvail(WireId wire) const
    {
        NPNR_ASSERT(wire != WireId());
        auto w2n = wire_to_net.find(wire);
        return w2n == wire_to_net.end() || w2n->second == nullptr;
    }

    NetInfo *getReservedWireNet(WireId wire) const
    {
        NPNR_ASSERT(wire != WireId());
        auto w2n = reserved_wires.find(wire);
        return w2n == reserved_wires.end() ? nullptr : w2n->second;
    }

    NetInfo *getBoundWireNet(WireId wire) const
    {
        NPNR_ASSERT(wire != WireId());
        auto w2n = wire_to_net.find(wire);
        return w2n == wire_to_net.end() ? nullptr : w2n->second;
    }

    WireId getConflictingWireWire(WireId wire) const { return wire; }

    NetInfo *getConflictingWireNet(WireId wire) const
    {
        NPNR_ASSERT(wire != WireId());
        auto w2n = wire_to_net.find(wire);
        return w2n == wire_to_net.end() ? nullptr : w2n->second;
    }

    DelayInfo getWireDelay(WireId wire) const
    {
        DelayInfo delay;
        delay.delay = 0;
        return delay;
    }

    TileWireRange getTileWireRange(WireId wire) const
    {
        TileWireRange range;
        range.b.chip = chip_info;
        range.b.baseWire = wire;
        range.b.cursor = -1;
        ++range.b;

        range.e.chip = chip_info;
        range.e.baseWire = wire;
        if (wire.tile == -1)
            range.e.cursor = chip_info->nodes[wire.index].num_tile_wires;
        else
            range.e.cursor = 1;
        return range;
    }

    BelPinRange getWireBelPins(WireId wire) const
    {
        BelPinRange range;
        NPNR_ASSERT(wire != WireId());
        TileWireRange twr = getTileWireRange(wire);
        range.b.chip = chip_info;
        range.b.twi = twr.b;
        range.b.twi_end = twr.e;
        range.b.cursor = -1;
        ++range.b;
        range.e.chip = chip_info;
        range.e.twi = twr.e;
        range.e.twi_end = twr.e;
        range.e.cursor = 0;
        return range;
    }

    WireRange getWires() const
    {
        WireRange range;
        range.b.chip = chip_info;
        range.b.cursor_tile = -1;
        range.b.cursor_index = 0;
        range.e.chip = chip_info;
        range.e.cursor_tile = chip_info->num_tiles;
        range.e.cursor_index = 0;
        return range;
    }

    // -------------------------------------------------

    mutable std::unordered_map<IdString, PipId> pip_by_name_cache;

    PipId getPipByName(IdString name) const;

    void bindPip(PipId pip, NetInfo *net, PlaceStrength strength)
    {
        NPNR_ASSERT(pip != PipId());
        NPNR_ASSERT(pip_to_net[pip] == nullptr);

        WireId dst = canonicalWireId(chip_info, pip.tile, locInfo(pip).pip_data[pip.index].dst_index);
        NPNR_ASSERT(wire_to_net[dst] == nullptr || wire_to_net[dst] == net);

        pip_to_net[pip] = net;
        driving_pip_loc[dst] = std::make_pair(pip.tile % chip_info->width, pip.tile / chip_info->width);

        wire_to_net[dst] = net;
        net->wires[dst].pip = pip;
        net->wires[dst].strength = strength;
        refreshUiPip(pip);
        refreshUiWire(dst);
    }

    void unbindPip(PipId pip)
    {
        NPNR_ASSERT(pip != PipId());
        NPNR_ASSERT(pip_to_net[pip] != nullptr);

        WireId dst = canonicalWireId(chip_info, pip.tile, locInfo(pip).pip_data[pip.index].dst_index);
        NPNR_ASSERT(wire_to_net[dst] != nullptr);
        wire_to_net[dst] = nullptr;
        pip_to_net[pip]->wires.erase(dst);

        pip_to_net[pip] = nullptr;
        refreshUiPip(pip);
        refreshUiWire(dst);
    }

    dict<int, pool<int>> blacklist_pips;
    // Per-tile-INSTANCE pip blacklist (keyed by tile index -> pip indices), for
    // reserving a pip in ONE specific tile only -- e.g. an INT pip whose config
    // bit overlaps a live IOB config bit (IOB config piggybacks on the adjacent
    // INT column's frames), which must be avoided at that tile but stays usable
    // everywhere else.  Loaded from NEXTPNR_PIP_BLACKLIST_TILE (TILENAME.DST.SRC).
    dict<int, pool<int>> blacklist_pip_instances;
    void setup_pip_blacklist();

    bool usp_pip_hard_unavail(PipId pip) const
    {
        if (blacklist_pips.count(locInfo(pip).type) && blacklist_pips.at(locInfo(pip).type).count(pip.index))
            return true;
        if (!blacklist_pip_instances.empty()) {
            auto it = blacklist_pip_instances.find(pip.tile);
            if (it != blacklist_pip_instances.end() && it->second.count(pip.index))
                return true;
        }
        if (locInfo(pip).pip_data[pip.index].flags == PIP_SITE_ENTRY) {
            WireId dst = getPipDstWire(pip);
            if (dst.tile != -1) {
                auto &wi = wireInfo(dst);
                if (wi.intent == ID_INTENT_SITE_GND) {
                    LogicTileStatus *lts = tileStatus[dst.tile].lts;
                    if (lts != nullptr && (lts->cells[BEL_5LUT] != nullptr || lts->cells[BEL_6LUT] != nullptr))
                        return true; // Ground driver only available if lowest 5LUT and 6LUT not used
                }
            }
        } else if (locInfo(pip).pip_data[pip.index].flags == PIP_CONST_DRIVER) {
            WireId dst = getPipDstWire(pip);
            // virtex7 clock-routing fan-out reaches PIP_CONST_DRIVER pips
            // whose getPipDstWire returns dst.tile == -1 (the pseudo-tile
            // for the const-driver wire).  The matching PIP_SITE_ENTRY
            // branch above already guards with `if (dst.tile != -1)` —
            // we do the same here to avoid tileStatus[-1] (caught by
            // ASan as a 64-byte-before-allocation read).  When dst.tile
            // is the pseudo-tile we conservatively report the pip
            // available (return false at the bottom of the function),
            // since there's no LogicTileStatus to consult anyway.
            if (dst.tile != -1) {
                LogicTileStatus *lts = tileStatus[xc7 ? dst.tile : pip.tile].lts;
                if (lts != nullptr && (lts->cells[BEL_5LUT] != nullptr || lts->cells[BEL_6LUT] != nullptr))
                    return true; // Ground driver only available if lowest 5LUT and 6LUT not used
            }
        } else if (locInfo(pip).pip_data[pip.index].flags == PIP_SITE_INTERNAL) {
            auto &pd = locInfo(pip).pip_data[pip.index];
            if (pd.bel == ID_TRIBUF)
                return true;
            if (pd.site >= 0 && pd.site <= int(tileStatus[pip.tile].sitevariant.size()))
                if (pd.site_variant > 0 && pd.site_variant != tileStatus[pip.tile].sitevariant.at(pd.site))
                    return true;
        } else if (locInfo(pip).pip_data[pip.index].flags == PIP_LUT_PERMUTATION) {
            LogicTileStatus *lts = tileStatus[pip.tile].lts;
            if (lts == nullptr)
                return false;
            int eight = (locInfo(pip).pip_data[pip.index].extra_data >> 8) & 0xF;

            if (((locInfo(pip).pip_data[pip.index].extra_data >> 4) & 0xF) ==
                (locInfo(pip).pip_data[pip.index].extra_data & 0xF))
                return false; // from==to, always valid

            const CellInfo *lut6 = lts->cells[(eight << 4) | BEL_6LUT];
            if (lut6 != nullptr && (lut6->lutInfo.is_memory || lut6->lutInfo.is_srl))
                return true;
            const CellInfo *lut5 = lts->cells[(eight << 4) | BEL_5LUT];
            if (lut5 != nullptr && (lut5->lutInfo.is_memory || lut5->lutInfo.is_srl))
                return true;
        } else if (locInfo(pip).pip_data[pip.index].flags == PIP_LUT_ROUTETHRU) {
            int eight = (locInfo(pip).pip_data[pip.index].extra_data >> 8) & 0xF;
            int dest = (locInfo(pip).pip_data[pip.index].extra_data) & 0x1;
            if (eight == 0)
                return true; // FIXME: conflict with ground
            if (dest & 0x1)
                return true; // FIXME: routethru to MUX
            LogicTileStatus *lts = tileStatus[pip.tile].lts;
            if (lts == nullptr)
                return false;
            const CellInfo *lut6 = lts->cells[(eight << 4) | BEL_6LUT];
            if (lut6 != nullptr)
                return true;
            const CellInfo *lut5 = lts->cells[(eight << 4) | BEL_5LUT];
            if (lut5 != nullptr)
                return true;
        } /*else if (chip_info->tile_types[chip_info->tile_insts[pip.tile].type].type == ID_BRAM) {
            auto &pd = locInfo(pip).pip_data[pip.index];
            if (pd.site != -1 && pd.site_variant != 0)
                return true;
        }*/
        return false;
    }

    bool checkPipAvail(PipId pip) const
    {
        NPNR_ASSERT(pip != PipId());
        if (usp_pip_hard_unavail(pip))
            return false;
        return pip_to_net.find(pip) == pip_to_net.end() || pip_to_net.at(pip) == nullptr;
    }

    NetInfo *getBoundPipNet(PipId pip) const
    {
        NPNR_ASSERT(pip != PipId());
        auto p2n = pip_to_net.find(pip);
        return p2n == pip_to_net.end() ? nullptr : p2n->second;
    }

    WireId getConflictingPipWire(PipId pip) const
    {
        if (usp_pip_hard_unavail(pip))
            return WireId();
        return getPipDstWire(pip);
    }

    NetInfo *getConflictingPipNet(PipId pip) const
    {
        if (usp_pip_hard_unavail(pip))
            return nullptr;
        NPNR_ASSERT(pip != PipId());
        auto p2n = pip_to_net.find(pip);
        return p2n == pip_to_net.end() ? nullptr : p2n->second;
    }

    AllPipRange getPips() const
    {
        AllPipRange range;
        range.b.cursor_tile = 0;
        range.b.cursor_index = -1;
        range.b.chip = chip_info;
        ++range.b; //-1 and then ++ deals with the case of no wries in the first tile
        range.e.cursor_tile = chip_info->width * chip_info->height;
        range.e.cursor_index = 0;
        range.e.chip = chip_info;
        return range;
    }

    Loc getPipLocation(PipId pip) const
    {
        Loc loc;
        loc.x = pip.tile % chip_info->width;
        loc.y = pip.tile / chip_info->width;
        loc.z = 0;
        return loc;
    }

    IdString getPipName(PipId pip) const;

    IdString getPipType(PipId pip) const;
    std::vector<std::pair<IdString, std::string>> getPipAttrs(PipId pip) const;

    uint32_t getPipChecksum(PipId pip) const { return pip.index; }

    WireId getPipSrcWire(PipId pip) const
    {
        return canonicalWireId(chip_info, pip.tile, locInfo(pip).pip_data[pip.index].src_index);
    }

    WireId getPipDstWire(PipId pip) const
    {
        return canonicalWireId(chip_info, pip.tile, locInfo(pip).pip_data[pip.index].dst_index);
    }

    delay_t approx_pip_delay(int32_t start_intent, int32_t end_intent) const
    {
        // std::cout << IdString(start_intent).str(this) << " -> " << IdString(end_intent).str(this) << std::endl;
        if (start_intent == ID_INTENT_DEFAULT && end_intent == ID_NODE_DEDICATED)
            return 539;
        if (start_intent == ID_INTENT_DEFAULT && end_intent == ID_NODE_GLOBAL_LEAF)
            return 0;
        if (start_intent == ID_INTENT_DEFAULT && end_intent == ID_NODE_OUTPUT)
            return 530;
        if (start_intent == ID_NODE_CLE_OUTPUT && end_intent == ID_INTENT_DEFAULT)
            return 28;
        if (start_intent == ID_NODE_CLE_OUTPUT && end_intent == ID_NODE_LOCAL)
            return 77;
        if (start_intent == ID_NODE_DEDICATED && end_intent == ID_INTENT_DEFAULT)
            return 328;
        if (start_intent == ID_NODE_DOUBLE && end_intent == ID_NODE_LOCAL)
            return 0;
        if (start_intent == ID_NODE_GLOBAL_BUFG && end_intent == ID_NODE_GLOBAL_BUFG)
            return 0;
        if (start_intent == ID_NODE_GLOBAL_BUFG && end_intent == ID_NODE_GLOBAL_VDISTR)
            return 0;
        if (start_intent == ID_NODE_GLOBAL_HDISTR && end_intent == ID_INTENT_DEFAULT)
            return 0;
        if (start_intent == ID_NODE_GLOBAL_HDISTR && end_intent == ID_NODE_GLOBAL_HDISTR)
            return 324;
        if (start_intent == ID_NODE_GLOBAL_LEAF && end_intent == ID_NODE_LOCAL)
            return 0;
        if (start_intent == ID_NODE_GLOBAL_VDISTR && end_intent == ID_NODE_GLOBAL_HDISTR)
            return 0;
        if (start_intent == ID_NODE_GLOBAL_VDISTR && end_intent == ID_NODE_GLOBAL_VDISTR)
            return 6;
        if (start_intent == ID_NODE_HLONG && end_intent == ID_NODE_HLONG)
            return 57;
        if (start_intent == ID_NODE_HLONG && end_intent == ID_NODE_LOCAL)
            return 265;
        if (start_intent == ID_NODE_HLONG && end_intent == ID_NODE_VLONG)
            return 197;
        if (start_intent == ID_NODE_HQUAD && end_intent == ID_NODE_HLONG)
            return 16;
        if (start_intent == ID_NODE_HQUAD && end_intent == ID_NODE_LOCAL)
            return 115;
        if (start_intent == ID_NODE_HQUAD && end_intent == ID_NODE_VLONG)
            return 56;
        if (start_intent == ID_NODE_INT_INTERFACE && end_intent == ID_NODE_LOCAL)
            return 0;
        if (start_intent == ID_NODE_LOCAL && end_intent == ID_NODE_DOUBLE)
            return 71;
        if (start_intent == ID_NODE_LOCAL && end_intent == ID_NODE_HQUAD)
            return 0;
        if (start_intent == ID_NODE_LOCAL && end_intent == ID_NODE_LOCAL)
            return 106;
        if (start_intent == ID_NODE_LOCAL && end_intent == ID_NODE_PINBOUNCE)
            return 55;
        if (start_intent == ID_NODE_LOCAL && end_intent == ID_NODE_PINFEED)
            return 0;
        if (start_intent == ID_NODE_LOCAL && end_intent == ID_NODE_SINGLE)
            return 0;
        if (start_intent == ID_NODE_LOCAL && end_intent == ID_NODE_VQUAD)
            return 0;
        if (start_intent == ID_NODE_OUTPUT && end_intent == ID_NODE_INT_INTERFACE)
            return 0;
        if (start_intent == ID_NODE_PINBOUNCE && end_intent == ID_NODE_LOCAL)
            return 0;
        if (start_intent == ID_NODE_PINFEED && end_intent == ID_INTENT_DEFAULT)
            return 0;
        if (start_intent == ID_NODE_SINGLE && end_intent == ID_NODE_LOCAL)
            return 63;
        if (start_intent == ID_NODE_VLONG && end_intent == ID_NODE_HLONG)
            return 43;
        if (start_intent == ID_NODE_VLONG && end_intent == ID_NODE_LOCAL)
            return 159;
        if (start_intent == ID_NODE_VLONG && end_intent == ID_NODE_VLONG)
            return 94;
        if (start_intent == ID_NODE_VQUAD && end_intent == ID_NODE_HLONG)
            return 0;
        if (start_intent == ID_NODE_VQUAD && end_intent == ID_NODE_LOCAL)
            return 81;
        if (start_intent == ID_NODE_VQUAD && end_intent == ID_NODE_VLONG)
            return 0;
        return 100; // catch-all default
    }

    int32_t wireIntent(WireId wire) const
    {
        if (wire.tile == -1)
            return chip_info->nodes[wire.index].intent;
        else
            return locInfo(wire).wire_data[wire.index].intent;
    }

    DelayInfo getPipDelay(PipId pip) const
    {
        DelayInfo delay;
        // early/fast-corner scale for the min-delay (hold) pass.  Fabric routing
        // ~0.45x slow (golden get_net_delays FAST_MIN/SLOW_MAX = 0.562, but the
        // per-PIP tail is lower); the dedicated global clock tree is low-variation
        // (~0.9) so hold-critical clock skew isn't understated.
        float minscale = 0.45f;
        NPNR_ASSERT(pip != PipId());
        if (locInfo(pip).pip_data[pip.index].flags == PIP_TILE_ROUTING) {
            int src_intent = wireIntent(getPipSrcWire(pip)), dst_intent = wireIntent(getPipDstWire(pip));
            if (src_intent == ID_NODE_GLOBAL_VDISTR || src_intent == ID_NODE_GLOBAL_HROUTE ||
                src_intent == ID_NODE_GLOBAL_VROUTE || src_intent == ID_NODE_GLOBAL_HDISTR ||
                src_intent == ID_NODE_GLOBAL_LEAF || src_intent == ID_NODE_GLOBAL_BUFG) {
                minscale = 0.9f;

                // Global clock-network per-hop delays, CALIBRATED to the golden
                // Vivado write_sdf on the VC707 ethloop design (see
                // ethsoc/openflow/opentimer/globalchar.{py,json}).  The BUFG->sink
                // insertion delay of the 994-fanout userclk2/eth_clk global net is
                // 2.05 ns median (tight, p95 2.09 -- low skew).  A BUFG->leaf path
                // = a few dedicated spine hops (global->global, shared low-R clock
                // metal) + exactly ONE leaf tap (global->local) into the sink's
                // fabric tile, and that once-per-path tap carries the bulk of the
                // insertion delay.  Loading the exit (fires once/sink) makes the
                // total robust to the spine hop-count the SDF can't resolve.
                // Old flat values were 100/250 ps -> ~650 ps total, 3x under Vivado.
                const delay_t GLOBAL_SPINE_HOP = 70;   // global->global dedicated spine
                const delay_t GLOBAL_EXIT_HOP = 1697;  // global->local/long leaf tap
                if (dst_intent == ID_NODE_LOCAL || dst_intent == ID_NODE_HLONG || dst_intent == ID_NODE_VLONG ||
                    dst_intent == ID_NODE_VQUAD || dst_intent == ID_NODE_HQUAD) {
                    delay.delay = GLOBAL_EXIT_HOP;
                } else {
                    delay.delay = GLOBAL_SPINE_HOP;
                }
            } else if (dst_intent == ID_NODE_LAGUNA_DATA) {
                delay.delay = 5000;
            } else {
                const delay_t pip_epsilon = 35;
                auto &pip_data = locInfo(pip).pip_data[pip.index];
                auto &pip_timing = chip_info->timing_data->pip_timing_classes[pip_data.timing_class];
                int src_len = 1;
                auto found_srcloc = driving_pip_loc.find(getPipSrcWire(pip));
                if (found_srcloc != driving_pip_loc.end()) {
                    src_len =
                            std::max(1, std::abs(found_srcloc->second.first - (pip.tile % chip_info->width)) +
                                                std::abs(found_srcloc->second.second - (pip.tile / chip_info->width)));
                }
                auto &src_timing =
                        chip_info->timing_data
                                ->wire_timing_classes[locInfo(pip).wire_data[pip_data.src_index].timing_class];
                delay_t pip_delay =
                        pip_timing.max_delay + delay_t((float(src_len * src_timing.resistance + pip_timing.resistance) *
                                                        pip_timing.capacitance) /
                                                       1e9);
                if (!pip_timing.is_buffered) {
                    auto &dst_timing =
                            chip_info->timing_data
                                    ->wire_timing_classes[locInfo(pip).wire_data[pip_data.dst_index].timing_class];
                    pip_delay += delay_t(
                            (float(src_timing.resistance + pip_timing.resistance) * dst_timing.capacitance) / 1e9);
                }
                delay.delay = std::max(pip_delay, pip_epsilon);
            }
        } else if (locInfo(pip).pip_data[pip.index].flags == PIP_LUT_ROUTETHRU) {
            delay.delay = 300;
        } else
            delay.delay = 25;
        delay.min = delay_t(delay.delay * minscale);   // fast/early corner (hold)
        return delay;
    }

    DownhillPipRange getPipsDownhill(WireId wire) const
    {
        DownhillPipRange range;
        NPNR_ASSERT(wire != WireId());
        TileWireRange twr = getTileWireRange(wire);
        range.b.chip = chip_info;
        range.b.twi = twr.b;
        range.b.twi_end = twr.e;
        range.b.cursor = -1;
        ++range.b;
        range.e.chip = chip_info;
        range.e.twi = twr.e;
        range.e.twi_end = twr.e;
        range.e.cursor = 0;
        return range;
    }

    UphillPipRange getPipsUphill(WireId wire) const
    {
        UphillPipRange range;
        NPNR_ASSERT(wire != WireId());
        TileWireRange twr = getTileWireRange(wire);
        range.b.chip = chip_info;
        range.b.twi = twr.b;
        range.b.twi_end = twr.e;
        range.b.cursor = -1;
        ++range.b;
        range.e.chip = chip_info;
        range.e.twi = twr.e;
        range.e.twi_end = twr.e;
        range.e.cursor = 0;
        return range;
    }

    UphillPipRange getWireAliases(WireId wire) const
    {
        UphillPipRange range;
        range.b.cursor = 0;
        range.b.twi.cursor = 0;
        range.e.cursor = 0;
        range.e.twi.cursor = 0;
        return range;
    }

    // -------------------------------------------------

    GroupId getGroupByName(IdString name) const { return GroupId(); }
    IdString getGroupName(GroupId group) const { return IdString(); }
    std::vector<GroupId> getGroups() const { return {}; }
    std::vector<BelId> getGroupBels(GroupId group) const { return {}; }
    std::vector<WireId> getGroupWires(GroupId group) const { return {}; }
    std::vector<PipId> getGroupPips(GroupId group) const { return {}; }
    std::vector<GroupId> getGroupGroups(GroupId group) const { return {}; }

    // -------------------------------------------------
    mutable IdString gnd_glbl, gnd_row, vcc_glbl, vcc_row;
    delay_t estimateDelay(WireId src, WireId dst, bool debug = false) const;
    delay_t predictDelay(const NetInfo *net_info, const PortRef &sink) const;
    ArcBounds getRouteBoundingBox(WireId src, WireId dst) const;
    delay_t getBoundingBoxCost(WireId src, WireId dst, int distance) const;
    delay_t getDelayEpsilon() const { return 20; }
    delay_t getRipupDelayPenalty() const { return 120; }
    delay_t getWireRipupDelayPenalty(WireId wire) const;
    float getDelayNS(delay_t v) const { return v * 0.001; }
    DelayInfo getDelayFromNS(float ns) const
    {
        DelayInfo del;
        del.delay = delay_t(ns * 1000);
        return del;
    }
    uint32_t getDelayChecksum(delay_t v) const { return v; }
    bool getBudgetOverride(const NetInfo *net_info, const PortRef &sink, delay_t &budget) const;

    // -------------------------------------------------

    bool pack();
    bool place();
    bool route();
    // -------------------------------------------------

    std::vector<GraphicElement> getDecalGraphics(DecalId decal) const;

    DecalXY getBelDecal(BelId bel) const;
    DecalXY getWireDecal(WireId wire) const;
    DecalXY getPipDecal(PipId pip) const;
    DecalXY getGroupDecal(GroupId group) const;

    // -------------------------------------------------

    // Get the delay through a cell from one port to another, returning false
    // if no path exists. This only considers combinational delays, as required by the Arch API
    bool getCellDelay(const CellInfo *cell, IdString fromPort, IdString toPort, DelayInfo &delay) const;
    // Get the port class, also setting clockInfoCount to the number of TimingClockingInfos associated with a port
    TimingPortClass getPortTimingClass(const CellInfo *cell, IdString port, int &clockInfoCount) const;

    // DSP48E1 combinational timing helpers (see arch.cc). Phase 1: model the
    // fully-combinational DSP48E1; registered configs stay TMG_IGNORE.
    IdString dspStripBusIndex(IdString port) const;
    bool dsp48e1IsCombinational(const CellInfo *cell) const;
    double dsp48e1CombInputDelayNS(IdString base) const;
    bool dsp48e1IsTimedOutput(IdString base) const;
    // Get the TimingClockingInfo of a port
    TimingClockingInfo getPortClockingInfo(const CellInfo *cell, IdString port, int index) const;

    // -------------------------------------------------

    // Perform placement validity checks, returning false on failure (all
    // implemented in arch_place.cc)

    bool xc7_cell_timing_lookup(int tt_id, int inst_id, IdString variant, IdString from_port, IdString to_port,
                                DelayInfo &delay) const;

    // Whether or not a given cell can be placed at a given Bel
    // This is not intended for Bel type checks, but finer-grained constraints
    // such as conflicting set/reset signals, etc
    bool isValidBelForCell(CellInfo *cell, BelId bel) const;

    // Return true whether all Bels at a given location are valid
    bool isBelLocationValid(BelId bel) const;
    void dumpTileStatus(BelId bel) const;

    bool xcu_logic_tile_valid(IdString tileType, LogicTileStatus &lts) const;
    bool xc7_logic_tile_valid(IdString tileType, LogicTileStatus &lts) const;

    IdString getBelTileType(BelId bel) const { return IdString(locInfo(bel).type); }
    bool isLogicTile(BelId bel) const
    {
        IdString belTileType = getBelTileType(bel);
        return (belTileType == id_CLEL_L || belTileType == id_CLEL_R || belTileType == id_CLEM ||
                belTileType == id_CLEM_R || belTileType == id_CLBLL_L || belTileType == id_CLBLL_R ||
                belTileType == id_CLBLM_L || belTileType == id_CLBLM_R);
    }
    bool isBRAMTile(BelId bel) const
    {
        IdString belTileType = getBelTileType(bel);
        return belTileType == id_BRAM || belTileType == id_BRAM_L || belTileType == id_BRAM_R;
    }
    bool isLogicTile(WireId wire) const
    {
        if (wire.tile == -1)
            return false;
        IdString wireTileType = chip_info->tile_insts[wire.tile].type;
        return (wireTileType == id_CLEL_L || wireTileType == id_CLEL_R || wireTileType == id_CLEM ||
                wireTileType == id_CLEM_R || wireTileType == id_CLBLL_L || wireTileType == id_CLBLL_R ||
                wireTileType == id_CLBLM_L || wireTileType == id_CLBLM_R);
    }

    Loc getSiteLocInTile(BelId bel) const
    {
        Loc l;
        auto &site = chip_info->tile_insts[bel.tile].site_insts[locInfo(bel).bel_data[bel.index].site];
        l.x = site.rel_x;
        l.y = site.rel_y;
        l.z = locInfo(bel).bel_data[bel.index].site_variant;
        return l;
    }

    std::vector<std::pair<std::string, std::string>> getTilesAndTypes() const
    {
        std::vector<std::pair<std::string, std::string>> tt;
        for (int i = 0; i < chip_info->num_tiles; i++)
            tt.emplace_back(chip_info->tile_insts[i].name.get(),
                            IdString(chip_info->tile_types[chip_info->tile_insts[i].type].type).str(this));
        return tt;
    }

    Loc getTileLocation(int tile) const
    {
        NPNR_ASSERT(0 <= tile);
        Loc loc;
        loc.x = tile % chip_info->width;
        loc.y = tile / chip_info->width;
        return loc;
    }

    const TileInstInfoPOD &getTileByLocation(int x, int y) const
    {
        NPNR_ASSERT(0 <= x && 0 <= y);
        auto tile_index = y * chip_info->width + x;
        NPNR_ASSERT(tile_index < chip_info->width * chip_info->height);
        return chip_info->tile_insts[tile_index];
    }

    const TileInstInfoPOD &getTileByIndex(int index) const
    {
        NPNR_ASSERT(0 <= index);
        NPNR_ASSERT(index < chip_info->num_tiles);
        return chip_info->tile_insts[index];
    }

    const IdString getTileType(const TileInstInfoPOD &tile_inst) const
    {
        return IdString(chip_info->tile_types[tile_inst.type].type);
    }

    // -------------------------------------------------
    // Assign architecure-specific arguments to nets and cells, which must be
    // called between packing or further
    // netlist modifications, and validity checks
    void assignArchInfo();
    void assignCellInfo(CellInfo *cell);

    void fixupPlacement();
    void fixupRouting();

    void routeVcc();
    void routeClock();
    void applyFixedRoutes(const std::string &filename);
    // region_only restricts the dump to the NEXTPNR_PARTITION_ROI rectangle.
    void writeFixedRoutes(const std::string &filename, bool region_only = false) const;
    bool gtClockTemplateRoute(NetInfo *clk_net, PortRef &usr);
    void findSourceSinkLocations();
    std::unordered_map<WireId, Loc> sink_locs, source_locs;
    // -------------------------------------------------

    void parseXdc(std::istream &file);
    mutable std::unordered_map<std::string, std::string> pin_to_site;
    std::string getPackagePinSite(const std::string &pin) const;
    std::string getBelPackagePin(BelId bel) const;
    std::string getBelSite(BelId bel) const
    {
        auto &site = getBelSiteRef(bel);
        return site.name.get();
    }

    const SiteInstInfoPOD &getBelSiteRef(BelId bel) const
    {
        int s = locInfo(bel).bel_data[bel.index].site;
        NPNR_ASSERT(s != -1);
        auto &tile = chip_info->tile_insts[bel.tile];
        return tile.site_insts[s];
    }

    int getHclkForIob(BelId pad);
    int getHclkForIoi(int tile);

    // -------------------------------------------------

    static const std::string defaultPlacer;
    static const std::vector<std::string> availablePlacers;

    static const std::string defaultRouter;
    static const std::vector<std::string> availableRouters;

    // -------------------------------------------------
    template <typename Id> const TileTypeInfoPOD &locInfo(Id &id) const
    {
        return chip_info->tile_types[chip_info->tile_insts[id.tile].type];
    }
    // -------------------------------------------------
    // region_only restricts emission to the NEXTPNR_PARTITION_ROI rectangle,
    // which is what makes the output a partial bitstream source.
    void writeFasm(const std::string &filename, bool region_only = false);
};

NEXTPNR_NAMESPACE_END
