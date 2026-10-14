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
| `Pipeline_Outputs/Model_Tables/EVENT_STUDY/`, `PNG_Plots/EVENT_STUDY/` | `STAGE4/EVENT_STUDY.R` |
| `Pipeline_Outputs/Conclusive_Results/CONCLUSIVE_MODEL_DIAGNOSTICS.xlsx`, `PHOTOS/<MODEL>/` | `DIAGNOSTIC.py` |
| `ECMT3150_Final_Best_Model_Analysis.md` | `FINAL SUMMARY.py` |
| `Pipeline_Logs/` | orchestrator |

Individual scripts can also be run on their own (VS Code terminal, RStudio `source()`, or `Rscript`); they
find the project folder from their own location, so the working directory does not matter. Folder rules
live in `ecmt3150_paths.py` (Python) and `ECMT3150_COMMON.R` (R).

Optional: set `ECMT3150_SPLIT=event` to train on the Historical period and test on the Event period
instead of the default chronological 80/20 split.

Other settings (environment variables): `ECMT3150_EVENT_DATE` (default `2026-03-02`),
`ECMT3150_EVENT_WINDOW_DAYS` (60), `ECMT3150_RV_MINUTES` (5), `ECMT3150_REFIT_EVERY_LFD` (21),
`ECMT3150_REFIT_EVERY_HFD` (1). The uranium instrument is chosen from `URANIUM_CANDIDATES` in
`STAGE1/LSEG_DATA_EXTRACTION.py`.
