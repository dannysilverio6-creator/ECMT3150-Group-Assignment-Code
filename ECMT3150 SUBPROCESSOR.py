#!/usr/bin/env python3
# ==============================================================================
# Pipeline Stage 0: Master Subprocessor & Pipeline Orchestrator
# Script Name: ECMT3150 SUBPROCESSOR.py
# Description: Executes all pipeline scripts sequentially, manages dependencies,
#              handles subprocess errors, and logs runtime outputs.
# ==============================================================================

import os
import sys
import glob
import subprocess
import time
import shutil
from datetime import datetime

# Automatically set working directory to the directory where this script resides
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if SCRIPT_DIR:
    os.chdir(SCRIPT_DIR)

# ------------------------------------------------------------------------------
# 1. Executable Auto-Discovery Functions
# ------------------------------------------------------------------------------
def get_rscript_path():
    """Dynamically locates Rscript.exe across standard Windows installation paths and PATH."""
    path_executable = shutil.which("Rscript")
    if path_executable:
        return path_executable

    search_patterns = [
        r"C:\Program Files\R\R-*\bin\Rscript.exe",
        r"C:\Program Files (x86)\R\R-*\bin\Rscript.exe",
        os.path.expanduser(r"~\AppData\Local\Programs\R\R-*\bin\Rscript.exe"),
        r"C:\R\R-*\bin\Rscript.exe",
        r"C:\Program Files\R\*\bin\Rscript.exe",
        r"C:\Program Files (x86)\R\*\bin\Rscript.exe"
    ]

    found_paths = []
    for pattern in search_patterns:
        found_paths.extend(glob.glob(pattern))

    if found_paths:
        found_paths.sort(reverse=True)
        return found_paths[0]

    return None

RSCRIPT_EXE = get_rscript_path()
PYTHON_EXE = sys.executable

# ------------------------------------------------------------------------------
# 2. Pipeline Execution Configuration
# ------------------------------------------------------------------------------
PIPELINE_STAGES = [
    {
        "stage": 1,
        "name": "LSEG Workspace Data Extraction",
        "interpreter": PYTHON_EXE,
        "script": "LSEG_DUAL_FREQUENCY_EXTRACTION.py",
        "required": True
    },
    {
        "stage": 2,
        "name": "Low-Frequency ARIMA Price Modeling",
        "interpreter": RSCRIPT_EXE,
        "script": "LFD_ARIMAMODEL.R",
        "required": True
    },
    {
        "stage": 2,
        "name": "Low-Frequency GARCH Volatility Modeling",
        "interpreter": RSCRIPT_EXE,
        "script": "LFD_GARCHMODEL.R",
        "required": True
    },
    {
        "stage": 2,
        "name": "Low-Frequency Hybrid Machine Learning",
        "interpreter": RSCRIPT_EXE,
        "script": "LFD_HYBRIDML.R",
        "required": True
    },
    {
        "stage": 3,
        "name": "High-Frequency ACD Microstructure Modeling",
        "interpreter": RSCRIPT_EXE,
        "script": "HFD_ACDMODEL.R",
        "required": True
    },
    {
        "stage": 3,
        "name": "High-Frequency UHF-GARCH Volatility Modeling",
        "interpreter": RSCRIPT_EXE,
        "script": "HFD_UHFGARCHMODEL.R",
        "required": True
    },
    {
        "stage": 4,
        "name": "High-Frequency Hybrid Econometric-ML Forecasting",
        "interpreter": RSCRIPT_EXE,
        "script": "HFD_HYBRIDML.R",
        "required": True
    },
    {
        "stage": 5,
        "name": "Pipeline Compiler & Summary Exporter",
        "interpreter": RSCRIPT_EXE,
        "script": "ECMT3150 COMPILER.R",
        "required": True
    },
    {
        "stage": 6,
        "name": "Final Model Analysis & Best Model Selection",
        "interpreter": PYTHON_EXE,
        "script": "ECMT3150_FINAL_SUMMARY.py",
        "required": True
    }
]

LOG_DIR = "Pipeline_Logs"
os.makedirs(LOG_DIR, exist_ok=True)
TIMESTAMP = datetime.now().strftime("%Y%m%d_%H%M%S")
MASTER_LOG_FILE = os.path.join(LOG_DIR, f"pipeline_execution_{TIMESTAMP}.log")

# ------------------------------------------------------------------------------
# 3. Helper Logging & Utility Functions
# ------------------------------------------------------------------------------
def log_message(msg, log_file=MASTER_LOG_FILE):
    """Logs message to console and master execution log."""
    timestamp = datetime.now().strftime("[%Y-%m-%d %H:%M:%S]")
    formatted_msg = f"{timestamp} {msg}"
    print(formatted_msg)
    try:
        with open(log_file, "a", encoding="utf-8") as f:
            f.write(formatted_msg + "\n")
    except Exception:
        pass

def check_executables():
    """Validates availability of Python and Rscript executables."""
    global RSCRIPT_EXE
    if not PYTHON_EXE:
        log_message("CRITICAL ERROR: Python executable not found.")
        sys.exit(1)

    if not RSCRIPT_EXE or not os.path.exists(RSCRIPT_EXE):
        print("\n[!] Rscript.exe was not automatically detected on your system.")
        print("Please enter the full path to your Rscript.exe (e.g. C:\\Program Files\\R\\R-4.4.2\\bin\\Rscript.exe)")
        manual_path = input("Rscript.exe path (or press Enter to try 'Rscript'): ").strip()
        if manual_path:
            RSCRIPT_EXE = manual_path.strip('"')
        else:
            RSCRIPT_EXE = "Rscript"
            
        for stage in PIPELINE_STAGES:
            if stage["script"].endswith(".R"):
                stage["interpreter"] = RSCRIPT_EXE

    log_message("System dependency check passed.")
    log_message(f"Working Directory set to: {SCRIPT_DIR}")
    log_message(f"Using Python path   : {PYTHON_EXE}")
    log_message(f"Using Rscript path  : {RSCRIPT_EXE}")

def safe_filename(text):
    return "".join([c if c.isalnum() else "_" for c in text])

def run_subprocess(stage_info):
    """Executes a single pipeline stage with real-time logging and failure handling."""
    interpreter = stage_info["interpreter"]
    script_path = stage_info["script"]
    stage_name = f"Stage {stage_info['stage']} - {stage_info['name']}"

    if not os.path.exists(script_path):
        log_message(f"ERROR: Script '{script_path}' does not exist in {SCRIPT_DIR}.")
        if stage_info["required"]:
            return False
        return True

    log_message(f"\n{'='*70}\nSTARTING: {stage_name}\nExecuting: {interpreter} {script_path}\n{'='*70}")
    
    start_time = time.time()
    cmd = [interpreter, script_path]
    
    stage_log_path = os.path.join(LOG_DIR, f"stage_{stage_info['stage']}_{safe_filename(script_path)}.log")

    try:
        with open(stage_log_path, "w", encoding="utf-8") as log_out:
            process = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
                cwd=SCRIPT_DIR
            )
            
            for line in process.stdout:
                sys.stdout.write(line)
                log_out.write(line)
                
            process.wait()
            
        elapsed_time = round(time.time() - start_time, 2)
        
        if process.returncode == 0:
            log_message(f"SUCCESS: {stage_name} completed in {elapsed_time}s.")
            return True
        else:
            log_message(f"FAILURE: {stage_name} failed with Exit Code {process.returncode} ({elapsed_time}s).")
            return False

    except Exception as e:
        log_message(f"EXCEPTION in {stage_name}: {str(e)}")
        return False

# ------------------------------------------------------------------------------
# 4. Execution Entry Point
# ------------------------------------------------------------------------------
def main():
    log_message("Starting Quantitative Pipeline Subprocessor Execution")
    check_executables()
    
    total_start = time.time()
    failed_stages = []

    for stage in PIPELINE_STAGES:
        success = run_subprocess(stage)
        if not success and stage["required"]:
            log_message(f"\nCRITICAL: Pipeline halted due to required stage failure ({stage['script']}).")
            failed_stages.append(stage['script'])
            break
        elif not success:
            failed_stages.append(stage['script'])

    total_elapsed = round(time.time() - total_start, 2)
    log_message(f"\n{'='*70}\nPIPELINE EXECUTION SUMMARY\n{'='*70}")
    log_message(f"Total Execution Time: {total_elapsed} seconds")
    
    if failed_stages:
        log_message(f"Status: FAILED. Unsuccessful scripts: {', '.join(failed_stages)}")
        sys.exit(1)
    else:
        log_message("Status: SUCCESS. All pipeline stages executed successfully.")
        sys.exit(0)

if __name__ == "__main__":
    main()