# ==============================================================================
# Script Name: DIAGNOSTIC.py
# Pipeline Stage: Stage 4 - Final Diagnostics & Conclusive Model Benchmark
# Description: Merges the Stage 2 and Stage 3 benchmark workbooks into
#              CONCLUSIVE_MODEL_DIAGNOSTICS.xlsx, ranks the models for each
#              ticker by OUT-OF-SAMPLE RMSE on a common test window (separately
#              for HFD and LFD), runs quality checks on the forecasts, and
#              sorts every diagnostic PNG into PHOTOS/<MODEL>/.
#
# Why RMSE and not AIC: AIC/BIC are in-sample criteria and are not comparable
# across models fitted to different data (e.g. GARCH on returns vs HAR-RV
# regressions on realised volatility). They are reported for reference only.
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
CONCLUSIVE_NAME = "CONCLUSIVE_MODEL_DIAGNOSTICS.xlsx"


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


def load_metrics():
    frames = []
    for key in ALL_MODELS:
        df = P.read_model_table(key, "oos_metrics")
        if df is not None and not df.empty:
            df = df.copy()
            df["Frequency"] = key.split("_")[0]
            frames.append(df)
    return pd.concat(frames, ignore_index=True) if frames else pd.DataFrame()


def load_forecasts():
    frames = [P.read_model_table(key, "oos_forecasts") for key in ALL_MODELS]
    frames = [f for f in frames if f is not None and not f.empty]
    return pd.concat(frames, ignore_index=True) if frames else pd.DataFrame()


# ------------------------------------------------------------------------------
# Naive benchmarks and Diebold-Mariano tests
# ------------------------------------------------------------------------------
NAIVE_LABEL = {"HFD": "HFD_Naive_RW", "LFD": "LFD_Naive_22D"}


def naive_forecasts(forecasts):
    """Simple baselines built from the realised target on the SAME rows.

    HFD: random walk - tomorrow's RV forecast is today's RV.
    LFD: 22-day moving average of |return| up to today.
    Rows are only used where the previous targets are consecutive, so no
    future information enters.
    """
    if forecasts.empty:
        return pd.DataFrame()
    out, done = [], set()
    for model in forecasts["Model"].unique():
        freq = model.split("_")[0]
        if freq not in NAIVE_LABEL or freq in done:
            continue
        done.add(freq)
        base = forecasts[forecasts["Model"] == model].copy()
        for ticker, grp in base.groupby("Ticker"):
            g = grp.sort_values("Origin_Date").copy()
            prev_target = g["Target_Date"].shift(1)
            consecutive = prev_target == g["Origin_Date"]
            if freq == "HFD":
                g["Forecast"] = g["Actual"].shift(1).where(consecutive)
            else:
                g["Forecast"] = g["Actual"].shift(1).rolling(22).mean().where(consecutive)
            g["Model"] = NAIVE_LABEL[freq]
            out.append(g)
    return pd.concat(out, ignore_index=True) if out else pd.DataFrame()


def metrics_from_forecasts(fc, template):
    """OOS metrics for naive forecasts, in the same layout as the R tables."""
    rows = []
    for (model, ticker), g in fc[fc["Split"] == "Test"].groupby(["Model", "Ticker"]):
        g = g.dropna(subset=["Actual", "Forecast"])
        if g.empty:
            continue
        a, f = g["Actual"].to_numpy(float), g["Forecast"].to_numpy(float)
        ok = (a > 0) & (f > 0)
        ratio = a[ok] ** 2 / f[ok] ** 2
        ref = template[(template["Ticker"] == ticker) &
                       (template["Frequency"] == model.split("_")[0])]
        rows.append({
            "Model": model, "Ticker": ticker,
            "Target": ref["Target"].iloc[0] if len(ref) else "",
            "Train_Start": ref["Train_Start"].iloc[0] if len(ref) else "",
            "Train_End": ref["Train_End"].iloc[0] if len(ref) else "",
            "Test_Start": g["Target_Date"].min(), "Test_End": g["Target_Date"].max(),
            "N_Train": ref["N_Train"].iloc[0] if len(ref) else np.nan,
            "N_Test": len(g), "RMSE": float(np.sqrt(np.mean((a - f) ** 2))),
            "MAE": float(np.mean(np.abs(a - f))),
            "QLIKE": float(np.mean(ratio - np.log(ratio) - 1)) if ok.any() else np.nan,
            "Frequency": model.split("_")[0],
        })
    return pd.DataFrame(rows)


def _t_sf(t, df):
    """Two-sided p-value for a t statistic (scipy if available, else normal)."""
    try:
        from scipy import stats
        return float(2 * stats.t.sf(abs(t), df))
    except Exception:
        return float(math.erfc(abs(t) / math.sqrt(2)))


def diebold_mariano(e1, e2):
    """DM test (squared-error loss, h=1) with the Harvey-Leybourne-Newbold
    small-sample correction. Negative statistic => model 1 is more accurate."""
    d = np.asarray(e1, float) ** 2 - np.asarray(e2, float) ** 2
    d = d[np.isfinite(d)]
    n = len(d)
    if n < 3 or np.var(d, ddof=1) == 0:
        return np.nan, np.nan
    dm = d.mean() / math.sqrt(np.var(d, ddof=1) / n)
    dm *= math.sqrt((n - 1) / n)
    return float(dm), _t_sf(dm, n - 1)


def add_dm_tests(ranked, forecasts):
    """DM test of every model against the best model and against the naive baseline."""
    if ranked.empty or forecasts.empty:
        return ranked
    test = forecasts[forecasts["Split"] == "Test"]
    errors = {(m, t): g.set_index("Target_Date")["Actual"] - g.set_index("Target_Date")["Forecast"]
              for (m, t), g in test.groupby(["Model", "Ticker"])}
    out = ranked.copy()
    for col in ("DM_stat_vs_Best", "DM_p_vs_Best", "DM_stat_vs_Naive", "DM_p_vs_Naive"):
        out[col] = np.nan
    for idx, row in out.iterrows():
        grp = out[(out["Frequency"] == row["Frequency"]) & (out["Ticker"] == row["Ticker"])]
        best = grp.sort_values("RMSE").iloc[0]["Model"]
        naive = NAIVE_LABEL.get(row["Frequency"])
        for ref, prefix in ((best, "vs_Best"), (naive, "vs_Naive")):
            if ref == row["Model"] or (ref, row["Ticker"]) not in errors:
                continue
            e1 = errors.get((row["Model"], row["Ticker"]))
            e2 = errors[(ref, row["Ticker"])]
            if e1 is None:
                continue
            joined = pd.concat([e1, e2], axis=1, join="inner").dropna()
            stat, p = diebold_mariano(joined.iloc[:, 0], joined.iloc[:, 1])
            out.loc[idx, f"DM_stat_{prefix}"] = stat
            out.loc[idx, f"DM_p_{prefix}"] = p
    return out


def leaderboard(metrics):
    if metrics.empty:
        return pd.DataFrame(), pd.DataFrame()
    ranked = metrics.sort_values(["Frequency", "Ticker", "RMSE"]).copy()
    ranked["Rank_RMSE"] = ranked.groupby(["Frequency", "Ticker"])["RMSE"].rank(method="min").astype(int)

    rows = []
    for (freq, ticker), grp in ranked.groupby(["Frequency", "Ticker"], sort=True):
        grp = grp.sort_values("RMSE")
        best = grp.iloc[0]
        runner = grp.iloc[1] if len(grp) > 1 else None
        windows = grp[["Test_Start", "Test_End", "N_Test"]].drop_duplicates()
        rows.append({
            "Frequency": freq,
            "Ticker": ticker,
            "Best_Model_Selected": best["Model"],
            "Best_RMSE": best["RMSE"],
            "Best_MAE": best["MAE"],
            "Runner_Up": None if runner is None else runner["Model"],
            "Runner_Up_RMSE": None if runner is None else runner["RMSE"],
            "RMSE_Improvement_vs_Runner_Up_%": (
                None if runner is None or runner["RMSE"] == 0
                else round(100 * (runner["RMSE"] - best["RMSE"]) / runner["RMSE"], 2)),
            "Models_Compared": len(grp),
            "Test_Start": best["Test_Start"],
            "Test_End": best["Test_End"],
            "N_Test": int(best["N_Test"]),
            "Common_Test_Window": "YES" if len(windows) == 1 else "NO - check windows",
            "Target": best["Target"],
        })
    return pd.DataFrame(rows), ranked


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
        out["Note"] = "In-sample criterion; compare only within the same model and data."
    return out


def run_checks(metrics, forecasts, benchmark_paths):
    checks = []

    def add(check, status, detail):
        checks.append({"Check": check, "Status": status, "Detail": detail})

    for name in BENCHMARKS:
        path = P.RESULTS_DIR / name
        add(f"Benchmark workbook {name}", "PASS" if path in benchmark_paths else "FAIL",
            str(path) if path in benchmark_paths else "missing")

    for key, label in ALL_MODELS.items():
        present = not metrics.empty and (metrics["Model"] == label).any()
        add(f"OOS metrics for {label}", "PASS" if present else "FAIL",
            "found" if present else f"no rows in {P.TABLE_DIR / key / 'oos_metrics.csv'}")

    if not forecasts.empty:
        test = forecasts[forecasts["Split"] == "Test"]
        nonfinite = int((~np.isfinite(test["Forecast"].astype(float))).sum())
        add("Test forecasts are finite", "PASS" if nonfinite == 0 else "WARNING",
            f"{nonfinite} non-finite test forecasts")
        neg = test[test["Forecast"].astype(float) < 0]
        detail = "0 negative test forecasts"
        if len(neg):
            by_model = neg.groupby(["Model", "Ticker"]).size()
            detail = f"{len(neg)} negative test forecasts: " + ", ".join(
                f"{m} {t} ({n})" for (m, t), n in by_model.items())
        add("Volatility forecasts are non-negative", "PASS" if neg.empty else "WARNING", detail)
        order_ok = (pd.to_datetime(test["Target_Date"]) > pd.to_datetime(test["Origin_Date"])).all()
        add("Forecast origin precedes target date", "PASS" if order_ok else "FAIL",
            "all test rows" if order_ok else "some targets are not after their origin")

    if not metrics.empty:
        chrono = (pd.to_datetime(metrics["Train_End"]) < pd.to_datetime(metrics["Test_Start"])).all()
        add("Train sample ends before test sample", "PASS" if chrono else "FAIL",
            "chronological split verified" if chrono else "overlap detected")
        for (freq, ticker), grp in metrics.groupby(["Frequency", "Ticker"]):
            same = len(grp[["Test_Start", "Test_End", "N_Test"]].drop_duplicates()) == 1
            add(f"Common test window {freq} {ticker}", "PASS" if same else "WARNING",
                f"{grp['Test_Start'].iloc[0]} to {grp['Test_End'].iloc[0]} ({int(grp['N_Test'].iloc[0])} obs)"
                if same else "models were scored on different dates")
            small = int(grp["N_Test"].min())
            if small < 20:
                add(f"Test sample size {freq} {ticker}", "WARNING",
                    f"only {small} out-of-sample observations - rankings are not statistically reliable")
    return pd.DataFrame(checks)


def main():
    print("======================================================")
    print(" FINAL DIAGNOSTICS & CONCLUSIVE BENCHMARK COMPILER ")
    print(f" Date: {datetime.now():%Y-%m-%d %H:%M}")
    print("======================================================")
    print(P.describe() + "\n")
    P.ensure_dirs(P.CONCLUSIVE_DIR)

    print("Task 1: Organizing PNG diagnostic plots into PHOTOS/<MODEL>/ ...")
    counts = sort_photos()
    for key, n in counts.items():
        print(f" -> {key:<14} {n} plots")
    print(f" -> PHOTOS folder: {P.PHOTOS_DIR}\n")

    print("Task 2: Merging benchmark workbooks...")
    benchmark_paths = [P.RESULTS_DIR / n for n in BENCHMARKS if (P.RESULTS_DIR / n).is_file()]
    if not benchmark_paths:
        print(f" [!] No benchmark workbooks found in {P.RESULTS_DIR}. Run Stages 2 and 3 first.")
        return 1

    metrics = load_metrics()
    forecasts = load_forecasts()
    naive = naive_forecasts(forecasts)
    if not naive.empty:
        forecasts = pd.concat([forecasts, naive], ignore_index=True)
        metrics = pd.concat([metrics, metrics_from_forecasts(naive, metrics)], ignore_index=True)
        print(" -> Added naive baselines: " + ", ".join(sorted(naive["Model"].unique())))
    best, ranked = leaderboard(metrics)
    ranked = add_dm_tests(ranked, forecasts)
    if not best.empty:
        runner_p = []
        for _, b in best.iterrows():
            r = ranked[(ranked["Frequency"] == b["Frequency"]) & (ranked["Ticker"] == b["Ticker"]) &
                       (ranked["Model"] == b["Runner_Up"])]
            runner_p.append(r["DM_p_vs_Best"].iloc[0] if len(r) else np.nan)
        best["DM_p_Best_vs_Runner_Up"] = runner_p
        best_naive = []
        for _, b in best.iterrows():
            r = ranked[(ranked["Frequency"] == b["Frequency"]) & (ranked["Ticker"] == b["Ticker"]) &
                       (ranked["Model"] == b["Best_Model_Selected"])]
            best_naive.append(r["DM_p_vs_Naive"].iloc[0] if len(r) else np.nan)
        best["DM_p_Best_vs_Naive"] = best_naive
        best["Significant_at_5%"] = np.where(best["DM_p_Best_vs_Runner_Up"] < 0.05, "YES",
                                             "NO - not distinguishable from runner-up")
    checks = run_checks(metrics, forecasts, benchmark_paths)
    ic = information_criteria()

    conclusive_path = P.CONCLUSIVE_DIR / CONCLUSIVE_NAME
    used = set()
    with pd.ExcelWriter(conclusive_path, engine="openpyxl") as writer:
        if not best.empty:
            best.to_excel(writer, sheet_name=sheet_title("Conclusive_Leaderboard", used), index=False)
            ranked.to_excel(writer, sheet_name=sheet_title("OOS_Ranking_All_Models", used), index=False)
            print(" -> 'Conclusive_Leaderboard' ranks models per ticker by out-of-sample RMSE.")
        for table, title in (("lfd_event_study", "Event_Study_LFD"),
                             ("hfd_event_study", "Event_Study_HFD"),
                             ("garch_event_dummy", "Event_Study_EGARCH_Dummy")):
            df = P.read_model_table("EVENT_STUDY", table)
            if df is not None and not df.empty:
                df.to_excel(writer, sheet_name=sheet_title(title, used), index=False)
        checks.to_excel(writer, sheet_name=sheet_title("Run_Checks", used), index=False)
        if not ic.empty:
            ic.to_excel(writer, sheet_name=sheet_title("Information_Criteria", used), index=False)
        for path in benchmark_paths:
            prefix = path.stem.split("_")[0]  # LFD / HFD / ML
            with pd.ExcelFile(path) as xls:
                for sheet in xls.sheet_names:
                    if sheet == "OOS_Forecasts":
                        continue  # kept in the benchmark workbooks; avoids a very large file
                    name = sheet if sheet.startswith(prefix) else f"{prefix}_{sheet}"
                    xls.parse(sheet).to_excel(writer, sheet_name=sheet_title(name, used), index=False)
            print(f" -> Merged {path.name}")

    n_fail = int((checks["Status"] == "FAIL").sum())
    n_warn = int((checks["Status"] == "WARNING").sum())
    print("\nQuality checks:")
    for _, row in checks.iterrows():
        if row["Status"] != "PASS":
            print(f"  {row['Status']:<8} {row['Check']}: {row['Detail']}")
    print(f"  {len(checks) - n_fail - n_warn} PASS, {n_warn} WARNING, {n_fail} FAIL")

    if not best.empty:
        print("\nBest model per ticker (out-of-sample RMSE):")
        print(best[["Frequency", "Ticker", "Best_Model_Selected", "Best_RMSE", "N_Test",
                    "DM_p_Best_vs_Runner_Up"]].to_string(index=False))

    print("\n======================================================")
    print(" DIAGNOSTICS COMPILATION COMPLETE! ")
    print(f" Conclusive Master Workbook : {conclusive_path}")
    print(f" Segmented Photos Directory : {P.PHOTOS_DIR}")
    print("======================================================\n")
    return 1 if n_fail else 0


if __name__ == "__main__":
    sys.exit(main())
