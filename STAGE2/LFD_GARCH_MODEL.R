# ==============================================================================
# Script Name: LFD_GARCH_MODEL.R
# Pipeline Stage: Stage 2 - Low-Frequency GARCH Volatility Modeling
# Description: Fits GARCH(1,1) on daily returns from LSEG_LFD.xlsx (Historical
#              + Event periods), exports ggplot2 diagnostic dashboards, and
#              evaluates genuine out-of-sample one-day-ahead volatility
#              forecasts on the common LFD test window.
#
# Outputs (ECMT3150 OUTPUTS/Pipeline_Outputs/):
#   RDS_Models/LFD_GARCH.rds
#   Model_Tables/LFD_GARCH/{summary,oos_metrics,oos_forecasts}.csv
#   PNG_Plots/LFD_GARCH/LFD_GARCH_Diagnostics_<ticker>.png
# ==============================================================================

# ---- 0. Locate the project folder and load the shared helpers ----------------
ECMT_PROJECT_ROOT <- local({
  starts <- Sys.getenv("ECMT3150_PROJECT_ROOT", "")
  file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
  if (length(file_arg) > 0) starts <- c(starts, dirname(gsub("~\\+~", " ", sub("^--file=", "", file_arg[1]))))
  ofile <- tryCatch(sys.frame(1)$ofile, error = function(e) NULL)
  if (!is.null(ofile)) starts <- c(starts, dirname(ofile))
  if (requireNamespace("rstudioapi", quietly = TRUE) && rstudioapi::isAvailable()) {
    p <- tryCatch(rstudioapi::getSourceEditorContext()$path, error = function(e) "")
    if (nzchar(p)) starts <- c(starts, dirname(p))
  }
  starts <- c(starts, getwd())
  root <- NULL
  for (s in starts[nzchar(starts)]) {
    d <- normalizePath(s, winslash = "/", mustWork = FALSE)
    for (i in 1:4) {
      if (file.exists(file.path(d, "ECMT3150_COMMON.R"))) { root <- d; break }
      d <- dirname(d)
    }
    if (!is.null(root)) break
  }
  if (is.null(root)) stop("Cannot find ECMT3150_COMMON.R - run this script from inside the project folder.")
  root
})
source(file.path(ECMT_PROJECT_ROOT, "ECMT3150_COMMON.R"))

# ---- 1. Packages and output folders ------------------------------------------
ecmt_require(c("readxl", "dplyr", "zoo", "rugarch", "forecast", "ggplot2", "patchwork"))
MODEL_KEY <- "LFD_GARCH"
dirs <- ecmt_model_dirs(MODEL_KEY)

# ---- 2. Locate and read the LFD workbook --------------------------------------
target_file <- ecmt_find_lseg_workbook("LFD")
cat("\n======================================================\n")
cat("Located LFD File  :", target_file, "\n")
cat("======================================================\n\n")

log_returns <- ecmt_read_lfd_returns(target_file)
company_columns <- ecmt_lfd_tickers(log_returns)

garch_spec <- ugarchspec(
  variance.model = list(model = "sGARCH", garchOrder = c(1, 1)),
  mean.model = list(armaOrder = c(0, 0), include.mean = TRUE),
  distribution.model = "norm"
)

garch_results <- list()
summary_rows <- list()
metric_rows <- list()
forecast_rows <- list()
options(device.ask.default = FALSE)

# ---- 3. Fit GARCH(1,1) for every ticker ----------------------------------------
for (company in company_columns) {
  cat("\nProcessing LFD GARCH Volatility for:", company, "...\n")

  keep <- !is.na(log_returns[[company]])
  dates <- log_returns$Date[keep]
  period <- log_returns$Period[keep]
  ret_pct <- as.numeric(log_returns[[company]][keep]) * 100

  if (length(ret_pct) < 50) {
    cat("Insufficient observations for", company, "- skipping...\n")
    next
  }

  # 3a. Full-sample fit (parameters, diagnostics, 30-day forecast)
  garch_fit <- try(ugarchfit(spec = garch_spec, data = ret_pct, solver = "hybrid"), silent = TRUE)
  if (inherits(garch_fit, "try-error") || convergence(garch_fit) != 0) {
    cat("GARCH convergence failed for", company, "\n")
    next
  }
  info_crit <- infocriteria(garch_fit)
  garch_fc <- ugarchforecast(garch_fit, n.ahead = 30)
  pred_vol <- as.numeric(sigma(garch_fc))

  # 3b. Out-of-sample evaluation on the common LFD frame (expanding window).
  # Parameters are re-estimated every ECMT_REFIT_EVERY_LFD test days using
  # returns up to that forecast origin only; the filter then gives sigma_{t+1}
  # from information up to day t.
  frame <- ecmt_lfd_frame(dates, ret_pct, period)
  is_test <- ecmt_test_rows(frame)
  blocks <- ecmt_refit_blocks(frame, is_test, ECMT_REFIT_EVERY_LFD)
  sigma_next <- ecmt_blocked_forecasts(
    frame, blocks,
    fit_fun = function(est_n) {
      f <- ugarchfit(spec = garch_spec, data = ret_pct[1:est_n], solver = "hybrid")
      if (convergence(f) != 0) NULL else coef(f)
    },
    forecast_fun = function(pars, rows) {
      fixed_spec <- garch_spec
      setfixed(fixed_spec) <- as.list(pars)
      last <- max(frame$Row_Index[rows]) + 1
      s_all <- as.numeric(sigma(ugarchfilter(fixed_spec, data = ret_pct[1:last])))
      s_all[frame$Row_Index[rows] + 1]
    }
  )
  if (any(is.finite(sigma_next[is_test]))) {
    # Under normality E|r| = sqrt(2/pi) * sigma, matching the |return| target.
    oos_forecast <- sqrt(2 / pi) * sigma_next
    metric_rows[[company]] <- cbind(
      ecmt_metrics_row("LFD_GARCH(1,1)", company, frame, is_test,
                       oos_forecast, "Target_Vol", "Next-day |return| (%)"),
      Refits = attr(sigma_next, "n_fits"), Refit_Failures = attr(sigma_next, "n_failed"))
    forecast_rows[[company]] <- ecmt_forecast_rows("LFD_GARCH(1,1)", company, frame, is_test,
                                                   oos_forecast, "Target_Vol")
    cat(sprintf("  OOS (%s to %s, n=%d, %d refits): RMSE = %.4f | MAE = %.4f\n",
                metric_rows[[company]]$Test_Start, metric_rows[[company]]$Test_End,
                metric_rows[[company]]$N_Test, attr(sigma_next, "n_fits"),
                metric_rows[[company]]$RMSE, metric_rows[[company]]$MAE))
  } else {
    cat("  GARCH could not be estimated on the training sample - no OOS forecasts for", company, "\n")
  }

  # 3c. Diagnostic dashboard
  df_p1 <- data.frame(Date = dates, Return = ret_pct)
  p1 <- ggplot(df_p1, aes(x = Date, y = Return)) +
    geom_line(color = "darkblue", linewidth = 0.5) +
    theme_minimal(base_size = 11) +
    labs(title = "Daily Returns Series", x = "Date", y = "Return (%)") +
    theme(plot.title = element_text(face = "bold", size = 11))

  cond_vol <- as.numeric(sigma(garch_fit))
  df_p2 <- data.frame(Date = dates, Volatility = cond_vol)
  p2 <- ggplot(df_p2, aes(x = Date, y = Volatility)) +
    geom_line(color = "darkred", linewidth = 1.0) +
    theme_minimal(base_size = 11) +
    labs(title = "GARCH Conditional Volatility Fit", x = "Date", y = "Volatility (%)") +
    theme(plot.title = element_text(face = "bold", size = 11))

  std_res <- as.numeric(residuals(garch_fit, standardize = TRUE))
  p3 <- ggAcf(std_res, lag.max = 20) +
    theme_minimal(base_size = 11) +
    labs(title = "Standardized Residual ACF", x = "Lag", y = "ACF") +
    theme(plot.title = element_text(face = "bold", size = 11))

  df_p4 <- data.frame(Horizon = seq_along(pred_vol), Volatility = pred_vol)
  p4 <- ggplot(df_p4, aes(x = Horizon, y = Volatility)) +
    geom_line(color = "darkred", linewidth = 1.2) +
    geom_point(color = "darkred", size = 2) +
    theme_minimal(base_size = 11) +
    labs(title = "30-Day Ahead Volatility Forecast", x = "Forecast Horizon (Days)", y = "Volatility (%)") +
    theme(plot.title = element_text(face = "bold", size = 11))

  diagnostic_dashboard <- (p1 + p2) / (p3 + p4) +
    plot_annotation(
      title = paste("LFD GARCH Model Diagnostics | Ticker:", company),
      theme = theme(plot.title = element_text(face = "bold", size = 14, hjust = 0.5))
    )
  png_path <- file.path(dirs$png, paste0("LFD_GARCH_Diagnostics_", ecmt_safe_name(company), ".png"))
  ggsave(png_path, diagnostic_dashboard, width = 12, height = 9, dpi = 150)

  # 3d. Coefficients & summary statistics (full sample)
  pars <- coef(garch_fit)
  summary_rows[[company]] <- data.frame(
    Ticker = company,
    Mu = unname(pars["mu"]),
    Omega = unname(pars["omega"]),
    Alpha1 = unname(pars["alpha1"]),
    Beta1 = unname(pars["beta1"]),
    Persistence = unname(pars["alpha1"] + pars["beta1"]),
    AIC = info_crit["Akaike", 1],
    BIC = info_crit["Bayes", 1],
    Mean_30D_Vol_Forecast = mean(pred_vol),
    N_Obs = length(ret_pct),
    Sample_Start = format(min(dates)),
    Sample_End = format(max(dates)),
    stringsAsFactors = FALSE
  )

  garch_results[[company]] <- list(
    ticker = company,
    fit = garch_fit,
    forecast = garch_fc,
    predicted_sigma = pred_vol,
    summary_df = summary_rows[[company]],
    oos_metrics = metric_rows[[company]],
    # One-step-ahead sigma for every origin date (used as an XGBoost feature)
    feature_series = data.frame(Date = frame$Date, GARCH_Sigma = sigma_next),
    source_file = target_file
  )
}

# ---- 4. Save outputs -----------------------------------------------------------
if (length(garch_results) == 0) {
  stop("LFD GARCH produced no results for any ticker - nothing was saved.", call. = FALSE)
}

saveRDS(garch_results, file = dirs$rds)
ecmt_write_tables(dirs, list(
  summary       = dplyr::bind_rows(summary_rows),
  oos_metrics   = dplyr::bind_rows(metric_rows),
  oos_forecasts = dplyr::bind_rows(forecast_rows)
))

cat("\n======================================================\n")
cat("LFD GARCH Execution Complete!\n")
cat("RDS Output Saved   : ", dirs$rds, "\n")
cat("Plots Exported To  : ", dirs$png, "\n")
cat("======================================================\n")
