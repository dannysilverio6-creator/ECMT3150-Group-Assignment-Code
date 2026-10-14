# ==============================================================================
# Script Name: STAGE2 COLLECTOR.py
# Pipeline Stage: Stage 2 -> 3 - Results Aggregation & Benchmark Compilation
# Description: Reads the CSV tables written by the four Stage 2 R models
#              (Model_Tables/<MODEL>/*.csv), compiles them into
#              LFD_BENCHMARK.xlsx and HFD_BENCHMARK.xlsx (parameter summaries,
#              out-of-sample metrics and forecasts), and copies every Stage 2
#              PNG dashboard into Consolidated_Plots/.
#
#              Exits with code 1 if any Stage 2 model's outputs are missing, so
#              the orchestrator never reports success on incomplete results.
# ==============================================================================

import shutil
import sys
from datetime import datetime
from pathlib import Path

import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import ecmt3150_paths as P  # noqa: E402

WORKBOOKS = {
    "LFD_BENCHMARK.xlsx": ["LFD_GARCH", "LFD_SV"],
    "HFD_BENCHMARK.xlsx": ["HFD_REALGARCH", "HFD_HARRV"],
}


def copy_plots(model_keys):
    count = 0
    for key in model_keys:
        folder = P.PNG_DIR / key
        if not folder.is_dir():
            continue
        for png in sorted(folder.glob("*.png")):
            shutil.copy2(png, P.PLOTS_DIR / png.name)
            count += 1
    return count


def build_workbook(name, model_keys):
    path = P.RESULTS_DIR / name
    missing = []
    sheets = {}
    metrics, forecasts = [], []
    for key in model_keys:
        summary = P.read_model_table(key, "summary")
        if summary is None:
            missing.append(key)
            continue
        sheets[P.STAGE2_MODELS[key]] = summary
        m = P.read_model_table(key, "oos_metrics")
        f = P.read_model_table(key, "oos_forecasts")
        if m is not None:
            metrics.append(m)
        if f is not None:
            forecasts.append(f)

    if not sheets:
        if path.exists():
            path.unlink()
        return None, missing

    with pd.ExcelWriter(path, engine="openpyxl") as writer:
        for sheet, df in sheets.items():
            df.to_excel(writer, sheet_name=sheet, index=False)
        if metrics:
            pd.concat(metrics, ignore_index=True).to_excel(writer, sheet_name="OOS_Metrics", index=False)
        if forecasts:
            pd.concat(forecasts, ignore_index=True).to_excel(writer, sheet_name="OOS_Forecasts", index=False)
    return path, missing


def main():
    print("======================================================")
    print(" STAGE 2 BENCHMARK COMPILER ")
    print(f" Date: {datetime.now():%Y-%m-%d %H:%M}")
    print("======================================================")
    print(P.describe() + "\n")
    P.ensure_dirs(P.RESULTS_DIR, P.PLOTS_DIR)

    print("Task 1: Consolidating PNG Diagnostic Plots...")
    keys = [k for keys in WORKBOOKS.values() for k in keys]
    n = copy_plots(keys)
    print(f" -> Copied {n} diagnostic plots to {P.PLOTS_DIR}\n")

    print("Task 2: Constructing Benchmark Workbooks...")
    all_missing = []
    for name, model_keys in WORKBOOKS.items():
        path, missing = build_workbook(name, model_keys)
        all_missing += missing
        if path:
            print(f" -> Created: {path}")
        else:
            print(f" -> {name}: no model outputs found.")
        for key in missing:
            print(f"    [!] Missing outputs for {key}: expected {P.TABLE_DIR / key / 'summary.csv'}")

    print("\n======================================================")
    if all_missing:
        print(f" COMPILATION INCOMPLETE - missing: {', '.join(all_missing)}")
        print("======================================================\n")
        return 1
    print(" COMPILATION COMPLETE! ")
    print(f" Benchmarks folder : {P.RESULTS_DIR}")
    print(f" Plots folder      : {P.PLOTS_DIR}")
    print("======================================================\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
