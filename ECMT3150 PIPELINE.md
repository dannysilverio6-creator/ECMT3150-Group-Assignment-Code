# Econometric Modeling & Data Pipeline Documentation (`ECMT3150`)

This document provides a comprehensive specification of the end-to-end econometric and machine learning pipeline. The architecture integrates Python orchestrators and LSEG (Refinitiv) extraction drivers with six dedicated R modeling scripts split across **High-Frequency Data (HFD)** and **Low-Frequency Data (LFD)** branches.

---

## 1. System Architecture Diagram

```
                       +-------------------+
                       |  SUBPROCESS.py    |
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
      [HFD_ACD.R]                           [LFD_ARIMA.R]
             |                                     |
             v                                     v
    [HFD_UHFGARCH.R]                        [LFD_GARCH.R]
             |                                     |
             v                                     v
    [HFD_MLHYBRID.R]                        [LFD_MLHYBRID.R]
             |                                     |
             +------------------+------------------+
                                |
                                v
                       +-------------------+
                       |    COMPILER.py    |
                       +---------+---------+
                                 |
                                 v
                       +-------------------+
                       |   ECMT3150.xlsx   |
                       | (Charts, CSV, Res)|
                       +-------------------+  
                                |
                                v
                       +-------------------+
                       |    COMPILER.py    |
                       +---------+---------+
                      

---

## 2. Pipeline Execution Stages & Workflows

### Stage 1: Orchestration & Data Extraction
1. **`SUBPROCESS.py` (Master Subprocess Coordinator)**:
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
+-----------------------------------------------------------------------------------+
|                            HIGH-FREQUENCY PIPELINE                                |
+-----------------------------------------------------------------------------------+
|                                                                                   |
|   [HFD_ACD.R]               [HFD_UHFGARCH.R]               [HFD_MLHYBRID.R]       |
|  +-------------------+     +-------------------+          +--------------------+  |
|  | Duration Dynamics | --> | Time-Deformed Vol | -------> |  XGBoost Regressor |  |
|  |   psi_i, lambda_i |     | sigma_adj, z_i    |          | OOS Forecast Y_i+1 |  |
|  +-------------------+     +-------------------+          +--------------------+  |
+-----------------------------------------------------------------------------------+
```

#### 1. `HFD_ACD.R` — Autoregressive Conditional Duration Model
* **Mathematical Specification**:
  Models non-stationary trade duration intervals $x_i = \Delta t_i = t_i - t_{i-1}$ adjusted for diurnal intraday rhythm using smooth cubic splines $s_d(t_i)$:
  $$x_{\text{adj}, i} = \frac{x_i}{s_d(t_i)}$$
  The conditional expected duration $\psi_i = \mathbb{E}[x_{\text{adj}, i} \mid \mathcal{F}_{i-1}]$ follows an Exponential ACD(1,1) process:
  $$\psi_i = \omega_A + \alpha_A x_{\text{adj}, i-1} + \beta_A \psi_{i-1}$$
* **Extracted State Variables**:
  * Trade Intensity Rate: $\lambda_i = \frac{1}{\psi_i}$
  * Microstructure Duration Residual: $\epsilon_i = \frac{x_{\text{adj}, i}}{\psi_i}$
  * Diurnal Factor: $s_d(t_i)$

#### 2. `HFD_UHFGARCH.R` — Ultra-High-Frequency GARCH Model
* **Mathematical Specification**:
  Models return rates per unit time $\tilde{r}_i = \frac{r_i}{\sqrt{\Delta t_i / 60}}$ adjusted for diurnal intraday volatility seasonality $s_v(t_i)$:
  $$r_{\text{adj}, i} = \frac{\tilde{r}_i}{s_v(t_i)}$$
  The conditional variance $\sigma_{\text{adj}, i}^2$ follows an sGARCH(1,1) specification with Student-t or Normal innovation distributions:
  $$\sigma_{\text{adj}, i}^2 = \omega_G + \alpha_G r_{\text{adj}, i-1}^2 + \beta_G \sigma_{\text{adj}, i-1}^2$$
  Total unadjusted conditional volatility rate per tick:
  $$\sigma_i = \sigma_{\text{adj}, i} \cdot s_v(t_i) \cdot \sqrt{\frac{\Delta t_i}{60}}$$
* **Extracted State Variables**:
  * Standardized Volatility Innovation: $z_i = \frac{r_{\text{adj}, i}}{\sigma_{\text{adj}, i}}$
  * Diurnal Volatility Factor: $s_v(t_i)$
  * Total Volatility Rate: $\sigma_i$

#### 3. `HFD_MLHYBRID.R` — Non-Linear High-Frequency ML Hybrid
* **Formulation**:
  Combines structural state variables from `HFD_ACD.R` and `HFD_UHFGARCH.R` with microstructure indicators into a non-linear gradient boosted target function:
  $$Y_{i+1} = f(\mathbf{X}_i) + \eta_{i+1}$$
  * **Target Variable**: Out-of-sample next-tick absolute return $|r_{i+1}|$.
  * **Feature Vector $\mathbf{X}_i$**:
    $$\mathbf{X}_i = \left[ \psi_i, \lambda_i, \epsilon_i, \sigma_{\text{adj}, i}, \sigma_i, z_i, s_d, s_v, \ln(V_i), \ln\left(\frac{H_i}{L_i}\right), r_i, (\sigma_i \cdot \lambda_i) \right]$$
* **Validation & Splitting**:
  * Chronological non-random time-series train/test split (70% train / 30% out-of-sample evaluation).
  * Evaluated against baseline UHF-GARCH using Out-Of-Sample Root Mean Squared Error (RMSE), Mean Absolute Error (MAE), coefficient of determination ($R^2$), and cumulative loss trajectories.

---

### Stage 3: Low-Frequency Data (LFD) Pipeline

The LFD branch models low-frequency daily trend persistence, conditional variance clustering, and daily price/volume range dynamics.

```
+-----------------------------------------------------------------------------------+
|                             LOW-FREQUENCY PIPELINE                                |
+-----------------------------------------------------------------------------------+
|                                                                                   |
|   [LFD_ARIMA.R]              [LFD_GARCH.R]                 [LFD_MLHYBRID.R]       |
|  +-------------------+     +-------------------+          +--------------------+  |
|  | Mean Forecasting  | --> | Volatility Model  | -------> |  XGBoost Regressor |  |
|  |  mu_hat_t, e_t    |     |  sigma_t, z_t     |          | OOS Forecast Y_t+1 |  |
|  +-------------------+     +-------------------+          +--------------------+  |
+-----------------------------------------------------------------------------------+
```

#### 1. `LFD_ARIMA.R` — Daily Mean Trend Model
* **Mathematical Specification**:
  Models price levels and daily percentage log returns $r_t = \ln(C_t / C_{t-1}) \times 100$ using an optimal $(p, d, q)$ ARIMA mean process selected via Akaike Information Criterion (AIC):
  $$\phi(B)(1 - B)^d r_t = \theta(B) e_t \implies \hat{\mu}_t = \mathbb{E}[r_t \mid \mathcal{F}_{t-1}]$$
* **Extracted State Variables**:
  * Expected Conditional Mean Return: $\hat{\mu}_t$
  * Linear Mean Residual Error: $e_t = r_t - \hat{\mu}_t$

#### 2. `LFD_GARCH.R` — Daily Conditional Heteroskedasticity Model
* **Mathematical Specification**:
  Models volatility clustering in return residuals using a daily sGARCH(1,1) specification:
  $$\sigma_t^2 = \omega + \alpha e_{t-1}^2 + \beta \sigma_{t-1}^2$$
* **Extracted State Variables**:
  * Daily Conditional Volatility: $\sigma_t$
  * Standardized Error Residuals: $z_t = \frac{e_t}{\sigma_t}$
  * Squared Innovation Magnitude: $e_t^2$

#### 3. `LFD_MLHYBRID.R` — Non-Linear Low-Frequency ML Hybrid
* **Formulation**:
  Couples linear mean estimates and conditional volatility metrics with daily OHLCV range features:
  $$|r_{t+1}| = f(\mathbf{X}_t) + \eta_{t+1}$$
  * **Daily Microstructure Proxy Variables**:
    * Log High-Low Parkinson Spread: $s_t^{\text{spread}} = \ln\left(\frac{\text{High}_t}{\text{Low}_t}\right)$
    * Log Close-Open Body Return: $s_t^{\text{body}} = \ln\left(\frac{\text{Close}_t}{\text{Open}_t}\right)$
    * Volume Level & Rate of Change: $v_t = \ln(\text{Volume}_t), \quad \Delta v_t = v_t - v_{t-1}$
  * **Feature Vector $\mathbf{X}_t$**:
    $$\mathbf{X}_t = \left[ \hat{\mu}_t, e_t, \sigma_t, z_t, e_t^2, |r_t|, |r_{t-1}|, s_t^{\text{spread}}, s_t^{\text{body}}, v_t, \Delta v_t, (\sigma_t \cdot v_t) \right]$$
* **Validation & Metrics**:
  * Chronological split (75% train / 25% test).
  * Out-of-sample benchmark comparison against daily standard GARCH(1,1) baseline forecasts.

---

## 4. Architectural Comparison: HFD vs. LFD Hybrid Frameworks

| Model Metric / Dimension | High-Frequency Data Pipeline (`HFD`) | Low-Frequency Data Pipeline (`LFD`) |
| :--- | :--- | :--- |
| **Observation Frequency** | Tick-by-tick / Intraday minute bars | Daily trading sessions |
| **Duration Modeling** | Exponential ACD(1,1) for trade intervals | Daily volume log-difference $\Delta v_t$ |
| **Mean Specification** | Zero-mean assumption ($\mu = 0$) | Optimal ARIMA $(p, d, q)$ mean filter $\hat{\mu}_t$ |
| **Volatility Process** | Diurnal-adjusted UHF-GARCH(1,1) | Daily sGARCH(1,1) |
| **Diurnal Seasonality** | Smooth splines $s_d(t)$ and $s_v(t)$ | N/A (Handled via calendar trading days) |
| **Target Variable ($Y$)** | Out-of-sample next-tick volatility $|r_{i+1}|$ | Out-of-sample next-day volatility $|r_{t+1}|$ |
| **Key Interaction Feature** | Volatility $\times$ Trade Intensity ($\sigma_i \cdot \lambda_i$) | Volatility $\times$ Log Volume ($\sigma_t \cdot v_t$) |
| **ML Engine Core** | XGBoost Regressor (Chronological 70/30) | XGBoost Regressor (Chronological 75/25) |

---

## 5. Stage 4: Output Aggregation & Final Deliverable

### `COMPILER.py` — Output Aggregator
1. Ingests raw `.rds` execution objects, parameter matrices, coefficient vectors, and diagnostic plot image files (`.png`/`.svg`) generated across all six R scripts.
2. Formats and compiles metrics into a master Excel deliverable: **`ECMT3150.xlsx`**.

### Structure of Master Output (`ECMT3150.xlsx`)
* **Sheet 1: `Executive Dashboard`**: Embedded interactive charts (Price history, ACF/PACF plots, diurnal seasonal curves, volatility fit overlays, OOS cumulative loss comparisons).
* **Sheet 2: `Model Parameters & Metrics`**: Unified comparative summary tables containing AIC, BIC, Log-Likelihood, persistence metrics ($\alpha + \beta$), RMSE, MAE, and $R^2$ scores for both econometric baselines and hybrid ML engines.
* **Sheet 3: `Cleaned Datasets`**: Cleaned long-format series for HFD and LFD inputs.

---

## 6. System File & Output Directory Map

| Filename / Object | Language / Type | System Role & Functionality |
| :--- | :--- | :--- |
| `SUBPROCESS.py` | Python Script | Master process trigger and pipeline orchestrator. |
| `LSEGEXTRACTION.py` | Python Script | LSEG API connector and data handler. |
| `HFD.xlsx` | Data Store | High-frequency tick and minute intraday dataset. |
| `LFD.xlsx` | Data Store | Daily price, returns, and OHLCV volume dataset. |
| `HFD_ACD.R` | R Script | Fits ACD(1,1) trade duration and intensity models. |
| `HFD_UHFGARCH.R` | R Script | Fits diurnal time-deformed UHF-GARCH(1,1) volatility models. |
| `HFD_MLHYBRID.R` | R Script | Trains high-frequency XGBoost ML hybrid model. |
| `LFD_ARIMA.R` | R Script | Fits `auto.arima` daily mean trend models. |
| `LFD_GARCH.R` | R Script | Fits daily GARCH(1,1) conditional volatility models. |
| `LFD_MLHYBRID.R` | R Script | Trains low-frequency XGBoost ML hybrid model. |
| `COMPILER.py` | Python Script | Consolidates figures, workspace outputs, and performance tables. |
| **`ECMT3150.xlsx`** | Master Deliverable | Final compiled Excel workbook containing all reports, charts, and metrics. |