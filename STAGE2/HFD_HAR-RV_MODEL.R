# ==============================================================================
# Script Name: HFD_HAR-RV_MODEL.R
# Pipeline Stage: Stage 2 - High-Frequency Volatility Pipeline (HAR-RV Model)
# Description: Reads the intraday data in LSEG_HFD.xlsx (Historical CSV + Event
#              CSV sheets), aggregates intraday returns to daily Realized
#              Volatility, fits a Heterogeneous Autoregressive (HAR-RV) model
#              with Daily, Weekly and Monthly components, outputs ggplot2 /
#              patchwork dashboards, and evaluates one-day-ahead
#              out-of-sample forecasts on the common HFD test window.
#
# Outputs (ECMT3150 OUTPUTS/Pipeline_Outputs/):
#   RDS_Models/HFD_HARRV.rds
#   Model_Tables/HFD_HARRV/{summary,oos_metrics,oos_forecasts}.csv
#   PNG_Plots/HFD_HARRV/HFD_HARRV_Diagnostics_<ticker>.png
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
ecmt_require(c("readxl", "dplyr", "zoo", "ggplot2", "patchwork"))
MODEL_KEY <- "HFD_HARRV"
dirs <- ecmt_model_dirs(MODEL_KEY)

# ---- 2. Locate and read the HFD workbook --------------------------------------
target_file <- ecmt_find_lseg_workbook("HFD")
cat("\n======================================================\n")
cat("Located HFD File :", target_file, "\n")
cat("======================================================\n\n")

hfd_raw <- ecmt_read_hfd_long(target_file)

unique_rics <- unique(hfd_raw$RIC)
all_harrv_results <- list()
summary_rows <- list()
metric_rows <- list()
forecast_rows <- list()
options(device.ask.default = FALSE)

# ---- 3. Master loop ------------------------------------------------------------
for (current_ric in unique_rics) {
  cat("\n------------------------------------------------------\n")
  cat("Processing HAR-RV for Ticker:", current_ric, "\n")
  cat("------------------------------------------------------\n")

  df_ticker <- hfd_raw[hfd_raw$RIC == current_ric, , drop = FALSE]
  if (nrow(df_ticker) < 50) {
    cat("Insufficient high-frequency observations for", current_ric, "- skipping...\n")
    next
  }

  # Intraday -> daily realised volatility, then HAR components (shared design)
  daily_data <- ecmt_daily_realised(df_ticker)
  if (nrow(daily_data) < 30) {
    cat("Insufficient daily aggregated observations (N < 30) for HAR-RV on", current_ric, "- skipping...\n")
    next
  }
  har_data <- ecmt_hfd_frame(daily_data)
  if (nrow(har_data) < 10) {
    cat("Insufficient data points after HAR-RV window rolling for", current_ric, "- skipping...\n")
    next
  }

  # Full-sample HAR-RV (coefficients and diagnostics)
  cat("Estimating HAR-RV model for", current_ric, "...\n")
  har_fit <- try(lm(RV_Target ~ RV_Daily + RV_Weekly + RV_Monthly, data = har_data), silent = TRUE)
  if (inherits(har_fit, "try-error")) {
    cat("Failed to fit HAR-RV model for", current_ric, "\n")
    next
  }
  har_data$Predicted_RV <- predict(har_fit)
  har_data$Residuals <- residuals(har_fit)
  pars <- coef(har_fit)
  summary_fit <- summary(har_fit)
  r_squared <- summary_fit$r.squared
  adj_r_squared <- summary_fit$adj.r.squared

  cat("Fit complete: \n",
      " Intercept =", round(pars["(Intercept)"], 4), "\n",
      " Beta_Daily =", round(pars["RV_Daily"], 4), "\n",
      " Beta_Weekly =", round(pars["RV_Weekly"], 4), "\n",
      " Beta_Monthly =", round(pars["RV_Monthly"], 4), "\n",
      " R-Squared =", round(r_squared, 4), "\n")

  # Out-of-sample, expanding window: re-estimate on every row whose target is
  # known at the forecast origin, then forecast the next block.
  # The regression is estimated in logs (log-HAR, Corsi 2009) - realised
  # volatility is strongly right-skewed and a levels HAR can forecast NEGATIVE
  # volatility in small samples. Forecasts are mapped back with the lognormal
  # bias correction exp(mu + s^2 / 2).
  is_test <- ecmt_test_rows(har_data)
  blocks <- ecmt_refit_blocks(har_data, is_test, ECMT_REFIT_EVERY_HFD)
  oos_forecast <- ecmt_blocked_forecasts(
    har_data, blocks,
    fit_fun = function(est_n) {
      lm(log(RV_Target) ~ log(RV_Daily) + log(RV_Weekly) + log(RV_Monthly),
         data = har_data[har_data$Row_Index + 1 <= est_n, ])
    },
    forecast_fun = function(m, rows) {
      exp(as.numeric(predict(m, newdata = har_data[rows, ])) + summary(m)$sigma^2 / 2)
    }
  )
  train_fit <- lm(log(RV_Target) ~ log(RV_Daily) + log(RV_Weekly) + log(RV_Monthly),
                  data = har_data[!is_test, ])
  metric_rows[[current_ric]] <- cbind(
    ecmt_metrics_row("HFD_HAR-RV", current_ric, har_data, is_test,
                     oos_forecast, "RV_Target", "Next-day realised volatility (%)"),
    OOS_Specification = "log-HAR", Refits = attr(oos_forecast, "n_fits"))
  forecast_rows[[current_ric]] <- ecmt_forecast_rows("HFD_HAR-RV", current_ric, har_data, is_test,
                                                     oos_forecast, "RV_Target")
  cat(sprintf("  OOS (%s to %s, n=%d): RMSE = %.4f | MAE = %.4f\n",
              metric_rows[[current_ric]]$Test_Start, metric_rows[[current_ric]]$Test_End,
              metric_rows[[current_ric]]$N_Test, metric_rows[[current_ric]]$RMSE, metric_rows[[current_ric]]$MAE))

  # ---- Diagnostic dashboard ----
  max_y <- max(c(har_data$RV_Target, har_data$Predicted_RV), na.rm = TRUE) * 1.1
  p1 <- ggplot(har_data, aes(x = Target_Date)) +
    geom_line(aes(y = RV_Target, color = "Observed RV (Target)"), linewidth = 0.6, alpha = 0.7) +
    geom_line(aes(y = Predicted_RV, color = "HAR-RV Fitted"), linewidth = 1) +
    scale_color_manual(values = c("Observed RV (Target)" = "gray60", "HAR-RV Fitted" = "darkred")) +
    coord_cartesian(ylim = c(0, max_y)) +
    theme_minimal(base_size = 11) +
    labs(title = "HAR-RV: 1-Day Ahead Volatility (Full-Sample Fit)", x = "Date",
         y = "Realized Volatility (%)", color = NULL) +
    theme(plot.title = element_text(face = "bold", size = 11), legend.position = "top",
          legend.margin = margin(0, 0, 0, 0))

  coef_df <- data.frame(
    Component = c("Daily", "Weekly", "Monthly"),
    Estimate = pars[2:4],
    StdError = summary_fit$coefficients[2:4, 2]
  )
  coef_df$Component <- factor(coef_df$Component, levels = c("Daily", "Weekly", "Monthly"))
  p2 <- ggplot(coef_df, aes(x = Component, y = Estimate, fill = Component)) +
    geom_bar(stat = "identity", width = 0.5, color = "black", alpha = 0.8) +
    geom_errorbar(aes(ymin = Estimate - 1.96 * StdError, ymax = Estimate + 1.96 * StdError),
                  width = 0.15, linewidth = 0.8) +
    scale_fill_manual(values = c("Daily" = "steelblue", "Weekly" = "forestgreen", "Monthly" = "goldenrod")) +
    theme_minimal(base_size = 11) +
    labs(title = "HAR-RV Component Weights (with 95% CI)", x = "Volatility Horizon", y = "Coefficient Estimate") +
    theme(plot.title = element_text(face = "bold", size = 11), legend.position = "none")

  acf_res <- acf(har_data$Residuals, plot = FALSE, lag.max = 20)
  acf_df <- data.frame(Lag = acf_res$lag[, , 1], ACF = acf_res$acf[, , 1])
  ci_bound <- 2 / sqrt(nrow(har_data))
  p3 <- ggplot(acf_df, aes(x = Lag, y = ACF)) +
    geom_hline(yintercept = 0, color = "gray30") +
    geom_hline(yintercept = c(ci_bound, -ci_bound), linetype = "dashed", color = "blue", alpha = 0.6) +
    geom_segment(aes(xend = Lag, yend = 0), color = "midnightblue", linewidth = 0.9) +
    geom_point(color = "midnightblue", size = 1.5) +
    theme_minimal(base_size = 11) +
    labs(title = "ACF of HAR-RV Residuals", x = "Lag", y = "ACF") +
    theme(plot.title = element_text(face = "bold", size = 11))

  har_data$Std_Residuals <- as.numeric(scale(har_data$Residuals))
  p4 <- ggplot(har_data, aes(x = Std_Residuals)) +
    geom_histogram(aes(y = after_stat(density)), bins = 30, fill = "purple4", color = "white", alpha = 0.6) +
    geom_density(color = "purple4", linewidth = 1) +
    stat_function(fun = dnorm, args = list(mean = 0, sd = 1), color = "black", linetype = "dashed", linewidth = 1) +
    theme_minimal(base_size = 11) +
    labs(title = "Standardized Residuals Density", x = "Standardized Residuals", y = "Density") +
    theme(plot.title = element_text(face = "bold", size = 11))

  diagnostic_dashboard <- (p1 + p2) / (p3 + p4) +
    plot_annotation(
      title = paste("HAR-RV Diagnostics | Ticker:", current_ric),
      subtitle = sprintf("Adj R-Squared: %.4f | OOS RMSE: %.4f", adj_r_squared, metric_rows[[current_ric]]$RMSE),
      theme = theme(plot.title = element_text(face = "bold", size = 14, hjust = 0.5),
                    plot.subtitle = element_text(size = 11, hjust = 0.5, color = "gray30"))
    )
  png_path <- file.path(dirs$png, paste0("HFD_HARRV_Diagnostics_", ecmt_safe_name(current_ric), ".png"))
  ggsave(png_path, diagnostic_dashboard, width = 12, height = 9, dpi = 150)

  summary_rows[[current_ric]] <- data.frame(
    Ticker = current_ric,
    Intercept = unname(pars["(Intercept)"]),
    Beta_Daily = unname(pars["RV_Daily"]),
    Beta_Weekly = unname(pars["RV_Weekly"]),
    Beta_Monthly = unname(pars["RV_Monthly"]),
    R_Squared = r_squared,
    Adj_R_Squared = adj_r_squared,
    AIC = AIC(har_fit),
    BIC = BIC(har_fit),
    N_Days = nrow(har_data),
    stringsAsFactors = FALSE
  )

  all_harrv_results[[current_ric]] <- list(
    data = har_data,
    fit = har_fit,
    train_fit = train_fit,
    coefficients = pars,
    r_squared = r_squared,
    adj_r_squared = adj_r_squared,
    AIC = AIC(har_fit),
    BIC = BIC(har_fit),
    summary_df = summary_rows[[current_ric]],
    oos_metrics = metric_rows[[current_ric]],
    source_file = target_file
  )
}

# ---- 4. Save outputs -----------------------------------------------------------
if (length(all_harrv_results) == 0) {
  stop("HFD HAR-RV produced no results for any ticker - nothing was saved.", call. = FALSE)
}

saveRDS(all_harrv_results, file = dirs$rds)
ecmt_write_tables(dirs, list(
  summary       = dplyr::bind_rows(summary_rows),
  oos_metrics   = dplyr::bind_rows(metric_rows),
  oos_forecasts = dplyr::bind_rows(forecast_rows)
))
cat("\nProcess complete! HAR-RV results saved to", dirs$rds, "\n")
