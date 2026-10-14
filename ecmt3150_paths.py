"""
ecmt3150_paths.py - single source of truth for pipeline folders (Python side).

Every Python stage imports this module, and every R stage sources
ECMT3150_COMMON.R, which uses exactly the same layout. Paths are resolved from
the location of THIS file, never from the current working directory, so the
scripts behave identically whether they are started by the orchestrator, from
the VS Code terminal in any folder, or by double-clicking.

    <project>/ECMT3150 OUTPUTS/
        ECMT3150_LSEG_OUTPUTs/          Stage 1 workbooks (LSEG_LFD.xlsx, LSEG_HFD.xlsx)
        Pipeline_Outputs/
            RDS_Models/<MODEL>.rds
            Model_Tables/<MODEL>/*.csv  summary / oos_metrics / oos_forecasts / feature_importance
            PNG_Plots/<MODEL>/*.png
            Consolidated_Results/       LFD_BENCHMARK.xlsx, HFD_BENCHMARK.xlsx, ML_BENCHMARK.xlsx
            Consolidated_Plots/         every PNG in one flat folder
            Conclusive_Results/         CONCLUSIVE_MODEL_DIAGNOSTICS.xlsx
        PHOTOS/<MODEL>/                 plots sorted by model
        ECMT3150_Final_Best_Model_Analysis.md

Set the environment variable ECMT3150_OUTPUT_DIR to put the outputs elsewhere.
"""

from __future__ import annotations

import glob
import os
import shutil
from pathlib import Path
from typing import Optional

PROJECT_ROOT = Path(__file__).resolve().parent
OUTPUT_ROOT = Path(os.environ.get("ECMT3150_OUTPUT_DIR") or (PROJECT_ROOT / "ECMT3150 OUTPUTS")).resolve()

LSEG_DIR = OUTPUT_ROOT / "ECMT3150_LSEG_OUTPUTs"
PIPELINE_DIR = OUTPUT_ROOT / "Pipeline_Outputs"
RDS_DIR = PIPELINE_DIR / "RDS_Models"
TABLE_DIR = PIPELINE_DIR / "Model_Tables"
PNG_DIR = PIPELINE_DIR / "PNG_Plots"
RESULTS_DIR = PIPELINE_DIR / "Consolidated_Results"
PLOTS_DIR = PIPELINE_DIR / "Consolidated_Plots"
CONCLUSIVE_DIR = PIPELINE_DIR / "Conclusive_Results"
PHOTOS_DIR = OUTPUT_ROOT / "PHOTOS"
FINAL_REPORT = OUTPUT_ROOT / "ECMT3150_Final_Best_Model_Analysis.md"

# Model keys used for folder and file names, with display names.
STAGE2_MODELS = {
    "LFD_GARCH": "LFD_GARCH(1,1)",
    "LFD_SV": "LFD_SV",
    "HFD_REALGARCH": "HFD_Realised_GARCH",
    "HFD_HARRV": "HFD_HAR-RV",
}
STAGE3_MODELS = {
    "HFD_XGBOOST": "HFD_XGBoost",
    "LFD_XGBOOST": "LFD_XGBoost",
}


def ensure_dirs(*paths: Path) -> None:
    for path in paths:
        Path(path).mkdir(parents=True, exist_ok=True)


def find_rscript() -> Optional[str]:
    """Rscript from RSCRIPT_EXE, PATH, or the usual Windows install folders."""
    override = os.environ.get("RSCRIPT_EXE")
    if override and Path(override).is_file():
        return override
    on_path = shutil.which("Rscript")
    if on_path:
        return on_path
    patterns = [
        r"C:\Program Files\R\R-*\bin\Rscript.exe",
        r"C:\Program Files (x86)\R\R-*\bin\Rscript.exe",
        str(Path.home() / "AppData/Local/Programs/R/R-*/bin/Rscript.exe"),
        r"C:\R\R-*\bin\Rscript.exe",
        "/Library/Frameworks/R.framework/Resources/bin/Rscript",
        "/opt/homebrew/bin/Rscript",
        "/usr/local/bin/Rscript",
    ]
    found = []
    for pattern in patterns:
        found.extend(glob.glob(pattern))
    return sorted(found, reverse=True)[0] if found else None


def find_lseg_workbook(freq: str) -> Optional[Path]:
    """Newest merged LSEG_<freq>.xlsx (same rule as ecmt_find_lseg_workbook in R)."""
    import re

    pattern = re.compile(rf"^LSEG_{freq}(_[0-9_-]+)?\.xlsx$", re.IGNORECASE)
    merged = re.compile(rf"^LSEG_{freq}(_[0-9]{{6}})?\.xlsx$", re.IGNORECASE)
    for folder, recursive in ((LSEG_DIR, True), (OUTPUT_ROOT, False), (PROJECT_ROOT, False)):
        if not folder.is_dir():
            continue
        files = folder.rglob("*.xlsx") if recursive else folder.glob("*.xlsx")
        candidates = [p for p in files if pattern.match(p.name) and not p.name.startswith("~$")]
        if candidates:
            candidates.sort(key=lambda p: (not merged.match(p.name), -p.stat().st_mtime))
            return candidates[0]
    return None


def read_model_table(model_key: str, table: str):
    """Read Model_Tables/<model_key>/<table>.csv, or None if it does not exist."""
    import pandas as pd

    path = TABLE_DIR / model_key / f"{table}.csv"
    if not path.is_file():
        return None
    try:
        return pd.read_csv(path)
    except Exception as exc:  # pragma: no cover - reported to the user
        print(f"  [!] Could not read {path}: {exc}")
        return None


def describe() -> str:
    return (f"Project root : {PROJECT_ROOT}\n"
            f"Output root  : {OUTPUT_ROOT}")
