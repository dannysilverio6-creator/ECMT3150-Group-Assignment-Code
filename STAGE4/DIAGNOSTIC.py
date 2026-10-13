# ==============================================================================
# Script Name: DIAGNOSTICS.py
# Pipeline Stage: Stage 4 - Final Diagnostics & Conclusive Model Benchmark
# Description: Scans consolidated benchmark outputs (Stage 2/3), merges them into 
#              a master conclusive Excel workbook (`CONCLUSIVE_MODEL_DIAGNOSTICS.xlsx`) 
#              with an automated evaluation layer that selects the best-performing 
#              model per ticker, and organizes all diagnostic PNG plots into a 
#              structured `PHOTOS/` directory segmented by model type.
# ==============================================================================

import os
import shutil
import pandas as pd
from datetime import datetime

def create_dir(path):
    os.makedirs(path, exist_ok=True)

def main():
    print("======================================================")
    print(" FINAL DIAGNOSTICS & CONCLUSIVE BENCHMARK COMPILER ")
    print(f" Date: {datetime.now().strftime('%Y-%m-%d')}")
    print("======================================================\n")

    # Resolve Base Output Directory (Targeting ECMT3150 OUTPUTS)
    if os.path.exists("../ECMT3150 OUTPUTS"):
        base_output_dir = os.path.abspath("../ECMT3150 OUTPUTS/Pipeline_Outputs")
        base_root_dir = os.path.abspath("../ECMT3150 OUTPUTS")
    else:
        base_output_dir = os.path.abspath("Pipeline_Outputs")
        base_root_dir = os.path.abspath(".")

    # 1. Directory Setup
    results_dir = os.path.join(base_output_dir, "Consolidated_Results")
    plots_source_dir = os.path.join(base_output_dir, "Consolidated_Plots")
    
    output_dir_compiled = os.path.join(base_output_dir, "Conclusive_Results")
    photos_dir = os.path.join(base_root_dir, "PHOTOS")
    
    create_dir(output_dir_compiled)
    create_dir(photos_dir)

    print(f"Reading Benchmarks from : {results_dir}")
    print(f"Reading Plots from      : {plots_source_dir}\n")

    # ---------------------------------------------------------
    # TASK 1: SEGREGATE PLOTS INTO PHOTOS/ DIRECTORY BY MODEL
    # ---------------------------------------------------------
    print("Task 1: Organizing PNG diagnostic plots into model-segmented PHOTOS/ folders...")
    
    model_categories = {
        "LFD_GARCH": "LFD_GARCH",
        "LFD_SV": "LFD_SV",
        "LFD_XGBoost": "LFD_XGBOOST",
        "HFD_Realised_GARCH": "RealGARCH",
        "HFD_HAR-RV": "HARRV",
        "HFD_UHF-GARCH": "UHF",
        "HFD_XGBoost": "XGBOOST"
    }

    # Create subfolders inside PHOTOS/
    for folder_name in model_categories.values():
        create_dir(os.path.join(photos_dir, folder_name))
    create_dir(os.path.join(photos_dir, "Misc"))

    copied_plots_count = 0
    if os.path.exists(plots_source_dir):
        for file in os.listdir(plots_source_dir):
            if file.lower().endswith(".png"):
                src_path = os.path.join(plots_source_dir, file)
                file_upper = file.upper()
                
                # Match file name to corresponding model category
                target_subfolder = "Misc"
                for key, subfolder in model_categories.items():
                    tokens = key.replace("_", "").upper()
                    if tokens in file_upper.replace("_", ""):
                        target_subfolder = subfolder
                        break
                
                dst_path = os.path.join(photos_dir, target_subfolder, file)
                shutil.copy2(src_path, dst_path)
                copied_plots_count += 1
                
        print(f" -> Successfully segmented and copied {copied_plots_count} plots into {photos_dir}/\n")
    else:
        print(" -> Consolidated plots source folder not found. Skipping plot segmentation.\n")

    # ---------------------------------------------------------
    # TASK 2: MERGE BENCHMARK EXCEL FILES & EVALUATE BEST MODELS
    # ---------------------------------------------------------
    print("Task 2: Merging benchmark outputs and determining the best models...")

    lfd_benchmark_path = os.path.join(results_dir, "LFD_BENCHMARK.xlsx")
    hfd_benchmark_path = os.path.join(results_dir, "HFD_BENCHMARK.xlsx")
    
    conclusive_path = os.path.join(output_dir_compiled, "CONCLUSIVE_MODEL_DIAGNOSTICS.xlsx")

    conclusive_writer = pd.ExcelWriter(conclusive_path, engine="openpyxl")
    
    summary_leaderboard_rows = []

    # Process LFD Benchmarks if available
    if os.path.exists(lfd_benchmark_path):
        lfd_xls = pd.ExcelFile(lfd_benchmark_path)
        for sheet in lfd_xls.sheet_names:
            df = lfd_xls.parse(sheet)
            df.to_excel(conclusive_writer, sheet_name=f"LFD_{sheet}", index=False)
            
            # Evaluate Information Criteria (AIC/BIC) for LFD models if columns exist
            if "AIC" in df.columns and "Ticker" in df.columns:
                for _, row in df.iterrows():
                    summary_leaderboard_rows.append({
                        "Frequency": "LFD",
                        "Model": sheet,
                        "Ticker": row["Ticker"],
                        "Criterion_AIC": row["AIC"],
                        "Criterion_BIC": row.get("BIC", None)
                    })
        print(f" -> Loaded LFD benchmarks from {lfd_benchmark_path}")

    # Process HFD Benchmarks if available
    if os.path.exists(hfd_benchmark_path):
        hfd_xls = pd.ExcelFile(hfd_benchmark_path)
        for sheet in hfd_xls.sheet_names:
            df = hfd_xls.parse(sheet)
            df.to_excel(conclusive_writer, sheet_name=f"HFD_{sheet}", index=False)
            
            # Evaluate Information Criteria or R-Squared for HFD models
            if "AIC" in df.columns and "Ticker" in df.columns:
                for _, row in df.iterrows():
                    summary_leaderboard_rows.append({
                        "Frequency": "HFD",
                        "Model": sheet,
                        "Ticker": row["Ticker"],
                        "Criterion_AIC": row["AIC"],
                        "Criterion_BIC": row.get("BIC", None)
                    })
            elif "R_Squared" in df.columns and "Ticker" in df.columns: # For HAR-RV
                for _, row in df.iterrows():
                    summary_leaderboard_rows.append({
                        "Frequency": "HFD",
                        "Model": sheet,
                        "Ticker": row["Ticker"],
                        "Criterion_AIC": -(row["Adj_R_Squared"] * 100), # Lower score representation
                        "Criterion_BIC": None
                    })
        print(f" -> Loaded HFD benchmarks from {hfd_benchmark_path}")

    # ---------------------------------------------------------
    # TASK 3: COMPILE CONCLUSIVE LEADERBOARD SHEET
    # ---------------------------------------------------------
    if summary_leaderboard_rows:
        lb_df = pd.DataFrame(summary_leaderboard_rows)
        lb_clean = lb_df.dropna(subset=["Criterion_AIC"])
        
        if not lb_clean.empty:
            best_models_idx = lb_clean.groupby(["Frequency", "Ticker"])["Criterion_AIC"].idxmin()
            best_models_df = lb_clean.loc[best_models_idx].copy()
            best_models_df = best_models_df.rename(columns={"Model": "Best_Model_Selected", "Criterion_AIC": "Min_AIC_Score"})
            
            best_models_df.to_excel(conclusive_writer, sheet_name="Conclusive_Leaderboard", index=False)
            print(" -> Generated 'Conclusive_Leaderboard' sheet identifying optimal models per ticker.")

    conclusive_writer.close()

    print("\n======================================================")
    print(" DIAGNOSTICS COMPILATION COMPLETE! ")
    print(f" Conclusive Master Workbook : {conclusive_path}")
    print(f" Segmented Photos Directory : {photos_dir}/")
    print("======================================================\n")

if __name__ == "__main__":
    main()
