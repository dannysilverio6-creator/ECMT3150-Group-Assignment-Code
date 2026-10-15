# ==============================================================================
# Script Name: LFD_SV_MODEL.R
# Pipeline Stage: Stage 2 - Low-Frequency Stochastic Volatility Modeling
# Description: Fits Bayesian Stochastic Volatility (SV) models to daily returns
#              using MCMC (stochvol), generates diagnostic dashboards for latent
#              volatility, and evaluates one-day-ahead out-of-sample volatility
#              forecasts on the common LFD test window.
#
# Out-of-sample design: SV parameters are estimated on the training sample
# only; a particle filter with those parameters then produces one-step-ahead
# predictive volatility E[exp(h_{t+1}/2) | returns up to day t].
#
# Outputs (ECMT3150 OUTPUTS/Pipeline_Outputs/):
#   RDS_Models/LFD_SV.rds
#   Model_Tables/LFD_SV/{summary,oos_metrics,oos_forecasts}.csv
#   PNG_Plots/LFD_SV/LFD_SV_Diagnostics_<ticker>.png
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
ecmt_require(c("readxl", "dplyr", "zoo", "forecast", "ggplot2", "patchwork", "stochvol"))
MODEL_KEY <- "LFD_SV"
dirs <- ecmt_model_dirs(MODEL_KEY)

# ---- 2. Locate and read the LFD workbook --------------------------------------
target_file <- ecmt_find_lseg_workbook("LFD")
cat("\n======================================================\n")
cat("Located LFD File  :", target_file, "\n")
cat("======================================================\n\n")

log_returns <- ecmt_read_lfd_returns(target_file)
company_columns <- ecmt_lfd_tickers(log_returns)

sv_results <- list()
summary_rows <- list()
metric_rows <- list()
forecast_rows <- list()
cf_rows <- list()
options(device.ask.default = FALSE)

# ---- 3. Master processing loop across tickers -----------------------------------
for (company in company_columns) {
  cat("\n------------------------------------------------------\n")
  cat("Processing LFD SV for Ticker:", company, "\n")
  cat("------------------------------------------------------\n")

  keep <- !is.na(log_returns[[company]])
  dates <- log_returns$Date[keep]
  period <- log_returns$Period[keep]
  ret_series <- as.numeric(log_returns[[company]][keep]) * 100

  if (length(ret_series) < 50) {
    cat("Insufficient observations for", company, "(< 50) - skipping...\n")
    next
  }

  # 3a. Full-sample fit (mean-centred returns, standard for baseline SV)
  ret_centered <- ret_series - mean(ret_series)
  cat("Estimating full-sample SV model via MCMC...\n")
  set.seed(ECMT_SEED)
  sv_fit <- try(svsample(ret_centered, quiet = TRUE), silent = TRUE)
  if (inherits(sv_fit, "try-error")) {
    cat("SV estimation failed for", company, "- skipping...\n")
    next
  }

  # Posterior medians of latent volatility exp(h_t / 2)
  vol_est <- apply(exp(ecmt_draws(sv_fit$latent) / 2), 2, median)
  std_resids <- ret_centered / vol_est

  # 30-day volatility forecast
  sv_fc <- predict(sv_fit, steps = 30)
  h_fc <- exp(ecmt_draws(sv_fc$h) / 2)
  vol_fc_mean <- apply(h_fc, 2, mean)
  vol_fc_lower <- apply(h_fc, 2, quantile, probs = 0.05)
  vol_fc_upper <- apply(h_fc, 2, quantile, probs = 0.95)

  # 3b. Event-study forecasts (Frozen / Adaptive, see ECMT3150_COMMON.R).
  # SV parameters are estimated on returns up to each origin; the particle
  # filter then gives one-step-ahead predictive volatility. Re-estimations use
  # a shorter MCMC chain to keep run time low.
  frame <- ecmt_lfd_frame(dates, ret_series, period)
  split <- ecmt_event_split(frame, "LFD")
  cat("Estimating event-study SV forecasts (frozen + adaptive)...\n")
  vol_fc <- ecmt_event_forecasts(
    frame, split, ECMT_REFIT_EVERY_LFD,
    fit_fun = function(est_n) {
      centre <- mean(ret_series[1:est_n])
      set.seed(ECMT_SEED)
      f <- svsample(ret_series[1:est_n] - centre, draws = 3000, burnin = 1000, quiet = TRUE)
      list(theta = ecmt_sv_params(f), centre = centre)
    },
    forecast_fun = function(p, rows) {
      last <- max(frame$Row_Index[rows]) + 1
      pv <- ecmt_sv_predictive_vol(ret_series[1:last] - p$centre,
                                   p$theta[["mu"]], p$theta[["phi"]], p$theta[["sigma"]])
      pv[frame$Row_Index[rows] + 1]
    }
  )
  oos <- lapply(vol_fc, function(s) sqrt(2 / pi) * s)
  res <- ecmt_collect_schemes(oos, "LFD_SV", company, frame, split,
                              "Target_Vol", "Next-day |return| (%)")
  metric_rows[[company]] <- res$metrics
  forecast_rows[[company]] <- res$forecasts
  ecmt_print_oos(res)

  # 3b'. "No-conflict" counterfactual: SV estimated on pre-event returns only,
  # predicting the latent volatility path over the whole post-event period.
  # The posterior predictive gives a 90% band for the counterfactual path.
  n_pre <- ecmt_pre_event_n(dates); n_post <- length(ret_series) - n_pre
  if (n_post > 0) {
    centre <- mean(ret_series[1:n_pre])
    set.seed(ECMT_SEED)
    sv_pre <- try(svsample(ret_series[1:n_pre] - centre, quiet = TRUE), silent = TRUE)
    if (!inherits(sv_pre, "try-error")) {
      h_cf <- exp(ecmt_draws(predict(sv_pre, steps = n_post)$h) / 2)
      cf_rows[[company]] <- data.frame(
        Model = "LFD_SV", Ticker = company, Date = dates[(n_pre + 1):length(dates)],
        Horizon = seq_len(n_post),
        # E[sigma_t^2]^(1/2): comparable with the GARCH sigma path
        CF_Sigma = sqrt(apply(h_cf^2, 2, mean)),
        CF_Sigma_Lower90 = apply(h_cf, 2, quantile, 0.05),
        CF_Sigma_Upper90 = apply(h_cf, 2, quantile, 0.95),
        Realized_Return = ret_series[(n_pre + 1):length(ret_series)] - centre,
        Distribution = "normal", stringsAsFactors = FALSE)
    }
  }

  # 3c. Diagnostic dashboard
  df_p1 <- data.frame(Date = dates, Return = ret_centered)
  p1 <- ggplot(df_p1, aes(x = Date, y = Return)) +
    geom_line(color = "gray50", linewidth = 0.5) +
    theme_minimal(base_size = 11) +
    labs(title = "Mean-Centered Daily Returns (%)", x = "Date", y = "Return") +
    theme(plot.title = element_text(face = "bold", size = 11))

  df_p2 <- data.frame(Date = dates, Volatility = vol_est)
  p2 <- ggplot(df_p2, aes(x = Date, y = Volatility)) +
    geom_line(color = "darkred", linewidth = 0.8) +
    theme_minimal(base_size = 11) +
    labs(title = "Estimated Latent Volatility (Posterior Median)", x = "Date", y = "Volatility (%)") +
    theme(plot.title = element_text(face = "bold", size = 11))

  p3 <- ggAcf(std_resids^2, lag.max = 20) +
    theme_minimal(base_size = 11) +
    labs(title = "ACF of Squared Standardized Residuals", x = "Lag", y = "ACF") +
    theme(plot.title = element_text(face = "bold", size = 11))

  df_p4 <- data.frame(Day = seq_along(vol_fc_mean), Mean = vol_fc_mean,
                      Lower = vol_fc_lower, Upper = vol_fc_upper)
  p4 <- ggplot(df_p4, aes(x = Day, y = Mean)) +
    geom_ribbon(aes(ymin = Lower, ymax = Upper), fill = "darkblue", alpha = 0.2) +
    geom_line(color = "darkblue", linewidth = 1) +
    theme_minimal(base_size = 11) +
    labs(title = "30-Day Volatility Forecast (90% CI)", x = "Horizon (Days)", y = "Forecasted Volatility (%)") +
    theme(plot.title = element_text(face = "bold", size = 11))

  diagnostic_dashboard <- (p1 + p2) / (p3 + p4) +
    plot_annotation(
      title = paste("LFD Stochastic Volatility Diagnostics | Ticker:", company),
      theme = theme(plot.title = element_text(face = "bold", size = 14, hjust = 0.5))
    )
  png_path <- file.path(dirs$png, paste0("LFD_SV_Diagnostics_", ecmt_safe_name(company), ".png"))
  ggsave(png_path, diagnostic_dashboard, width = 12, height = 9, dpi = 150)

  # 3d. Parameter summary (full sample, posterior means)
  para_draws <- ecmt_draws(sv_fit$para)
  summary_rows[[company]] <- data.frame(
    Ticker = company,
    Mu_Mean = mean(para_draws[, "mu"]),
    Phi_Mean = mean(para_draws[, "phi"]),
    Sigma_Mean = mean(para_draws[, "sigma"]),
    Mean_30D_Vol_Forecast = mean(vol_fc_mean),
    N_Obs = length(ret_series),
    Sample_Start = format(min(dates)),
    Sample_End = format(max(dates)),
    stringsAsFactors = FALSE
  )

  # Only summaries are stored: the raw MCMC draws made LFD_SV.rds ~450 MB.
  sv_results[[company]] <- list(
    ticker = company,
    dates = dates,
    volatility = vol_est,
    forecast = data.frame(Day = seq_along(vol_fc_mean), Mean = vol_fc_mean,
                          Lower_5 = vol_fc_lower, Upper_95 = vol_fc_upper),
    # coda's summary() fails on SV's fixed parameters (nu = Inf, rho = 0),
    # so summarise the three estimated parameters directly.
    parameter_summary = t(apply(para_draws[, c("mu", "phi", "sigma")], 2, function(x)
      c(Mean = mean(x), SD = sd(x), Q2.5 = unname(quantile(x, 0.025)), Q97.5 = unname(quantile(x, 0.975))))),
    summary_df = summary_rows[[company]],
    oos_metrics = metric_rows[[company]],
    # One-step-ahead predictive volatility for every origin date (XGBoost feature)
    feature_series = data.frame(Date = frame$Date, SV_Vol_Frozen = vol_fc$Frozen,
                                SV_Vol_Adaptive = vol_fc$Adaptive),
    source_file = target_file
  )
}

# ---- 4. Save outputs -----------------------------------------------------------
if (length(sv_results) == 0) {
  stop("LFD SV produced no results for any ticker - nothing was saved.", call. = FALSE)
}

saveRDS(sv_results, file = dirs$rds)
ecmt_write_tables(dirs, list(
  summary       = dplyr::bind_rows(summary_rows),
  oos_metrics   = dplyr::bind_rows(metric_rows),
  oos_forecasts = dplyr::bind_rows(forecast_rows),
  counterfactual = dplyr::bind_rows(cf_rows)
))

cat("\n======================================================\n")
cat("LFD Stochastic Volatility Execution Complete!\n")
cat("RDS Output Saved   : ", dirs$rds, "\n")
cat("Plots Exported To  : ", dirs$png, "\n")
cat("======================================================\n")
