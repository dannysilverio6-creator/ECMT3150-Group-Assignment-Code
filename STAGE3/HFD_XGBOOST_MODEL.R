# ==============================================================================
# Script Name: HFD_XGBOOST_MODEL.R
# Pipeline Stage: Stage 3 - High-Frequency Machine Learning Hybrid (XGBoost)
# Description: Reads the intraday data in LSEG_HFD.xlsx, aggregates it to daily
#              Realized Volatility, and trains an XGBoost regression to predict
#              next-day Realized Volatility. Features are the HAR-RV components
#              (daily, weekly, monthly RV) plus the one-step-ahead Realized
#              GARCH volatility forecast produced by Stage 2
#              (HFD_REALGARCH.rds).
#
# Leakage controls:
#   * The Realized GARCH feature is a one-step-ahead forecast from parameters
#     estimated on the training sample only.
#   * Early stopping uses a validation block at the end of the TRAINING
#     sample; the test set is used only for the final evaluation.
#   * Train/test dates are identical to the HAR-RV and Realized GARCH
#     evaluations.
#
# Outputs (ECMT3150 OUTPUTS/Pipeline_Outputs/):
#   RDS_Models/HFD_XGBOOST.rds
#   Model_Tables/HFD_XGBOOST/{oos_metrics,oos_forecasts,feature_importance}.csv
#   PNG_Plots/HFD_XGBOOST/HFD_XGBOOST_Diagnostics_<ticker>.png
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
ecmt_require(c("readxl", "dplyr", "zoo", "xgboost", "ggplot2", "patchwork"))
MODEL_KEY <- "HFD_XGBOOST"
dirs <- ecmt_model_dirs(MODEL_KEY)

# ---- 2. Inputs: HFD data + Stage 2 Realized GARCH forecasts --------------------
target_file <- ecmt_find_lseg_workbook("HFD")
cat("\n======================================================\n")
cat("Located HFD File :", target_file, "\n")
cat("======================================================\n\n")
hfd_raw <- ecmt_read_hfd_long(target_file)

rg_path <- file.path(ECMT_RDS_DIR, "HFD_REALGARCH.rds")
rg_rds <- if (file.exists(rg_path)) readRDS(rg_path) else {
  cat("  Note: HFD_REALGARCH.rds not found - run Stage 2 first. A rolling-SD fallback feature will be used.\n")
  list()
}

features <- c("RV_Daily", "RV_Weekly", "RV_Monthly", "RG_Sigma")
xgb_params <- list(
  objective = "reg:squarederror",
  eta = 0.05,
  max_depth = 3,
  subsample = 0.8,
  colsample_bytree = 0.8
)

unique_rics <- unique(hfd_raw$RIC)
all_xgb_results <- list()
metric_rows <- list()
forecast_rows <- list()
importance_rows <- list()
options(device.ask.default = FALSE)

# ---- 3. Master loop ------------------------------------------------------------
for (current_ric in unique_rics) {
  cat("\n------------------------------------------------------\n")
  cat("Processing XGBoost Hybrid for Ticker:", current_ric, "\n")
  cat("------------------------------------------------------\n")

  df_ticker <- hfd_raw[hfd_raw$RIC == current_ric, , drop = FALSE]

  # Step 1: intraday -> daily realised volatility and HAR components
  daily_data <- ecmt_daily_realised(df_ticker)
  if (nrow(daily_data) < 40) {
    cat("Insufficient daily aggregated observations (N < 40) for", current_ric, "- skipping...\n")
    next
  }
  ml_data <- ecmt_hfd_frame(daily_data)

  # Step 2: Realized GARCH one-step-ahead volatility feature from Stage 2
  fs <- rg_rds[[current_ric]]$feature_series
  if (!is.null(fs) && any(!is.na(fs$RG_Sigma))) {
    ml_data <- dplyr::left_join(ml_data, fs[, c("Date", "RG_Sigma")], by = "Date")
    cat("  -> Realized GARCH one-step-ahead sigma loaded from HFD_REALGARCH.rds\n")
  } else {
    cat("  -> Realized GARCH feature unavailable. Using 5-day rolling SD of daily returns as fallback.\n")
    ml_data$RG_Sigma <- zoo::rollapplyr(daily_data$Daily_Return, 5, sd, fill = NA)[ml_data$Row_Index]
  }
  ml_data <- ml_data[stats::complete.cases(ml_data[, c(features, "RV_Target")]), , drop = FALSE]

  if (nrow(ml_data) < 15) {
    cat("Insufficient rows after feature construction for", current_ric, "- skipping...\n")
    next
  }

  # Step 3: chronological split (same dates as HAR-RV / Realized GARCH)
  is_test <- ecmt_test_rows(ml_data)
  train_data <- ml_data[!is_test, , drop = FALSE]
  test_data <- ml_data[is_test, , drop = FALSE]

  # Step 4: train XGBoost on an expanding window, refitting every
  # ECMT_REFIT_EVERY_HFD test observations (same schedule as the econometric models).
  # Early stopping uses the end of each training sample, never the test set.
  blocks <- ecmt_refit_blocks(ml_data, is_test, ECMT_REFIT_EVERY_HFD)
  first_model <- NULL; last_fit <- NULL
  cat("  -> Training XGBoost models (expanding window)...\n")
  all_forecast <- ecmt_blocked_forecasts(
    ml_data, blocks,
    fit_fun = function(est_n) {
      tr <- ml_data[ml_data$Row_Index + 1 <= est_n, , drop = FALSE]
      fit <- ecmt_xgb_fit(as.matrix(tr[, features]), tr$RV_Target, xgb_params,
                          nrounds = 150, early_stopping_rounds = 15)
      if (is.null(first_model)) first_model <<- fit
      last_fit <<- fit
      fit
    },
    forecast_fun = function(fit, rows) {
      # Volatility cannot be negative; squared-error trees can undershoot slightly.
      pmax(predict(fit$model, xgboost::xgb.DMatrix(as.matrix(ml_data[rows, features]))), 0)
    }
  )
  xgb <- last_fit
  xgb_model <- xgb$model
  test_data$XGB_Forecast <- all_forecast[is_test]

  metrics <- cbind(
    ecmt_metrics_row("HFD_XGBoost", current_ric, ml_data, is_test, all_forecast,
                     "RV_Target", "Next-day realised volatility (%)"),
    Best_Iteration = xgb$best_iteration,
    Refits = attr(all_forecast, "n_fits")
  )
  metric_rows[[current_ric]] <- metrics
  forecast_rows[[current_ric]] <- ecmt_forecast_rows("HFD_XGBoost", current_ric, ml_data, is_test,
                                                     all_forecast, "RV_Target")
  rmse <- metrics$RMSE
  mae <- metrics$MAE
  cat(sprintf("  -> Out-of-Sample Performance (%s to %s, n=%d): RMSE = %.4f | MAE = %.4f\n",
              metrics$Test_Start, metrics$Test_End, metrics$N_Test, rmse, mae))

  # Step 5: dashboards
  importance_matrix <- ecmt_xgb_importance(xgb_model, features)
  importance_rows[[current_ric]] <- cbind(Ticker = current_ric, importance_matrix)

  p1 <- ggplot(importance_matrix, aes(x = reorder(Feature, Gain), y = Gain, fill = Feature)) +
    geom_bar(stat = "identity", color = "black", alpha = 0.8) +
    coord_flip() +
    scale_fill_brewer(palette = "Set1") +
    theme_minimal(base_size = 11) +
    labs(title = "XGBoost Feature Importance (Gain)", x = "Feature", y = "Relative Importance") +
    theme(plot.title = element_text(face = "bold", size = 11), legend.position = "none")

  plot_data <- ml_data
  plot_data$XGB_Forecast <- all_forecast
  plot_data$Split <- ifelse(is_test, "Test", "Train")
  max_y <- max(c(plot_data$RV_Target, plot_data$XGB_Forecast)) * 1.1
  p2 <- ggplot(plot_data, aes(x = Target_Date)) +
    annotate("rect", xmin = min(test_data$Target_Date), xmax = max(test_data$Target_Date),
             ymin = -Inf, ymax = Inf, fill = "gold", alpha = 0.15) +
    geom_line(aes(y = RV_Target, color = "Observed RV (Target)"), linewidth = 0.8, alpha = 0.7) +
    geom_line(aes(y = XGB_Forecast, color = "XGBoost Forecast"), linewidth = 1.0) +
    scale_color_manual(values = c("Observed RV (Target)" = "gray50", "XGBoost Forecast" = "darkblue")) +
    coord_cartesian(ylim = c(0, max_y)) +
    theme_minimal(base_size = 11) +
    labs(title = "1-Day Ahead RV Forecast (shaded = out-of-sample)", x = "Date",
         y = "Realized Volatility (%)", color = NULL) +
    theme(plot.title = element_text(face = "bold", size = 11), legend.position = "top",
          legend.margin = margin(0, 0, 0, 0))

  p3 <- ggplot(test_data, aes(x = RV_Target, y = XGB_Forecast)) +
    geom_point(color = "midnightblue", alpha = 0.7, size = 2.5) +
    geom_abline(slope = 1, intercept = 0, linetype = "dashed", color = "black", linewidth = 0.8) +
    coord_cartesian(xlim = c(0, max_y), ylim = c(0, max_y)) +
    theme_minimal(base_size = 11) +
    labs(title = "Out-of-Sample Accuracy (Forecast vs Actual)", x = "Actual RV (%)", y = "Forecasted RV (%)") +
    theme(plot.title = element_text(face = "bold", size = 11))

  test_data$Residual <- test_data$RV_Target - test_data$XGB_Forecast
  p4 <- ggplot(test_data, aes(x = Target_Date, y = Residual)) +
    geom_hline(yintercept = 0, color = "black", linetype = "dashed") +
    geom_line(color = "darkred", linewidth = 0.8) +
    geom_point(color = "darkred", size = 1.5) +
    theme_minimal(base_size = 11) +
    labs(title = "Out-of-Sample Prediction Errors", x = "Date", y = "Residual (Actual - Forecast)") +
    theme(plot.title = element_text(face = "bold", size = 11))

  diagnostic_dashboard <- (p1 + p2) / (p3 + p4) +
    plot_annotation(
      title = paste("HFD XGBoost Hybrid (HAR-RV + Realized GARCH) | Ticker:", current_ric),
      subtitle = sprintf("Out-of-Sample Testing | RMSE: %.4f | MAE: %.4f | n = %d days",
                         rmse, mae, metrics$N_Test),
      theme = theme(plot.title = element_text(face = "bold", size = 14, hjust = 0.5),
                    plot.subtitle = element_text(size = 11, hjust = 0.5, color = "gray30"))
    )
  png_path <- file.path(dirs$png, paste0("HFD_XGBOOST_Diagnostics_", ecmt_safe_name(current_ric), ".png"))
  ggsave(png_path, diagnostic_dashboard, width = 12, height = 9, dpi = 150)

  all_xgb_results[[current_ric]] <- list(
    train_data = train_data,
    test_data = test_data,
    model = xgb_model,
    feature_importance = importance_matrix,
    metrics = metrics,
    source_file = target_file
  )
}

# ---- 4. Save outputs -----------------------------------------------------------
if (length(all_xgb_results) == 0) {
  stop("HFD XGBoost produced no results for any ticker - nothing was saved.", call. = FALSE)
}

saveRDS(all_xgb_results, file = dirs$rds)
ecmt_write_tables(dirs, list(
  oos_metrics        = dplyr::bind_rows(metric_rows),
  oos_forecasts      = dplyr::bind_rows(forecast_rows),
  feature_importance = dplyr::bind_rows(importance_rows)
))
cat("\nProcess complete! HFD XGBoost results saved to", dirs$rds, "\n")
