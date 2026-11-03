#!/usr/bin/env python3
"""Convert L4T (kernel 4.9) Tegra210 EMC DT tables to the mainline binary format.

Mainline's tegra210-emc driver reads an array of `struct tegra210_emc_timing`
(drivers/memory/tegra/tegra210-emc.h, unchanged since v5.10) from a
"nvidia,tegra210-emc-table" reserved-memory region, terminated by an entry
with revision == 0. L4T instead describes each timing as a DT node of
"nvidia,tegra21-emc-table" properties. The field <-> property mapping below
follows the struct order exactly.

  l4t-emc-to-bin.py INPUT.dtsi OUT_NOMINAL.bin OUT_DERATED.bin

INPUT holds one `emc-table@<ramcode>` node with `emc-table@<khz>` and
`emc-table-derated@<khz>` children (see hw/l4t-emc-table-ramcode0.dtsi).
Each output is padded with zeroes to REGION_SIZE (so the terminating zero
entry is present).
"""
import re
import struct
import sys

REGION_SIZE = 0x8000

# (struct field, L4T property, kind, count)
#   kind: "u32" -> count cells; "str" -> fixed-size NUL-padded char array
CLKTREE = ["c0d0u0", "c0d0u1", "c0d1u0", "c0d1u1",
           "c1d0u0", "c1d0u1", "c1d1u0", "c1d1u1"]
LAYOUT = [
    ("revision", "nvidia,revision", "u32", 1),
    ("dvfs_ver", "nvidia,dvfs-version", "str", 60),
    ("rate", "clock-frequency", "u32", 1),
    ("min_volt", "nvidia,emc-min-mv", "u32", 1),
    ("gpu_min_volt", "nvidia,gk20a-min-mv", "u32", 1),
    ("clock_src", "nvidia,source", "str", 32),
    ("clk_src_emc", "nvidia,src-sel-reg", "u32", 1),
    ("needs_training", "nvidia,needs-training", "u32", 1),
    ("training_pattern", "nvidia,training_pattern", "u32", 1),
    ("trained", "nvidia,trained", "u32", 1),
    ("periodic_training", "nvidia,periodic_training", "u32", 1),
    *[(f"trained_dram_clktree[{c}]", f"nvidia,trained_dram_clktree_{c}", "u32", 1) for c in CLKTREE],
    *[(f"current_dram_clktree[{c}]", f"nvidia,current_dram_clktree_{c}", "u32", 1) for c in CLKTREE],
    ("run_clocks", "nvidia,run_clocks", "u32", 1),
    ("tree_margin", "nvidia,tree_margin", "u32", 1),
    ("num_burst", "nvidia,burst-regs-num", "u32", 1),
    ("num_burst_per_ch", "nvidia,burst-regs-per-ch-num", "u32", 1),
    ("num_trim", "nvidia,trim-regs-num", "u32", 1),
    ("num_trim_per_ch", "nvidia,trim-regs-per-ch-num", "u32", 1),
    ("num_mc_regs", "nvidia,burst-mc-regs-num", "u32", 1),
    ("num_up_down", "nvidia,la-scale-regs-num", "u32", 1),
    ("vref_num", "nvidia,vref-regs-num", "u32", 1),
    ("training_mod_num", "nvidia,training-mod-regs-num", "u32", 1),
    ("dram_timing_num", "nvidia,dram-timing-regs-num", "u32", 1),
    ("ptfv_list", "nvidia,ptfv", "u32", 12),
    ("burst_regs", "nvidia,emc-registers", "u32", 221),
    ("burst_reg_per_ch", "nvidia,emc-burst-regs-per-ch", "u32", 8),
    ("shadow_regs_ca_train", "nvidia,emc-shadow-regs-ca-train", "u32", 221),
    ("shadow_regs_quse_train", "nvidia,emc-shadow-regs-quse-train", "u32", 221),
    ("shadow_regs_rdwr_train", "nvidia,emc-shadow-regs-rdwr-train", "u32", 221),
    ("trim_regs", "nvidia,emc-trim-regs", "u32", 138),
    ("trim_perch_regs", "nvidia,emc-trim-regs-per-ch", "u32", 10),
    ("vref_perch_regs", "nvidia,emc-vref-regs", "u32", 4),
    ("dram_timings", "nvidia,emc-dram-timing-regs", "u32", 5),
    ("training_mod_regs", "nvidia,emc-training-mod-regs", "u32", 20),
    ("save_restore_mod_regs", "nvidia,emc-save-restore-mod-regs", "u32", 12),
    ("burst_mc_regs", "nvidia,emc-burst-mc-regs", "u32", 33),
    ("la_scale_regs", "nvidia,emc-la-scale-regs", "u32", 24),
    ("min_mrs_wait", "nvidia,min-mrs-wait", "u32", 1),
    ("emc_mrw", "nvidia,emc-mrw", "u32", 1),
    ("emc_mrw2", "nvidia,emc-mrw2", "u32", 1),
    ("emc_mrw3", "nvidia,emc-mrw3", "u32", 1),
    ("emc_mrw4", "nvidia,emc-mrw4", "u32", 1),
    ("emc_mrw9", "nvidia,emc-mrw9", "u32", 1),
    ("emc_mrs", "nvidia,emc-mrs", "u32", 1),
    ("emc_emrs", "nvidia,emc-emrs", "u32", 1),
    ("emc_emrs2", "nvidia,emc-emrs2", "u32", 1),
    ("emc_auto_cal_config", "nvidia,emc-auto-cal-config", "u32", 1),
    *[(f"emc_auto_cal_config{i}", f"nvidia,emc-auto-cal-config{i}", "u32", 1) for i in range(2, 9)],
    ("emc_cfg_2", "nvidia,emc-cfg-2", "u32", 1),
    ("emc_sel_dpd_ctrl", "nvidia,emc-sel-dpd-ctrl", "u32", 1),
    ("emc_fdpd_ctrl_cmd_no_ramp", "nvidia,emc-fdpd-ctrl-cmd-no-ramp", "u32", 1),
    ("dll_clk_src", "nvidia,dll-clk-src", "u32", 1),
    ("clk_out_enb_x_0_clk_enb_emc_dll", "nvidia,clk-out-enb-x-0-clk-enb-emc-dll", "u32", 1),
    ("latency", "nvidia,emc-clock-latency-change", "u32", 1),
]
# Properties present in L4T nodes but not part of the binary struct.
IGNORED = {"compatible", "name", "phandle", "linux,phandle"}

ENTRY_SIZE = sum(4 * n if k == "u32" else n for _, _, k, n in LAYOUT)


def parse_nodes(text):
    """Return {node_name: {prop: value}} for every `emc-table*@<khz>` leaf node."""
    nodes = {}
    # leaf nodes only: bodies without nested braces (skips the ram-code container)
    for m in re.finditer(r"(emc-table(?:-derated)?@\d+)\s*\{([^{}]*)\};", text):
        name, body = m.group(1), m.group(2)
        if "clock-frequency" not in body:
            continue
        props = {}
        for p in re.finditer(r"([\w,#-]+)\s*=\s*(<[^;]*>|\"[^\"]*\")\s*;", body):
            key, val = p.group(1), p.group(2)
            if val.startswith("<"):
                props[key] = [int(x, 0) for x in val[1:-1].split()]
            else:
                props[key] = val[1:-1]
        nodes[name] = props
    return nodes


def pack(props, node):
    out = b""
    used = set()
    for field, prop, kind, n in LAYOUT:
        if prop not in props:
            sys.exit(f"{node}: missing {prop} ({field})")
        used.add(prop)
        v = props[prop]
        if kind == "str":
            b = v.encode()
            if len(b) >= n:
                sys.exit(f"{node}: {prop} too long")
            out += b.ljust(n, b"\0")
        else:
            if len(v) != n:
                sys.exit(f"{node}: {prop} has {len(v)} cells, expected {n}")
            out += struct.pack(f"<{n}I", *v)
    extra = set(props) - used - IGNORED
    if extra:
        sys.exit(f"{node}: unmapped properties {sorted(extra)}")
    # sanity: the *-num counts must match the arrays we packed
    assert props["nvidia,burst-regs-num"][0] == 221
    assert props["nvidia,trim-regs-num"][0] == 138
    assert len(out) == ENTRY_SIZE
    return out


def main():
    src, out_nom, out_der = sys.argv[1:4]
    nodes = parse_nodes(open(src).read())
    tables = {"nominal": [], "derated": []}
    for name, props in nodes.items():
        kind = "derated" if "derated" in name else "nominal"
        tables[kind].append((props["clock-frequency"][0], name, props))
    for kind, path in (("nominal", out_nom), ("derated", out_der)):
        entries = sorted(tables[kind])
        if not entries:
            sys.exit(f"no {kind} entries")
        blob = b"".join(pack(p, n) for _, n, p in entries)
        blob = blob.ljust(REGION_SIZE, b"\0")
        assert len(blob) == REGION_SIZE, "table does not fit the region"
        open(path, "wb").write(blob)
        rates = ", ".join(f"{r} kHz rev {p['nvidia,revision'][0]:#x}" for r, _, p in entries)
        print(f"{kind}: {len(entries)} entries ({rates}), entry {ENTRY_SIZE} B -> {path}")


if __name__ == "__main__":
    main()
