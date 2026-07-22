#!/usr/bin/env python3
"""
WALT -> PELT migration patcher.
Applies 6 exact-match edits. ABORTS (no partial writes to that file) if any
expected 'old' text isn't found verbatim -- meaning your repo's current
content differs from what was audited, and this needs re-review rather than
a fuzzy/forced apply.
"""
import sys

FAIL = []

def apply_edit(path, old, new, label):
    try:
        with open(path, 'r') as f:
            content = f.read()
    except FileNotFoundError:
        FAIL.append(f"[{label}] FILE NOT FOUND: {path}")
        return
    if old not in content:
        FAIL.append(f"[{label}] OLD TEXT NOT FOUND in {path} -- repo content has diverged from what was audited. Skipped.")
        return
    if content.count(old) > 1:
        FAIL.append(f"[{label}] OLD TEXT MATCHES {content.count(old)} TIMES in {path} -- ambiguous, refusing to guess. Skipped.")
        return
    content = content.replace(old, new, 1)
    with open(path, 'w') as f:
        f.write(content)
    print(f"[OK] {label} -> {path}")

# ---------------------------------------------------------------------------
# 1. arch/arm64/configs/munch_defconfig -- disable WALT
# ---------------------------------------------------------------------------
apply_edit(
    "arch/arm64/configs/munch_defconfig",
    "CONFIG_SCHED_WALT=y\n",
    "# CONFIG_SCHED_WALT is not set\n",
    "defconfig: disable SCHED_WALT",
)

# ---------------------------------------------------------------------------
# 2. init/Kconfig -- SCHED_CORE_CTL no longer depends on SCHED_WALT
# ---------------------------------------------------------------------------
apply_edit(
    "init/Kconfig",
    "config SCHED_CORE_CTL\n\tbool \"QTI Core Control\"\n\tdepends on SMP && SCHED_WALT\n",
    "config SCHED_CORE_CTL\n"
    "\tbool \"QTI Core Control\"\n"
    "\tdepends on SMP\n"
    "\t# Historically depended on SCHED_WALT: core_ctl's cluster discovery\n"
    "\t# used WALT's sched_cluster list, and its notifier telemetry\n"
    "\t# (msm_performance.c aggr_top_load/etc, sysfs-only, not consumed by\n"
    "\t# any in-kernel scheduling or thermal decision) used\n"
    "\t# walt_fill_ta_data(). Both were replaced with WALT-independent\n"
    "\t# equivalents in kernel/sched/core_ctl.c (capacity-grouped cluster\n"
    "\t# discovery via arch_scale_cpu_capacity(), and a PELT util_avg based\n"
    "\t# notifier data source) so this now only requires SMP, matching\n"
    "\t# every other CPU-hotplug-adjacent Kconfig option in this file.\n",
    "Kconfig: decouple SCHED_CORE_CTL from SCHED_WALT",
)

# ---------------------------------------------------------------------------
# 3. kernel/sched/features.h -- enable SUGOV_RT_MAX_FREQ
# ---------------------------------------------------------------------------
apply_edit(
    "kernel/sched/features.h",
    "SCHED_FEAT(SUGOV_RT_MAX_FREQ, false)\n",
    "SCHED_FEAT(SUGOV_RT_MAX_FREQ, true)\n",
    "features.h: enable SUGOV_RT_MAX_FREQ",
)

# ---------------------------------------------------------------------------
# 4. kernel/sched/core.c -- uclamp cgroup defaults
# ---------------------------------------------------------------------------
apply_edit(
    "kernel/sched/core.c",
    "static const struct uclamp_default_entry uclamp_forced_defaults[] = {\n"
    "\t{ \"top-app\",\t384,\t1024 },\n"
    "\t{ \"foreground\",\t128,\t768  },\n"
    "\t{ \"background\",\t0,\t512  },\n"
    "\t{ \"system\",\t64,\t1024 },\n"
    "};\n",
    "/*\n"
    " * Tuned for the WALT->PELT migration (see kernel/sched/core_ctl.c and\n"
    " * kernel/sched/topology.c for the rest of that migration).\n"
    " *\n"
    " * This device's little cluster tops out at capacity ~553/1024\n"
    " * (capacity-dmips-mhz 1024 vs 1894 in arch/arm64/boot/dts/vendor/qcom/\n"
    " * kona.dtsi, normalized). Values below reason from that ceiling rather\n"
    " * than being arbitrary:\n"
    " *\n"
    " * top-app min raised 384 -> 576 (~0.5625): previously sat below the\n"
    " * little-core ceiling, so a top-app task could run fully pinned to a\n"
    " * little core at max frequency with no floor pushing it to a big core.\n"
    " * 576 sits just above the little-core ceiling -- enough to avoid a\n"
    " * foreground task getting stuck maxed-out on a little core (a real\n"
    " * latency and, despite intuition, sometimes battery cost), without\n"
    " * unconditionally forcing every top-app task onto a big core regardless\n"
    " * of actual load. This is a deliberate balance point, not a maximum;\n"
    " * chosen over both a battery-leaning (~450-500) and performance-leaning\n"
    " * (~650-700) alternative.\n"
    " *\n"
    " * foreground max raised 768 -> 1024: 768 capped legitimately demanding\n"
    " * foreground work (e.g. a foreground service doing a burst of real work)\n"
    " * below full big-core capacity for no clear reason -- nothing about\n"
    " * \"foreground but not top-app\" implies it should be perf-limited below\n"
    " * background. min unchanged; this only removes an unnecessary ceiling.\n"
    " *\n"
    " * background, system: unchanged. Already sound -- background correctly\n"
    " * can't exceed little-core-equivalent capacity (thermal/battery\n"
    " * protection), system already has full ceiling with a small floor.\n"
    " */\n"
    "static const struct uclamp_default_entry uclamp_forced_defaults[] = {\n"
    "\t{ \"top-app\",\t576,\t1024 },\n"
    "\t{ \"foreground\",\t128,\t1024 },\n"
    "\t{ \"background\",\t0,\t512  },\n"
    "\t{ \"system\",\t64,\t1024 },\n"
    "};\n",
    "core.c: retune uclamp cgroup defaults",
)

# ---------------------------------------------------------------------------
# 5. kernel/sched/topology.c -- decouple EAS-force-on from CONFIG_SCHED_WALT
# ---------------------------------------------------------------------------
apply_edit(
    "kernel/sched/topology.c",
    "\t/*\n"
    "\t * EAS gets disabled when there are no asymmetric capacity\n"
    "\t * CPUs in the system. For example, all big CPUs are\n"
    "\t * hotplugged out on a b.L system. We want EAS enabled\n"
    "\t * all the time to get both power and perf benefits. Apply\n"
    "\t * this policy when WALT is enabled.\n"
    "\t */\n"
    "#ifndef CONFIG_SCHED_WALT\n"
    "\tif (!per_cpu(sd_asym_cpucapacity, cpu)) {\n"
    "\t\tif (sched_debug()) {\n"
    "\t\t\tpr_info(\"rd %*pbl: CPUs do not have asymmetric capacities\\n\",\n"
    "\t\t\t\t\tcpumask_pr_args(cpu_map));\n"
    "\t\t}\n"
    "\t\tgoto free;\n"
    "\t}\n"
    "#endif\n",
    "\t/*\n"
    "\t * EAS gets disabled when there are no asymmetric capacity\n"
    "\t * CPUs in the system. For example, all big CPUs are\n"
    "\t * hotplugged out on a b.L system. We want EAS enabled\n"
    "\t * all the time to get both power and perf benefits.\n"
    "\t *\n"
    "\t * This deliberately deviates from upstream, which turns EAS off\n"
    "\t * during a transient symmetric-only state (e.g. big cores offlined\n"
    "\t * by thermal mitigation or core_ctl). That upstream check is\n"
    "\t * skipped unconditionally here -- this was previously gated on\n"
    "\t * CONFIG_SCHED_WALT; kept as PitchKernel policy independent of the\n"
    "\t * WALT->PELT migration by explicit request. Revisit if EAS\n"
    "\t * behavior during sustained thermal throttling proves undesirable.\n"
    "\t */\n",
    "topology.c: decouple EAS force-enable from CONFIG_SCHED_WALT",
)

# ---------------------------------------------------------------------------
# 6. kernel/sched/core_ctl.c -- this is the large one (cluster discovery +
#    walt_fill_ta_data replacement). Applied as two separate edits.
# ---------------------------------------------------------------------------
apply_edit(
    "kernel/sched/core_ctl.c",
    "static int __init core_ctl_init(void)\n"
    "{\n"
    "\tstruct sched_cluster *cluster;\n"
    "\tint ret;\n"
    "\n"
    "\tcpuhp_setup_state_nocalls(CPUHP_AP_ONLINE_DYN,\n"
    "\t\t\t\"core_ctl/isolation:online\",\n"
    "\t\t\tcore_ctl_isolation_online_cpu, NULL);\n"
    "\n"
    "\tcpuhp_setup_state_nocalls(CPUHP_CORE_CTL_ISOLATION_DEAD,\n"
    "\t\t\t\"core_ctl/isolation:dead\",\n"
    "\t\t\tNULL, core_ctl_isolation_dead_cpu);\n"
    "\n"
    "\tfor_each_sched_cluster(cluster) {\n"
    "\t\tret = cluster_init(&cluster->cpus);\n"
    "\t\tif (ret)\n"
    "\t\t\tpr_warn(\"unable to create core ctl group: %d\\n\", ret);\n"
    "\t}\n"
    "\n"
    "\tinitialized = true;\n"
    "\treturn 0;\n"
    "}\n",
    "/*\n"
    " * Discover CPU clusters from relative compute capacity rather than WALT's\n"
    " * sched_cluster linked list. Two CPUs are considered part of the same\n"
    " * cluster iff arch_scale_cpu_capacity() reports the same value for both,\n"
    " * which is the same capacity-grouping primitive EAS/fair.c already use\n"
    " * for performance-domain construction -- this keeps core_ctl's notion of\n"
    " * \"cluster\" consistent with EAS's rather than introducing a second,\n"
    " * divergent grouping mechanism.\n"
    " *\n"
    " * This runs once at late_initcall, well before hotplug, so a plain\n"
    " * for_each_possible_cpu() scan is fine -- no capacity values change\n"
    " * during this pass.\n"
    " */\n"
    "static int __init core_ctl_init_clusters(void)\n"
    "{\n"
    "\tcpumask_t assigned = CPU_MASK_NONE;\n"
    "\tint cpu, ret;\n"
    "\n"
    "\tfor_each_possible_cpu(cpu) {\n"
    "\t\tcpumask_t group;\n"
    "\t\tunsigned long cap;\n"
    "\t\tint other;\n"
    "\n"
    "\t\tif (cpumask_test_cpu(cpu, &assigned))\n"
    "\t\t\tcontinue;\n"
    "\n"
    "\t\tcap = arch_scale_cpu_capacity(NULL, cpu);\n"
    "\t\tcpumask_clear(&group);\n"
    "\t\tcpumask_set_cpu(cpu, &group);\n"
    "\n"
    "\t\tfor_each_possible_cpu(other) {\n"
    "\t\t\tif (other == cpu || cpumask_test_cpu(other, &assigned))\n"
    "\t\t\t\tcontinue;\n"
    "\t\t\tif (arch_scale_cpu_capacity(NULL, other) == cap)\n"
    "\t\t\t\tcpumask_set_cpu(other, &group);\n"
    "\t\t}\n"
    "\n"
    "\t\tcpumask_or(&assigned, &assigned, &group);\n"
    "\n"
    "\t\tret = cluster_init(&group);\n"
    "\t\tif (ret)\n"
    "\t\t\tpr_warn(\"unable to create core ctl group: %d\\n\", ret);\n"
    "\t}\n"
    "\n"
    "\treturn 0;\n"
    "}\n"
    "\n"
    "static int __init core_ctl_init(void)\n"
    "{\n"
    "\tcpuhp_setup_state_nocalls(CPUHP_AP_ONLINE_DYN,\n"
    "\t\t\t\"core_ctl/isolation:online\",\n"
    "\t\t\tcore_ctl_isolation_online_cpu, NULL);\n"
    "\n"
    "\tcpuhp_setup_state_nocalls(CPUHP_CORE_CTL_ISOLATION_DEAD,\n"
    "\t\t\t\"core_ctl/isolation:dead\",\n"
    "\t\t\tNULL, core_ctl_isolation_dead_cpu);\n"
    "\n"
    "\tcore_ctl_init_clusters();\n"
    "\n"
    "\tinitialized = true;\n"
    "\treturn 0;\n"
    "}\n",
    "core_ctl.c: capacity-based cluster discovery (replaces WALT sched_cluster)",
)

apply_edit(
    "kernel/sched/core_ctl.c",
    "static void core_ctl_call_notifier(void)\n"
    "{\n"
    "\tstruct core_ctl_notif_data ndata = {0};\n"
    "\tstruct notifier_block *nb;\n"
    "\n"
    "\t/*\n"
    "\t * Don't bother querying the stats when the notifier\n"
    "\t * chain is empty.\n"
    "\t */\n"
    "\trcu_read_lock();\n"
    "\tnb = rcu_dereference_raw(core_ctl_notifier.head);\n"
    "\trcu_read_unlock();\n"
    "\n"
    "\tif (!nb)\n"
    "\t\treturn;\n"
    "\n"
    "\tndata.nr_big = last_nr_big;\n"
    "\twalt_fill_ta_data(&ndata);\n"
    "\ttrace_core_ctl_notif_data(ndata.nr_big, ndata.coloc_load_pct,\n"
    "\t\t\tndata.ta_util_pct, ndata.cur_cap_pct);\n"
    "\n"
    "\tatomic_notifier_call_chain(&core_ctl_notifier, 0, &ndata);\n"
    "}\n",
    "/*\n"
    " * PELT-based replacement for WALT's walt_fill_ta_data(). Feeds the same\n"
    " * core_ctl_notif_data consumed by drivers/soc/qcom/msm_performance.c,\n"
    " * which only republishes these numbers as read-only sysfs telemetry\n"
    " * (aggr_top_load, top_load_cluster, etc) -- nothing in-kernel makes\n"
    " * scheduling or thermal decisions from this struct, so an approximation\n"
    " * here affects userspace-visible telemetry accuracy only, not scheduler\n"
    " * or thermal correctness.\n"
    " *\n"
    " * coloc_load_pct: WALT derived this from p->ravg.coloc_demand for tasks\n"
    " * in the DEFAULT_CGROUP_COLOC_ID related_thread_group (WALT's notion of\n"
    " * \"latency sensitive, keep together\" tasks -- in practice populated from\n"
    " * top-app + foreground). There is no PELT equivalent to\n"
    " * related_thread_group, so this reconstructs the same intent from the\n"
    " * cpu.uclamp cgroups those tasks actually live in: sum cfs_rq->avg.util_avg\n"
    " * for the top-app and foreground task_groups, scaled to the lowest-capacity\n"
    " * CPU the same way WALT's version scaled to min_cap_cpu.\n"
    " *\n"
    " * ta_util_pct[]/cur_cap_pct[]: per-cluster aggregate CFS utilization and\n"
    " * current frequency-capacity percentage, using core_ctl's own\n"
    " * cluster_state[] (populated by core_ctl_init_clusters(), capacity-grouped,\n"
    " * WALT-independent) instead of WALT's aggr_grp_load/sched_cluster list.\n"
    " */\n"
    "static struct task_group *coloc_tg_cache[2]; /* top-app, foreground */\n"
    "static bool coloc_tg_resolved;\n"
    "\n"
    "static void resolve_coloc_task_groups(void)\n"
    "{\n"
    "\tstatic const char * const coloc_names[2] = { \"top-app\", \"foreground\" };\n"
    "\tstruct task_group *tg;\n"
    "\tint found = 0;\n"
    "\n"
    "\trcu_read_lock();\n"
    "\tlist_for_each_entry_rcu(tg, &task_groups, list) {\n"
    "\t\tconst char *name;\n"
    "\t\tint i;\n"
    "\n"
    "\t\tif (!tg->css.cgroup || !tg->css.cgroup->kn)\n"
    "\t\t\tcontinue;\n"
    "\t\tname = tg->css.cgroup->kn->name;\n"
    "\t\tif (!name)\n"
    "\t\t\tcontinue;\n"
    "\n"
    "\t\tfor (i = 0; i < 2; i++) {\n"
    "\t\t\tif (!coloc_tg_cache[i] && !strcmp(name, coloc_names[i])) {\n"
    "\t\t\t\tcoloc_tg_cache[i] = tg;\n"
    "\t\t\t\tfound++;\n"
    "\t\t\t}\n"
    "\t\t}\n"
    "\t\tif (found == 2)\n"
    "\t\t\tbreak;\n"
    "\t}\n"
    "\trcu_read_unlock();\n"
    "\n"
    "\t/*\n"
    "\t * Cgroups are created once at boot by init and not recreated, so\n"
    "\t * once both are found the cache is permanently valid. If either\n"
    "\t * is still missing (e.g. called before init has set up cpuctl),\n"
    "\t * leave coloc_tg_resolved false so the next notifier tick retries.\n"
    "\t */\n"
    "\tif (coloc_tg_cache[0] && coloc_tg_cache[1])\n"
    "\t\tcoloc_tg_resolved = true;\n"
    "}\n"
    "\n"
    "static unsigned int coloc_group_util_sum(struct task_group *tg)\n"
    "{\n"
    "\tunsigned int sum = 0;\n"
    "\tint cpu;\n"
    "\n"
    "\tif (!tg || !tg->cfs_rq)\n"
    "\t\treturn 0;\n"
    "\n"
    "\tfor_each_possible_cpu(cpu) {\n"
    "\t\tstruct cfs_rq *cfs_rq = tg->cfs_rq[cpu];\n"
    "\n"
    "\t\tif (cfs_rq)\n"
    "\t\t\tsum += READ_ONCE(cfs_rq->avg.util_avg);\n"
    "\t}\n"
    "\n"
    "\treturn sum;\n"
    "}\n"
    "\n"
    "static void core_ctl_fill_ta_data(struct core_ctl_notif_data *data)\n"
    "{\n"
    "\tstruct cluster_data *cluster;\n"
    "\tunsigned int total_util = 0, min_cap_scale = 1024;\n"
    "\tint index = 0, i;\n"
    "\n"
    "\tif (!coloc_tg_resolved)\n"
    "\t\tresolve_coloc_task_groups();\n"
    "\n"
    "\tif (coloc_tg_resolved) {\n"
    "\t\ttotal_util = coloc_group_util_sum(coloc_tg_cache[0]) +\n"
    "\t\t\t     coloc_group_util_sum(coloc_tg_cache[1]);\n"
    "\n"
    "\t\t/* Scale to the lowest-capacity cluster, matching WALT's\n"
    "\t\t * min_cap_cpu normalization in the original implementation.\n"
    "\t\t */\n"
    "\t\tfor_each_cluster(cluster, index) {\n"
    "\t\t\tunsigned long cap =\n"
    "\t\t\t\tarch_scale_cpu_capacity(NULL, cluster->first_cpu);\n"
    "\t\t\tif (cap < min_cap_scale)\n"
    "\t\t\t\tmin_cap_scale = cap;\n"
    "\t\t}\n"
    "\n"
    "\t\tdata->coloc_load_pct = min_t(unsigned int,\n"
    "\t\t\t\tdiv_u64((u64)total_util * 100, min_cap_scale),\n"
    "\t\t\t\t100);\n"
    "\t}\n"
    "\n"
    "\ti = 0;\n"
    "\tindex = 0;\n"
    "\tfor_each_cluster(cluster, index) {\n"
    "\t\tunsigned int cluster_util = 0;\n"
    "\t\tunsigned long scale;\n"
    "\t\tint cpu;\n"
    "\n"
    "\t\tif (i == MAX_CLUSTERS)\n"
    "\t\t\tbreak;\n"
    "\n"
    "\t\tfor_each_cpu(cpu, &cluster->cpu_mask)\n"
    "\t\t\tcluster_util += READ_ONCE(cpu_rq(cpu)->cfs.avg.util_avg);\n"
    "\n"
    "\t\tscale = arch_scale_cpu_capacity(NULL, cluster->first_cpu);\n"
    "\t\tdata->ta_util_pct[i] = div_u64((u64)cluster_util * 100, scale);\n"
    "\n"
    "\t\tscale = arch_scale_freq_capacity(cluster->first_cpu);\n"
    "\t\tdata->cur_cap_pct[i] = (scale * 100) / 1024;\n"
    "\t\ti++;\n"
    "\t}\n"
    "}\n"
    "\n"
    "static void core_ctl_call_notifier(void)\n"
    "{\n"
    "\tstruct core_ctl_notif_data ndata = {0};\n"
    "\tstruct notifier_block *nb;\n"
    "\n"
    "\t/*\n"
    "\t * Don't bother querying the stats when the notifier\n"
    "\t * chain is empty.\n"
    "\t */\n"
    "\trcu_read_lock();\n"
    "\tnb = rcu_dereference_raw(core_ctl_notifier.head);\n"
    "\trcu_read_unlock();\n"
    "\n"
    "\tif (!nb)\n"
    "\t\treturn;\n"
    "\n"
    "\tndata.nr_big = last_nr_big;\n"
    "\tcore_ctl_fill_ta_data(&ndata);\n"
    "\ttrace_core_ctl_notif_data(ndata.nr_big, ndata.coloc_load_pct,\n"
    "\t\t\tndata.ta_util_pct, ndata.cur_cap_pct);\n"
    "\n"
    "\tatomic_notifier_call_chain(&core_ctl_notifier, 0, &ndata);\n"
    "}\n",
    "core_ctl.c: PELT-based walt_fill_ta_data replacement",
)

print()
if FAIL:
    print("=" * 70)
    print(f"{len(FAIL)} edit(s) FAILED -- these files were NOT modified:")
    for f in FAIL:
        print(" -", f)
    print("=" * 70)
    print("Fix these manually or re-run the audit against current repo state.")
    sys.exit(1)
else:
    print("All 6 edits applied successfully.")
