#!/usr/bin/env python3
# =============================================================================
# ECMT3150 QUANTITATIVE COMMODITY PIPELINE ORCHESTRATOR
#
# Coordinates the pipeline shown in the pipeline design:
#
# ORCHESTRATOR.py
#   -> STAGE1/LSEG_DATA_EXTRACTION.py        -> LSEG_LFD.xlsx + LSEG_HFD.xlsx
#   -> STAGE2/S2 INSTALLATIONS.R             (R packages)
#   -> STAGE2/HFD_RealisedGARCH_MODEL.R, HFD_HAR-RV_MODEL.R,
#      LFD_GARCH_MODEL.R, LFD_SV_MODEL.R
#   -> STAGE2/STAGE2 COLLECTOR.py            -> LFD_BENCHMARK.xlsx + HFD_BENCHMARK.xlsx
#   -> STAGE3/HFD_XGBOOST_MODEL.R, LFD_XGBOOST_MODEL.R
#   -> STAGE3/STAGE3 COLLECTOR.py            -> ML_BENCHMARK.xlsx
#   -> STAGE4/EVENT_STUDY.R                  -> event-study tables + comparison plots
#   -> STAGE4/DIAGNOSTIC.py                  -> CONCLUSIVE_MODEL_DIAGNOSTICS.xlsx + PHOTOS/
#   -> STAGE4/FINAL SUMMARY.py               -> ECMT3150_Final_Best_Model_Analysis.md
#
# All outputs go to "<project>/ECMT3150 OUTPUTS" (see ecmt3150_paths.py and
# ECMT3150_COMMON.R). Run from the VS Code terminal, in any folder:
#   python "ECMT3150 ORCHESTRATOR.py"
#
# Optional:
#   python "ECMT3150 ORCHESTRATOR.py" --dry-run
#   python "ECMT3150 ORCHESTRATOR.py" --skip-extract     (reuse existing LSEG workbooks;
#                                                        no LSEG Workspace needed)
#   python "ECMT3150 ORCHESTRATOR.py" --continue-independent
#
# The orchestrator does not implement the modelling itself. It runs the scripts
# listed below, checks their exit codes and that each expected output file was
# (re)written during this run, and records what happened.
# =============================================================================

from __future__ import annotations

import argparse
import glob
import os
import shutil
import subprocess
import sys
import time
import traceback
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Optional, Sequence

# ------------------------------- PATHS ---------------------------------------

BASE_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(BASE_DIR))
import ecmt3150_paths as P  # noqa: E402  (shared folder definitions)

OUTPUT_DIR = P.OUTPUT_ROOT            # "<project>/ECMT3150 OUTPUTS"
LOG_DIR = OUTPUT_DIR / "Pipeline_Logs"

PYTHON_EXE = sys.executable

# Set this to a full path to pin an R installation, or leave as None for auto-find
# (RSCRIPT_EXE environment variable, PATH, then the usual install folders).
RSCRIPT_OVERRIDE = None
RSCRIPT_EXE = RSCRIPT_OVERRIDE or P.find_rscript()

# -------------------------- USER CONFIGURATION -------------------------------
# Each stage has:
#   id          unique short name used in logs
#   script      script filename relative to BASE_DIR (or absolute path)
#   runtime     "python" or "r"
#   required    if False, failure is logged but does not halt the pipeline
#   depends_on  IDs of stages that must succeed first
#   outputs     files expected after the script exits successfully, relative to
#               OUTPUT_DIR ("<project>/ECMT3150 OUTPUTS"). Glob patterns are
#               allowed. Each must have been written during this run.

RDS = "Pipeline_Outputs/RDS_Models"
TABLES = "Pipeline_Outputs/Model_Tables"
RESULTS = "Pipeline_Outputs/Consolidated_Results"

PIPELINE_STAGES = [
    {
        "id": "extract",
        "stage": 1,
        "name": "LSEG dual-frequency extraction",
        "runtime": "python",
        "script": "STAGE1/LSEG_DATA_EXTRACTION.py",
        "required": True,
        "depends_on": [],
        "outputs": ["ECMT3150_LSEG_OUTPUTs/**/LSEG_HFD*.xlsx", "ECMT3150_LSEG_OUTPUTs/**/LSEG_LFD*.xlsx"],
    },
    {
        "id": "stage2_install",
        "stage": 2,
        "name": "Stage 2/3 R package installation",
        "runtime": "r",
        "script": "STAGE2/S2 INSTALLATIONS.R",
        "required": True,
        "depends_on": [],
        "outputs": [],
    },
    {
        "id": "hfd_realized_garch",
        "stage": 2,
        "name": "HFD Realized GARCH",
        "runtime": "r",
        "script": "STAGE2/HFD_RealisedGARCH_MODEL.R",
        "required": True,
        "depends_on": ["extract", "stage2_install"],
        "outputs": [f"{RDS}/HFD_REALGARCH.rds", f"{TABLES}/HFD_REALGARCH/oos_metrics.csv"],
    },
    {
        "id": "hfd_har_rv",
        "stage": 2,
        "name": "HFD HAR-RV",
        "runtime": "r",
        "script": "STAGE2/HFD_HAR-RV_MODEL.R",
        "required": True,
        "depends_on": ["extract", "stage2_install"],
        "outputs": [f"{RDS}/HFD_HARRV.rds", f"{TABLES}/HFD_HARRV/oos_metrics.csv"],
    },
    {
        "id": "lfd_garch",
        "stage": 2,
        "name": "LFD GARCH(1,1)",
        "runtime": "r",
        "script": "STAGE2/LFD_GARCH_MODEL.R",
        "required": True,
        "depends_on": ["extract", "stage2_install"],
        "outputs": [f"{RDS}/LFD_GARCH.rds", f"{TABLES}/LFD_GARCH/oos_metrics.csv"],
    },
    {
        "id": "lfd_sv",
        "stage": 2,
        "name": "LFD Stochastic Volatility",
        "runtime": "r",
        "script": "STAGE2/LFD_SV_MODEL.R",
        "required": True,
        "depends_on": ["extract", "stage2_install"],
        "outputs": [f"{RDS}/LFD_SV.rds", f"{TABLES}/LFD_SV/oos_metrics.csv"],
    },
    {
        "id": "benchmark",
        "stage": 3,
        "name": "Benchmark comparison and workbook creation",
        "runtime": "python",
        "script": "STAGE2/STAGE2 COLLECTOR.py",
        "required": True,
        "depends_on": [
            "hfd_realized_garch", "hfd_har_rv", "lfd_garch", "lfd_sv"
        ],
        "outputs": [f"{RESULTS}/LFD_BENCHMARK.xlsx", f"{RESULTS}/HFD_BENCHMARK.xlsx"],
    },
    {
        "id": "hfd_hybrid",
        "stage": 4,
        "name": "HFD hybrid econometric and ML model",
        "runtime": "r",
        "script": "STAGE3/HFD_XGBOOST_MODEL.R",
        "required": True,
        "depends_on": ["benchmark"],
        "outputs": [f"{RDS}/HFD_XGBOOST.rds", f"{TABLES}/HFD_XGBOOST/oos_metrics.csv"],
    },
    {
        "id": "lfd_hybrid",
        "stage": 4,
        "name": "LFD hybrid econometric and ML model",
        "runtime": "r",
        "script": "STAGE3/LFD_XGBOOST_MODEL.R",
        "required": True,
        "depends_on": ["benchmark"],
        "outputs": [f"{RDS}/LFD_XGBOOST.rds", f"{TABLES}/LFD_XGBOOST/oos_metrics.csv"],
    },
    {
        "id": "collector",
        "stage": 5,
        "name": "Collect model outputs",
        "runtime": "python",
        "script": "STAGE3/STAGE3 COLLECTOR.py",
        "required": True,
        "depends_on": ["hfd_hybrid", "lfd_hybrid"],
        "outputs": [f"{RESULTS}/ML_BENCHMARK.xlsx"],
    },
    {
        "id": "event_study",
        "stage": 6,
        "name": "Event study: shock windows, counterfactual, model robustness",
        "runtime": "r",
        "script": "STAGE4/EVENT_STUDY.R",
        "required": True,
        "depends_on": ["collector"],
        "outputs": [f"{TABLES}/EVENT_STUDY/window_metrics.csv",
                    f"{TABLES}/EVENT_STUDY/abnormal_volatility.csv",
                    f"{TABLES}/EVENT_STUDY/lfd_event_study.csv",
                    "Pipeline_Outputs/PNG_Plots/EVENT_STUDY/*.png"],
    },
    {
        "id": "diagnostic",
        "stage": 7,
        "name": "Model verdict (leaderboards, DM tests) and conclusive workbook",
        "runtime": "python",
        "script": "STAGE4/DIAGNOSTIC.py",
        "required": True,
        "depends_on": ["event_study"],
        "outputs": ["Pipeline_Outputs/Conclusive_Results/CONCLUSIVE_MODEL_DIAGNOSTICS.xlsx"],
    },
    {
        "id": "final_summary",
        "stage": 8,
        "name": "Final Summary",
        "runtime": "python",
        "script": "STAGE4/FINAL SUMMARY.py",
        "required": True,
        "depends_on": ["diagnostic"],
        "outputs": ["ECMT3150_Final_Best_Model_Analysis.md"],
    }
]

# ------------------------------- LOGGING -------------------------------------

RUN_ID = datetime.now().strftime("%Y%m%d_%H%M%S")
LOG_DIR.mkdir(parents=True, exist_ok=True)
MASTER_LOG = LOG_DIR / f"pipeline_{RUN_ID}.log"
STAGE_STATUS_LOG = LOG_DIR / f"pipeline_status_{RUN_ID}.csv"


def log(message: str) -> None:
    timestamped = f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {message}"
    print(timestamped, flush=True)
    try:
        with MASTER_LOG.open("a", encoding="utf-8") as handle:
            handle.write(timestamped + "\n")
    except OSError:
        # Console logging should continue even if the log file cannot be written.
        pass


def safe_name(value: str) -> str:
    return "".join(ch if ch.isalnum() or ch in "-_" else "_" for ch in value)


def runtime_executable(runtime: str) -> Optional[str]:
    if runtime.lower() == "python":
        return PYTHON_EXE
    if runtime.lower() == "r":
        return RSCRIPT_EXE
    raise ValueError(f"Unsupported runtime {runtime!r}; use 'python' or 'r'.")


def resolve_script(script_value: str) -> Path:
    path = Path(script_value)
    return path if path.is_absolute() else BASE_DIR / path


def child_environment() -> dict:
    """Environment for every stage: shared folders, Rscript path, UTF-8 output."""
    env = os.environ.copy()
    env["ECMT3150_PROJECT_ROOT"] = str(BASE_DIR)
    env["ECMT3150_OUTPUT_DIR"] = str(OUTPUT_DIR)
    env["ECMT3150_RUN_ID"] = RUN_ID
    if RSCRIPT_EXE:
        env["RSCRIPT_EXE"] = RSCRIPT_EXE
    env["PYTHONUTF8"] = "1"
    env["PYTHONIOENCODING"] = "utf-8"
    env["PYTHONUNBUFFERED"] = "1"
    return env


def check_outputs(patterns: Sequence[str], since: float) -> tuple[list[str], list[str]]:
    """Return (found, problems). Each pattern must match a file written after `since`."""
    found, problems = [], []
    for pattern in patterns:
        matches = [Path(m) for m in glob.glob(str(OUTPUT_DIR / pattern), recursive=True)]
        matches = [m for m in matches if m.is_file() and not m.name.startswith("~$")]
        if not matches:
            problems.append(f"{pattern} (not found)")
            continue
        newest = max(matches, key=lambda m: m.stat().st_mtime)
        # 2-second tolerance for coarse file-system timestamps
        if newest.stat().st_mtime < since - 2:
            problems.append(f"{pattern} (stale: last written "
                            f"{datetime.fromtimestamp(newest.stat().st_mtime):%Y-%m-%d %H:%M})")
            continue
        found.append(str(newest.relative_to(OUTPUT_DIR)))
    return found, problems


def append_status(row: dict) -> None:
    import csv

    exists = STAGE_STATUS_LOG.exists()
    fields = [
        "run_id", "stage", "id", "name", "script", "status",
        "exit_code", "seconds", "started_at", "finished_at", "message"
    ]
    try:
        with STAGE_STATUS_LOG.open("a", newline="", encoding="utf-8") as handle:
            writer = csv.DictWriter(handle, fieldnames=fields)
            if not exists:
                writer.writeheader()
            writer.writerow({key: row.get(key, "") for key in fields})
    except OSError as exc:
        log(f"WARNING: Could not write status CSV: {exc}")


# ----------------------------- PRE-FLIGHT ------------------------------------

def check_runtime(runtime: str) -> tuple[bool, str]:
    exe = runtime_executable(runtime)
    if not exe:
        return False, (
            "Rscript was not found. Install R and add its bin folder to PATH, "
            "or set RSCRIPT_OVERRIDE near the top of ORCHESTRATOR.py."
        )
    if os.path.isabs(exe) and not os.path.exists(exe):
        return False, f"Interpreter does not exist: {exe}"
    if not os.path.isabs(exe) and shutil.which(exe) is None:
        return False, f"Interpreter is not available on PATH: {exe}"
    return True, exe


def preflight(dry_run: bool) -> bool:
    log(f"Project folder: {BASE_DIR}")
    log(f"Output folder: {OUTPUT_DIR}")
    log(f"Python executable: {PYTHON_EXE}")
    log(f"Rscript executable: {RSCRIPT_EXE or 'NOT FOUND'}")
    log(f"Master log: {MASTER_LOG}")
    log(f"Dry run: {dry_run}")

    missing_scripts = []
    missing_runtimes = []

    for stage in PIPELINE_STAGES:
        script_path = resolve_script(stage["script"])
        if not script_path.is_file():
            missing_scripts.append(f"{stage['id']}: {script_path.name}")

        ok, detail = check_runtime(stage["runtime"])
        if not ok:
            missing_runtimes.append(f"{stage['id']} runtime: {detail}")

    if missing_scripts:
        log("WARNING: Some pipeline scripts are not present yet:")
        for item in missing_scripts:
            log(f"  - {item}")
        log(
            "The orchestrator will run available stages in dependency order. "
            "A missing script will be marked as failed when its stage is reached."
        )

    if missing_runtimes:
        log("ERROR: Required runtimes are unavailable:")
        for item in missing_runtimes:
            log(f"  - {item}")
        if not dry_run:
            log("Install/configure the missing runtime(s) before running the pipeline.")
            return False
        log("Dry run will still print the configured plan.")

    return True


# ------------------------------ EXECUTION ------------------------------------

@dataclass
class StageResult:
    id: str
    name: str
    status: str
    exit_code: Optional[int] = None
    seconds: float = 0.0
    message: str = ""
    outputs_found: list[str] = field(default_factory=list)


def run_stage(stage: dict, dry_run: bool = False) -> StageResult:
    script_path = resolve_script(stage["script"])
    runtime = runtime_executable(stage["runtime"])
    started = datetime.now().isoformat(timespec="seconds")
    start_clock = time.time()

    if dry_run:
        command = [runtime or stage["runtime"], str(script_path)]
        log(f"DRY RUN Stage {stage['stage']}: {' '.join(command)}")
        return StageResult(stage["id"], stage["name"], "DRY_RUN", message="Not executed")

    if not script_path.is_file():
        message = f"Script not found: {script_path}"
        log(f"ERROR: {message}")
        result = StageResult(stage["id"], stage["name"], "MISSING_SCRIPT", message=message)
        append_status({
            "run_id": RUN_ID, "stage": stage["stage"], "id": stage["id"],
            "name": stage["name"], "script": stage["script"], "status": result.status,
            "started_at": started, "finished_at": datetime.now().isoformat(timespec="seconds"),
            "message": message,
        })
        return result

    if not runtime:
        message = f"No interpreter found for runtime: {stage['runtime']}"
        log(f"ERROR: {message}")
        return StageResult(stage["id"], stage["name"], "MISSING_RUNTIME", message=message)

    stage_log = LOG_DIR / f"stage_{stage['stage']}_{safe_name(stage['id'])}_{RUN_ID}.log"
    command = [runtime, str(script_path)]
    log("=" * 78)
    log(f"START Stage {stage['stage']}: {stage['name']}")
    log(f"Command: {' '.join(command)}")
    log(f"Stage log: {stage_log}")

    exit_code = None
    try:
        with stage_log.open("w", encoding="utf-8", errors="replace") as log_file:
            process = subprocess.Popen(
                command,
                cwd=str(BASE_DIR),
                env=child_environment(),
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                encoding="utf-8",
                errors="replace",
                bufsize=1,
            )
            assert process.stdout is not None
            for line in process.stdout:
                print(line, end="", flush=True)
                log_file.write(line)
            exit_code = process.wait()

        elapsed = round(time.time() - start_clock, 2)
        if exit_code != 0:
            result = StageResult(
                stage["id"], stage["name"], "FAILED",
                exit_code=exit_code, seconds=elapsed,
                message=f"Process exited with code {exit_code}"
            )
        else:
            found, problems = check_outputs(stage.get("outputs", []), start_clock)
            if problems:
                result = StageResult(
                    stage["id"], stage["name"], "MISSING_OUTPUT",
                    exit_code=exit_code, seconds=elapsed,
                    message="Expected output(s) not written in this run: "
                            + "; ".join(problems) + f" [under {OUTPUT_DIR}]"
                )
            else:
                result = StageResult(
                    stage["id"], stage["name"], "SUCCESS",
                    exit_code=exit_code, seconds=elapsed,
                    message="Outputs: " + ", ".join(found) if found else "",
                    outputs_found=found
                )

    except KeyboardInterrupt:
        log("Interrupted by user; terminating current stage.")
        try:
            process.terminate()  # type: ignore[possibly-undefined]
        except Exception:
            pass
        result = StageResult(
            stage["id"], stage["name"], "INTERRUPTED",
            seconds=round(time.time() - start_clock, 2),
            message="Stopped by keyboard interrupt"
        )
    except Exception as exc:
        result = StageResult(
            stage["id"], stage["name"], "EXCEPTION",
            seconds=round(time.time() - start_clock, 2),
            message=f"{exc}\n{traceback.format_exc()}"
        )

    log(
        f"{result.status}: {stage['name']} | "
        f"runtime={result.seconds:.2f}s | {result.message or 'OK'}"
    )
    append_status({
        "run_id": RUN_ID, "stage": stage["stage"], "id": stage["id"],
        "name": stage["name"], "script": stage["script"], "status": result.status,
        "exit_code": "" if result.exit_code is None else result.exit_code,
        "seconds": result.seconds, "started_at": started,
        "finished_at": datetime.now().isoformat(timespec="seconds"),
        "message": result.message,
    })
    return result


def dependencies_succeeded(stage: dict, results: dict[str, StageResult]) -> tuple[bool, str]:
    for dependency in stage.get("depends_on", []):
        result = results.get(dependency)
        if result is None:
            return False, f"Dependency '{dependency}' has not run."
        if result.status not in ("SUCCESS", "REUSED", "DRY_RUN"):
            return False, f"Dependency '{dependency}' status is {result.status}."
    return True, ""


def reuse_extraction(stage: dict) -> StageResult:
    """--skip-extract: accept existing LSEG workbooks instead of re-downloading."""
    found = {freq: P.find_lseg_workbook(freq) for freq in ("LFD", "HFD")}
    missing = [freq for freq, path in found.items() if path is None]
    if missing:
        message = (f"--skip-extract was given but no LSEG_{'/'.join(missing)} workbook exists in "
                   f"{P.LSEG_DIR}. Run the extraction once (needs LSEG Workspace) or copy the "
                   f"workbooks there.")
        log(f"ERROR: {message}")
        return StageResult(stage["id"], stage["name"], "MISSING_OUTPUT", message=message)
    for freq, path in found.items():
        log(f"Reusing {freq} workbook: {path}")
    return StageResult(stage["id"], stage["name"], "REUSED",
                       message="Existing workbooks reused (--skip-extract)",
                       outputs_found=[str(p) for p in found.values()])


def run_pipeline(dry_run: bool = False, continue_independent: bool = False,
                 skip_extract: bool = False) -> int:
    results: dict[str, StageResult] = {}
    stop_pipeline = False

    for stage in PIPELINE_STAGES:
        if skip_extract and stage["id"] == "extract":
            result = reuse_extraction(stage)
            results[stage["id"]] = result
            if result.status != "REUSED" and not continue_independent:
                stop_pipeline = True
            continue

        if stop_pipeline:
            result = StageResult(
                stage["id"], stage["name"], "NOT_RUN",
                message="Skipped because an earlier required stage failed."
            )
            results[stage["id"]] = result
            log(f"SKIP: {stage['name']} — earlier required stage failed.")
            continue

        deps_ok, reason = dependencies_succeeded(stage, results)
        if not deps_ok:
            result = StageResult(
                stage["id"], stage["name"], "BLOCKED", message=reason
            )
            results[stage["id"]] = result
            log(f"BLOCKED: {stage['name']} — {reason}")
            continue

        result = run_stage(stage, dry_run=dry_run)
        results[stage["id"]] = result

        if result.status not in ("SUCCESS", "REUSED", "DRY_RUN"):
            if stage["id"] == "extract" and all(P.find_lseg_workbook(f) for f in ("LFD", "HFD")):
                log("Tip: LSEG workbooks from an earlier extraction exist. Re-run with "
                    "--skip-extract to model them without connecting to LSEG Workspace.")
            if stage.get("required", True):
                log(f"Required stage failed: {stage['script']}")
                if not continue_independent:
                    stop_pipeline = True

    log("\n" + "=" * 78)
    log("PIPELINE SUMMARY")
    log("=" * 78)
    for stage in PIPELINE_STAGES:
        result = results.get(stage["id"])
        if result:
            log(f"{result.status:15} | Stage {stage['stage']} | {stage['name']}")

    failures = [
        result for result in results.values()
        if result.status not in ("SUCCESS", "REUSED", "DRY_RUN")
    ]
    log(f"Master log: {MASTER_LOG}")
    log(f"Status CSV: {STAGE_STATUS_LOG}")

    if dry_run:
        log("Dry run complete; no pipeline scripts were executed.")
        return 0
    if failures:
        log(f"Pipeline finished with {len(failures)} unsuccessful/blocked stage(s).")
        return 1
    log("All configured stages completed successfully.")
    log(f"Final report: {P.FINAL_REPORT}")
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run the ECMT3150 LSEG commodity-analysis pipeline."
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Print the execution plan without running scripts."
    )
    parser.add_argument(
        "--skip-extract", action="store_true",
        help=("Do not run the LSEG extraction; reuse LSEG_LFD.xlsx / LSEG_HFD.xlsx already in "
              "'ECMT3150 OUTPUTS/ECMT3150_LSEG_OUTPUTs'. Use this on machines without LSEG Workspace.")
    )
    parser.add_argument(
        "--continue-independent", action="store_true",
        help=(
            "Continue attempting independent branches after a required stage fails. "
            "Stages whose dependencies failed will still be blocked."
        )
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    log("Starting ECMT3150 quantitative commodity pipeline.")
    if not preflight(dry_run=args.dry_run):
        log("Pre-flight failed. No stages were executed.")
        return 2
    return run_pipeline(
        dry_run=args.dry_run,
        continue_independent=args.continue_independent,
        skip_extract=args.skip_extract,
    )


if __name__ == "__main__":
    raise SystemExit(main())
