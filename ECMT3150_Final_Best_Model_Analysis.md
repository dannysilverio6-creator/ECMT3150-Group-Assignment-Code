# ECMT3150 - Effects of the Iran conflict on commodity volatility

_Generated 2026-10-15 12:53 from the pipeline outputs. Every number below is read from the output tables; nothing is typed by hand._

## Key findings

- **XAU=** daily volatility fell from 36.9% to 26.3% annualised comparing the 60 trading days before and after 2026-03-02 (x0.71; Brown-Forsythe p = 0.494; full-sample ratio x1.40); once volatility clustering is controlled for (EGARCH event dummy), the shift is not significant at 5% (delta = 0.046, p = 0.228).
- **XAG=** daily volatility fell from 106.8% to 55.3% annualised comparing the 60 trading days before and after 2026-03-02 (x0.52; Brown-Forsythe p = 0.045; full-sample ratio x1.19); once volatility clustering is controlled for (EGARCH event dummy), the shift is not significant at 5% (delta = 0.000, p = 0.925).
- **URA.P** daily volatility fell from 55.2% to 53.7% annualised comparing the 60 trading days before and after 2026-03-02 (x0.97; Brown-Forsythe p = 0.940; full-sample ratio x1.27); once volatility clustering is controlled for (EGARCH event dummy), the shift is not significant at 5% (delta = -18.157, p = 0.139).
- **URA.P** intraday realised volatility averaged 2.69% per day before the event and 3.61% after (x1.34; Welch p = 0.135; 11 post-event days).
- **XAG=** intraday realised volatility averaged 5.48% per day before the event and 4.90% after (x0.89; Welch p = 0.793; 10 post-event days).
- **XAU=** intraday realised volatility averaged 2.01% per day before the event and 1.92% after (x0.96; Welch p = 0.627; 10 post-event days).
- HFD URA.P: best forecaster is **HAR-RV (log)** (RMSE 0.9875) and the gap to the runner-up is statistically significant (DM p = 0.018).
- HFD XAG=: best forecaster is **Naive: RV(t)** (RMSE 1.1238) but it is not statistically distinguishable from the runner-up (DM p = 0.240).
- HFD XAU=: best forecaster is **Naive: RV(t)** (RMSE 0.3644) but it is not statistically distinguishable from the runner-up (DM p = 0.179).
- LFD URA.P: best forecaster is **GARCH(1,1)** (RMSE 2.0021) but it is not statistically distinguishable from the runner-up (DM p = 0.110).
- LFD XAG=: best forecaster is **Naive: 22-day mean |r|** (RMSE 3.1790) but it is not statistically distinguishable from the runner-up (DM p = 0.537).
- LFD XAU=: best forecaster is **GARCH(1,1)** (RMSE 1.2578) but it is not statistically distinguishable from the runner-up (DM p = 0.668).

## 1. Event study

### Daily data (LFD)

Volatility is annualised (x sqrt(252)). BF = Brown-Forsythe test of equal variances (robust to fat tails). Full-sample = all data since 2023 vs all post-event data.

| Ticker | Vol % 60d before | Vol % 60d after | Ratio | BF p | Full-sample ratio | Full-sample BF p | Return first 5d % | Return first 20d % | Max |move| first 5d % | Obs pre / post |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| XAU= | 36.9 | 26.3 | 0.71 | 0.494 | 1.40 | <0.001 | -2.04 | -16.10 | 4.61 | 815 / 159 |
| XAG= | 106.8 | 55.3 | 0.52 | 0.045 | 1.19 | <0.001 | -10.64 | -29.62 | 8.63 | 815 / 159 |
| URA.P | 55.2 | 53.7 | 0.97 | 0.940 | 1.27 | <0.001 | -10.69 | -15.28 | 8.09 | 790 / 155 |

### EGARCH(1,1)-t with a post-event dummy in the log-variance equation

delta > 0 means higher conditional volatility after the event, controlling for volatility clustering. Robust (QML) standard errors. \*/\*\*/\*\*\* = 10/5/1% significance.

| Ticker | delta (post-event) | robust t | p | beta | Long-run vol multiplier | t-dist df |
| --- | --- | --- | --- | --- | --- | --- |
| XAU= | 0.0455 | 1.20 | 0.228 | 0.967 | 2.01 | 8.0 |
| XAG= | 0.0004 | 0.09 | 0.925 | 0.995 | 1.04 | 4.9 |
| URA.P | -18.1574 | -1.48 | 0.139 | 0.856 | 0.00 | 3.3 |

### Intraday data (HFD, daily realised volatility from 5-minute returns)

| Ticker | Mean daily RV pre % | Mean daily RV post % | Ratio | Welch p (log RV) | Week before % | First 5 days after % | Peak day | Days pre / post |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| URA.P | 2.69 | 3.61 | 1.34 | 0.135 | 2.27 | 4.30 | 2026-03-03 | 48 / 11 |
| XAG= | 5.48 | 4.90 | 0.89 | 0.793 | 3.65 | 5.80 | 2026-03-03 | 41 / 10 |
| XAU= | 2.01 | 1.92 | 0.96 | 0.627 | 1.36 | 2.32 | 2026-03-03 | 41 / 10 |

Charts: `PHOTOS/EVENT_STUDY/LFD_Event_Volatility.png`, `HFD_Event_RV.png`.

## 2. Forecast comparison: high-frequency models

Target: next-day realised volatility (%). All models are re-estimated on an expanding window and scored on the same test days. DM = Diebold-Mariano test (squared error, HLN small-sample correction); a p-value below 0.05 means the difference in accuracy is statistically significant.

| Ticker | Rank | Model | RMSE | MAE | QLIKE | DM p vs best | DM p vs naive | Test window |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| URA.P | 1 | HAR-RV (log) | 0.9875 | 0.6795 | 0.3338 | - | 0.164 | 2026-03-05 to 2026-03-13 (n=8) |
| URA.P | 2 | XGBoost hybrid | 1.2440 | 1.0701 | 0.4387 | 0.018 | 0.226 | 2026-03-05 to 2026-03-13 (n=8) |
| URA.P | 3 | Realised GARCH | 1.2775 | 0.8734 | 0.4036 | 0.281 | 0.254 | 2026-03-05 to 2026-03-13 (n=8) |
| URA.P | 4 | Naive: RV(t) | 1.9514 | 1.4087 | 6.5499 | 0.164 | - | 2026-03-05 to 2026-03-13 (n=8) |
| XAG= | 1 | Naive: RV(t) | 1.1238 | 0.9939 | 0.1364 | - | - | 2026-03-06 to 2026-03-13 (n=6) |
| XAG= | 2 | XGBoost hybrid | 1.6901 | 1.6119 | 0.2294 | 0.240 | 0.240 | 2026-03-06 to 2026-03-13 (n=6) |
| XAG= | 3 | HAR-RV (log) | 2.1577 | 1.8463 | 0.2600 | 0.199 | 0.199 | 2026-03-06 to 2026-03-13 (n=6) |
| XAG= | 4 | Realised GARCH | 2.7070 | 2.4923 | 0.3940 | 0.051 | 0.051 | 2026-03-06 to 2026-03-13 (n=6) |
| XAU= | 1 | Naive: RV(t) | 0.3644 | 0.3071 | 0.0899 | - | - | 2026-03-06 to 2026-03-13 (n=6) |
| XAU= | 2 | XGBoost hybrid | 0.5900 | 0.5158 | 0.1943 | 0.179 | 0.179 | 2026-03-06 to 2026-03-13 (n=6) |
| XAU= | 3 | Realised GARCH | 0.6276 | 0.5387 | 0.1983 | 0.126 | 0.126 | 2026-03-06 to 2026-03-13 (n=6) |
| XAU= | 4 | HAR-RV (log) | 0.8675 | 0.7239 | 0.2624 | 0.122 | 0.122 | 2026-03-06 to 2026-03-13 (n=6) |

## 3. Forecast comparison: low-frequency models

Target: next-day absolute return (%). GARCH and SV volatility forecasts are converted to E|r| = sqrt(2/pi) x sigma. Parameters re-estimated every 21 trading days.

| Ticker | Rank | Model | RMSE | MAE | QLIKE | DM p vs best | DM p vs naive | Test window |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| URA.P | 1 | GARCH(1,1) | 2.0021 | 1.6766 | 1.4548 | - | 0.110 | 2026-01-15 to 2026-10-09 (n=185) |
| URA.P | 2 | Naive: 22-day mean |r| | 2.0449 | 1.7098 | 1.5435 | 0.110 | - | 2026-01-15 to 2026-10-09 (n=185) |
| URA.P | 3 | Stochastic volatility | 2.0758 | 1.6216 | 2.0246 | 0.107 | 0.561 | 2026-01-15 to 2026-10-09 (n=185) |
| URA.P | 4 | XGBoost hybrid | 2.0787 | 1.6600 | 1.9020 | 0.051 | 0.514 | 2026-01-15 to 2026-10-09 (n=185) |
| XAG= | 1 | Naive: 22-day mean |r| | 3.1790 | 1.9474 | 1.8191 | - | - | 2026-01-15 to 2026-10-09 (n=191) |
| XAG= | 2 | GARCH(1,1) | 3.2126 | 1.9779 | 2.0069 | 0.537 | 0.537 | 2026-01-15 to 2026-10-09 (n=191) |
| XAG= | 3 | Stochastic volatility | 3.2206 | 1.8438 | 2.6191 | 0.664 | 0.664 | 2026-01-15 to 2026-10-09 (n=191) |
| XAG= | 4 | XGBoost hybrid | 3.6690 | 2.2314 | 2.2275 | 0.049 | 0.049 | 2026-01-15 to 2026-10-09 (n=191) |
| XAU= | 1 | GARCH(1,1) | 1.2578 | 0.8660 | 1.9876 | - | 0.097 | 2026-01-15 to 2026-10-09 (n=191) |
| XAU= | 2 | Stochastic volatility | 1.2630 | 0.8585 | 2.1718 | 0.668 | 0.133 | 2026-01-15 to 2026-10-09 (n=191) |
| XAU= | 3 | Naive: 22-day mean |r| | 1.3090 | 0.9194 | 2.0254 | 0.097 | - | 2026-01-15 to 2026-10-09 (n=191) |
| XAU= | 4 | XGBoost hybrid | 1.3685 | 0.9437 | 2.8164 | 0.028 | 0.108 | 2026-01-15 to 2026-10-09 (n=191) |

Chart: `PHOTOS/EVENT_STUDY/HFD_OOS_Model_Comparison.png`, `LFD_OOS_Model_Comparison.png`.

## 4. HFD XGBoost feature importance (final refit)

| Ticker | Feature | Gain | Cover | Frequency |
| --- | --- | --- | --- | --- |
| URA.P | RV_Monthly | 0.5172 | 0.3925 | 0.2905 |
| URA.P | RV_Weekly | 0.1866 | 0.2323 | 0.2669 |
| URA.P | RV_Daily | 0.1556 | 0.2077 | 0.2838 |
| URA.P | RG_Sigma | 0.1406 | 0.1674 | 0.1588 |
| XAG= | RV_Weekly | 0.6847 | 0.5817 | 0.4737 |
| XAG= | RV_Daily | 0.1978 | 0.2471 | 0.2632 |
| XAG= | RV_Monthly | 0.0719 | 0.0456 | 0.1579 |
| XAG= | RG_Sigma | 0.0456 | 0.1255 | 0.1053 |
| XAU= | RV_Weekly | 0.4134 | 0.3973 | 0.3571 |
| XAU= | RV_Daily | 0.4054 | 0.2595 | 0.2857 |
| XAU= | RG_Sigma | 0.1042 | 0.1703 | 0.1429 |
| XAU= | RV_Monthly | 0.0770 | 0.1730 | 0.2143 |

## 5. LFD XGBoost feature importance (final refit)

| Ticker | Feature | Gain | Cover | Frequency |
| --- | --- | --- | --- | --- |
| XAU= | Abs_Return | 0.2668 | 0.2084 | 0.2725 |
| XAU= | Vol_Monthly | 0.2316 | 0.2431 | 0.2176 |
| XAU= | Vol_Weekly | 0.2232 | 0.2118 | 0.2154 |
| XAU= | GARCH_Sigma | 0.1688 | 0.1746 | 0.1670 |
| XAU= | SV_Vol | 0.1097 | 0.1621 | 0.1275 |
| XAG= | Vol_Monthly | 0.3023 | 0.3561 | 0.2144 |
| XAG= | Vol_Weekly | 0.2651 | 0.1611 | 0.2072 |
| XAG= | Abs_Return | 0.2047 | 0.2023 | 0.2865 |
| XAG= | GARCH_Sigma | 0.1178 | 0.1628 | 0.1369 |
| XAG= | SV_Vol | 0.1101 | 0.1177 | 0.1550 |
| URA.P | GARCH_Sigma | 0.3899 | 0.4265 | 0.2927 |
| URA.P | Vol_Weekly | 0.2378 | 0.2084 | 0.2195 |
| URA.P | Vol_Monthly | 0.2102 | 0.2006 | 0.2154 |
| URA.P | SV_Vol | 0.0906 | 0.0911 | 0.1423 |
| URA.P | Abs_Return | 0.0715 | 0.0733 | 0.1301 |

## Notes and limitations

- The event study is descriptive: a change in volatility after the event date is consistent with, but does not prove, a causal effect of the conflict (other news falls in the same window).
- The HFD sample covers only a few weeks, so the HFD test window has few days and the DM tests have little power. Treat HFD rankings as indicative.
- The uranium proxy is an exchange-traded instrument (see `STAGE1/LSEG_DATA_EXTRACTION.py`, URANIUM_CANDIDATES); it trades only in its exchange session and, for an ETF of miners, also carries equity-market risk.
- Full tables: `Pipeline_Outputs/Conclusive_Results/CONCLUSIVE_MODEL_DIAGNOSTICS.xlsx`.
