# ==============================================================================
# Script Name: DIAGNOSTIC.py
# Pipeline Stage: Stage 4 - Event-study model evaluation & conclusive workbook
# Description: Turns the event-study outputs into a model verdict:
#   1. Window leaderboards: best model per instrument in the calm pre-event
#      window, the shock week and the whole post-event period, for both the
#      Frozen (estimated before the event, never updated) and Adaptive
#      (re-estimated through the event) schemes, with Diebold-Mariano tests
#      against the best model and against the naive benchmark.
#   2. Robustness ranking: average rank of each model across instruments in
#      every window, its accuracy relative to naive, how much its error grows
#      from calm to shock, and whether its 95% volatility band still covers
#      realised moves (Kupiec test) -> recommended model per frequency.
#   3. Frozen vs Adaptive: how much re-estimation through the event helps.
#   4. Quality checks, and plots sorted into PHOTOS/<MODEL>/.
# Output: Pipeline_Outputs/Conclusive_Results/CONCLUSIVE_MODEL_DIAGNOSTICS.xlsx
# ==============================================================================

import math
import shutil
import sys
from datetime import datetime
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import ecmt3150_paths as P  # noqa: E402

BENCHMARKS = ["LFD_BENCHMARK.xlsx", "HFD_BENCHMARK.xlsx", "ML_BENCHMARK.xlsx"]
ALL_MODELS = {**P.STAGE2_MODELS, **P.STAGE3_MODELS}
FORECAST_KEYS = [*ALL_MODELS, "NAIVE_BENCHMARKS"]
CONCLUSIVE_NAME = "CONCLUSIVE_MODEL_DIAGNOSTICS.xlsx"
KEY_WINDOWS = ["Pre-event (calm)", "Shock (days 1-5)", "All post-event"]
SHOCK = "Shock (days 1-5)"
PRE = "Pre-event (calm)"
POST = "All post-event"


def sheet_title(name, used):
    title = name[:31]
    i = 2
    while title.lower() in used:
        suffix = f"_{i}"
        title = name[:31 - len(suffix)] + suffix
        i += 1
    used.add(title.lower())
    return title


def sort_photos():
    """Copy PNG_Plots/<MODEL>/*.png to PHOTOS/<MODEL>/ (fresh copy each run)."""
    if P.PHOTOS_DIR.exists():
        shutil.rmtree(P.PHOTOS_DIR)
    counts = {}
    for key in [*ALL_MODELS, "EVENT_STUDY"]:
        src = P.PNG_DIR / key
        pngs = sorted(src.glob("*.png")) if src.is_dir() else []
        if not pngs:
            continue
        dst = P.PHOTOS_DIR / key
        dst.mkdir(parents=True, exist_ok=True)
        for png in pngs:
            shutil.copy2(png, dst / png.name)
        counts[key] = len(pngs)
    return counts


def load_forecasts():
    frames = [P.read_model_table(key, "oos_forecasts") for key in FORECAST_KEYS]
    frames = [f for f in frames if f is not None and not f.empty]
    if not frames:
        return pd.DataFrame()
    fc = pd.concat(frames, ignore_index=True)
    fc["Frequency"] = fc["Model"].str.split("_").str[0]
    return fc


# Same windows as ECMT_EVENT_WINDOWS in ECMT3150_COMMON.R (trading days after the event).
EVENT_WINDOWS = {
    "LFD": {"Shock (days 1-5)": (1, 5), "Short run (6-20)": (6, 20),
            "Medium run (21-60)": (21, 60), "Long run (61+)": (61, math.inf)},
    "HFD": {"Shock (days 1-5)": (1, 5), "Aftermath (6+)": (6, math.inf)},
}


def window_labels(fc, wm=None):
    """One row per forecast and window it belongs to (rows appear in their own
    window and in 'All post-event')."""
    out = [fc[fc["Split"] == "PreEvent"].assign(Window=PRE),
           fc[fc["Split"] == "Event"].assign(Window=POST)]
    for freq, wins in EVENT_WINDOWS.items():
        ev = fc[(fc["Frequency"] == freq) & (fc["Split"] == "Event")]
        for name, (lo, hi) in wins.items():
            out.append(ev[(ev["Event_Day"] >= lo) & (ev["Event_Day"] <= hi)].assign(Window=name))
    return pd.concat(out, ignore_index=True)


# ------------------------------------------------------------------------------
# Diebold-Mariano test
# ------------------------------------------------------------------------------
def _t_sf(t, df):
    try:
        from scipy import stats
        return float(2 * stats.t.sf(abs(t), df))
    except Exception:
        return float(math.erfc(abs(t) / math.sqrt(2)))


def diebold_mariano(e1, e2):
    """Squared-error DM test, h=1, Harvey-Leybourne-Newbold correction.
    Negative statistic => model 1 more accurate."""
    d = np.asarray(e1, float) ** 2 - np.asarray(e2, float) ** 2
    d = d[np.isfinite(d)]
    n = len(d)
    if n < 3 or np.var(d, ddof=1) == 0:
        return np.nan, np.nan
    dm = d.mean() / math.sqrt(np.var(d, ddof=1) / n) * math.sqrt((n - 1) / n)
    return float(dm), _t_sf(dm, n - 1)


def leaderboards(wm, fc_win):
    """Best model per Frequency x Ticker x Scheme x Window, with DM tests."""
    rows, ranked = [], []
    errors = {}
    if not fc_win.empty:
        for k, g in fc_win.groupby(["Frequency", "Ticker", "Scheme", "Window", "Model"]):
            errors[k] = (g["Actual"] - g["Forecast"]).set_axis(g["Target_Date"].values)
    for (freq, ticker, scheme, win), g in wm[wm["Window"].isin(KEY_WINDOWS)].groupby(
            ["Frequency", "Ticker", "Scheme", "Window"]):
        g = g.sort_values("RMSE").copy()
        best = g.iloc[0]["Model"]
        naive = next((m for m in g["Model"] if "Naive" in m), None)
        for ref, col in ((best, "vs_Best"), (naive, "vs_Naive")):
            stats_, ps = [], []
            for m in g["Model"]:
                e1 = errors.get((freq, ticker, scheme, win, m))
                e2 = errors.get((freq, ticker, scheme, win, ref))
                if ref is None or m == ref or e1 is None or e2 is None:
                    stats_.append(np.nan); ps.append(np.nan); continue
                j = pd.concat([e1, e2], axis=1, join="inner").dropna()
                s, p = diebold_mariano(j.iloc[:, 0], j.iloc[:, 1])
                stats_.append(s); ps.append(p)
            g[f"DM_stat_{col}"] = stats_
            g[f"DM_p_{col}"] = ps
        ranked.append(g)
        runner = g.iloc[1] if len(g) > 1 else None
        b = g.iloc[0]
        rows.append({
            "Frequency": freq, "Ticker": ticker, "Scheme": scheme, "Window": win,
            "Best_Model": b["Model"], "Best_RMSE": b["RMSE"], "Best_RMSE_vs_Naive": b["RMSE_vs_Naive"],
            "Runner_Up": None if runner is None else runner["Model"],
            "Runner_Up_RMSE": None if runner is None else runner["RMSE"],
            "DM_p_Best_vs_Runner_Up": None if runner is None else runner["DM_p_vs_Best"],
            "DM_p_Best_vs_Naive": b["DM_p_vs_Naive"],
            "Significant_vs_Runner_Up_5%": "YES" if runner is not None and runner["DM_p_vs_Best"] < 0.05 else "NO",
            "N": int(b["N"]), "Start": b["Start"], "End": b["End"],
        })
    order = {w: i for i, w in enumerate(KEY_WINDOWS)}
    best_df = pd.DataFrame(rows)
    if not best_df.empty:
        best_df = best_df.sort_values(["Frequency", "Scheme", "Window", "Ticker"],
                                      key=lambda c: c.map(order) if c.name == "Window" else c)
    ranked_df = pd.concat(ranked, ignore_index=True) if ranked else pd.DataFrame()
    return best_df, ranked_df


def robustness(wm):
    """Average performance of each model across instruments, window by window."""
    if wm.empty:
        return pd.DataFrame(), pd.DataFrame()
    g = wm.groupby(["Frequency", "Model", "Scheme", "Window"])
    summ = g.agg(Instruments=("Ticker", "nunique"), Avg_Rank=("Rank_in_Window", "mean"),
                 Avg_RMSE_vs_Naive=("RMSE_vs_Naive", "mean"),
                 Avg_RMSE_vs_PreEvent=("RMSE_vs_PreEvent", "mean"),
                 Avg_Bias=("Bias", "mean"),
                 Avg_Band95_Exceed=("Band95_Exceed_Rate", "mean"),
                 Band_Rejections_5pct=("Band95_Kupiec_p", lambda p: int((p < 0.05).sum()))).reset_index()

    # Recommendation: lowest average rank over the post-event windows
    # (excluding the "All" aggregate), adaptive scheme; ties -> RMSE vs naive.
    post = summ[(~summ["Window"].isin([PRE, POST])) & (~summ["Model"].str.contains("Naive"))]
    rec = []
    for (freq, scheme), gg in post.groupby(["Frequency", "Scheme"]):
        score = gg.groupby("Model").agg(Avg_Post_Rank=("Avg_Rank", "mean"),
                                        Avg_RMSE_vs_Naive=("Avg_RMSE_vs_Naive", "mean")).reset_index()
        shock = gg[gg["Window"] == SHOCK].set_index("Model")
        calm = summ[(summ["Frequency"] == freq) & (summ["Scheme"] == scheme) & (summ["Window"] == PRE)].set_index("Model")
        allp = summ[(summ["Frequency"] == freq) & (summ["Scheme"] == scheme) & (summ["Window"] == POST)].set_index("Model")
        score["Calm_Rank"] = score["Model"].map(calm["Avg_Rank"])
        score["Shock_Rank"] = score["Model"].map(shock["Avg_Rank"])
        score["Shock_Error_Growth_x"] = score["Model"].map(shock["Avg_RMSE_vs_PreEvent"])
        score["Post_Band95_Exceed"] = score["Model"].map(allp["Avg_Band95_Exceed"])
        score["Post_Band_Rejections"] = score["Model"].map(allp["Band_Rejections_5pct"])
        score = score.sort_values(["Avg_Post_Rank", "Avg_RMSE_vs_Naive"])
        score.insert(0, "Scheme", scheme)
        score.insert(0, "Frequency", freq)
        score["Recommended"] = ["YES"] + ["" for _ in range(len(score) - 1)]
        rec.append(score)
    return summ, (pd.concat(rec, ignore_index=True) if rec else pd.DataFrame())


def frozen_vs_adaptive(wm):
    """% change in RMSE from re-estimating through the event (negative = adaptive better)."""
    p = wm[wm["Window"].isin([SHOCK, POST]) & ~wm["Model"].str.contains("Naive")]
    piv = p.pivot_table(index=["Frequency", "Ticker", "Model", "Window"], columns="Scheme", values="RMSE").reset_index()
    if {"Frozen", "Adaptive"} <= set(piv.columns):
        piv["Adaptive_vs_Frozen_RMSE_%"] = 100 * (piv["Adaptive"] / piv["Frozen"] - 1)
    return piv


def information_criteria():
    rows = []
    for key in P.STAGE2_MODELS:
        df = P.read_model_table(key, "summary")
        if df is None or "AIC" not in df.columns:
            continue
        for _, r in df.iterrows():
            rows.append({"Model": P.STAGE2_MODELS[key], "Ticker": r["Ticker"],
                         "AIC": r["AIC"], "BIC": r.get("BIC", np.nan)})
    out = pd.DataFrame(rows)
    if not out.empty:
        out["Note"] = "Full-sample, in-sample criterion; compare only within the same model and data."
    return out


def run_checks(fc, wm, benchmark_paths):
    checks = []

    def add(check, status, detail):
        checks.append({"Check": check, "Status": status, "Detail": detail})

    for name in BENCHMARKS:
        path = P.RESULTS_DIR / name
        add(f"Benchmark workbook {name}", "PASS" if path in benchmark_paths else "FAIL",
            str(path) if path in benchmark_paths else "missing")
    for key, label in ALL_MODELS.items():
        ok = not fc.empty and (fc["Model"] == label).any()
        add(f"Forecasts for {label}", "PASS" if ok else "FAIL",
            "found" if ok else f"no rows in {P.TABLE_DIR / key / 'oos_forecasts.csv'}")
    add("Event-study window metrics", "PASS" if not wm.empty else "FAIL",
        "found" if not wm.empty else "run STAGE4/EVENT_STUDY.R")
    if fc.empty:
        return pd.DataFrame(checks)

    oos = fc[fc["Split"].isin(["PreEvent", "Event"])]
    nonfinite = int((~np.isfinite(oos["Forecast"].astype(float))).sum())
    add("Out-of-sample forecasts are finite", "PASS" if nonfinite == 0 else "WARNING",
        f"{nonfinite} non-finite forecasts (naive needs 22 prior days)" if nonfinite else "all finite")
    neg = oos[oos["Forecast"].astype(float) < 0]
    add("Volatility forecasts are non-negative", "PASS" if neg.empty else "WARNING",
        f"{len(neg)} negative forecasts" if len(neg) else "none negative")
    order_ok = (pd.to_datetime(oos["Target_Date"]) > pd.to_datetime(oos["Origin_Date"])).all()
    add("Forecast origin precedes target date", "PASS" if order_ok else "FAIL",
        "all rows" if order_ok else "some targets are not after their origin")
    for (freq, ticker), g in fc.groupby(["Frequency", "Ticker"]):
        train_end = pd.to_datetime(g.loc[g["Split"] == "Train", "Target_Date"]).max()
        first_event = pd.to_datetime(g.loc[g["Split"] == "Event", "Target_Date"]).min()
        add(f"Estimation sample precedes event {freq} {ticker}",
            "PASS" if train_end < first_event else "FAIL",
            f"train ends {train_end:%Y-%m-%d}, event window starts {first_event:%Y-%m-%d}")
        ev = g[(g["Split"] == "Event") & (g["Scheme"] == "Adaptive") & ~g["Model"].str.contains("Naive")]
        windows = ev.groupby("Model")["Target_Date"].agg(["min", "max", "count"]).drop_duplicates()
        add(f"Common post-event window {freq} {ticker}", "PASS" if len(windows) == 1 else "WARNING",
            "all models scored on the same days" if len(windows) == 1 else "models scored on different days")
        n_post = int(ev.groupby("Model").size().min()) if len(ev) else 0
        if n_post < 20:
            add(f"Post-event sample size {freq} {ticker}", "WARNING",
                f"only {n_post} post-event days - DM tests have little power")
    return pd.DataFrame(checks)


def main():
    print("======================================================")
    print(" EVENT-STUDY MODEL EVALUATION & CONCLUSIVE WORKBOOK ")
    print(f" Date: {datetime.now():%Y-%m-%d %H:%M}")
    print("======================================================")
    print(P.describe() + "\n")
    P.ensure_dirs(P.CONCLUSIVE_DIR)

    print("Task 1: Organizing PNG plots into PHOTOS/<MODEL>/ ...")
    for key, n in sort_photos().items():
        print(f" -> {key:<14} {n} plots")

    benchmark_paths = [P.RESULTS_DIR / n for n in BENCHMARKS if (P.RESULTS_DIR / n).is_file()]
    if not benchmark_paths:
        print(f" [!] No benchmark workbooks found in {P.RESULTS_DIR}. Run Stages 2 and 3 first.")
        return 1
    wm = P.read_model_table("EVENT_STUDY", "window_metrics")
    if wm is None or wm.empty:
        print(" [!] EVENT_STUDY/window_metrics.csv not found. Run STAGE4/EVENT_STUDY.R first.")
        return 1

    print("\nTask 2: Leaderboards, Diebold-Mariano tests and robustness ranking...")
    fc = load_forecasts()
    fc_win = window_labels(fc, wm)
    best, ranked = leaderboards(wm, fc_win)
    summ, rec = robustness(wm)
    fva = frozen_vs_adaptive(wm)
    checks = run_checks(fc, wm, benchmark_paths)

    path = P.CONCLUSIVE_DIR / CONCLUSIVE_NAME
    used = set()
    with pd.ExcelWriter(path, engine="openpyxl") as writer:
        rec.to_excel(writer, sheet_name=sheet_title("Model_Recommendation", used), index=False)
        best.to_excel(writer, sheet_name=sheet_title("Window_Leaderboard", used), index=False)
        ranked.to_excel(writer, sheet_name=sheet_title("Window_Ranking_DM_Tests", used), index=False)
        summ.to_excel(writer, sheet_name=sheet_title("Robustness_By_Window", used), index=False)
        fva.to_excel(writer, sheet_name=sheet_title("Frozen_vs_Adaptive", used), index=False)
        wm.to_excel(writer, sheet_name=sheet_title("Window_Metrics_All", used), index=False)
        for table, title in (("abnormal_volatility", "Abnormal_Volatility"),
                             ("lfd_event_study", "Event_Study_LFD"),
                             ("hfd_event_study", "Event_Study_HFD"),
                             ("garch_event_dummy", "Event_Study_EGARCH_Dummy")):
            df = P.read_model_table("EVENT_STUDY", table)
            if df is not None and not df.empty:
                df.to_excel(writer, sheet_name=sheet_title(title, used), index=False)
        checks.to_excel(writer, sheet_name=sheet_title("Run_Checks", used), index=False)
        ic = information_criteria()
        if not ic.empty:
            ic.to_excel(writer, sheet_name=sheet_title("Information_Criteria", used), index=False)
        for bpath in benchmark_paths:
            prefix = bpath.stem.split("_")[0]
            with pd.ExcelFile(bpath) as xls:
                for sheet in xls.sheet_names:
                    if sheet in ("OOS_Forecasts", "OOS_Metrics"):
                        continue
                    name = sheet if sheet.startswith(prefix) else f"{prefix}_{sheet}"
                    xls.parse(sheet).to_excel(writer, sheet_name=sheet_title(name, used), index=False)

    n_fail = int((checks["Status"] == "FAIL").sum())
    n_warn = int((checks["Status"] == "WARNING").sum())
    print("\nQuality checks:")
    for _, row in checks.iterrows():
        if row["Status"] != "PASS":
            print(f"  {row['Status']:<8} {row['Check']}: {row['Detail']}")
    print(f"  {len(checks) - n_fail - n_warn} PASS, {n_warn} WARNING, {n_fail} FAIL")

    if not rec.empty:
        print("\nRecommended model per frequency (lowest average post-event rank):")
        print(rec[rec["Recommended"] == "YES"][["Frequency", "Scheme", "Model", "Avg_Post_Rank",
                                                "Avg_RMSE_vs_Naive", "Shock_Error_Growth_x"]].to_string(index=False))
    print(f"\n Conclusive workbook : {path}")
    print(f" Photos              : {P.PHOTOS_DIR}")
    return 1 if n_fail else 0


if __name__ == "__main__":
    sys.exit(main())
