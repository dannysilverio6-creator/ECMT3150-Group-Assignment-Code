#!/usr/bin/env python3
# ==============================================================================
# Script Name: FINAL SUMMARY.py
# Pipeline Stage: Stage 4 (Orchestrator Step 7) - Advanced Multi-Criteria Engine
# Description: Ingests model outputs from the ECMT3150 LSEG pipeline, evaluating 
#              econometric and machine learning criteria across ASX equities and 
#              commodities (Gold, Silver, Uranium). Ranks models (XGBoost, 
#              Realised GARCH, HAR-RV, GARCH(1,1), SV) and exports a formatted 
#              Markdown deliverable including HFD and LFD feature importance.
# ==============================================================================

import os
import pandas as pd
import numpy as np
from pathlib import Path

def run_advanced_summary():
    # Define paths relative to the project root (assuming script is in STAGE4/)
    base_dir = Path(__file__).resolve().parent.parent
    input_dir_excel = base_dir / "Pipeline_Outputs" / "Excel_Summaries"
    output_path = base_dir / "ECMT3150_Final_Best_Model_Analysis.md"
    
    os.makedirs(input_dir_excel, exist_ok=True)

    print("======================================================")
    print("ECMT3150 Model Analysis & Executive Decision Engine")
    print("======================================================\n")

    def safe_read(filename, sheet_name):
        path = input_dir_excel / filename
        if path.exists():
            try:
                return pd.read_excel(path, sheet_name=sheet_name)
            except Exception as e:
                print(f"  [!] Could not read {sheet_name} from {filename}: {e}")
                return None
        return None

    # Load all model summaries aligned with the architecture diagram
    hfd_xgb = safe_read("HFD_XGBOOST_Model_Summary.xlsx", "OOS_Metrics")
    hfd_imp = safe_read("HFD_XGBOOST_Model_Summary.xlsx", "Feature_Importance")
    hfd_rg  = safe_read("HFD_RealisedGARCH_Model_Summary.xlsx", "Metrics")
    hfd_har = safe_read("HFD_HAR_RV_Model_Summary.xlsx", "Metrics")
    
    lfd_xgb   = safe_read("LFD_XGBOOST_Model_Summary.xlsx", "OOS_Metrics")
    lfd_imp   = safe_read("LFD_XGBOOST_Model_Summary.xlsx", "Feature_Importance")
    lfd_garch = safe_read("LFD_GARCH_Model_Summary.xlsx", "Metrics")
    lfd_sv    = safe_read("LFD_SV_Model_Summary.xlsx", "Metrics")

    # Aggregate unique tickers across all successfully loaded dataframes
    tickers = set()
    dfs = [hfd_xgb, hfd_rg, hfd_har, lfd_xgb, lfd_garch, lfd_sv]
    for df in dfs:
        if df is not None and "Ticker" in df.columns:
            tickers.update(df["Ticker"].dropna().unique())

    tickers = sorted(list(tickers))

    if not tickers:
        print("Warning: No ticker summaries found across Excel files. Ensure earlier stages output to Pipeline_Outputs/Excel_Summaries.")
        return False

    executive_rows = []
    
    def get_val(df, ticker, col):
        if df is not None and ticker in df["Ticker"].values and col in df.columns:
            return df.loc[df["Ticker"] == ticker, col].values[0]
        return np.nan

    for t in tickers:
        # 1. High Frequency Evaluation
        hfd_xgb_rmse = get_val(hfd_xgb, t, "RMSE")
        hfd_rg_rmse  = get_val(hfd_rg, t, "RMSE")
        hfd_har_rmse = get_val(hfd_har, t, "RMSE")
        
        # Determine best HFD model based on lowest RMSE
        hfd_models = {
            "HFD XGBoost": hfd_xgb_rmse,
            "Realised GARCH": hfd_rg_rmse,
            "HAR-RV": hfd_har_rmse
        }
        valid_hfd = {k: v for k, v in hfd_models.items() if not pd.isna(v)}
        best_hfd = min(valid_hfd, key=valid_hfd.get) if valid_hfd else "N/A"
        
        # Calculate HFD XGBoost Improvement over Realised GARCH baseline
        if not pd.isna(hfd_xgb_rmse) and not pd.isna(hfd_rg_rmse) and hfd_rg_rmse > 0:
            hfd_improvement = ((hfd_rg_rmse - hfd_xgb_rmse) / hfd_rg_rmse) * 100
        else:
            hfd_improvement = np.nan

        # 2. Low Frequency Evaluation
        lfd_xgb_rmse   = get_val(lfd_xgb, t, "RMSE")
        lfd_garch_rmse = get_val(lfd_garch, t, "RMSE")
        lfd_sv_rmse    = get_val(lfd_sv, t, "RMSE")
        
        lfd_garch_aic = get_val(lfd_garch, t, "AIC")
        lfd_sv_aic    = get_val(lfd_sv, t, "AIC")
        lfd_garch_pers = get_val(lfd_garch, t, "Persistence")
        vol_forecast   = get_val(lfd_garch, t, "Mean_30D_Vol_Forecast")

        # Determine best LFD model based on lowest RMSE
        lfd_models = {
            "LFD XGBoost": lfd_xgb_rmse,
            "GARCH(1,1)": lfd_garch_rmse,
            "Stochastic Volatility": lfd_sv_rmse
        }
        valid_lfd = {k: v for k, v in lfd_models.items() if not pd.isna(v)}
        best_lfd = min(valid_lfd, key=valid_lfd.get) if valid_lfd else "N/A"

        executive_rows.append({
            "Asset / Ticker": t,
            "Best HFD Model": best_hfd,
            "HFD XGBoost RMSE": round(hfd_xgb_rmse, 6) if not pd.isna(hfd_xgb_rmse) else "N/A",
            "HFD Realised GARCH RMSE": round(hfd_rg_rmse, 6) if not pd.isna(hfd_rg_rmse) else "N/A",
            "HFD HAR-RV RMSE": round(hfd_har_rmse, 6) if not pd.isna(hfd_har_rmse) else "N/A",
            "HFD ML Improv. %": round(hfd_improvement, 2) if not pd.isna(hfd_improvement) else "N/A",
            "Best LFD Model": best_lfd,
            "LFD XGBoost RMSE": round(lfd_xgb_rmse, 6) if not pd.isna(lfd_xgb_rmse) else "N/A",
            "LFD GARCH(1,1) RMSE": round(lfd_garch_rmse, 6) if not pd.isna(lfd_garch_rmse) else "N/A",
            "LFD SV RMSE": round(lfd_sv_rmse, 6) if not pd.isna(lfd_sv_rmse) else "N/A",
            "GARCH(1,1) AIC": round(lfd_garch_aic, 2) if not pd.isna(lfd_garch_aic) else "N/A",
            "SV AIC": round(lfd_sv_aic, 2) if not pd.isna(lfd_sv_aic) else "N/A",
            "GARCH Persistence": round(lfd_garch_pers, 4) if not pd.isna(lfd_garch_pers) else "N/A",
            "30D Vol Forecast %": round(vol_forecast, 4) if not pd.isna(vol_forecast) else "N/A"
        })

    df_executive = pd.DataFrame(executive_rows)
    
    # ---------------------------------------------------------
    # MARKDOWN FORMATTING & EXPORT
    # ---------------------------------------------------------
    
    # Helper function to generate clean Markdown tables safely
    def df_to_markdown_table(df):
        header = "| " + " | ".join(str(c) for c in df.columns) + " |"
        separator = "| " + " | ".join("---" for _ in df.columns) + " |"
        rows = []
        for _, row in df.iterrows():
            rows.append("| " + " | ".join(str(x) if pd.notna(x) else "N/A" for x in row) + " |")
        return "\n".join([header, separator] + rows)

    try:
        with open(output_path, 'w', encoding='utf-8') as md_file:
            # Write Document Header
            md_file.write("# ECMT3150 Quantitative Pipeline - Executive Best Model Analysis\n\n")
            
            # Write Sheet 1 equivalent
            md_file.write("## 1. Executive Summary\n\n")
            md_file.write(df_to_markdown_table(df_executive))
            md_file.write("\n\n")
            
            # Write Sheet 2 equivalent
            if hfd_imp is not None and not hfd_imp.empty:
                md_file.write("## 2. HFD XGBoost Feature Importance\n\n")
                md_file.write(df_to_markdown_table(hfd_imp))
                md_file.write("\n\n")
            
            # Write Sheet 3 equivalent
            if lfd_imp is not None and not lfd_imp.empty:
                md_file.write("## 3. LFD XGBoost Feature Importance\n\n")
                md_file.write(df_to_markdown_table(lfd_imp))
                md_file.write("\n\n")

        print(f"Success! Advanced Final Best Model Analysis generated.")
        print(f"Saved to: {output_path}\n")
        
        # Print a stylized console summary for the terminal
        print(df_executive[["Asset / Ticker", "Best HFD Model", "Best LFD Model", "HFD ML Improv. %"]].to_string(index=False))
        return True
        
    except Exception as e:
        print(f"Error saving Markdown file: {e}")
        return False

if __name__ == "__main__":
    run_advanced_summary()
