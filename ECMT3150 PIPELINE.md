# Econometric Modeling & Data Pipeline Documentation (`ECMT3150`)

"Affects of the IRAN WAR on Commodities"


This document provides a comprehensive specification of the end-to-end econometric and machine learning pipeline. The architecture integrates Python orchestrators and LSEG (Refinitiv) extraction drivers with six dedicated R modeling scripts split across **High-Frequency Data (HFD)** and **Low-Frequency Data (LFD)** branches.


---------------------------------
## 1. System Architecture Diagram
---------------------------------


                      +-------------------+
                      |  ORCHESTRATOR.py  |
                      +---------+---------+
                                |
                                v
                      +--------------------+
                      |  LSEGEXTRACTION.py |
                      +---------+----------+
                                |
             +------------------+------------------+
             |                                     |
             v                                     v
       +-----------+                         +-----------+
       | HFD.xlsx  |                         | LFD.xlsx  |
       +-----+-----+                         +-----+-----+
             |                                     |
             v                                     v
    [HFD_Realised_GARCH.R]                 [LFD_GARCH(1,1).R]
             |                                     |
             v                                     v
       [HFD_HAR-RV.R]                          [LFD_SV.R]
             |                                     |
             |                                     |
             +------------------+------------------+
                                |
                                v
                      +-------------------+    +-----------------------+     +-----------------------+
                      |    Benchmark.py   |--->|    LFD_BENCHMARK.CSV  |  /  |    HFD_BENCHMARK.CSV  |  
                      +---------+---------+    +-----------+-----------+     +-----------+-----------+
                                |
             +------------------+------------------+
             |                                     |
             v                                     v
    [HFD_MLHYBRID.R]                        [LFD_MLHYBRID.R]
             |                                     |
             +------------------+------------------+
                                |
                                v
                      +-------------------+
                      |    Collector.py   |
                      +---------+---------+
                                |
                                v
                      +-------------------+
                      |    Diagnostic.py  |
                      +---------+---------+
                                |
                                v
             +-------------------------------------+
             |   ECMT3150_CommodityFindings.xlsx   |
             |         (Charts, CSV, Res)          |
             +-------------------------------------+ 
                                |
                                v
                    +----------------------+
                    |   Run_Report.md      |
                    | optional PDF/HTML    |
                    +----------------------+

-------------------------------------------
## 2. Pipeline Execution Stages & Workflows
-------------------------------------------


### Stage 1: Orchestration & Data Extraction

1. **`ORCHESTRATOR.py` — Master Subprocess Coordinator**
   - Loads a central configuration file (recommended: `config.yaml` or `config.json`) for symbols, date range, frequency, output folders, random seeds, and model settings.
   - Checks Python and R versions, required packages, environment variables, LSEG session availability, and read/write permissions before starting.
   - Executes stages in dependency order and checks each subprocess exit code. A failed required stage must be marked as failed; it must not silently produce a successful final report.
   - Writes a run ID, start/end timestamps, configuration snapshot, software versions, logs, and a machine-readable status file to `logs/` and `outputs/<run_id>/`.
   - Supports a `--dry-run` option to validate configuration and paths without downloading or fitting models, and a `--resume` option only for stages whose inputs and configuration hashes have not changed.

2.**ORGANISE DATE's**

### Stage 1: High-Frequency Dates (HFD)
  - Historical Estimation Period: 01-01-2025 to 20-02-2026.
  - Event Study Period: 23-02-2026 to 13-03-2026.
  - Data Frequency: Minute-by-minute intraday observations, subject to LSEG data availability and extraction limits.
  - Purpose: Captures immediate commodity market reactions, intraday volatility changes, and price adjustments surrounding the initial military strikes on Iran.

### Stage 2: Low-Frequency Dates (LFD)
  - Historical Estimation Period: 01-01-2023 to 27-02-2026.
  - Post-Event Analysis Period: 02-03-2026 to 09-10-2026.
  - Data Frequency: Daily OHLCV (Open, High, Low, Close, Volume), adjusted prices where available, and derived log returns.
  - Purpose: Estimates historical commodity market behaviour and examines the persistence of price and volatility changes following the outbreak of the conflict.

3.**ORGANISE Commodities**
  - Gold: XAU= (spot) or GCc1 (COMEX futures).
  - Silver: XAG= (spot) or SIc1 (COMEX futures).
  - Uranium: Identify the appropriate CME uranium futures RIC or UxC spot-price benchmark in LSEG Workspace. (MAY NEED TO PIVOT!)

Validate each RIC, data availability, and subscription access before extraction. Record instrument type, currency, units, timestamps, and frequency, keeping spot, futures, and equity proxies separate. Uranium may not have minute-level spot data available, so document any proxy used.


4. **`LSEGEXTRACTION.py` — API Extractor**
   - Connects through the supported LSEG Workspace/LSEG Data Library interface configured for the user's entitlement. Do not assume Eikon, DataScope, and Workspace endpoints are interchangeable.
   - Extracts only fields and instruments available under the account's subscription.
   - Produces two standardized datasets:
     - **`HFD.xlsx`**: intraday bars or trade/quote records at the configured resolution. Prefer minute bars for a manageable initial workflow; raw tick data should be an explicit, separately configured option.
     - **`LFD.xlsx`**: daily OHLCV (Open, High, Low, Close, Volume), adjusted-price fields where available, and derived log returns.
   - Records instrument identifiers, exchange/currency, timezone, sampling interval, extraction timestamp, requested and actual date ranges, source fields, missing-data counts, and adjustment policy.
   - Writes a data dictionary and extraction manifest. If a query is truncated, rate-limited, or returns no data, report it clearly rather than treating it as a valid complete dataset.
---

----------------------------------------
## 3. High-Frequency Data (HFD) Pipeline
----------------------------------------


The HFD branch models intraday market microstructure, trade arrival dynamics, and time-deformed conditional volatility.

```
+------------------------------------------------------------------------------------------------+
|                                  HIGH-FREQUENCY PIPELINE                                       |
+------------------------------------------------------------------------------------------------+
|                                                                                                |
| HFD.xlsx --> validation/session handling -->  +----------------------+                         |
|                                               | HFD_Realised_GARCH.R |                         |
|                                               +----------+-----------+                         |
|                                                          |                                     |
|                                               +----------------------+                         |
|                                               |    HFD_HAR-RV.R      |                         |
|                                               +----------+-----------+                         |
|                                                          |                                     |
|                         forecast files + diagnostics + common evaluation dates                 |
|                                                          |                                     |
|                                               +----------------------+                         |
|                                               |   HFD_MLHYBRID.R     |                         |
|                                               +----------+-----------+                         |
|                                                          v                                     |
|                                               HFD_BENCHMARK.csv / .xlsx                        |
+------------------------------------------------------------------------------------------------+
```
```

#### 1. `HFD_Realised GARCH.R` — Autoregressive Conditional Duration Model
**Purpose:** Relate latent conditional return variance to a realized-volatility measure calculated from intraday returns. This model is appropriate when the data support a valid realized-volatility series.



#### 2. `HFD_HAR-RV.R` — Ultra-High-Frequency GARCH Model
**Purpose:** Forecast realized volatility using persistence at multiple horizons. HAR-RV is a realized-volatility regression model, not an ultra-high-frequency GARCH model.


**HFD outputs:** `HFD_BENCHMARK.xslx`{`hfd_realised_garch_forecasts.csv`, `hfd_har_rv_forecasts.csv`, model diagnostics}


#### 3. `HFD_MLHYBRID.R` — Non-Linear High-Frequency ML Hybrid (XGBoost)
**Purpose:** Test whether non-linear features improve forecasts beyond the econometric baselines. The proposed default is XGBoost regression, but a simpler model should be retained as a sanity check.

**Target and features**
- Define a specific target, for example next-session realized variance, log realized variance, or next-interval volatility.
- Candidate features may include lagged realized volatility, HAR components, lagged returns, intraday range, volume, time-of-day/session indicators, and out-of-sample econometric forecasts.
- Include news or macro variables only if timestamps show that the information was available before the forecast decision.


----------------------------------------
## 4. Low-Frequency Data (LFD) Pipeline
----------------------------------------

The LFD branch models low-frequency daily trend persistence, conditional variance clustering, and daily price/volume range dynamics.



+------------------------------------------------------------------------------------------------+
|                                   LOW-FREQUENCY PIPELINE                                       |
+------------------------------------------------------------------------------------------------+
|                                                                                                |
| LFD.xlsx --> validation/returns --> +----------------------+                                   |
|                                     | LFD_GARCH(1,1).R     |                                   |
|                                     +----------+-----------+                                   |
|                                                |                                               |
|                                     +----------------------+                                   |
|                                     |     LFD_SV.R         |                                   |
|                                     +----------+-----------+                                   |
|                                                |                                               |
|                         forecasts + diagnostics + common evaluation dates                      |
|                                                |                                               |
|                                     +----------------------+                                   |
|                                     |   LFD_MLHYBRID.R     |                                   |
|                                     +----------+-----------+                                   |
|                                                |                                               |
|                                                v                                               |
|                                     LFD_BENCHMARK.csv / .xlsx                                  |
+------------------------------------------------------------------------------------------------+

#### 1. `LFD_GARCH.R` — Daily Conditional Heteroskedasticity Model
**Purpose:** Estimate volatility clustering in daily returns and generate conditional-variance forecasts.

#### 2. `LFD_SV.R` — Daily Stochastic Volatility Model
**Purpose:** Estimate a latent volatility process in which log variance evolves stochastically, providing a model class distinct from GARCH.


**LFD outputs:** `LFD_BENCHMARK.xslx`{lfd_garch_forecasts.csv`, `lfd_sv_forecasts.csv`, diagnostics}

#### 3. `LFD_MLHYBRID.R` — Non-Linear Low-Frequency ML Hybrid (XGBoost)
**Purpose:** Determine whether non-linear patterns in lagged market information improve forecasts beyond econometric baselines.

**Candidate target and features**
- Targets may include next-day squared return, next-day absolute return, or a realized-volatility proxy. These are not interchangeable; choose one before model fitting.
- Candidate features include lagged returns, lagged squared/absolute returns, rolling volatility, OHLC range, volume changes, and lagged GARCH/SV forecasts.
- Fundamentals, macroeconomic releases, and news variables can be added only when their publication/availability timestamps are respected.


------------------------------
## 5. HFD and LFD BENCHMARKING
------------------------------

### 1. `BENCHMARK.py`

**Purpose:** Consolidate model forecast files and evaluate forecast accuracy consistently. It should not fit models unless explicitly assigned that responsibility.

**Responsibilities**
1. Read forecast outputs from all successfully completed models.
2. Validate required columns: instrument, forecast origin/time, target horizon, actual value (when available), forecast, model name, and split label.
3. Align models to the same evaluation timestamps and target definition before comparing metrics.
4. Compute metrics appropriate to the target:
   - **MAE:** mean absolute error.
   - **RMSE:** root mean squared error.
   - **QLIKE:** useful for volatility forecast comparison when its assumptions and target proxy are appropriate.
   - **Directional accuracy:** only for a clearly defined directional target; not a substitute for volatility accuracy.
   - **Economic utility/backtest measures:** optional and separate from statistical forecast accuracy; include transaction costs, slippage, turnover, and risk constraints.
5. Include uncertainty or model-comparison tests where justified, such as a Diebold–Mariano test for comparable forecast errors. State assumptions and account for multiple comparisons where relevant.
6. Save a model ranking table with metric definitions, sample size, test period, and target/horizon.

**Fair-comparison rules**
- All models must be scored on identical timestamps for each comparison.
- Never use in-sample fitted values as if they were out-of-sample forecasts.
- Do not tune models on the final test set.
- Do not compare HFD metrics directly with LFD metrics unless the target, horizon, scale, and evaluation design make the comparison meaningful.
- Keep separate results by instrument and, where useful, provide a pooled summary without hiding cross-instrument variation.


### 2. `LFD_BENCHMARK.xslx`

The LFD benchmark file should contain one row per model/instrument/target/horizon/evaluation split or a documented long-form equivalent. Recommended columns:

`run_id, instrument, model, forecast_origin, target_date, horizon, actual, forecast, forecast_variance, split, MAE_component, absolute_error, squared_error`

A summary table should report `n_obs`, `MAE`, `RMSE`, and `QLIKE` where appropriate, plus the evaluation dates and target definition. CSV is a plain-text table and cannot contain embedded charts or multiple sheets. If charts and multiple tables are required, use **`LFD_BENCHMARK.xlsx`** and optionally export a CSV summary alongside it.


### 3. `HFD_BENCHMARK.xslx`

Use the same schema principles as the LFD benchmark, but include the HFD sampling/session information where necessary. Recommended additional metadata include `sampling_interval`, `session_id`, `realised_measure`, and `target_horizon`.

Again, use `.csv` for a single flat table or `.xlsx` for multiple sheets and charts. Avoid describing a CSV as an Excel workbook.



### 4. Architectural Comparison: HFD vs. LFD Hybrid Frameworks


| Dimension | High-Frequency Data (HFD) | Low-Frequency Data (LFD) |
| :--- | :--- | :--- |
| Typical input | Minute bars or trade/quote records | Daily OHLCV and adjusted prices |
| Primary focus | Intraday/realized volatility and microstructure | Daily returns and conditional volatility |
| Main econometric models | Realized GARCH and HAR-RV | GARCH(1,1) and stochastic volatility |
| ML role | Non-linear forecast improvement using lagged intraday/session features | Non-linear forecast improvement using lagged daily features |
| Key data risks | Timestamp errors, microstructure noise, session boundaries, high volume | Corporate actions, missing sessions, adjusted/unadjusted prices |
| Evaluation design | Session-aware, chronological out-of-sample forecasts | Chronological or rolling-origin out-of-sample forecasts |
| Common metrics | MAE/RMSE and suitable volatility loss such as QLIKE | MAE/RMSE and suitable volatility loss such as QLIKE |
| Resource requirements | Potentially high storage and processing; aggregate tick data where appropriate | Usually lower storage and computational cost |
| Main limitation | Results depend heavily on sampling and realized-measure construction | Daily data may miss intraday dynamics and rapid market responses |

**Interpretation:** HFD and LFD are complementary, not interchangeable. HFD can help characterize intraday risk and realized volatility, while LFD provides a more manageable basis for daily forecasting. Any combined strategy should specify how HFD information becomes available to the daily decision process and must prevent information from the future trading session from entering earlier forecasts.


-----------------------------------------------------
## 6. Output Aggregation & Final Deliverable
-----------------------------------------------------

### `Collector.py` — Output Aggregator

**Purpose:** Assemble outputs from extraction, model fitting, benchmarking, and diagnostics into a reproducible deliverable.

**Responsibilities**
- Read only outputs associated with the current `run_id` and record each input file's path, size, and modification time or checksum.
- Consolidate model metrics, forecasts, parameter estimates, convergence status, diagnostics, and charts.
- Preserve separate HFD and LFD worksheets and provide a clearly labeled combined summary.
- Check for missing expected files and distinguish a model that failed from a model that completed with warnings.
- Avoid silently replacing previous runs. Store run-specific outputs under `outputs/<run_id>/` and optionally maintain a clearly labeled `latest/` copy.
- Produce the final workbook **`ECMT3150.xlsx`** with suggested sheets:
  1. `Run_Summary`
  2. `Data_Manifest`
  3. `Data_Quality`
  4. `HFD_Forecasts`
  5. `HFD_Benchmark`
  6. `HFD_Diagnostics`
  7. `LFD_Forecasts`
  8. `LFD_Benchmark`
  9. `LFD_Diagnostics`
  10. `Model_Parameters`
  11. `Warnings_Errors`
- Keep raw data in dedicated data files rather than copying huge tick-level datasets into the summary workbook.

### `Diagnostic.py` — Quality Assurance and Run Validation

Run checks after extraction, each model, benchmarking, and collection.

**Minimum checks**
- Required files and columns exist; files are readable and non-empty.
- Dates, symbols, units, and frequency conform to configuration.
- Duplicate observations and missing-data rates are reported.
- Price/return and OHLC consistency checks pass or generate a documented warning.
- Forecasts and metrics are finite; variance forecasts are non-negative.
- Train/test dates are chronological and no feature uses information after its forecast origin.
- Benchmark rows use matching actuals and target horizons.
- Model convergence and optimizer/sampler warnings are captured.
- Final workbook contains expected sheets and a run status.

Use explicit status values such as `PASS`, `WARNING`, `FAIL`, and `SKIPPED`. A missing optional model may be marked `SKIPPED`; a missing required extraction file should fail the run.

### `Run_Report.py` — Automated Run Report (recommended addition)

**Purpose:** Generate a concise, evidence-based report after each run. An LLM/AI component is optional; the report should still work deterministically if no AI service is configured.

**Report contents**
- Run ID, execution time, configuration, data period, symbols, and extraction status.
- Data-quality summary and material limitations.
- Models attempted, completed, failed, or skipped.
- Out-of-sample performance table, with the evaluation window and target clearly stated.
- Best-performing model by the selected metric, plus comparison against a simple baseline.
- Important diagnostics, convergence issues, missing files, and warnings.
- Charts for actual versus forecast, forecast errors, and volatility forecasts where suitable.
- A limitations section explaining that predictive performance is not proof of causality or guaranteed trading profitability.

**AI-report safeguards**
- Supply the reporting model only with generated summaries and approved output tables, not credentials or unrestricted raw account data.
- Require every numerical claim to be traceable to a pipeline output. Do not allow the AI to invent metrics or describe failed models as successful.
- Label interpretations as descriptive, not causal, unless a suitable causal design has actually been used.
- Store the prompt/template, model identifier, generation timestamp, and source artifact list.
- If AI generation fails or is unavailable, generate a template-based Markdown report from the same metrics.
- Review external-service privacy, data licensing, and institutional requirements before sending market data to a third-party service.

**Outputs:** `Run_Report.md` and optionally `Run_Report.html` or `Run_Report.pdf`, saved in the current run folder.



####`ECMT3150_CommodityFindings.xlsx`


----------------------------------------
## 7. System File & Output Directory Map
----------------------------------------


### Recommended project structure

```text
ECMT3150_PIPELINE/
├── config/
│   └── config.yaml
├── scripts/
│   ├── ORCHESTRATOR.py
│   ├── LSEGEXTRACTION.py
│   ├── BENCHMARK.py
│   ├── Collector.py
│   ├── Diagnostic.py
│   ├── Run_Report.py
│   └── models/
│       ├── HFD_Realised_GARCH.R
│       ├── HFD_HAR-RV.R
│       ├── HFD_MLHYBRID.R
│       ├── LFD_GARCH(1,1).R
│       ├── LFD_SV.R
│       └── LFD_MLHYBRID.R
├── data/
│   ├── raw/
│   └── processed/
├── outputs/
│   └── <run_id>/
│       ├── forecasts/
│       ├── benchmarks/
│       ├── diagnostics/
│       ├── charts/
│       ├── ECMT3150.xlsx
│       ├── Run_Report.md
│       └── run_manifest.json
├── logs/
├── tests/
│   ├── test_data_validation.py
│   └── test_forecast_alignment.py
├── requirements.txt
├── renv.lock
└── README.md

### File and object responsibilities

| Filename / Object | Language / Type | System role and functionality |
| :--- | :--- | :--- |
| `ORCHESTRATOR.py` | Python script | Main entry point; config, dependencies, subprocess order, run status, logging |
| `LSEGEXTRACTION.py` | Python script | LSEG connection, extraction, normalization, metadata, extraction validation |
| `HFD.xlsx` | Data file | Intraday input; minute bars or explicitly configured trade/quote data |
| `LFD.xlsx` | Data file | Daily OHLCV/adjusted prices and derived daily returns |

| `HFD_Realised_GARCH.R` | R script | Fits a realized-volatility/return model and exports forecasts/diagnostics |
| `HFD_HAR-RV.R` | R script | Fits HAR-RV realized-volatility forecasts |


| `LFD_GARCH(1,1).R` | R script | Fits daily GARCH(1,1) conditional variance |
| `LFD_SV.R` | R script | Fits a daily stochastic-volatility model |


| `BENCHMARK.py` | Python script | Aligns forecasts and computes comparable out-of-sample metrics |
| `HFD_BENCHMARK.csv` | CSV file | Flat HFD benchmark results; use `.xlsx` separately if multiple sheets/charts are needed |
| `LFD_BENCHMARK.csv` | CSV file | Flat LFD benchmark results; use `.xlsx` separately if multiple sheets/charts are needed |

| `HFD_MLHYBRID.R` | R script | Fits and evaluates the HFD ML model using leakage-safe features |
| `LFD_MLHYBRID.R` | R script | Fits and evaluates the LFD ML model using leakage-safe features |


| `Collector.py` | Python script | Assembles forecasts, diagnostics, metrics, and charts into the final workbook |
| `Diagnostic.py` | Python script | Data, model, forecast, and workbook quality checks |
| `Run_Report.py` | Python script | Creates the automated run report from verified pipeline artifacts |
| `ECMT3150_CommodityFindings.xlsx` | Excel workbook | Final summary workbook with results, charts, diagnostics, and warnings |
| `Report.md` | Markdown report | Portable text report of the run and model comparison |

| `run_manifest.json` | JSON metadata | Run configuration, timestamps, file inventory, statuses, and version information |
| `logs/` | Log directory | Extraction, subprocess, modeling, and reporting logs |
| `requirements.txt` | Python dependency file | Python package versions or constraints |
| `renv.lock` | R dependency lockfile | Reproducible R package environment |



