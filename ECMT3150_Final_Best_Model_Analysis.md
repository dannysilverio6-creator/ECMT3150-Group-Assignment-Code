# ECMT3150 - Modelling commodity volatility through the Iran conflict

_Generated 2026-10-15 14:00 from the pipeline outputs; every number below is read from the output tables._

## Design

- **Event date:** 2026-03-02 (first trading day after the strikes of 28 Feb 2026).
- **Estimation:** models are estimated only with data before each forecast origin. The **Frozen** scheme fixes parameters at the event (estimated on calm, pre-event data only) and never updates them; the **Adaptive** scheme re-estimates on an expanding window as post-event data arrive (daily data every 21 trading days, intraday models every day).
- **Evaluation windows:** a calm pre-event window (out-of-sample, last 60 trading days for daily data / 5 days for intraday) as the benchmark of normal accuracy, then the shock week (days 1-5) and later post-event windows.
- **Targets:** daily models forecast next-day |return|; intraday models forecast next-day realised volatility from 5-minute returns. Naive benchmarks: 22-day mean |return| (daily), random walk RV (intraday).

## Key findings

- **XAU= (daily):** volatility went from 36.9% to 26.3% annualised (60 days before vs after; x0.71, Brown-Forsythe p = 0.494); EGARCH event dummy delta = 0.046 (p = 0.228).
- **XAG= (daily):** volatility went from 106.8% to 55.3% annualised (60 days before vs after; x0.52, Brown-Forsythe p = 0.045); EGARCH event dummy delta = 0.000 (p = 0.925).
- **URA.P (daily):** volatility went from 55.2% to 53.7% annualised (60 days before vs after; x0.97, Brown-Forsythe p = 0.940); EGARCH event dummy delta = -18.157 (p = 0.139).
- **XAU= (LFD) vs the pre-event no-conflict forecast:** GARCH(1,1), shock: x1.43 (above; p = 0.147); Stochastic volatility, all post-event: x1.36 (above; p = <0.001); Stochastic volatility, shock: x1.56 (above; p = 0.068); GARCH(1,1), all post-event: x1.24 (above; p = <0.001).
- **URA.P (LFD) vs the pre-event no-conflict forecast:** Stochastic volatility, all post-event: x1.28 (above; p = <0.001); Stochastic volatility, shock: x2.06 (above; p = 0.001); GARCH(1,1), all post-event: x0.93 (below; p = 0.239); GARCH(1,1), shock: x1.44 (above; p = 0.128).
- **XAG= (LFD) vs the pre-event no-conflict forecast:** Stochastic volatility, shock: x1.12 (above; p = 0.596); Stochastic volatility, all post-event: x1.00 (below; p = 0.950); GARCH(1,1), shock: x0.67 (below; p = 0.369); GARCH(1,1), all post-event: x0.43 (below; p = <0.001).
- **URA.P (HFD) vs the pre-event no-conflict forecast:** HAR-RV (log), shock: x0.91 (below; p = 0.766); HAR-RV (log), all post-event: x0.86 (below; p = 0.831); Realised GARCH, all post-event: x1.20 (above; p = 0.292); Realised GARCH, shock: x1.40 (above; p = 0.160).
- **XAU= (HFD) vs the pre-event no-conflict forecast:** HAR-RV (log), shock: x0.84 (below; p = 0.268); Realised GARCH, all post-event: x1.10 (above; p = 0.380); Realised GARCH, shock: x1.46 (above; p = 0.091); HAR-RV (log), all post-event: x0.59 (below; p = <0.001).
- **XAG= (HFD) vs the pre-event no-conflict forecast:** HAR-RV (log), all post-event: x0.60 (below; p = <0.001); HAR-RV (log), shock: x0.95 (below; p = 0.893); Realised GARCH, all post-event: x1.51 (above; p = 0.009); Realised GARCH, shock: x1.91 (above; p = 0.002).
- **Best HFD model through the event (adaptive, average post-event rank 2.50):** Realised GARCH. Its error during the shock week was x1.32 its calm pre-event error, and it averaged 1.19 x the naive benchmark's RMSE.
- **Best LFD model through the event (adaptive, average post-event rank 2.25):** Stochastic volatility. Its error during the shock week was x0.98 its calm pre-event error, and it averaged 1.03 x the naive benchmark's RMSE.
- In the shock week the winning model was significantly better than the runner-up for 0 of 6 instrument-frequency pairs; the naive benchmark won 3 of them.
- Re-estimating through the event changed post-event RMSE by -0.2% (median across models and instruments; negative = re-estimation helps).

## Q1. Did volatility change after the event?

**Daily data.** Annualised volatility; BF = Brown-Forsythe test of equal variances.

| Ticker | Vol % 60d before | Vol % 60d after | Ratio | BF p | Full-sample ratio | Return 5d % | Return 20d % | Max abs move 5d % |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| XAU= | 36.9 | 26.3 | 0.71 | 0.494 | 1.40 | -2.04 | -16.10 | 4.61 |
| XAG= | 106.8 | 55.3 | 0.52 | 0.045 | 1.19 | -10.64 | -29.62 | 8.63 |
| URA.P | 55.2 | 53.7 | 0.97 | 0.940 | 1.27 | -10.69 | -15.28 | 8.09 |

**EGARCH(1,1)-t with a post-event dummy in the log-variance equation** (delta > 0 = higher volatility after the event, controlling for clustering; QML robust SEs; \*/\*\*/\*\*\* = 10/5/1%).

| Ticker | delta | robust t | p | beta | Long-run vol multiplier |
| --- | --- | --- | --- | --- | --- |
| XAU= | 0.0455 | 1.20 | 0.228 | 0.967 | 2.01 |
| XAG= | 0.0004 | 0.09 | 0.925 | 0.995 | 1.04 |
| URA.P | -18.1574 | -1.48 | 0.139 | 0.856 | 0.00 |

**Intraday data** (daily realised volatility from 5-minute returns).

| Ticker | Mean RV pre % | Mean RV post % | Ratio | Welch p (log RV) | Week before % | First 5 days % | Peak day |
| --- | --- | --- | --- | --- | --- | --- | --- |
| URA.P | 2.69 | 3.61 | 1.34 | 0.135 | 2.27 | 4.30 | 2026-03-03 |
| XAG= | 5.48 | 4.90 | 0.89 | 0.793 | 3.65 | 5.80 | 2026-03-03 |
| XAU= | 2.01 | 1.92 | 0.96 | 0.627 | 1.36 | 2.32 | 2026-03-03 |

## Q2. Was post-event volatility abnormal relative to the pre-event models?

Each econometric model is estimated on pre-event data only and forecasts the whole post-event period from the event date without seeing any post-event data (the no-conflict counterfactual). Ratio = realised / counterfactual volatility; > 1 means the market was more volatile than the pre-event model expected. Tests: returns-based models use sum (r / sigma_cf)^2 ~ chi2(n); HAR-RV uses the mean standardised log-RV surprise. p-values are two-sided.

| Freq | Ticker | Model | Window | Days | Realised vol | Counterfactual vol | Ratio | p |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| LFD | XAU= | GARCH(1,1) | Shock (days 1-5) | 5 | 2.35 | 1.65 | 1.43 | 0.147 |
| LFD | XAU= | GARCH(1,1) | Short run (6-20) | 15 | 2.11 | 1.52 | 1.39** | 0.026 |
| LFD | XAU= | GARCH(1,1) | Medium run (21-60) | 40 | 1.33 | 1.33 | 1.00 | 0.972 |
| LFD | XAU= | GARCH(1,1) | Long run (61+) | 99 | 1.57 | 1.22 | 1.29*** | <0.001 |
| LFD | XAU= | GARCH(1,1) | All post-event | 159 | 1.61 | 1.30 | 1.24*** | <0.001 |
| LFD | XAG= | GARCH(1,1) | Shock (days 1-5) | 5 | 4.67 | 6.98 | 0.67 | 0.369 |
| LFD | XAG= | GARCH(1,1) | Short run (6-20) | 15 | 3.43 | 6.97 | 0.49*** | 0.003 |
| LFD | XAG= | GARCH(1,1) | Medium run (21-60) | 40 | 3.30 | 6.96 | 0.47*** | <0.001 |
| LFD | XAG= | GARCH(1,1) | Long run (61+) | 99 | 2.63 | 6.92 | 0.38*** | <0.001 |
| LFD | XAG= | GARCH(1,1) | All post-event | 159 | 2.97 | 6.93 | 0.43*** | <0.001 |
| LFD | URA.P | GARCH(1,1) | Shock (days 1-5) | 5 | 4.81 | 3.33 | 1.44 | 0.128 |
| LFD | URA.P | GARCH(1,1) | Short run (6-20) | 15 | 2.65 | 3.34 | 0.80 | 0.300 |
| LFD | URA.P | GARCH(1,1) | Medium run (21-60) | 40 | 3.37 | 3.35 | 1.01 | 0.899 |
| LFD | URA.P | GARCH(1,1) | Long run (61+) | 95 | 2.98 | 3.37 | 0.88 | 0.112 |
| LFD | URA.P | GARCH(1,1) | All post-event | 155 | 3.13 | 3.36 | 0.93 | 0.239 |
| LFD | XAU= | Stochastic volatility | Shock (days 1-5) | 5 | 2.38 | 1.52 | 1.56* | 0.068 |
| LFD | XAU= | Stochastic volatility | Short run (6-20) | 15 | 2.17 | 1.38 | 1.57*** | 0.002 |
| LFD | XAU= | Stochastic volatility | Medium run (21-60) | 40 | 1.34 | 1.21 | 1.10 | 0.348 |
| LFD | XAU= | Stochastic volatility | Long run (61+) | 99 | 1.59 | 1.14 | 1.39*** | <0.001 |
| LFD | XAU= | Stochastic volatility | All post-event | 159 | 1.62 | 1.19 | 1.36*** | <0.001 |
| LFD | XAG= | Stochastic volatility | Shock (days 1-5) | 5 | 4.75 | 4.24 | 1.12 | 0.596 |
| LFD | XAG= | Stochastic volatility | Short run (6-20) | 15 | 3.50 | 3.73 | 0.94 | 0.884 |
| LFD | XAG= | Stochastic volatility | Medium run (21-60) | 40 | 3.29 | 3.10 | 1.06 | 0.411 |
| LFD | XAG= | Stochastic volatility | Long run (61+) | 99 | 2.65 | 2.74 | 0.97 | 0.565 |
| LFD | XAG= | Stochastic volatility | All post-event | 159 | 2.99 | 3.00 | 1.00 | 0.950 |
| LFD | URA.P | Stochastic volatility | Shock (days 1-5) | 5 | 4.87 | 2.37 | 2.06*** | 0.001 |
| LFD | URA.P | Stochastic volatility | Short run (6-20) | 15 | 2.67 | 2.46 | 1.09 | 0.550 |
| LFD | URA.P | Stochastic volatility | Medium run (21-60) | 40 | 3.36 | 2.47 | 1.36*** | 0.002 |
| LFD | URA.P | Stochastic volatility | Long run (61+) | 95 | 2.99 | 2.46 | 1.21*** | 0.003 |
| LFD | URA.P | Stochastic volatility | All post-event | 155 | 3.14 | 2.46 | 1.28*** | <0.001 |
| HFD | URA.P | Realised GARCH | Shock (days 1-5) | 5 | 4.88 | 3.48 | 1.40 | 0.160 |
| HFD | URA.P | Realised GARCH | Aftermath (6+) | 6 | 3.49 | 3.48 | 1.00 | 0.837 |
| HFD | URA.P | Realised GARCH | All post-event | 11 | 4.18 | 3.48 | 1.20 | 0.292 |
| HFD | XAG= | Realised GARCH | Shock (days 1-5) | 5 | 5.24 | 2.74 | 1.91*** | 0.002 |
| HFD | XAG= | Realised GARCH | Aftermath (6+) | 5 | 3.02 | 2.94 | 1.03 | 0.762 |
| HFD | XAG= | Realised GARCH | All post-event | 10 | 4.28 | 2.84 | 1.51*** | 0.009 |
| HFD | XAU= | Realised GARCH | Shock (days 1-5) | 5 | 2.27 | 1.55 | 1.46* | 0.091 |
| HFD | XAU= | Realised GARCH | Aftermath (6+) | 5 | 1.20 | 1.74 | 0.69 | 0.400 |
| HFD | XAU= | Realised GARCH | All post-event | 10 | 1.82 | 1.65 | 1.10 | 0.380 |
| HFD | URA.P | HAR-RV (log) | Shock (days 1-5) | 5 | 4.30 | 4.74 | 0.91 | 0.766 |
| HFD | URA.P | HAR-RV (log) | Aftermath (6+) | 6 | 3.04 | 3.75 | 0.81 | 0.575 |
| HFD | URA.P | HAR-RV (log) | All post-event | 11 | 3.61 | 4.20 | 0.86 | 0.831 |
| HFD | XAG= | HAR-RV (log) | Shock (days 1-5) | 5 | 5.80 | 6.14 | 0.95 | 0.893 |
| HFD | XAG= | HAR-RV (log) | Aftermath (6+) | 5 | 3.99 | 10.17 | 0.39*** | <0.001 |
| HFD | XAG= | HAR-RV (log) | All post-event | 10 | 4.90 | 8.16 | 0.60*** | <0.001 |
| HFD | XAU= | HAR-RV (log) | Shock (days 1-5) | 5 | 2.32 | 2.75 | 0.84 | 0.268 |
| HFD | XAU= | HAR-RV (log) | Aftermath (6+) | 5 | 1.52 | 3.75 | 0.41*** | <0.001 |
| HFD | XAU= | HAR-RV (log) | All post-event | 10 | 1.92 | 3.25 | 0.59*** | <0.001 |

Charts: `PHOTOS/EVENT_STUDY/LFD_Counterfactual_Volatility.png`, `HFD_Counterfactual_Volatility.png` (includes cumulative abnormal volatility).

## Q3. Which model handles the disruption best, and do they hold up?

**Robustness ranking** (averaged across instruments; rank 1 = most accurate, naive included in the ranking). 'Shock error / calm error' > 1 means accuracy deteriorated in the shock week. A well-calibrated 95% band is exceeded about 5% of the time; Kupiec rejections count instruments where the exceedance rate differs significantly from 5%.

| Freq | Scheme | Model | Avg post-event rank | Calm rank | Shock rank | RMSE / naive | Shock error / calm error | 95% band exceed (post) | Kupiec rejections | Recommended |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| HFD | Adaptive | Realised GARCH | 2.50 | 3.67 | 2.00 | 1.19 | 1.32 | 0.064 | 0 | YES |
| HFD | Adaptive | XGBoost hybrid | 2.67 | 2.67 | 2.67 | 1.14 | 2.52 | 0.094 | 0 |  |
| HFD | Adaptive | HAR-RV (log) | 2.67 | 2.00 | 3.00 | 1.26 | 5.23 | 0.067 | 0 |  |
| HFD | Frozen | Realised GARCH | 2.17 | 3.67 | 1.67 | 1.20 | 1.18 | 0.094 | 0 | YES |
| HFD | Frozen | XGBoost hybrid | 2.33 | 3.33 | 2.33 | 1.39 | 2.02 | 0.094 | 0 |  |
| HFD | Frozen | HAR-RV (log) | 3.17 | 1.33 | 3.33 | 3.72 | 4.74 | 0.067 | 0 |  |
| LFD | Adaptive | Stochastic volatility | 2.25 | 3.00 | 3.33 | 1.03 | 0.98 | 0.091 | 2 | YES |
| LFD | Adaptive | GARCH(1,1) | 2.42 | 1.33 | 3.00 | 1.03 | 0.95 | 0.053 | 0 |  |
| LFD | Adaptive | XGBoost hybrid | 3.42 | 3.67 | 2.00 | 1.16 | 0.89 | 0.070 | 0 |  |
| LFD | Frozen | GARCH(1,1) | 2.33 | 1.33 | 3.00 | 1.03 | 0.96 | 0.053 | 0 | YES |
| LFD | Frozen | Stochastic volatility | 2.42 | 2.67 | 3.33 | 1.03 | 0.96 | 0.108 | 3 |  |
| LFD | Frozen | XGBoost hybrid | 3.08 | 4.00 | 2.00 | 1.23 | 0.87 | 0.074 | 1 |  |

**Best model by window** (adaptive scheme; DM = Diebold-Mariano test, HLN correction).

| Freq | Ticker | Window | Best model | RMSE | RMSE / naive | Runner-up | DM p vs runner-up | Days |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| HFD | URA.P | Pre-event (calm) | Naive RW | 1.220 | 1.00 | XGBoost hybrid | 0.475 | 5 |
| HFD | XAG= | Pre-event (calm) | HAR-RV (log) | 0.473 | 0.67 | Naive RW | 0.074 | 5 |
| HFD | XAU= | Pre-event (calm) | HAR-RV (log) | 0.250 | 0.93 | Naive RW | 0.853 | 5 |
| HFD | URA.P | Shock (days 1-5) | HAR-RV (log) | 1.785 | 0.63 | Realised GARCH | 0.950 | 5 |
| HFD | XAG= | Shock (days 1-5) | Naive RW | 2.408 | 1.00 | XGBoost hybrid | 0.508 | 5 |
| HFD | XAU= | Shock (days 1-5) | Realised GARCH | 0.994 | 0.92 | Naive RW | 0.644 | 5 |
| HFD | URA.P | All post-event | HAR-RV (log) | 1.469 | 0.58 | Realised GARCH | 0.663 | 11 |
| HFD | XAG= | All post-event | Naive RW | 1.901 | 1.00 | XGBoost hybrid | 0.254 | 10 |
| HFD | XAU= | All post-event | Naive RW | 0.812 | 1.00 | Realised GARCH | 0.839 | 10 |
| LFD | URA.P | Pre-event (calm) | GARCH(1,1) | 2.175 | 0.96 | Naive 22-day mean | 0.118 | 60 |
| LFD | XAG= | Pre-event (calm) | Naive 22-day mean | 5.036 | 1.00 | GARCH(1,1) | 0.832 | 60 |
| LFD | XAU= | Pre-event (calm) | GARCH(1,1) | 1.648 | 0.94 | Stochastic volatility | 0.736 | 60 |
| LFD | URA.P | Shock (days 1-5) | Naive 22-day mean | 2.599 | 1.00 | GARCH(1,1) | 0.451 | 5 |
| LFD | XAG= | Shock (days 1-5) | XGBoost hybrid | 2.669 | 0.91 | Stochastic volatility | 0.514 | 5 |
| LFD | XAU= | Shock (days 1-5) | Naive 22-day mean | 1.352 | 1.00 | XGBoost hybrid | 0.787 | 5 |
| LFD | URA.P | All post-event | GARCH(1,1) | 1.934 | 0.99 | Naive 22-day mean | 0.308 | 155 |
| LFD | XAG= | All post-event | Stochastic volatility | 1.904 | 0.99 | Naive 22-day mean | 0.799 | 159 |
| LFD | XAU= | All post-event | GARCH(1,1) | 1.035 | 1.00 | Stochastic volatility | 0.997 | 159 |

**RMSE relative to the naive benchmark, window by window** (adaptive scheme; < 1 = beats naive).

| Frequency | Ticker | Model | Pre-event (calm) | Shock (days 1-5) | Short run (6-20) | Medium run (21-60) | Long run (61+) | Aftermath (6+) | All post-event |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| HFD | URA.P | HAR-RV (log) | 1.39 | 0.63 | N/A | N/A | N/A | 0.51 | 0.58 |
| HFD | URA.P | Realised GARCH | 1.39 | 0.65 | N/A | N/A | N/A | 0.65 | 0.65 |
| HFD | URA.P | XGBoost hybrid | 1.22 | 0.69 | N/A | N/A | N/A | 0.61 | 0.66 |
| HFD | XAG= | HAR-RV (log) | 0.67 | 1.44 | N/A | N/A | N/A | 1.46 | 1.45 |
| HFD | XAG= | Realised GARCH | 4.19 | 1.21 | N/A | N/A | N/A | 2.12 | 1.44 |
| HFD | XAG= | XGBoost hybrid | 1.20 | 1.21 | N/A | N/A | N/A | 1.47 | 1.26 |
| HFD | XAU= | HAR-RV (log) | 0.93 | 1.70 | N/A | N/A | N/A | 1.80 | 1.71 |
| HFD | XAU= | Realised GARCH | 1.96 | 0.92 | N/A | N/A | N/A | 1.61 | 1.03 |
| HFD | XAU= | XGBoost hybrid | 1.74 | 1.22 | N/A | N/A | N/A | 1.64 | 1.28 |
| LFD | URA.P | GARCH(1,1) | 0.96 | 1.07 | 1.05 | 0.98 | 0.98 | N/A | 0.99 |
| LFD | URA.P | Stochastic volatility | 1.00 | 1.25 | 1.05 | 1.05 | 0.98 | N/A | 1.02 |
| LFD | URA.P | XGBoost hybrid | 1.02 | 1.18 | 1.20 | 1.02 | 1.00 | N/A | 1.03 |
| LFD | XAG= | GARCH(1,1) | 1.01 | 1.06 | 1.16 | 1.02 | 1.01 | N/A | 1.03 |
| LFD | XAG= | Stochastic volatility | 1.05 | 0.96 | 0.92 | 0.99 | 1.01 | N/A | 0.99 |
| LFD | XAG= | XGBoost hybrid | 1.04 | 0.91 | 2.03 | 1.19 | 1.05 | N/A | 1.23 |
| LFD | XAU= | GARCH(1,1) | 0.94 | 1.17 | 0.94 | 0.95 | 1.01 | N/A | 1.00 |
| LFD | XAU= | Stochastic volatility | 0.95 | 1.20 | 0.97 | 0.93 | 1.01 | N/A | 1.00 |
| LFD | XAU= | XGBoost hybrid | 1.02 | 1.12 | 1.08 | 1.02 | 1.09 | N/A | 1.08 |

**Frozen vs adaptive:** does re-estimating through the event help? (negative change = adaptive more accurate)

| Freq | Ticker | Model | Window | Frozen RMSE | Adaptive RMSE | Change % |
| --- | --- | --- | --- | --- | --- | --- |
| HFD | URA.P | HAR-RV (log) | All post-event | 1.423 | 1.469 | 3.2 |
| HFD | URA.P | HAR-RV (log) | Shock (days 1-5) | 1.727 | 1.785 | 3.4 |
| HFD | URA.P | Realised GARCH | All post-event | 1.534 | 1.647 | 7.4 |
| HFD | URA.P | Realised GARCH | Shock (days 1-5) | 1.696 | 1.839 | 8.4 |
| HFD | URA.P | XGBoost hybrid | All post-event | 1.642 | 1.659 | 1.0 |
| HFD | URA.P | XGBoost hybrid | Shock (days 1-5) | 1.989 | 1.957 | -1.6 |
| HFD | XAG= | HAR-RV (log) | All post-event | 6.381 | 2.749 | -56.9 |
| HFD | XAG= | HAR-RV (log) | Shock (days 1-5) | 3.288 | 3.475 | 5.7 |
| HFD | XAG= | Realised GARCH | All post-event | 2.800 | 2.731 | -2.5 |
| HFD | XAG= | Realised GARCH | Shock (days 1-5) | 2.785 | 2.913 | 4.6 |
| HFD | XAG= | XGBoost hybrid | All post-event | 3.447 | 2.403 | -30.3 |
| HFD | XAG= | XGBoost hybrid | Shock (days 1-5) | 2.706 | 2.912 | 7.6 |
| HFD | XAU= | HAR-RV (log) | All post-event | 3.378 | 1.389 | -58.9 |
| HFD | XAU= | HAR-RV (log) | Shock (days 1-5) | 1.588 | 1.829 | 15.2 |
| HFD | XAU= | Realised GARCH | All post-event | 0.794 | 0.835 | 5.2 |
| HFD | XAU= | Realised GARCH | Shock (days 1-5) | 0.926 | 0.994 | 7.4 |
| HFD | XAU= | XGBoost hybrid | All post-event | 0.867 | 1.036 | 19.5 |
| HFD | XAU= | XGBoost hybrid | Shock (days 1-5) | 1.065 | 1.312 | 23.3 |
| LFD | URA.P | GARCH(1,1) | All post-event | 1.934 | 1.934 | -0.0 |
| LFD | URA.P | GARCH(1,1) | Shock (days 1-5) | 2.779 | 2.779 | 0.0 |
| LFD | URA.P | Stochastic volatility | All post-event | 2.008 | 1.997 | -0.5 |
| LFD | URA.P | Stochastic volatility | Shock (days 1-5) | 3.258 | 3.258 | 0.0 |
| LFD | URA.P | XGBoost hybrid | All post-event | 1.965 | 2.014 | 2.5 |
| LFD | URA.P | XGBoost hybrid | Shock (days 1-5) | 2.950 | 3.070 | 4.1 |
| LFD | XAG= | GARCH(1,1) | All post-event | 2.000 | 1.984 | -0.8 |
| LFD | XAG= | GARCH(1,1) | Shock (days 1-5) | 3.108 | 3.108 | 0.0 |
| LFD | XAG= | Stochastic volatility | All post-event | 1.904 | 1.904 | -0.0 |
| LFD | XAG= | Stochastic volatility | Shock (days 1-5) | 2.832 | 2.832 | 0.0 |
| LFD | XAG= | XGBoost hybrid | All post-event | 3.217 | 2.358 | -26.7 |
| LFD | XAG= | XGBoost hybrid | Shock (days 1-5) | 2.823 | 2.669 | -5.4 |
| LFD | XAU= | GARCH(1,1) | All post-event | 1.038 | 1.035 | -0.3 |
| LFD | XAU= | GARCH(1,1) | Shock (days 1-5) | 1.587 | 1.587 | 0.0 |
| LFD | XAU= | Stochastic volatility | All post-event | 1.037 | 1.035 | -0.2 |
| LFD | XAU= | Stochastic volatility | Shock (days 1-5) | 1.628 | 1.628 | 0.0 |
| LFD | XAU= | XGBoost hybrid | All post-event | 1.143 | 1.117 | -2.2 |
| LFD | XAU= | XGBoost hybrid | Shock (days 1-5) | 1.576 | 1.521 | -3.5 |

Charts: `PHOTOS/EVENT_STUDY/LFD_Accuracy_By_Window.png`, `HFD_Accuracy_By_Window.png`, `LFD_OOS_Model_Comparison.png`, `HFD_OOS_Model_Comparison.png`.

## Notes and limitations

- The event study is descriptive: other news in the same window (e.g. the January 2026 precious-metals sell-off) also moves volatility, so a change after the event date is consistent with, but does not prove, a causal effect of the conflict.
- The intraday sample ends 10 trading days after the event, so intraday windows contain 5 days each and DM / Kupiec tests have little power there; daily results are the more reliable evidence.
- Counterfactual paths are multi-step forecasts; for HAR-RV the test uses the one-step residual standard deviation, which understates multi-step uncertainty (so it over-rejects).
- Full tables: `Pipeline_Outputs/Conclusive_Results/CONCLUSIVE_MODEL_DIAGNOSTICS.xlsx`.
