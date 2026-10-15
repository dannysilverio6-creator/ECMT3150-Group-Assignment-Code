# ==============================================================================
# Script Name: LFD_XGBOOST_MODEL.R
# Pipeline Stage: Stage 3 - Low-Frequency Machine Learning Hybrid (XGBoost)
# Description: Reads daily returns from LSEG_LFD.xlsx and trains an XGBoost
#              regression to predict next-day absolute returns (the LFD
#              volatility proxy). Features are HAR-style lagged absolute
#              returns plus the one-step-ahead GARCH(1,1) and SV volatility
#              forecasts produced by Stage 2 (LFD_GARCH.rds, LFD_SV.rds).
#
# Leakage controls:
#   * GARCH/SV features are one-step-ahead forecasts from parameters
#     estimated on the training sample only (see Stage 2 scripts).
#   * Early stopping uses a validation block at the end of the TRAINING
#     sample; the test set is used only for the final evaluation.
#   * Train/test dates are identical to the GARCH and SV evaluations.
#
# Outputs (ECMT3150 OUTPUTS/Pipeline_Outputs/):
#   RDS_Models/LFD_XGBOOST.rds
#   Model_Tables/LFD_XGBOOST/{oos_metrics,oos_forecasts,feature_importance}.csv
#   PNG_Plots/LFD_XGBOOST/LFD_XGBOOST_Diagnostics_<ticker>.png
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
MODEL_KEY <- "LFD_XGBOOST"
dirs <- ecmt_model_dirs(MODEL_KEY)

# ---- 2. Inputs: LFD returns + Stage 2 volatility forecasts ---------------------
target_file <- ecmt_find_lseg_workbook("LFD")
cat("\n======================================================\n")
cat("Located LFD File  :", target_file, "\n")
cat("======================================================\n\n")
log_returns <- ecmt_read_lfd_returns(target_file)
company_columns <- ecmt_lfd_tickers(log_returns)

read_stage2 <- function(key) {
  path <- file.path(ECMT_RDS_DIR, paste0(key, ".rds"))
  if (!file.exists(path)) {
    cat("  Note:", basename(path), "not found - run Stage 2 first. A rolling-SD fallback feature will be used.\n")
    return(list())
  }
  readRDS(path)
}
garch_rds <- read_stage2("LFD_GARCH")
sv_rds <- read_stage2("LFD_SV")

stage2_feature <- function(rds, ticker, column) {
  fs <- rds[[ticker]]$feature_series
  if (is.null(fs) || all(is.na(fs[[column]]))) return(NULL)
  fs[, c("Date", column)]
}

features <- c("Abs_Return", "Vol_Weekly", "Vol_Monthly", "GARCH_Sigma", "SV_Vol")
xgb_params <- list(
  objective = "reg:squarederror",
  eta = 0.05,
  max_depth = 4,
  subsample = 0.8,
  colsample_bytree = 0.8
)

all_xgb_results <- list()
metric_rows <- list()
forecast_rows <- list()
importance_rows <- list()
options(device.ask.default = FALSE)

# ---- 3. Master loop ------------------------------------------------------------
for (company in company_columns) {
  cat("\n------------------------------------------------------\n")
  cat("Processing XGBoost Hybrid for Ticker:", company, "\n")
  cat("------------------------------------------------------\n")

  keep <- !is.na(log_returns[[company]])
  if (sum(keep) < 50) {
    cat("Insufficient observations for", company, "(< 50) - skipping...\n")
    next
  }
  ret_pct <- as.numeric(log_returns[[company]][keep]) * 100
  ml_data <- ecmt_lfd_frame(log_returns$Date[keep], ret_pct, log_returns$Period[keep])

  # Step 1-2: GARCH / SV one-step-ahead volatility features from Stage 2,
  # one version per scheme (Frozen features for the Frozen XGBoost, etc.)
  for (spec in list(list(rds = garch_rds, base = "GARCH_Sigma", width = 5, label = "GARCH(1,1) sigma"),
                    list(rds = sv_rds, base = "SV_Vol", width = 22, label = "SV volatility"))) {
    fs <- spec$rds[[company]]$feature_series
    cols <- paste0(spec$base, "_", ECMT_SCHEMES)
    if (!is.null(fs) && all(cols %in% names(fs)) && any(!is.na(fs[[cols[2]]]))) {
      ml_data <- dplyr::left_join(ml_data, fs[, c("Date", cols)], by = "Date")
      cat("  -> One-step-ahead", spec$label, "loaded from Stage 2\n")
    } else {
      cat("  ->", spec$label, "unavailable. Using a", spec$width, "-day rolling SD as fallback.\n")
      fb <- zoo::rollapplyr(ret_pct, spec$width, sd, fill = NA)[ml_data$Row_Index]
      for (c in cols) ml_data[[c]] <- fb
    }
  }
  scheme_cols <- c(paste0("GARCH_Sigma_", ECMT_SCHEMES), paste0("SV_Vol_", ECMT_SCHEMES))
  ml_data <- ml_data[stats::complete.cases(ml_data[, c(setdiff(features, c("GARCH_Sigma", "SV_Vol")),
                                                      scheme_cols, "Target_Vol")]), , drop = FALSE]

  if (nrow(ml_data) < 30) {
    cat("Insufficient rows after feature construction for", company, "- skipping...\n")
    next
  }

  # Step 3: event-study split (identical dates to the econometric models)
  split <- tryCatch(ecmt_event_split(ml_data, "LFD"), error = function(e) NULL)
  if (is.null(split) || sum(split == "Train") < 10) {
    cat("Too few pre-event rows to train XGBoost for", company, "- skipping...\n")
    next
  }
  is_test <- split == "Event"

  # Step 4: train XGBoost under both schemes (Frozen: trained before the event
  # only; Adaptive: re-trained every ECMT_REFIT_EVERY_LFD days on an expanding
  # window). Early stopping uses the end of each training sample, never the
  # test period. Volatility cannot be negative, so forecasts are floored at 0.
  fc <- list(); last_fit <- NULL
  for (sc in ECMT_SCHEMES) {
    d <- ml_data
    d$GARCH_Sigma <- d[[paste0("GARCH_Sigma_", sc)]]
    d$SV_Vol <- d[[paste0("SV_Vol_", sc)]]
    every <- if (sc == "Frozen") Inf else ECMT_REFIT_EVERY_LFD
    cat("  -> Training XGBoost (", sc, ")...\n", sep = "")
    fc[[sc]] <- ecmt_blocked_forecasts(
      d, ecmt_schedule_blocks(d, split, every),
      fit_fun = function(est_n) {
        tr <- d[d$Row_Index + 1 <= est_n, , drop = FALSE]
        fit <- ecmt_xgb_fit(as.matrix(tr[, features]), tr$Target_Vol, xgb_params,
                            nrounds = 150, early_stopping_rounds = 15)
        if (sc == "Adaptive") last_fit <<- fit
        fit
      },
      forecast_fun = function(fit, rows) {
        pmax(predict(fit$model, xgboost::xgb.DMatrix(as.matrix(d[rows, features]))), 0)
      }
    )
  }
  xgb <- last_fit
  xgb_model <- xgb$model
  all_forecast <- fc$Adaptive
  train_data <- ml_data[!is_test, , drop = FALSE]
  test_data <- ml_data[is_test, , drop = FALSE]
  test_data$XGB_Forecast <- all_forecast[is_test]

  res <- ecmt_collect_schemes(fc, "LFD_XGBoost", company, ml_data, split,
                              "Target_Vol", "Next-day |return| (%)")
  res$metrics$Best_Iteration <- xgb$best_iteration
  metrics <- res$metrics
  metric_rows[[company]] <- metrics
  forecast_rows[[company]] <- res$forecasts
  ecmt_print_oos(res)
  rmse <- metrics$RMSE[metrics$Scheme == "Adaptive"]
  mae <- metrics$MAE[metrics$Scheme == "Adaptive"]
  metrics <- metrics[metrics$Scheme == "Adaptive", ]

  # Step 5: dashboards
  importance_matrix <- ecmt_xgb_importance(xgb_model, features)
  importance_rows[[company]] <- cbind(Ticker = company, importance_matrix)

  p1 <- ggplot(importance_matrix, aes(x = reorder(Feature, Gain), y = Gain, fill = Feature)) +
    geom_bar(stat = "identity", color = "black", alpha = 0.8) +
    coord_flip() +
    scale_fill_brewer(palette = "Set1") +
    theme_minimal(base_size = 11) +
    labs(title = "XGBoost Feature Importance (Gain)", x = "Feature", y = "Relative Importance") +
    theme(plot.title = element_text(face = "bold", size = 11), legend.position = "none")

  max_y <- max(c(test_data$Target_Vol, test_data$XGB_Forecast)) * 1.1
  p2 <- ggplot(test_data, aes(x = Target_Date)) +
    geom_line(aes(y = Target_Vol, color = "Actual |Return| (Target)"), linewidth = 0.8, alpha = 0.6) +
    geom_line(aes(y = XGB_Forecast, color = "XGBoost Forecast"), linewidth = 1.0) +
    scale_color_manual(values = c("Actual |Return| (Target)" = "gray50", "XGBoost Forecast" = "darkblue")) +
    coord_cartesian(ylim = c(0, max_y)) +
    theme_minimal(base_size = 11) +
    labs(title = "Out-of-Sample: 1-Day Ahead Volatility Forecast", x = "Date",
         y = "Volatility Proxy (%)", color = NULL) +
    theme(plot.title = element_text(face = "bold", size = 11), legend.position = "top",
          legend.margin = margin(0, 0, 0, 0))

  p3 <- ggplot(test_data, aes(x = Target_Vol, y = XGB_Forecast)) +
    geom_point(color = "midnightblue", alpha = 0.6, size = 2) +
    geom_abline(slope = 1, intercept = 0, linetype = "dashed", color = "black", linewidth = 0.8) +
    coord_cartesian(xlim = c(0, max_y), ylim = c(0, max_y)) +
    theme_minimal(base_size = 11) +
    labs(title = "Prediction Accuracy (Forecast vs Actual)", x = "Actual Volatility Proxy",
         y = "Forecasted Volatility") +
    theme(plot.title = element_text(face = "bold", size = 11))

  test_data$Residual <- test_data$Target_Vol - test_data$XGB_Forecast
  p4 <- ggplot(test_data, aes(x = Target_Date, y = Residual)) +
    geom_hline(yintercept = 0, color = "black", linetype = "dashed") +
    geom_line(color = "darkred", linewidth = 0.8) +
    geom_point(color = "darkred", size = 1.5) +
    theme_minimal(base_size = 11) +
    labs(title = "Out-of-Sample Prediction Errors", x = "Date", y = "Residual (Actual - Forecast)") +
    theme(plot.title = element_text(face = "bold", size = 11))

  diagnostic_dashboard <- (p1 + p2) / (p3 + p4) +
    plot_annotation(
      title = paste("LFD XGBoost Hybrid (GARCH + SV) | Ticker:", company),
      subtitle = sprintf("Post-event, adaptive scheme | RMSE: %.4f | MAE: %.4f", rmse, mae),
      theme = theme(plot.title = element_text(face = "bold", size = 14, hjust = 0.5),
                    plot.subtitle = element_text(size = 11, hjust = 0.5, color = "gray30"))
    )
  png_path <- file.path(dirs$png, paste0("LFD_XGBOOST_Diagnostics_", ecmt_safe_name(company), ".png"))
  ggsave(png_path, diagnostic_dashboard, width = 12, height = 9, dpi = 150)

  all_xgb_results[[company]] <- list(
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
  stop("LFD XGBoost produced no results for any ticker - nothing was saved.", call. = FALSE)
}

saveRDS(all_xgb_results, file = dirs$rds)
ecmt_write_tables(dirs, list(
  oos_metrics        = dplyr::bind_rows(metric_rows),
  oos_forecasts      = dplyr::bind_rows(forecast_rows),
  feature_importance = dplyr::bind_rows(importance_rows)
))
cat("\nProcess complete! LFD XGBoost results saved to", dirs$rds, "\n")
