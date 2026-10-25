/*
 *  nextpnr -- Next Generation Place and Route
 *
 *  Copyright (C) 2018  Clifford Wolf <clifford@symbioticeda.com>
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

#ifdef MAIN_EXECUTABLE

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <initializer_list>
#include "command.h"
#include "design_utils.h"
#include "jsonwrite.h"
#include "log.h"
#include "router2.h"
#include "timing.h"
#include "util.h"

USING_NEXTPNR_NAMESPACE

class UspCommandHandler : public CommandHandler
{
  public:
    UspCommandHandler(int argc, char **argv);
    virtual ~UspCommandHandler(){};
    std::unique_ptr<Context> createContext(std::unordered_map<std::string, Property> &values) override;
    void setupArchContext(Context *ctx) override;
    void customBitstream(Context *ctx) override;
    void customAfterLoad(Context *ctx) override;

  protected:
    po::options_description getArchOptions() override;
};

UspCommandHandler::UspCommandHandler(int argc, char **argv) : CommandHandler(argc, argv) {}

po::options_description UspCommandHandler::getArchOptions()
{
    po::options_description specific("Architecture specific options");
    specific.add_options()("chipdb", po::value<std::string>(), "name of chip database binary");
    specific.add_options()("xdc", po::value<std::vector<std::string>>(), "XDC-style constraints file");
    specific.add_options()("xdc-strict", "treat an XDC target that matches nothing, an unsupported XDC command or an unread option as an error");
    specific.add_options()("fasm", po::value<std::string>(), "fasm bitstream file to write");
    specific.add_options()("fixed-routes", po::value<std::string>(),
                           "frozen hard-macro routing to LOCK before routing (net + src->dst pips)");
    specific.add_options()("write-fixed-routes", po::value<std::string>(),
                           "after routing, dump fabric routing in --fixed-routes format");
    specific.add_options()("region-only",
                           "restrict --fasm and --write-fixed-routes output to the NEXTPNR_PARTITION_ROI rectangle");
    specific.add_options()("allow-const-holdouts",
                           "only warn when a constant (GND/VCC) sink cannot be driven; the pin's silicon "
                           "value is then undefined (default: error).  Does not cover a constant driver "
                           "LUT whose net the router itself fails to route");
    specific.add_options()("test-keepout",
                           "run the partition keepout licence and verdict unit tests against this chipdb, print one "
                           "line per test and exit non-zero if any fails");

    return specific;
}

void UspCommandHandler::customBitstream(Context *ctx)
{
    bool region_only = vm.count("region-only") > 0;
    if (vm.count("fasm")) {
        std::string filename = vm["fasm"].as<std::string>();
        ctx->writeFasm(filename, region_only);
    }
    if (vm.count("write-fixed-routes"))
        ctx->writeFixedRoutes(vm["write-fixed-routes"].as<std::string>(), region_only);
    ctx->record_partition_modes();
}

std::unique_ptr<Context> UspCommandHandler::createContext(std::unordered_map<std::string, Property> &values)
{
    ArchArgs chipArgs;
    if (!vm.count("chipdb")) {
        log_error("chip database binary must be provided\n");
    }
    chipArgs.chipdb = vm["chipdb"].as<std::string>();
    return std::unique_ptr<Context>(new Context(chipArgs));
}

void UspCommandHandler::setupArchContext(Context *ctx)
{
    if (vm.count("test-keepout"))
        std::exit(partition_keepout_self_test(ctx) == 0 ? 0 : 1);
    if (vm.count("fixed-routes"))
        ctx->settings[ctx->id("fixed-routes")] = vm["fixed-routes"].as<std::string>();
}

void UspCommandHandler::customAfterLoad(Context *ctx)
{
    ctx->xdc_strict = vm.count("xdc-strict") != 0;
    if (vm.count("fixed-routes")) {
        const IdString key = ctx->id("fixed-routes");
        const std::string given = vm["fixed-routes"].as<std::string>();
        const std::string loaded = str_or_default(ctx->settings, key, "");
        if (loaded != given)
            log_info("fixed-routes: '%s' from the command line replaces '%s' stored in the input netlist\n",
                     given.c_str(), loaded.c_str());
        ctx->settings[key] = given;
    }
    auto erase_attrs = [&](std::unordered_map<IdString, Property> &attrs, std::initializer_list<const char *> names) {
        for (auto it = attrs.begin(); it != attrs.end();) {
            const std::string &key = it->first.str(ctx);
            if (std::any_of(names.begin(), names.end(), [&](const char *n) { return key == n; }))
                it = attrs.erase(it);
            else
                ++it;
        }
    };
    for (auto &c : ctx->cells)
        erase_attrs(c.second->attrs, {"NEXTPNR_TEXC_FROM", "NEXTPNR_TEXC_TO"});
    for (auto &n : ctx->nets)
        erase_attrs(n.second->attrs, {"NEXTPNR_TIMING_IGNORE"});
    if (vm.count("xdc")) {
        std::vector<std::string> files = vm["xdc"].as<std::vector<std::string>>();
        for (const auto &filename : files) {
            std::ifstream in(filename);
            if (!in)
                log_error("failed to open XDC file '%s'\n", filename.c_str());
            ctx->xdc_file = filename;
            ctx->parseXdc(in);
        }
        if (!ctx->xdc_dropped.empty()) {
            for (const auto &d : ctx->xdc_dropped)
                log_info("XDC target dropped: %s\n", d.c_str());
            log_error("%d XDC constraint(s) or target(s) were not applied, listed above [--xdc-strict]\n",
                      int(ctx->xdc_dropped.size()));
        }
    }
    ctx->snapshot_rm_cells();
    if (vm.count("no-pack") && !vm.count("pack-only"))
        ctx->warn_prepacked_x9_parity();
    (void)ctx->roi_active();
    if (vm.count("region-only") && ctx->roi_active() && ctx->rm_cells.empty())
        log_error("--region-only: the RM cell set snapshotted at import is empty%s, so the partition rectangle "
                  "governs no nets and the region-only outputs would cut every net at its edge with nothing checked. "
                  "An RM partial needs its RM cells unplaced in the input netlist; a placed netlist cannot supply "
                  "them.\n",
                  vm.count("no-place") ? " (--no-place with a placed input netlist)" : "");
    if (!vm.count("region-only") && ctx->roi_active() && ctx->rm_cells.empty())
        log_warning("partition rectangle: the RM cell set snapshotted at import is empty%s, so no RM net is governed "
                    "and the route clamp and the partition routing check confine nothing. This is the shape of a "
                    "static build; an RM build needs its RM cells unplaced in the input netlist.\n",
                    vm.count("no-place") ? " (--no-place with a placed input netlist)" : "");
    if (const char *blf = getenv("NEXTPNR_BEL_BLACKLIST")) {
        std::error_code ec;
        if (std::filesystem::is_directory(blf, ec))
            log_error("NEXTPNR_BEL_BLACKLIST: '%s' is a directory, not a file of bel names\n", blf);
        std::ifstream probe(blf);
        if (!probe)
            log_error("NEXTPNR_BEL_BLACKLIST: cannot open '%s'\n", blf);
    }
    if (vm.count("no-route") && vm.count("no-place") && !vm.count("route-clock-only"))
        log_info("routed import: recorded %d permuted LUT input pin(s) as routed sink wires\n",
                 ctx->recordLutPermutationPins());
    const bool allow_const_holdouts_given = vm.count("allow-const-holdouts") != 0;
    if (allow_const_holdouts_given)
        ctx->allow_const_holdouts = true;
}

int main(int argc, char *argv[])
{
    UspCommandHandler handler(argc, argv);
    return handler.exec();
}

#endif
