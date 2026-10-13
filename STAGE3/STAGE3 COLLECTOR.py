# ==============================================================================
# Script Name: ML_Benchmark_Collector.py
# Pipeline Stage: Stage 3 - Machine Learning Results Aggregation
# Description: Scans the output directory for XGBoost RDS model files (LFD and HFD). 
#              Extracts RMSE, MAE, and iteration benchmarks using a lightweight 
#              R subprocess, and compiles them into a single ML_BENCHMARK.xlsx.
# ==============================================================================

import os
import shutil
import subprocess
import pandas as pd
from datetime import datetime

def create_dir(path):
    if not os.path.exists(path):
        os.makedirs(path)

def main():
    print("======================================================")
    print(" XGBOOST ML BENCHMARK COMPILER INITIALIZED ")
    print(f" Date: {datetime.now().strftime('%Y-%m-%d')}")
    print("======================================================\n")

    # Target Directories
    input_dir_rds = os.path.join("Pipeline_Outputs", "RDS_Models")
    output_dir_compiled = os.path.join("Pipeline_Outputs", "Consolidated_Results")
    
    create_dir(output_dir_compiled)

    # ---------------------------------------------------------
    # TASK 1: EXTRACT BENCHMARKS FROM RDS (Via R Subprocess)
    # ---------------------------------------------------------
    print("Task 1: Parsing XGBoost RDS Files and Extracting Metrics...")
    
    temp_csv_dir = "temp_ml_csvs"
    create_dir(temp_csv_dir)
    
    # Inline R script to safely extract metrics from XGBoost RDS list objects
    r_extractor_script = f"""
suppressPackageStartupMessages(library(dplyr))
out_dir <- "{temp_csv_dir}"
rds_dir <- "{input_dir_rds}"

get_latest <- function(pattern) {{
  files <- list.files(rds_dir, pattern = pattern, full.names = TRUE, ignore.case = TRUE)
  if(length(files) > 0) return(files[order(file.info(files)$mtime, decreasing = TRUE)][1])
  return(NULL)
}}

# 1. HFD XGBoost
f_hfd_xgb <- get_latest("hfd_xgboost")
if(!is.null(f_hfd_xgb)) {{
  res <- readRDS(f_hfd_xgb)
  df <- bind_rows(lapply(res, function(x) x$metrics))
  write.csv(df, file.path(out_dir, "HFD_XGBOOST.csv"), row.names=FALSE)
}}

# 2. LFD XGBoost
f_lfd_xgb <- get_latest("LFD_XGBOOST")
if(!is.null(f_lfd_xgb)) {{
  res <- readRDS(f_lfd_xgb)
  df <- bind_rows(lapply(res, function(x) x$metrics))
  write.csv(df, file.path(out_dir, "LFD_XGBOOST.csv"), row.names=FALSE)
}}
"""
    
    r_script_path = "temp_ml_extractor.R"
    with open(r_script_path, "w") as f:
        f.write(r_extractor_script)
        
    try:
        subprocess.run(["Rscript", r_script_path], check=True, capture_output=True, text=True)
        print(" -> XGBoost metrics successfully extracted to temporary CSVs.\n")
    except subprocess.CalledProcessError as e:
        print(" -> Error executing R extraction script. Ensure Rscript is in your system PATH.")
        print(e.stderr)
        return
    except FileNotFoundError:
        print(" -> 'Rscript' command not found. Please ensure R is installed and in your PATH.")
        return

    # ---------------------------------------------------------
    # TASK 2: WRITE MASTER EXCEL WORKBOOK
    # ---------------------------------------------------------
    print("Task 2: Constructing ML_BENCHMARK.xlsx...")
    date_str = datetime.now().strftime("%Y-%m-%d")
    
    ml_path = os.path.join(output_dir_compiled, f"ML_BENCHMARK_{date_str}.xlsx")
    hfd_csv = os.path.join(temp_csv_dir, "HFD_XGBOOST.csv")
    lfd_csv = os.path.join(temp_csv_dir, "LFD_XGBOOST.csv")
    
    wrote_ml = False
    with pd.ExcelWriter(ml_path) as writer:
        if os.path.exists(hfd_csv):
            pd.read_csv(hfd_csv).to_excel(writer, sheet_name="HFD_XGBoost", index=False)
            wrote_ml = True
            print(" -> Appended HFD_XGBoost sheet.")
            
        if os.path.exists(lfd_csv):
            pd.read_csv(lfd_csv).to_excel(writer, sheet_name="LFD_XGBoost", index=False)
            wrote_ml = True
            print(" -> Appended LFD_XGBoost sheet.")
            
    if wrote_ml:
        print(f"\n -> Created: {ml_path}")
    else:
        if os.path.exists(ml_path):
            os.remove(ml_path)
        print("\n -> No XGBoost models found to compile. Ensure the RDS files exist.")

    # ---------------------------------------------------------
    # TASK 3: CLEANUP
    # ---------------------------------------------------------
    shutil.rmtree(temp_csv_dir)
    if os.path.exists(r_script_path):
        os.remove(r_script_path)
    
    print("\n======================================================")
    print(" ML COMPILATION COMPLETE! ")
    print(f" Output File : {ml_path if wrote_ml else 'N/A'}")
    print("======================================================\n")

if __name__ == "__main__":
    main()
