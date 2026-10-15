# ECMT3150-Group-Assignment-Code
This is the complete pipeline for the Financial Econometric Analysis discussed in ECMT3150 Group Assignment.

## Running the pipeline

From a terminal, in any folder:

```
python "ECMT3150 ORCHESTRATOR.py"                  # full run (needs LSEG Workspace open and logged in)
python "ECMT3150 ORCHESTRATOR.py" --skip-extract   # reuse LSEG_LFD.xlsx / LSEG_HFD.xlsx already extracted
python "ECMT3150 ORCHESTRATOR.py" --dry-run        # print the plan only
```

Every stage reads and writes the same folder, `ECMT3150 OUTPUTS/` inside this project:

| Folder / file | Written by |
| --- | --- |
| `ECMT3150_LSEG_OUTPUTs/LSEG_LFD.xlsx`, `LSEG_HFD.xlsx` | Stage 1 extraction |
| `Pipeline_Outputs/RDS_Models/<MODEL>.rds` | R model scripts |
| `Pipeline_Outputs/Model_Tables/<MODEL>/*.csv` | R model scripts (summary, out-of-sample metrics and forecasts) |
| `Pipeline_Outputs/PNG_Plots/<MODEL>/*.png` | R model scripts |
| `Pipeline_Outputs/Consolidated_Results/LFD_BENCHMARK.xlsx`, `HFD_BENCHMARK.xlsx` | `STAGE2 COLLECTOR.py` |
| `Pipeline_Outputs/Consolidated_Results/ML_BENCHMARK.xlsx` | `STAGE3 COLLECTOR.py` |
| `Pipeline_Outputs/Model_Tables/EVENT_STUDY/`, `NAIVE_BENCHMARKS/`, `PNG_Plots/EVENT_STUDY/` | `STAGE4/EVENT_STUDY.R` |
| `Pipeline_Outputs/Conclusive_Results/CONCLUSIVE_MODEL_DIAGNOSTICS.xlsx`, `PHOTOS/<MODEL>/` | `DIAGNOSTIC.py` |
| `ECMT3150_Final_Best_Model_Analysis.md` | `FINAL SUMMARY.py` |
| `Pipeline_Logs/` | orchestrator |

Individual scripts can also be run on their own (VS Code terminal, RStudio `source()`, or `Rscript`); they
find the project folder from their own location, so the working directory does not matter. Folder rules
live in `ecmt3150_paths.py` (Python) and `ECMT3150_COMMON.R` (R).

## Event-study design

The pipeline asks how volatility models cope with the Iran conflict (event date `2026-03-02`, the first
trading day after the 28 Feb 2026 strikes):

1. **Estimation** uses only pre-event data. Every model is run under two schemes:
   - **Frozen:** parameters are fixed at the event and never updated.
   - **Adaptive:** parameters are re-estimated on an expanding window, every 21 days for daily data and
     every day for intraday data.
2. **Scoring** happens in a calm pre-event window (the out-of-sample benchmark) and then in post-event
   windows: the shock week (days 1–5), then the short, medium and long run. Models are compared against
   naive benchmarks, with Diebold–Mariano tests and a check of whether their 95% volatility bands still
   cover realised moves (Kupiec test).
3. **"No-conflict" counterfactual:** each econometric model, estimated before the event, forecasts the
   post-event path. Realised volatility above or below that path is abnormal volatility, and it is tested
   statistically.

The results are in `ECMT3150_Final_Best_Model_Analysis.md` and in
`CONCLUSIVE_MODEL_DIAGNOSTICS.xlsx` (sheets `Model_Recommendation`, `Window_Leaderboard`,
`Abnormal_Volatility`, `Frozen_vs_Adaptive`). The charts are in `PHOTOS/EVENT_STUDY/`.

Settings (environment variables):

| Variable | Default | Controls |
| --- | --- | --- |
| `ECMT3150_EVENT_DATE` | `2026-03-02` | Event date |
| `ECMT3150_PRE_WINDOW_LFD` | 60 | Calm pre-event window, daily data (trading days) |
| `ECMT3150_PRE_WINDOW_HFD` | 5 | Calm pre-event window, intraday data (trading days) |
| `ECMT3150_EVENT_WINDOW_DAYS` | 60 | Before/after comparison in the event study (trading days) |
| `ECMT3150_REFIT_EVERY_LFD` | 21 | Adaptive re-estimation interval, daily data |
| `ECMT3150_REFIT_EVERY_HFD` | 1 | Adaptive re-estimation interval, intraday data |
| `ECMT3150_RV_MINUTES` | 5 | Sampling interval for realised volatility (minutes) |

The uranium instrument is chosen from `URANIUM_CANDIDATES` in `STAGE1/LSEG_DATA_EXTRACTION.py`.
