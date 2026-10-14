# ==============================================================================
# Script Name: STAGE3 COLLECTOR.py
# Pipeline Stage: Stage 3 - Machine Learning Results Aggregation
# Description: Reads the CSV tables written by the two XGBoost R scripts
#              (Model_Tables/HFD_XGBOOST, Model_Tables/LFD_XGBOOST) and compiles
#              ML_BENCHMARK.xlsx with out-of-sample metrics, feature importance
#              and forecasts. Copies the XGBoost dashboards to
#              Consolidated_Plots/.
#
#              Exits with code 1 if either XGBoost model's outputs are missing.
# ==============================================================================

import shutil
import sys
from datetime import datetime
from pathlib import Path

import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import ecmt3150_paths as P  # noqa: E402

ML_WORKBOOK = "ML_BENCHMARK.xlsx"


def main():
    print("======================================================")
    print(" XGBOOST ML BENCHMARK COMPILER ")
    print(f" Date: {datetime.now():%Y-%m-%d %H:%M}")
    print("======================================================")
    print(P.describe() + "\n")
    P.ensure_dirs(P.RESULTS_DIR, P.PLOTS_DIR)

    # Task 1: plots
    n_plots = 0
    for key in P.STAGE3_MODELS:
        folder = P.PNG_DIR / key
        if folder.is_dir():
            for png in sorted(folder.glob("*.png")):
                shutil.copy2(png, P.PLOTS_DIR / png.name)
                n_plots += 1
    print(f"Task 1: Copied {n_plots} XGBoost plots to {P.PLOTS_DIR}\n")

    # Task 2: workbook
    print(f"Task 2: Constructing {ML_WORKBOOK}...")
    ml_path = P.RESULTS_DIR / ML_WORKBOOK
    missing = []
    sheets = {}
    forecasts = []
    for key, label in P.STAGE3_MODELS.items():
        metrics = P.read_model_table(key, "oos_metrics")
        if metrics is None:
            missing.append(key)
            continue
        sheets[label] = metrics
        importance = P.read_model_table(key, "feature_importance")
        if importance is not None:
            sheets[f"{label.split('_')[0]}_Feature_Importance"] = importance
        fc = P.read_model_table(key, "oos_forecasts")
        if fc is not None:
            forecasts.append(fc)

    if sheets:
        with pd.ExcelWriter(ml_path, engine="openpyxl") as writer:
            for sheet, df in sheets.items():
                df.to_excel(writer, sheet_name=sheet, index=False)
                print(f" -> Wrote sheet {sheet} ({len(df)} rows)")
            if forecasts:
                pd.concat(forecasts, ignore_index=True).to_excel(writer, sheet_name="OOS_Forecasts", index=False)
        print(f"\n -> Created: {ml_path}")
    elif ml_path.exists():
        ml_path.unlink()

    for key in missing:
        print(f" [!] Missing outputs for {key}: expected {P.TABLE_DIR / key / 'oos_metrics.csv'}")

    print("\n======================================================")
    if missing:
        print(f" ML COMPILATION INCOMPLETE - missing: {', '.join(missing)}")
        print("======================================================\n")
        return 1
    print(" ML COMPILATION COMPLETE! ")
    print(f" Output File : {ml_path}")
    print("======================================================\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
