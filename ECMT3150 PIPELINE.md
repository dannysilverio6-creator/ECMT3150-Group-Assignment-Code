# Econometric Modeling & Data Pipeline Documentation (`ECMT3150`)

This document provides a comprehensive specification of the end-to-end econometric and machine learning pipeline. The architecture integrates Python orchestrators and LSEG (Refinitiv) extraction drivers with six dedicated R modeling scripts split across **High-Frequency Data (HFD)** and **Low-Frequency Data (LFD)** branches.

---

## 1. System Architecture Diagram

```
                      +-------------------+
                      |  ORCHESTRATOR.py  |
                      +---------+---------+
                                |
                                v
                       +-------------------+
                       | LSEGEXTRACTION.py |
                       +--------+----------+
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
                      +-------------------+
                      |   ECMT3150.xlsx   |
                      | (Charts, CSV, Res)|
                      +-------------------+ 
---

## 2. Pipeline Execution Stages & Workflows

### Stage 1: Orchestration & Data Extraction
1. **`ORCHESTRATOR.py` (Master Subprocess Coordinator)**:
   * Initializes environment paths, manages R and Python runtime environments, checks dependencies, and executes sub-pipeline stages sequentially.
2. **`LSEGEXTRACTION.py` (API Extractor)**:
   * Interfaces with LSEG (Refinitiv) Eikon/DataScope APIs to retrieve tick-level market microstructure and daily time series datasets.
   * Outputs two standardized files:
     * **`HFD.xlsx`**: Tick-by-tick and sub-minute high-frequency intraday trades, bid/ask quotes, price changes, timestamps, and durations.
     * **`LFD.xlsx`**: Daily OHLCV (Open, High, Low, Close, Volume) prices and log returns across target equities.

---

### Stage 2: High-Frequency Data (HFD) Pipeline

The HFD branch models intraday market microstructure, trade arrival dynamics, and time-deformed conditional volatility.

```
+----------------------------------------------------------------------------------------------------------------+
|                                      HIGH-FREQUENCY PIPELINE                                                   |
+----------------------------------------------------------------------------------------------------------------+
|                                                                                                                |
|  [HFD_Realised_GARCH.R]         [HFD_HAR-RV.R]               [Benchmark.py]                [HFD_MLHYBRID.R]    |
|  +--------------------+     +--------------------+         +-------------------+        +--------------------+ |
|  |                    | --> |                    | ------->| HFD_Benchmark.csv |------->|  XGBoost Regressor | |
|  |                    |     |                    |         +-------------------+        | OOS Forecast Y_i+1 | |
|  +--------------------+     +--------------------+                                      +--------------------+ |
+----------------------------------------------------------------------------------------------------------------+
```

#### 1. `HFD_Realised GARCH.R` — Autoregressive Conditional Duration Model
* **Mathematical Specification**:


#### 2. `HFD_HAR-RV.R` — Ultra-High-Frequency GARCH Model
* **Mathematical Specification**:

#### 3. `HFD_MLHYBRID.R` — Non-Linear High-Frequency ML Hybrid
* **Formulation**:


---

### Stage 3: Low-Frequency Data (LFD) Pipeline

The LFD branch models low-frequency daily trend persistence, conditional variance clustering, and daily price/volume range dynamics.

```

```
+----------------------------------------------------------------------------------------------------------------+
|                                       LOW-FREQUENCY PIPELINE                                                   |
+----------------------------------------------------------------------------------------------------------------+
|                                                                                                                |
|    [LFD_GARCH(1,1).R]            [LFD_SV.R]                   [Benchmark.py]               [LFD_MLHYBRID.R]    |
|  +--------------------+     +--------------------+         +-------------------+        +--------------------+ |
|  |  Volatility Model  | --> |                    | ------->| LFD_Benchmark.csv |------->|  XGBoost Regressor | |
|  |  sigma_t, z_t      |     |                    |         +-------------------+        | OOS Forecast Y_i+1 | |
|  +--------------------+     +--------------------+                                      +--------------------+ |
+----------------------------------------------------------------------------------------------------------------+

#### 1. `LFD_GARCH.R` — Daily Conditional Heteroskedasticity Model
* **Mathematical Specification**:

#### 2. `LFD_SV.R` — Daily Stochastic Volatility Model
* **Mathematical Specification**:


#### 3. `LFD_MLHYBRID.R` — Non-Linear Low-Frequency ML Hybrid
* **Formulation**:


---
## BENCHMARKING

#### 1. 'BENCHMARK.py'


#### 2. 'LFD_BENCHMARK.CSV`


#### 3. 'HFD_BENCHMARK.CSV`




## 4. Architectural Comparison: HFD vs. LFD Hybrid Frameworks



## 5. Stage 4: Output Aggregation & Final Deliverable

### `Collector.py` — Output Aggregator

####`ECMT3150.xlsx`

---

## 6. System File & Output Directory Map

| Filename / Object | Language / Type | System Role & Functionality |
| :--- | :--- | :--- |
| `ORCHESTRATOR.py` | Python Script | Master process trigger and pipeline orchestrator. |
| `LSEGEXTRACTION.py` | Python Script | LSEG API connector and data handler. |
| `HFD.xlsx` | Data Store | High-frequency tick and minute intraday dataset. |
| `LFD.xlsx` | Data Store | Daily price, returns, and OHLCV volume dataset. |

| `HFD_Realised_GARCH.R` | R Script | Fits ACD(1,1) trade duration and intensity models. |
| `HFD_HAR-RV.R` | R Script | Fits diurnal time-deformed UHF-GARCH(1,1) volatility models. |
| `LFD_GARCH(1,1).R` | R Script | Fits daily GARCH(1,1) conditional volatility models. |
| `LFD_SV.R` | R Script | Daily Stochastic Volatility Model. |

| `BENCHMARK.py` | Python Script | Consolidates figures, workspace outputs, and performance tables. |
| **`LFD_BENCHMARK.CSV`** | Master Deliverable | LFD compiled Excel workbook containing LFD MODEL performance, charts, and metrics. |
| **`HFD_BENCHMARK.CSV`** | Master Deliverable | HFD compiled Excel workbook containing HFD MODEL performance, charts, and metrics. |

| `HFD_MLHYBRID.R` | R Script | Trains high-frequency XGBoost ML hybrid model. |
| `LFD_MLHYBRID.R` | R Script | Trains low-frequency XGBoost ML hybrid model. |

| `COLLECTOR.py` | Python Script | Consolidates figures, workspace outputs, performance tables, and Compare it to BENCHMARK |
| **`ECMT3150.xlsx`** | Master Deliverable | Final compiled Excel workbook containing all reports, charts, and metrics. |
