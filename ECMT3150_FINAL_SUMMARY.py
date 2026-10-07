# ==============================================================================
# Script Name: ECMT3150_FINAL_SUMMARY.py
# Pipeline Stage: Stage 6 - Advanced Model Analysis & Multi-Criteria Decision Engine
# Description: Ingests all model summaries, evaluates comprehensive econometric 
#              and machine learning criteria (RMSE, MAE, R2, AIC, BIC, Persistence, 
#              Feature Importance Gains), generates deep statistical rankings per 
#              company, and exports an advanced multi-sheet executive Excel deliverable.
# ==============================================================================

import os
import pandas as pd
import numpy as np
from openpyxl import Workbook
from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
from openpyxl.utils import get_column_letter

def run_advanced_summary():
    input_dir_excel = "Pipeline_Outputs/Excel_Summaries"
    os.makedirs(input_dir_excel, exist_ok=True)

    print("======================================================")
    print("Advanced Model Analysis & Executive Decision Engine")
    print("======================================================\n")

    def safe_read(filename, sheet_name):
        path = os.path.join(input_dir_excel, filename)
        if os.path.exists(path):
            try:
                return pd.read_excel(path, sheet_name=sheet_name)
            except Exception:
                return None
        return None

    # Load all model summaries
    hfd_hybrid = safe_read("HFD_HybridML_Model_Summary.xlsx", "OOS_Metrics")
    hfd_imp    = safe_read("HFD_HybridML_Model_Summary.xlsx", "Feature_Importance")
    lfd_arima  = safe_read("LFD_ARIMA_Model_Summary.xlsx", "ARIMA_Summary")
    lfd_garch  = safe_read("LFD_GARCH_Model_Summary.xlsx", "GARCH_Summary")
    hfd_acd    = safe_read("HFD_ACD_Model_Summary.xlsx", "ACD_Summary")
    hfd_uhf    = safe_read("HFD_UHFGARCH_Model_Summary.xlsx", "UHF_Summary")

    tickers = set()
    for df in [hfd_hybrid, lfd_arima, lfd_garch, hfd_acd, hfd_uhf]:
        if df is not None and "Ticker" in df.columns:
            tickers.update(df["Ticker"].dropna().unique())

    tickers = sorted(list(tickers))

    if not tickers:
        print("Warning: No ticker summaries found across Excel files.")
        return False

    executive_rows = []
    
    for t in tickers:
        # 1. High Frequency Evaluation
        hfd_ml_rmse = hfd_hybrid.loc[hfd_hybrid["Ticker"] == t, "rmse_ml"].values[0] if (hfd_hybrid is not None and t in hfd_hybrid["Ticker"].values) else np.nan
        hfd_g_rmse  = hfd_hybrid.loc[hfd_hybrid["Ticker"] == t, "rmse_garch"].values[0] if (hfd_hybrid is not None and t in hfd_hybrid["Ticker"].values) else np.nan
        hfd_ml_r2   = hfd_hybrid.loc[hfd_hybrid["Ticker"] == t, "r2_ml"].values[0] if (hfd_hybrid is not None and t in hfd_hybrid["Ticker"].values) else np.nan
        hfd_g_r2    = hfd_hybrid.loc[hfd_hybrid["Ticker"] == t, "r2_garch"].values[0] if (hfd_hybrid is not None and t in hfd_hybrid["Ticker"].values) else np.nan
        
        # Improvement %
        hfd_improvement = ((hfd_g_rmse - hfd_ml_rmse) / hfd_g_rmse * 100) if (not pd.isna(hfd_ml_rmse) and not pd.isna(hfd_g_rmse) and hfd_g_rmse > 0) else np.nan
        best_hfd = "HFD Hybrid ML (XGBoost)" if (not pd.isna(hfd_ml_rmse) and not pd.isna(hfd_g_rmse) and hfd_ml_rmse < hfd_g_rmse) else "UHF-GARCH Baseline"
        
        # 2. Low Frequency Evaluation (ARIMA vs GARCH)
        lfd_a_aic = lfd_arima.loc[lfd_arima["Ticker"] == t, "AIC"].values[0] if (lfd_arima is not None and t in lfd_arima["Ticker"].values) else np.nan
        lfd_g_aic = lfd_garch.loc[lfd_garch["Ticker"] == t, "AIC"].values[0] if (lfd_garch is not None and t in lfd_garch["Ticker"].values) else np.nan
        lfd_g_bic = lfd_garch.loc[lfd_garch["Ticker"] == t, "BIC"].values[0] if (lfd_garch is not None and t in lfd_garch["Ticker"].values) else np.nan
        lfd_persistence = lfd_garch.loc[lfd_garch["Ticker"] == t, "Persistence"].values[0] if (lfd_garch is not None and t in lfd_garch["Ticker"].values) else np.nan
        vol_forecast = lfd_garch.loc[lfd_garch["Ticker"] == t, "Mean_30D_Vol_Forecast"].values[0] if (lfd_garch is not None and t in lfd_garch["Ticker"].values) else np.nan
        
        best_lfd = "LFD GARCH Volatility Model"
        if not pd.isna(lfd_a_aic) and not pd.isna(lfd_g_aic):
            best_lfd = "LFD ARIMA Mean Model" if lfd_a_aic < lfd_g_aic else "LFD GARCH Volatility Model"

        # 3. Microstructure ACD Persistence
        acd_pers = hfd_acd.loc[hfd_acd["Ticker"] == t, "Persistence"].values[0] if (hfd_acd is not None and t in hfd_acd["Ticker"].values) else np.nan
        uhf_pers = hfd_uhf.loc[hfd_uhf["Ticker"] == t, "Persistence"].values[0] if (hfd_uhf is not None and t in hfd_uhf["Ticker"].values) else np.nan

        executive_rows.append({
            "Ticker": t,
            "Best_HighFrequency_Model": best_hfd,
            "HFD_Hybrid_RMSE": round(hfd_ml_rmse, 6) if not pd.isna(hfd_ml_rmse) else np.nan,
            "HFD_UHF_GARCH_RMSE": round(hfd_g_rmse, 6) if not pd.isna(hfd_g_rmse) else np.nan,
            "HFD_RMSE_Improvement_%": round(hfd_improvement, 2) if not pd.isna(hfd_improvement) else np.nan,
            "HFD_Hybrid_R2": round(hfd_ml_r2, 4) if not pd.isna(hfd_ml_r2) else np.nan,
            "Best_LowFrequency_Model": best_lfd,
            "LFD_ARIMA_AIC": round(lfd_a_aic, 2) if not pd.isna(lfd_a_aic) else np.nan,
            "LFD_GARCH_AIC": round(lfd_g_aic, 2) if not pd.isna(lfd_g_aic) else np.nan,
            "LFD_GARCH_BIC": round(lfd_g_bic, 2) if not pd.isna(lfd_g_bic) else np.nan,
            "LFD_GARCH_Persistence": round(lfd_persistence, 4) if not pd.isna(lfd_persistence) else np.nan,
            "Mean_30D_Volatility_Forecast_%": round(vol_forecast, 4) if not pd.isna(vol_forecast) else np.nan,
            "HFD_ACD_Persistence": round(acd_pers, 4) if not pd.isna(acd_pers) else np.nan,
            "HFD_UHF_Persistence": round(uhf_pers, 4) if not pd.isna(uhf_pers) else np.nan
        })

    df_executive = pd.DataFrame(executive_rows)
    out_path = os.path.join(input_dir_excel, "ECMT3150_Final_Best_Model_Analysis.xlsx")
    
    wb = Workbook()
    
    # Sheet 1: Executive Summary
    ws1 = wb.active
    ws1.title = "Executive Summary"
    ws1.views.sheetView[0].showGridLines = True
    
    header_fill = PatternFill(start_color="1F4E78", end_color="1F4E78", fill_type="solid")
    header_font = Font(name="Calibri", size=11, bold=True, color="FFFFFF")
    thin_border = Border(left=Side(style='thin', color='D9D9D9'),
                         right=Side(style='thin', color='D9D9D9'),
                         top=Side(style='thin', color='D9D9D9'),
                         bottom=Side(style='thin', color='D9D9D9'))
    
    ws1.append(["ECMT3150 Advanced Quantitative Pipeline - Executive Best Model Analysis"])
    ws1.merge_cells("A1:N1")
    ws1["A1"].font = Font(name="Calibri", size=14, bold=True, color="1F4E78")
    ws1["A1"].alignment = Alignment(horizontal="center", vertical="center")
    ws1.row_dimensions[1].height = 30
    ws1.append([])
    
    headers = list(df_executive.columns)
    ws1.append(headers)
    ws1.row_dimensions[3].height = 24
    for col_num, h in enumerate(headers, 1):
        cell = ws1.cell(row=3, column=col_num)
        cell.fill = header_fill
        cell.font = header_font
        cell.alignment = Alignment(horizontal="center", vertical="center")
        cell.border = thin_border

    for row_idx, row_data in df_executive.iterrows():
        row_values = [row_data[h] for h in headers]
        ws1.append(row_values)
        r = ws1.max_row
        ws1.row_dimensions[r].height = 20
        for col_num in range(1, len(headers) + 1):
            cell = ws1.cell(row=r, column=col_num)
            cell.border = thin_border
            cell.alignment = Alignment(horizontal="center", vertical="center")
            cell.font = Font(name="Calibri", size=10)

    for col in ws1.columns:
        max_len = max(len(str(cell.value or '')) for cell in col)
        col_letter = get_column_letter(col[0].column)
        ws1.column_dimensions[col_letter].width = max(max_len + 4, 12)

    # Sheet 2: Feature Importance
    if hfd_imp is not None and not hfd_imp.empty:
        ws2 = wb.create_sheet(title="HFD Feature Importance")
        ws2.views.sheetView[0].showGridLines = True
        imp_headers = list(hfd_imp.columns)
        ws2.append(imp_headers)
        ws2.row_dimensions[1].height = 24
        for col_num, h in enumerate(imp_headers, 1):
            cell = ws2.cell(row=1, column=col_num)
            cell.fill = header_fill
            cell.font = header_font
            cell.alignment = Alignment(horizontal="center", vertical="center")
            cell.border = thin_border
            
        for _, row_data in hfd_imp.iterrows():
            row_values = [row_data[h] for h in imp_headers]
            ws2.append(row_values)
            r = ws2.max_row
            ws2.row_dimensions[r].height = 20
            for col_num in range(1, len(imp_headers) + 1):
                cell = ws2.cell(row=r, column=col_num)
                cell.border = thin_border
                cell.alignment = Alignment(horizontal="center", vertical="center")
                cell.font = Font(name="Calibri", size=10)
                
        for col in ws2.columns:
            max_len = max(len(str(cell.value or '')) for cell in col)
            col_letter = get_column_letter(col[0].column)
            ws2.column_dimensions[col_letter].width = max(max_len + 4, 15)

    wb.save(out_path)
    print(f"Successfully generated Advanced Final Best Model Analysis:")
    print(f"Saved to: {out_path}\n")
    print(df_executive)
    return True

if __name__ == "__main__":
    run_advanced_summary()