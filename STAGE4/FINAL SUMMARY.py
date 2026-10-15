#!/usr/bin/env python3
# ==============================================================================
# Script Name: FINAL SUMMARY.py
# Pipeline Stage: Stage 4 (final step) - Event-study report
# Description: Writes the Markdown report answering the pipeline's questions:
#   Q1  Did commodity volatility change after the strikes on Iran?
#   Q2  Using models estimated BEFORE the event: was post-event volatility
#       abnormal relative to their "no-conflict" forecast path?
#   Q3  Which model forecasts volatility best through the shock, and do the
#       models hold up (accuracy vs calm markets, volatility-band coverage,
#       frozen vs re-estimated parameters)?
# Every number is read from the pipeline output tables; key findings are
# generated from those numbers, not typed by hand.
#
# Inputs : Model_Tables/EVENT_STUDY/*.csv, Conclusive_Results/CONCLUSIVE_MODEL_DIAGNOSTICS.xlsx
# Output : ECMT3150 OUTPUTS/ECMT3150_Final_Best_Model_Analysis.md
# ==============================================================================

import sys
from datetime import datetime
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import ecmt3150_paths as P  # noqa: E402

CONCLUSIVE = P.CONCLUSIVE_DIR / "CONCLUSIVE_MODEL_DIAGNOSTICS.xlsx"
SHOCK, PRE, POST = "Shock (days 1-5)", "Pre-event (calm)", "All post-event"
NICE = {
    "HFD_XGBoost": "XGBoost hybrid", "HFD_Realised_GARCH": "Realised GARCH",
    "HFD_HAR-RV": "HAR-RV (log)", "HFD_Naive_RW": "Naive RW",
    "LFD_XGBoost": "XGBoost hybrid", "LFD_GARCH(1,1)": "GARCH(1,1)",
    "LFD_SV": "Stochastic volatility", "LFD_Naive_22D": "Naive 22-day mean",
}


def nice(m):
    return NICE.get(m, m)


def isnum(v):
    return isinstance(v, (int, float, np.floating)) and np.isfinite(v)


def fmt(v, d=3):
    return f"{float(v):.{d}f}" if isnum(v) else "N/A"


def fmt_p(p):
    if not isnum(p):
        return "-"
    return "<0.001" if p < 0.001 else f"{p:.3f}"


def stars(p):
    if not isnum(p):
        return ""
    return "***" if p < 0.01 else "**" if p < 0.05 else "*" if p < 0.10 else ""


def md_table(df):
    if df is None or df.empty:
        return "_No results._"
    head = "| " + " | ".join(map(str, df.columns)) + " |"
    sep = "| " + " | ".join("---" for _ in df.columns) + " |"
    rows = ["| " + " | ".join("" if pd.isna(x) else str(x) for x in r) + " |" for _, r in df.iterrows()]
    return "\n".join([head, sep] + rows)


def sheet(name):
    try:
        return pd.read_excel(CONCLUSIVE, sheet_name=name)
    except Exception:
        return None


def es(name):
    return P.read_model_table("EVENT_STUDY", name)


# ------------------------------------------------------------------------------
# Key findings (generated from the tables)
# ------------------------------------------------------------------------------
def findings(lfd_ev, hfd_ev, eg, ab, rec, lead, fva):
    out = []
    if lfd_ev is not None:
        for _, r in lfd_ev.iterrows():
            e = eg[eg["Ticker"] == r["Ticker"]].iloc[0] if eg is not None and r["Ticker"] in eg["Ticker"].values else None
            w = int(r["Window_Days"])
            txt = (f"**{r['Ticker']} (daily):** volatility went from {r['Pre_W_Ann_Vol_pct']:.1f}% to "
                   f"{r['Post_W_Ann_Vol_pct']:.1f}% annualised ({w} days before vs after; x{r['Vol_Ratio_W']:.2f}, "
                   f"Brown-Forsythe p = {fmt_p(r['BrownForsythe_W_p'])})")
            if e is not None:
                txt += (f"; EGARCH event dummy delta = {e['Delta_Post_Event']:.3f}{stars(e['Delta_p'])} "
                        f"(p = {fmt_p(e['Delta_p'])})")
            out.append(txt + ".")
    if ab is not None and not ab.empty:
        for (freq, ticker), g in ab.sort_values("Frequency", ascending=False).groupby(["Frequency", "Ticker"], sort=False):
            parts = []
            for _, r in g[g["Window"].isin([SHOCK, POST])].iterrows():
                tag = "above" if r["Abnormal_Vol_Ratio"] > 1 else "below"
                parts.append(f"{nice(r['Model'])}, {r['Window'].split(' (')[0].lower()}: x{r['Abnormal_Vol_Ratio']:.2f} "
                             f"({tag}; p = {fmt_p(r['p_Two_Sided'])})")
            out.append(f"**{ticker} ({freq}) vs the pre-event no-conflict forecast:** " + "; ".join(parts) + ".")
    if rec is not None and not rec.empty:
        for _, r in rec[(rec["Recommended"] == "YES") & (rec["Scheme"] == "Adaptive")].iterrows():
            out.append(f"**Best {r['Frequency']} model through the event (adaptive, average post-event rank "
                       f"{r['Avg_Post_Rank']:.2f}):** {nice(r['Model'])}. Its error during the shock week was "
                       f"x{r['Shock_Error_Growth_x']:.2f} its calm pre-event error, and it averaged "
                       f"{r['Avg_RMSE_vs_Naive']:.2f} x the naive benchmark's RMSE.")
    if lead is not None and not lead.empty:
        sh = lead[(lead["Window"] == SHOCK) & (lead["Scheme"] == "Adaptive")]
        sig = int((sh["Significant_vs_Runner_Up_5%"] == "YES").sum())
        naive_wins = int(sh["Best_Model"].str.contains("Naive").sum())
        out.append(f"In the shock week the winning model was significantly better than the runner-up for "
                   f"{sig} of {len(sh)} instrument-frequency pairs; the naive benchmark won {naive_wins} of them.")
    if fva is not None and "Adaptive_vs_Frozen_RMSE_%" in fva:
        p = fva[fva["Window"] == POST]
        if not p.empty:
            out.append(f"Re-estimating through the event changed post-event RMSE by "
                       f"{p['Adaptive_vs_Frozen_RMSE_%'].median():+.1f}% (median across models and instruments; "
                       f"negative = re-estimation helps).")
    return out


def main():
    print("======================================================")
    print(" ECMT3150 Event-Study Report")
    print("======================================================")
    print(P.describe() + "\n")
    if not CONCLUSIVE.is_file():
        print(f"Error: {CONCLUSIVE} not found. Run STAGE4/DIAGNOSTIC.py first.")
        return False

    lfd_ev, hfd_ev, eg, ab, wm = (es("lfd_event_study"), es("hfd_event_study"), es("garch_event_dummy"),
                                  es("abnormal_volatility"), es("window_metrics"))
    rec, lead, robust, fva = (sheet("Model_Recommendation"), sheet("Window_Leaderboard"),
                              sheet("Robustness_By_Window"), sheet("Frozen_vs_Adaptive"))
    if wm is None:
        print("Error: event-study window metrics missing. Run STAGE4/EVENT_STUDY.R first.")
        return False

    event_date = lfd_ev["Event_Date"].iloc[0] if lfd_ev is not None else "2026-03-02"
    out = P.FINAL_REPORT
    with open(out, "w", encoding="utf-8") as md:
        w = md.write
        w("# ECMT3150 - Modelling commodity volatility through the Iran conflict\n\n")
        w(f"_Generated {datetime.now():%Y-%m-%d %H:%M} from the pipeline outputs; every number below is read "
          "from the output tables._\n\n")
        w("## Design\n\n")
        w(f"- **Event date:** {event_date} (first trading day after the strikes of 28 Feb 2026).\n")
        w("- **Estimation:** models are estimated only with data before each forecast origin. The **Frozen** "
          "scheme fixes parameters at the event (estimated on calm, pre-event data only) and never updates "
          "them; the **Adaptive** scheme re-estimates on an expanding window as post-event data arrive "
          "(daily data every 21 trading days, intraday models every day).\n")
        w("- **Evaluation windows:** a calm pre-event window (out-of-sample, last 60 trading days for daily "
          "data / 5 days for intraday) as the benchmark of normal accuracy, then the shock week (days 1-5) "
          "and later post-event windows.\n")
        w("- **Targets:** daily models forecast next-day |return|; intraday models forecast next-day realised "
          "volatility from 5-minute returns. Naive benchmarks: 22-day mean |return| (daily), random walk RV "
          "(intraday).\n\n")

        w("## Key findings\n\n")
        for line in findings(lfd_ev, hfd_ev, eg, ab, rec, lead, fva):
            w(f"- {line}\n")
        w("\n")

        # ---------------- Q1 ----------------
        w("## Q1. Did volatility change after the event?\n\n")
        if lfd_ev is not None:
            win = int(lfd_ev["Window_Days"].iloc[0])
            t = pd.DataFrame({
                "Ticker": lfd_ev["Ticker"],
                f"Vol % {win}d before": lfd_ev["Pre_W_Ann_Vol_pct"].map(lambda v: fmt(v, 1)),
                f"Vol % {win}d after": lfd_ev["Post_W_Ann_Vol_pct"].map(lambda v: fmt(v, 1)),
                "Ratio": lfd_ev["Vol_Ratio_W"].map(lambda v: fmt(v, 2)),
                "BF p": lfd_ev["BrownForsythe_W_p"].map(fmt_p),
                "Full-sample ratio": lfd_ev["Vol_Ratio_Post_Pre"].map(lambda v: fmt(v, 2)),
                "Return 5d %": lfd_ev["Post_5D_Return_pct"].map(lambda v: fmt(v, 2)),
                "Return 20d %": lfd_ev["Post_20D_Return_pct"].map(lambda v: fmt(v, 2)),
                "Max abs move 5d %": lfd_ev["Max_Abs_Move_First_5D_pct"].map(lambda v: fmt(v, 2)),
            })
            w("**Daily data.** Annualised volatility; BF = Brown-Forsythe test of equal variances.\n\n" + md_table(t) + "\n\n")
        if eg is not None:
            t = pd.DataFrame({
                "Ticker": eg["Ticker"],
                "delta": eg.apply(lambda r: fmt(r["Delta_Post_Event"], 4) + stars(r["Delta_p"]), axis=1),
                "robust t": eg["Delta_t"].map(lambda v: fmt(v, 2)), "p": eg["Delta_p"].map(fmt_p),
                "beta": eg["Beta1"].map(lambda v: fmt(v, 3)),
                "Long-run vol multiplier": eg["LongRun_Vol_Multiplier"].map(lambda v: fmt(v, 2)),
            })
            w("**EGARCH(1,1)-t with a post-event dummy in the log-variance equation** (delta > 0 = higher "
              "volatility after the event, controlling for clustering; QML robust SEs; "
              "\\*/\\*\\*/\\*\\*\\* = 10/5/1%).\n\n" + md_table(t) + "\n\n")
        if hfd_ev is not None:
            t = pd.DataFrame({
                "Ticker": hfd_ev["Ticker"],
                "Mean RV pre %": hfd_ev["Mean_Daily_RV_Pre_pct"].map(lambda v: fmt(v, 2)),
                "Mean RV post %": hfd_ev["Mean_Daily_RV_Post_pct"].map(lambda v: fmt(v, 2)),
                "Ratio": hfd_ev["RV_Ratio_Post_Pre"].map(lambda v: fmt(v, 2)),
                "Welch p (log RV)": hfd_ev["Welch_t_logRV_p"].map(fmt_p),
                "Week before %": hfd_ev["Mean_RV_Week_Before_pct"].map(lambda v: fmt(v, 2)),
                "First 5 days %": hfd_ev["Mean_RV_First_5D_Post_pct"].map(lambda v: fmt(v, 2)),
                "Peak day": hfd_ev["Peak_Post_RV_Date"],
            })
            w("**Intraday data** (daily realised volatility from 5-minute returns).\n\n" + md_table(t) + "\n\n")

        # ---------------- Q2 ----------------
        w("## Q2. Was post-event volatility abnormal relative to the pre-event models?\n\n")
        w("Each econometric model is estimated on pre-event data only and forecasts the whole post-event "
          "period from the event date without seeing any post-event data (the no-conflict counterfactual). "
          "Ratio = realised / counterfactual volatility; > 1 means the market was more volatile than the "
          "pre-event model expected. Tests: returns-based models use sum (r / sigma_cf)^2 ~ chi2(n); HAR-RV "
          "uses the mean standardised log-RV surprise. p-values are two-sided.\n\n")
        if ab is not None and not ab.empty:
            t = ab.copy()
            t = pd.DataFrame({
                "Freq": t["Frequency"], "Ticker": t["Ticker"], "Model": t["Model"].map(nice), "Window": t["Window"],
                "Days": t["N"], "Realised vol": t["Realized_Vol"].map(lambda v: fmt(v, 2)),
                "Counterfactual vol": t["Counterfactual_Vol"].map(lambda v: fmt(v, 2)),
                "Ratio": t.apply(lambda r: fmt(r["Abnormal_Vol_Ratio"], 2) + stars(r["p_Two_Sided"]), axis=1),
                "p": t["p_Two_Sided"].map(fmt_p),
            })
            w(md_table(t) + "\n\n")
        w("Charts: `PHOTOS/EVENT_STUDY/LFD_Counterfactual_Volatility.png`, `HFD_Counterfactual_Volatility.png` "
          "(includes cumulative abnormal volatility).\n\n")

        # ---------------- Q3 ----------------
        w("## Q3. Which model handles the disruption best, and do they hold up?\n\n")
        if rec is not None and not rec.empty:
            t = pd.DataFrame({
                "Freq": rec["Frequency"], "Scheme": rec["Scheme"], "Model": rec["Model"].map(nice),
                "Avg post-event rank": rec["Avg_Post_Rank"].map(lambda v: fmt(v, 2)),
                "Calm rank": rec["Calm_Rank"].map(lambda v: fmt(v, 2)),
                "Shock rank": rec["Shock_Rank"].map(lambda v: fmt(v, 2)),
                "RMSE / naive": rec["Avg_RMSE_vs_Naive"].map(lambda v: fmt(v, 2)),
                "Shock error / calm error": rec["Shock_Error_Growth_x"].map(lambda v: fmt(v, 2)),
                "95% band exceed (post)": rec["Post_Band95_Exceed"].map(lambda v: fmt(v, 3)),
                "Kupiec rejections": rec["Post_Band_Rejections"],
                "Recommended": rec["Recommended"].fillna(""),
            })
            w("**Robustness ranking** (averaged across instruments; rank 1 = most accurate, naive included in "
              "the ranking). 'Shock error / calm error' > 1 means accuracy deteriorated in the shock week. "
              "A well-calibrated 95% band is exceeded about 5% of the time; Kupiec rejections count "
              "instruments where the exceedance rate differs significantly from 5%.\n\n" + md_table(t) + "\n\n")
        if lead is not None and not lead.empty:
            t = lead[lead["Scheme"] == "Adaptive"]
            t = pd.DataFrame({
                "Freq": t["Frequency"], "Ticker": t["Ticker"], "Window": t["Window"],
                "Best model": t["Best_Model"].map(nice), "RMSE": t["Best_RMSE"].map(lambda v: fmt(v, 3)),
                "RMSE / naive": t["Best_RMSE_vs_Naive"].map(lambda v: fmt(v, 2)),
                "Runner-up": t["Runner_Up"].map(nice), "DM p vs runner-up": t["DM_p_Best_vs_Runner_Up"].map(fmt_p),
                "Days": t["N"],
            })
            w("**Best model by window** (adaptive scheme; DM = Diebold-Mariano test, HLN correction).\n\n"
              + md_table(t) + "\n\n")
        sub = wm[(wm["Scheme"] == "Adaptive") & (~wm["Model"].str.contains("Naive"))]
        if not sub.empty:
            piv = sub.pivot_table(index=["Frequency", "Ticker", "Model"], columns="Window",
                                  values="RMSE_vs_Naive").reset_index()
            cols = ["Frequency", "Ticker", "Model"] + [c for c in
                    ["Pre-event (calm)", "Shock (days 1-5)", "Short run (6-20)", "Medium run (21-60)",
                     "Long run (61+)", "Aftermath (6+)", "All post-event"] if c in piv.columns]
            piv = piv[cols]
            piv["Model"] = piv["Model"].map(nice)
            for c in cols[3:]:
                piv[c] = piv[c].map(lambda v: fmt(v, 2))
            w("**RMSE relative to the naive benchmark, window by window** (adaptive scheme; < 1 = beats "
              "naive).\n\n" + md_table(piv) + "\n\n")
        if fva is not None and not fva.empty and "Adaptive_vs_Frozen_RMSE_%" in fva:
            t = fva.copy()
            t = pd.DataFrame({"Freq": t["Frequency"], "Ticker": t["Ticker"], "Model": t["Model"].map(nice),
                              "Window": t["Window"], "Frozen RMSE": t["Frozen"].map(lambda v: fmt(v, 3)),
                              "Adaptive RMSE": t["Adaptive"].map(lambda v: fmt(v, 3)),
                              "Change %": t["Adaptive_vs_Frozen_RMSE_%"].map(lambda v: fmt(v, 1))})
            w("**Frozen vs adaptive:** does re-estimating through the event help? (negative change = "
              "adaptive more accurate)\n\n" + md_table(t) + "\n\n")
        w("Charts: `PHOTOS/EVENT_STUDY/LFD_Accuracy_By_Window.png`, `HFD_Accuracy_By_Window.png`, "
          "`LFD_OOS_Model_Comparison.png`, `HFD_OOS_Model_Comparison.png`.\n\n")

        w("## Notes and limitations\n\n")
        w("- The event study is descriptive: other news in the same window (e.g. the January 2026 precious-metals "
          "sell-off) also moves volatility, so a change after the event date is consistent with, but does not "
          "prove, a causal effect of the conflict.\n")
        w("- The intraday sample ends 10 trading days after the event, so intraday windows contain 5 days each and "
          "DM / Kupiec tests have little power there; daily results are the more reliable evidence.\n")
        w("- Counterfactual paths are multi-step forecasts; for HAR-RV the test uses the one-step residual "
          "standard deviation, which understates multi-step uncertainty (so it over-rejects).\n")
        w("- Full tables: `Pipeline_Outputs/Conclusive_Results/CONCLUSIVE_MODEL_DIAGNOSTICS.xlsx`.\n")

    print(f"Report saved to: {out}")
    return True


if __name__ == "__main__":
    sys.exit(0 if main() else 1)
