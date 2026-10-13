# ==============================================================================
# Script Name: STAGE2 COLLECTOR.py
# Pipeline Stage: Stage 3 - Results Aggregation & Benchmark Compilation
# Description: Scans all output directories for RDS model files and PNG
#              diagnostic dashboards. Safely extracts key statistical benchmarks
#              using a lightweight R subprocess (to handle complex rugarch S4 
#              objects), and compiles them into LFD_BENCHMARK.xlsx and 
#              HFD_BENCHMARK.xlsx. Aggregates all PNG plots into a central folder.
# ==============================================================================

import os
import shutil
import subprocess
import pandas as pd
from datetime import datetime
from pathlib import Path

def create_dir(path):
    os.makedirs(path, exist_ok=True)

def main():
    print("======================================================")
    print(" PIPELINE BENCHMARK COMPILER INITIALIZED ")
    print(f" Date: {datetime.now().strftime('%Y-%m-%d')}")
    print("======================================================\n")

    # Resolve Base Output Directory (Targeting ECMT3150 OUTPUTS)
    if os.path.exists("../ECMT3150 OUTPUTS"):
        base_output_dir = os.path.abspath("../ECMT3150 OUTPUTS/Pipeline_Outputs")
    else:
        base_output_dir = os.path.abspath("Pipeline_Outputs")

    # Target Directories
    input_dir_rds = os.path.join(base_output_dir, "RDS_Models")
    input_dir_png = os.path.join(base_output_dir, "PNG_Plots")
    
    output_dir_compiled = os.path.join(base_output_dir, "Consolidated_Results")
    output_dir_plots = os.path.join(base_output_dir, "Consolidated_Plots")
    
    create_dir(output_dir_compiled)
    create_dir(output_dir_plots)

    print(f"Reading RDS Models from : {input_dir_rds}")
    print(f"Reading PNG Plots from  : {input_dir_png}\n")

    # ---------------------------------------------------------
    # TASK 1: CONSOLIDATE PNG DASHBOARDS
    # ---------------------------------------------------------
    print("Task 1: Consolidating PNG Diagnostic Plots...")
    png_count = 0
    if os.path.exists(input_dir_png):
        for root, dirs, files in os.walk(input_dir_png):
            for file in files:
                if file.lower().endswith(".png"):
                    src_path = os.path.join(root, file)
                    dst_path = os.path.join(output_dir_plots, file)
                    shutil.copy2(src_path, dst_path)
                    png_count += 1
        print(f" -> Successfully copied {png_count} diagnostic plots to {output_dir_plots}\n")
    else:
        print(" -> No PNG plots directory found at expected path.\n")

    # ---------------------------------------------------------
    # TASK 2: EXTRACT BENCHMARKS FROM RDS (Via R Subprocess)
    # ---------------------------------------------------------
    print("Task 2: Parsing Model RDS Files and Extracting Benchmarks...")
    
    temp_csv_dir = os.path.abspath("temp_benchmark_csvs")
    create_dir(temp_csv_dir)
    
    # Escape paths for R script string injection
    r_rds_dir = input_dir_rds.replace("\\", "/")
    r_out_dir = temp_csv_dir.replace("\\", "/")

    # Inline R script to safely bypass Python's inability to read S4 R objects
    r_extractor_script = f"""
suppressPackageStartupMessages(library(dplyr))
out_dir <- "{r_out_dir}"
rds_dir <- "{r_rds_dir}"

cat("Scanning RDS directory:", rds_dir, "\\n")

get_latest <- function(pattern) {{
  files <- list.files(rds_dir, pattern = pattern, full.names = TRUE, ignore.case = TRUE)
  if(length(files) > 0) return(files[order(file.info(files)$mtime, decreasing = TRUE)][1])
  return(NULL)
}}

# 1. LFD GARCH(1,1)
f_lfd_garch <- get_latest("LFD_GARCH")
if(!is.null(f_lfd_garch)) {{
  cat("Processing:", basename(f_lfd_garch), "\\n")
  res <- readRDS(f_lfd_garch)
  df <- bind_rows(lapply(res, function(x) x$summary_df))
  write.csv(df, file.path(out_dir, "LFD_GARCH.csv"), row.names=FALSE)
}}

# 2. LFD SV
f_lfd_sv <- get_latest("LFD_SV")
if(!is.null(f_lfd_sv)) {{
  cat("Processing:", basename(f_lfd_sv), "\\n")
  res <- readRDS(f_lfd_sv)
  df <- bind_rows(lapply(res, function(x) x$summary_df))
  write.csv(df, file.path(out_dir, "LFD_SV.csv"), row.names=FALSE)
}}

# 3. HFD Realised GARCH
f_hfd_rg <- get_latest("realgarch")
if(!is.null(f_hfd_rg)) {{
  cat("Processing:", basename(f_hfd_rg), "\\n")
  res <- readRDS(f_hfd_rg)
  df <- bind_rows(lapply(names(res), function(nm) {{
    x <- res[[nm]]
    data.frame(
      Ticker = nm,
      Model_Type = x$model_type,
      Omega = ifelse("omega" %in% names(x$coefficients), as.numeric(x$coefficients["omega"]), NA),
      Alpha1 = ifelse("alpha1" %in% names(x$coefficients), as.numeric(x$coefficients["alpha1"]), NA),
      Beta1 = ifelse("beta1" %in% names(x$coefficients), as.numeric(x$coefficients["beta1"]), NA),
      LogLikelihood = x$log_likelihood,
      AIC = x$AIC,
      BIC = x$BIC
    )
  }}))
  write.csv(df, file.path(out_dir, "HFD_RealGARCH.csv"), row.names=FALSE)
}}

# 4. HFD HAR-RV
f_hfd_har <- get_latest("harrv")
if(!is.null(f_hfd_har)) {{
  cat("Processing:", basename(f_hfd_har), "\\n")
  res <- readRDS(f_hfd_har)
  df <- bind_rows(lapply(names(res), function(nm) {{
    x <- res[[nm]]
    data.frame(
      Ticker = nm,
      Intercept = as.numeric(x$coefficients["(Intercept)"]),
      Beta_Daily = as.numeric(x$coefficients["RV_Daily"]),
      Beta_Weekly = as.numeric(x$coefficients["RV_Weekly"]),
      Beta_Monthly = as.numeric(x$coefficients["RV_Monthly"]),
      R_Squared = x$r_squared,
      Adj_R_Squared = x$adj_r_squared,
      AIC = x$AIC,
      BIC = x$BIC
    )
  }}))
  write.csv(df, file.path(out_dir, "HFD_HARRV.csv"), row.names=FALSE)
}}
"""
    
    r_script_path = "temp_extractor.R"
    with open(r_script_path, "w", encoding="utf-8") as f:
        f.write(r_extractor_script)
        
    try:
        subprocess.run(["Rscript", r_script_path], check=True, capture_output=True, text=True)
        print(" -> RDS data successfully extracted to temporary CSVs.\n")
    except subprocess.CalledProcessError as e:
        print(" -> Error executing R extraction script.")
        print(e.stderr)
        if os.path.exists(temp_csv_dir):
            shutil.rmtree(temp_csv_dir)
        if os.path.exists(r_script_path):
            os.remove(r_script_path)
        return
    except FileNotFoundError:
        print(" -> 'Rscript' command not found. Please ensure R is installed and in your PATH.")
        return

    # ---------------------------------------------------------
    # TASK 3: WRITE MASTER EXCEL WORKBOOKS
    # ---------------------------------------------------------
    print("Task 3: Constructing Benchmark Workbooks...")
    
    # -- A. LFD_BENCHMARK.xlsx --
    lfd_path = os.path.join(output_dir_compiled, "LFD_BENCHMARK.xlsx")
    lfd_garch_csv = os.path.join(temp_csv_dir, "LFD_GARCH.csv")
    lfd_sv_csv = os.path.join(temp_csv_dir, "LFD_SV.csv")
    
    wrote_lfd = False
    with pd.ExcelWriter(lfd_path) as writer:
        if os.path.exists(lfd_garch_csv):
            pd.read_csv(lfd_garch_csv).to_excel(writer, sheet_name="LFD_GARCH(1,1)", index=False)
            wrote_lfd = True
        if os.path.exists(lfd_sv_csv):
            pd.read_csv(lfd_sv_csv).to_excel(writer, sheet_name="LFD_SV", index=False)
            wrote_lfd = True
            
    if wrote_lfd:
        print(f" -> Created: {lfd_path}")
    else:
        if os.path.exists(lfd_path):
            os.remove(lfd_path)
        print(" -> No LFD models found to compile.")

    # -- B. HFD_BENCHMARK.xlsx --
    hfd_path = os.path.join(output_dir_compiled, "HFD_BENCHMARK.xlsx")
    hfd_rg_csv = os.path.join(temp_csv_dir, "HFD_RealGARCH.csv")
    hfd_har_csv = os.path.join(temp_csv_dir, "HFD_HARRV.csv")
    
    wrote_hfd = False
    with pd.ExcelWriter(hfd_path) as writer:
        if os.path.exists(hfd_rg_csv):
            pd.read_csv(hfd_rg_csv).to_excel(writer, sheet_name="HFD_Realised_GARCH", index=False)
            wrote_hfd = True
        if os.path.exists(hfd_har_csv):
            pd.read_csv(hfd_har_csv).to_excel(writer, sheet_name="HFD_HAR-RV", index=False)
            wrote_hfd = True
            
    if wrote_hfd:
        print(f" -> Created: {hfd_path}")
    else:
        if os.path.exists(hfd_path):
            os.remove(hfd_path)
        print(" -> No HFD models found to compile.")

    # ---------------------------------------------------------
    # TASK 4: CLEANUP
    # ---------------------------------------------------------
    if os.path.exists(temp_csv_dir):
        shutil.rmtree(temp_csv_dir)
    if os.path.exists(r_script_path):
        os.remove(r_script_path)
    
    print("\n======================================================")
    print(" COMPILATION COMPLETE! ")
    print(f" LFD Benchmarks : {lfd_path if wrote_lfd else 'N/A'}")
    print(f" HFD Benchmarks : {hfd_path if wrote_hfd else 'N/A'}")
    print(f" Consolidated Plots Folder : {output_dir_plots}")
    print("======================================================\n")

if __name__ == "__main__":
    main()
