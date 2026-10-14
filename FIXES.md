# Pipeline fixes (October 2026)

## Directory issues
- **Stages wrote and read different folders.** Stage 1 resolved `../ECMT3150 OUTPUTS` from `STAGE1/`
  (giving `<project>/ECMT3150 OUTPUTS`), while every other script resolved it from the working directory
  (giving `<project>/../ECMT3150 OUTPUTS` when run by the orchestrator). All stages now use one folder,
  `<project>/ECMT3150 OUTPUTS`, defined once in `ecmt3150_paths.py` (Python) and `ECMT3150_COMMON.R` (R) and
  resolved from each script's own location, so the working directory no longer matters.
- **Wrong input file picked up.** The HFD scripts searched recursively for `*HFD*.xlsx`, which also matched
  `HFD_BENCHMARK.xlsx` and Excel lock files (`~$...`). Only `LSEG_HFD*.xlsx` / `LSEG_LFD*.xlsx` are accepted now.
- **Orchestrator pointed at a missing script** (`STAGE2_INSTALLATIONS.R` instead of `S2 INSTALLATIONS.R`) and
  checked for outputs in the project root, where no stage writes. It now checks the real output paths and
  requires each file to have been written during the current run.
- Temporary R scripts and CSV folders are no longer written into the working directory.

## Output issues
- **Sheet names.** Stage 1 merges each frequency into `LSEG_LFD.xlsx` / `LSEG_HFD.xlsx` with sheets
  `Historical - Returns` / `Event - Returns` and `Historical CSV` / `Event CSV`. The R scripts asked for
  `Returns` (crash) and `Data_Long` (fell back to the first sheet, the README). Both periods are now read and combined.
- **`HFD_XGBOOST_MODEL.R` was truncated** mid-statement (`spec_sgarch <-`) and could not run. It is now complete.
- **Realized GARCH never ran.** rugarch requires `xts` inputs for `realGARCH`; plain vectors raised an error, so
  every ticker fell back silently to sGARCH. The inputs are now `xts`.
- **stochvol 3.x:** `sv_fit$latent` and `predict()$h` are `mcmc.list` objects, so `exp(x / 2)` failed. Fixed.
- **xgboost 3.x:** `watchlist` is deprecated in favour of `evals`, and xgboost warns that it will become an
  error. The code now uses whichever argument the installed version accepts (1.7.x or 3.x).
- **Final summary was always empty.** It read `Excel_Summaries/*_Model_Summary.xlsx`, which no stage wrote.
  It now reads the model tables and writes `ECMT3150_Final_Best_Model_Analysis.md`.
- **Model comparison was not like-for-like.** GARCH, SV, Realized GARCH and HAR-RV now produce out-of-sample
  one-day-ahead forecasts on the same test dates and target as the XGBoost model for their frequency.
  The leaderboard ranks by out-of-sample RMSE instead of mixing in-sample AIC with −Adj R² across models.
- **Leakage in XGBoost.** Early stopping used the test set, and the GARCH/SV features came from fits on the
  full sample. Early stopping now uses the end of the training sample, and the features are one-step-ahead
  forecasts from training-sample parameters.
- **Silent failures.** Collectors returned exit code 0 when R failed or models were missing, and R scripts
  could exit 0 with nothing saved. Both now exit non-zero, and each model clears its previous outputs at the
  start, so stale results cannot be reported as current.
- **PHOTOS sorting.** Realized GARCH and HAR-RV plots went into `Misc/`, and XGBoost plots were never collected.
  Plots are now copied into `PHOTOS/<MODEL>/`.
- RDS file names no longer embed `.xlsx` (for example `LFD_GARCH_LSEG_LFD.xlsx.rds`). They are now `<MODEL>.rds`.

# Round 2: uranium and output quality

## Uranium
- **Root cause.** `U_u.TO` did return data: 793 daily rows and about 15,000 one-minute rows. But LSEG does not
  publish `MID_PRICE` for exchange-traded units, so the Mid column, and with it every return, was empty and
  uranium was skipped by every model. Stage 1 now rebuilds a missing mid from (BID+ASK)/2, and the R loaders
  apply the same fallback to workbooks that were already extracted.
- **New ticker.** `INSTRUMENTS` now holds a `URANIUM` placeholder. After connecting, Stage 1 tries
  `URANIUM_CANDIDATES` in order (`URA.P`, then `URA.K`, then `U_u.TO`, then `CCJ.N`) with two small probe
  requests, and uses the first one that has enough daily and 1-minute data. Reorder the list to change the
  preference.

## Better outputs
- **Trading days.** Spot-metal sessions open around 22:00–23:00 UTC on the previous calendar day. Days are now
  dated by session (UTC + 2h) instead of UTC calendar date, which removes the one-hour "Sunday" pseudo-days.
- **Realised volatility.** It is now computed from 5-minute returns (standard practice) instead of 1-minute mid
  quotes, which are inflated by bid-ask bounce. Set `ECMT3150_RV_MINUTES=1` to go back.
- **Expanding-window re-estimation.** Every model is re-fitted every 21 trading days (LFD) or every day (HFD),
  instead of being estimated once.
- **HAR-RV in logs (log-HAR).** The levels HAR forecast negative volatility on short samples. The log
  specification fixes that. Together with the RV fixes above, it cut HAR-RV's out-of-sample RMSE by about
  40–50% for silver and gold.
- **Naive baselines** (RV(t), and the 22-day mean |r|) plus **Diebold–Mariano tests** (with the HLN
  small-sample correction). These show whether a ranking is statistically meaningful.
- **New `STAGE4/EVENT_STUDY.R`**:
  - volatility in the 60 trading days before vs after the event, plus a full-sample comparison;
  - a Brown–Forsythe test of equal variances;
  - EGARCH(1,1)-t with a post-event dummy, using robust standard errors;
  - HFD realised volatility before vs after, with a Welch test;
  - volatility timelines and a chart comparing every model's out-of-sample forecasts.
- **Final report** opens with key findings that are generated from the output tables.
- **Smaller files.** `LFD_SV.rds` fell from about 450 MB to under 100 KB (the raw MCMC draws are no longer saved).
- **Quieter logs.** Removed the NumPy/pandas deprecation-warning spam from the Stage 1 log.
