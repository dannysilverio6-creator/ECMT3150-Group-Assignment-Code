#!/usr/bin/env python3
# ==============================================================================
# Script Name: FINAL SUMMARY.py
# Pipeline Stage: Stage 4 (Orchestrator Step 8) - Executive Summary
# Description: Writes the Markdown report for the assignment from the verified
#              pipeline outputs:
#                1. Key findings (generated from the numbers below, not hand-written)
#                2. Event study: did volatility change after the strikes?
#                3. HFD and LFD model rankings by out-of-sample RMSE, with
#                   Diebold-Mariano tests against the best model and a naive
#                   baseline
#                4. XGBoost feature importance
#
# Inputs : Conclusive_Results/CONCLUSIVE_MODEL_DIAGNOSTICS.xlsx (Stage 4 diagnostic)
#          Model_Tables/EVENT_STUDY/*.csv, Model_Tables/<MODEL>/*.csv
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
NICE = {
    "HFD_XGBoost": "XGBoost hybrid", "HFD_Realised_GARCH": "Realised GARCH",
    "HFD_HAR-RV": "HAR-RV (log)", "HFD_Naive_RW": "Naive: RV(t)",
    "LFD_XGBoost": "XGBoost hybrid", "LFD_GARCH(1,1)": "GARCH(1,1)",
    "LFD_SV": "Stochastic volatility", "LFD_Naive_22D": "Naive: 22-day mean |r|",
}


def nice(model):
    return NICE.get(model, model)


def fmt(value, digits=4):
    if value is None or (isinstance(value, float) and not np.isfinite(value)):
        return "N/A"
    try:
        return f"{float(value):.{digits}f}"
    except (TypeError, ValueError):
        return str(value)


def fmt_p(p):
    if p is None or (isinstance(p, float) and not np.isfinite(p)):
        return "-"
    return "<0.001" if p < 0.001 else f"{p:.3f}"


def stars(p):
    if p is None or not np.isfinite(p):
        return ""
    return "***" if p < 0.01 else "**" if p < 0.05 else "*" if p < 0.10 else ""


def md_table(df):
    header = "| " + " | ".join(str(c) for c in df.columns) + " |"
    sep = "| " + " | ".join("---" for _ in df.columns) + " |"
    rows = ["| " + " | ".join("N/A" if pd.isna(x) else str(x) for x in r) + " |"
            for _, r in df.iterrows()]
    return "\n".join([header, sep] + rows)


def read_sheet(name):
    if not CONCLUSIVE.is_file():
        return None
    try:
        return pd.read_excel(CONCLUSIVE, sheet_name=name)
    except Exception:
        return None


def ranking_table(ranked, freq):
    rows = []
    sub = ranked[ranked["Frequency"] == freq].sort_values(["Ticker", "RMSE"])
    for _, r in sub.iterrows():
        rows.append({
            "Ticker": r["Ticker"],
            "Rank": int(r["Rank_RMSE"]),
            "Model": nice(r["Model"]),
            "RMSE": fmt(r["RMSE"]),
            "MAE": fmt(r["MAE"]),
            "QLIKE": fmt(r.get("QLIKE")),
            "DM p vs best": fmt_p(r.get("DM_p_vs_Best")),
            "DM p vs naive": fmt_p(r.get("DM_p_vs_Naive")),
            "Test window": f"{str(r['Test_Start'])[:10]} to {str(r['Test_End'])[:10]} (n={int(r['N_Test'])})",
        })
    return pd.DataFrame(rows)


def key_findings(lfd_ev, hfd_ev, eg, best):
    lines = []
    if lfd_ev is not None:
        for _, r in lfd_ev.iterrows():
            direction = "rose" if r["Vol_Ratio_W"] > 1 else "fell"
            w = int(r["Window_Days"])
            line = (f"**{r['Ticker']}** daily volatility {direction} from {r['Pre_W_Ann_Vol_pct']:.1f}% to "
                    f"{r['Post_W_Ann_Vol_pct']:.1f}% annualised comparing the {w} trading days before and "
                    f"after {r['Event_Date']} (x{r['Vol_Ratio_W']:.2f}; Brown-Forsythe p = "
                    f"{fmt_p(r['BrownForsythe_W_p'])}; full-sample ratio x{r['Vol_Ratio_Post_Pre']:.2f})")
            if eg is not None and r["Ticker"] in eg["Ticker"].values:
                e = eg[eg["Ticker"] == r["Ticker"]].iloc[0]
                sig = "significant" if e["Delta_p"] < 0.05 else "not significant"
                line += (f"; once volatility clustering is controlled for (EGARCH event dummy), the shift is "
                         f"{sig} at 5% (delta = {e['Delta_Post_Event']:.3f}, p = {fmt_p(e['Delta_p'])})")
            lines.append(line + ".")
    if hfd_ev is not None:
        for _, r in hfd_ev.iterrows():
            lines.append(f"**{r['Ticker']}** intraday realised volatility averaged {r['Mean_Daily_RV_Pre_pct']:.2f}% "
                         f"per day before the event and {r['Mean_Daily_RV_Post_pct']:.2f}% after "
                         f"(x{r['RV_Ratio_Post_Pre']:.2f}; Welch p = {fmt_p(r['Welch_t_logRV_p'])}; "
                         f"{int(r['N_Post_Days'])} post-event days).")
    if best is not None and not best.empty:
        for _, b in best.iterrows():
            p_ru = b.get("DM_p_Best_vs_Runner_Up")
            verdict = ("and the gap to the runner-up is statistically significant"
                       if isinstance(p_ru, float) and p_ru < 0.05 else
                       "but it is not statistically distinguishable from the runner-up")
            lines.append(f"{b['Frequency']} {b['Ticker']}: best forecaster is **{nice(b['Best_Model_Selected'])}** "
                         f"(RMSE {b['Best_RMSE']:.4f}) {verdict} (DM p = {fmt_p(p_ru)}).")
    return lines


def run_advanced_summary():
    print("======================================================")
    print("ECMT3150 Model Analysis & Executive Decision Engine")
    print("======================================================")
    print(P.describe() + "\n")

    best = read_sheet("Conclusive_Leaderboard")
    ranked = read_sheet("OOS_Ranking_All_Models")
    if ranked is None or ranked.empty:
        print(f"Error: no ranking found in {CONCLUSIVE}. Run STAGE4/DIAGNOSTIC.py first.")
        return False

    lfd_ev = P.read_model_table("EVENT_STUDY", "lfd_event_study")
    hfd_ev = P.read_model_table("EVENT_STUDY", "hfd_event_study")
    eg = P.read_model_table("EVENT_STUDY", "garch_event_dummy")
    hfd_imp = P.read_model_table("HFD_XGBOOST", "feature_importance")
    lfd_imp = P.read_model_table("LFD_XGBOOST", "feature_importance")

    out = P.FINAL_REPORT
    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "w", encoding="utf-8") as md:
        md.write("# ECMT3150 - Effects of the Iran conflict on commodity volatility\n\n")
        md.write(f"_Generated {datetime.now():%Y-%m-%d %H:%M} from the pipeline outputs. "
                 "Every number below is read from the output tables; nothing is typed by hand._\n\n")

        md.write("## Key findings\n\n")
        for line in key_findings(lfd_ev, hfd_ev, eg, best):
            md.write(f"- {line}\n")
        md.write("\n")

        md.write("## 1. Event study\n\n")
        if lfd_ev is not None and not lfd_ev.empty:
            w = int(lfd_ev["Window_Days"].iloc[0])
            t = pd.DataFrame({
                "Ticker": lfd_ev["Ticker"],
                f"Vol % {w}d before": lfd_ev["Pre_W_Ann_Vol_pct"].map(lambda v: fmt(v, 1)),
                f"Vol % {w}d after": lfd_ev["Post_W_Ann_Vol_pct"].map(lambda v: fmt(v, 1)),
                "Ratio": lfd_ev["Vol_Ratio_W"].map(lambda v: fmt(v, 2)),
                "BF p": lfd_ev["BrownForsythe_W_p"].map(fmt_p),
                "Full-sample ratio": lfd_ev["Vol_Ratio_Post_Pre"].map(lambda v: fmt(v, 2)),
                "Full-sample BF p": lfd_ev["BrownForsythe_p"].map(fmt_p),
                "Return first 5d %": lfd_ev["Post_5D_Return_pct"].map(lambda v: fmt(v, 2)),
                "Return first 20d %": lfd_ev["Post_20D_Return_pct"].map(lambda v: fmt(v, 2)),
                "Max |move| first 5d %": lfd_ev["Max_Abs_Move_First_5D_pct"].map(lambda v: fmt(v, 2)),
                "Obs pre / post": lfd_ev["N_Pre"].astype(str) + " / " + lfd_ev["N_Post"].astype(str),
            })
            md.write("### Daily data (LFD)\n\nVolatility is annualised (x sqrt(252)). BF = Brown-Forsythe "
                     "test of equal variances (robust to fat tails). Full-sample = all data since 2023 vs all "
                     "post-event data.\n\n" + md_table(t) + "\n\n")
        if eg is not None and not eg.empty:
            t = pd.DataFrame({
                "Ticker": eg["Ticker"],
                "delta (post-event)": eg.apply(lambda r: fmt(r["Delta_Post_Event"]) + stars(r["Delta_p"]), axis=1),
                "robust t": eg["Delta_t"].map(lambda v: fmt(v, 2)),
                "p": eg["Delta_p"].map(fmt_p),
                "beta": eg["Beta1"].map(lambda v: fmt(v, 3)),
                "Long-run vol multiplier": eg["LongRun_Vol_Multiplier"].map(lambda v: fmt(v, 2)),
                "t-dist df": eg["Student_t_df"].map(lambda v: fmt(v, 1)),
            })
            md.write("### EGARCH(1,1)-t with a post-event dummy in the log-variance equation\n\n"
                     "delta > 0 means higher conditional volatility after the event, controlling for "
                     "volatility clustering. Robust (QML) standard errors. "
                     "\\*/\\*\\*/\\*\\*\\* = 10/5/1% significance.\n\n" + md_table(t) + "\n\n")
        if hfd_ev is not None and not hfd_ev.empty:
            t = pd.DataFrame({
                "Ticker": hfd_ev["Ticker"],
                "Mean daily RV pre %": hfd_ev["Mean_Daily_RV_Pre_pct"].map(lambda v: fmt(v, 2)),
                "Mean daily RV post %": hfd_ev["Mean_Daily_RV_Post_pct"].map(lambda v: fmt(v, 2)),
                "Ratio": hfd_ev["RV_Ratio_Post_Pre"].map(lambda v: fmt(v, 2)),
                "Welch p (log RV)": hfd_ev["Welch_t_logRV_p"].map(fmt_p),
                "Week before %": hfd_ev["Mean_RV_Week_Before_pct"].map(lambda v: fmt(v, 2)),
                "First 5 days after %": hfd_ev["Mean_RV_First_5D_Post_pct"].map(lambda v: fmt(v, 2)),
                "Peak day": hfd_ev["Peak_Post_RV_Date"],
                "Days pre / post": hfd_ev["N_Pre_Days"].astype(str) + " / " + hfd_ev["N_Post_Days"].astype(str),
            })
            mins = int(hfd_ev["RV_Sampling_Minutes"].iloc[0]) if "RV_Sampling_Minutes" in hfd_ev else 5
            md.write(f"### Intraday data (HFD, daily realised volatility from {mins}-minute returns)\n\n"
                     + md_table(t) + "\n\n")
        md.write("Charts: `PHOTOS/EVENT_STUDY/LFD_Event_Volatility.png`, `HFD_Event_RV.png`.\n\n")

        md.write("## 2. Forecast comparison: high-frequency models\n\n"
                 "Target: next-day realised volatility (%). All models are re-estimated on an expanding "
                 "window and scored on the same test days. DM = Diebold-Mariano test (squared error, "
                 "HLN small-sample correction); a p-value below 0.05 means the difference in accuracy is "
                 "statistically significant.\n\n")
        md.write(md_table(ranking_table(ranked, "HFD")) + "\n\n")
        md.write("## 3. Forecast comparison: low-frequency models\n\n"
                 "Target: next-day absolute return (%). GARCH and SV volatility forecasts are converted "
                 "to E|r| = sqrt(2/pi) x sigma. Parameters re-estimated every 21 trading days.\n\n")
        md.write(md_table(ranking_table(ranked, "LFD")) + "\n\n")
        md.write("Chart: `PHOTOS/EVENT_STUDY/HFD_OOS_Model_Comparison.png`, `LFD_OOS_Model_Comparison.png`.\n\n")

        for title, imp in (("4. HFD XGBoost feature importance (final refit)", hfd_imp),
                           ("5. LFD XGBoost feature importance (final refit)", lfd_imp)):
            if imp is None or imp.empty:
                continue
            t = imp[[c for c in ["Ticker", "Feature", "Gain", "Cover", "Frequency"] if c in imp.columns]].copy()
            for c in ("Gain", "Cover", "Frequency"):
                if c in t.columns:
                    t[c] = t[c].map(fmt)
            md.write(f"## {title}\n\n" + md_table(t) + "\n\n")

        md.write("## Notes and limitations\n\n")
        md.write("- The event study is descriptive: a change in volatility after the event date is consistent "
                 "with, but does not prove, a causal effect of the conflict (other news falls in the same window).\n")
        md.write("- The HFD sample covers only a few weeks, so the HFD test window has few days and the DM tests "
                 "have little power. Treat HFD rankings as indicative.\n")
        md.write("- The uranium proxy is an exchange-traded instrument (see `STAGE1/LSEG_DATA_EXTRACTION.py`, "
                 "URANIUM_CANDIDATES); it trades only in its exchange session and, for an ETF of miners, also "
                 "carries equity-market risk.\n")
        md.write("- Full tables: `Pipeline_Outputs/Conclusive_Results/CONCLUSIVE_MODEL_DIAGNOSTICS.xlsx`.\n")

    print(f"Success! Report saved to: {out}\n")
    if best is not None and not best.empty:
        print(best[["Frequency", "Ticker", "Best_Model_Selected", "Best_RMSE"]].to_string(index=False))
    return True


if __name__ == "__main__":
    sys.exit(0 if run_advanced_summary() else 1)
