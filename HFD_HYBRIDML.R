# ==============================================================================
# Script Name: HFD_HYBRIDML.R
# Pipeline Stage: Stage 4 - High-Frequency Hybrid Econometric-ML Forecasting
# Description: Merges state variables from ACD and UHF-GARCH models to feed
#              an XGBoost regressor, predicting out-of-sample tick volatility,
#              with centralized pathing and robust fallback merging.
# ==============================================================================

# 1. Load Required Packages
required_packages <- c("dplyr", "xgboost", "ggplot2", "patchwork")
for (pkg in required_packages) {
  if (!require(pkg, character.only = TRUE)) {
    install.packages(pkg, dependencies = TRUE)
    library(pkg, character.only = TRUE)
  }
}

# 2. Setup Output Directories
output_dir_png <- "Pipeline_Outputs/PNG_Plots/HFD_HybridML"
output_dir_rds <- "Pipeline_Outputs/RDS_Models"
dir.create(output_dir_png, recursive = TRUE, showWarnings = FALSE)
dir.create(output_dir_rds, recursive = TRUE, showWarnings = FALSE)

# 3. Dynamic Search for High-Frequency RDS Files inside the RDS Folder
get_latest_file <- function(pattern) {
  # Now searches specifically inside Pipeline_Outputs/RDS_Models
  search_paths <- c(".", output_dir_rds)
  files <- list.files(path = search_paths, pattern = pattern, full.names = TRUE, recursive = TRUE)
  if (length(files) == 0) return(NULL)
  return(files[order(file.info(files)$mtime, decreasing = TRUE)][1])
}

acd_file <- get_latest_file("hfd_acd_results_ALL_.*\\.rds$")
uhf_file <- get_latest_file("hfd_uhfgarch_results_ALL_.*\\.rds$")

if (is.null(acd_file) || is.null(uhf_file)) {
  stop("Error: Required HFD RDS files not found. Ensure ACD and UHF-GARCH models run successfully first.")
}

cat("\n======================================================\n")
cat("Located ACD File       :", acd_file, "\n")
cat("Located UHF-GARCH File :", uhf_file, "\n")
cat("======================================================\n\n")

# 4. Load Data
acd_data <- readRDS(acd_file)
uhf_data <- readRDS(uhf_file)
extraction_date <- format(Sys.Date(), "%Y-%m-%d")

all_hybrid_results <- list()
options(device.ask.default = FALSE)

# 5. Master Processing Loop across Tickers
for (ric in names(uhf_data)) {
  if (!(ric %in% names(acd_data)) || is.null(acd_data[[ric]]$data)) {
    cat("Skipping", ric, "- Missing ACD data.\n")
    next
  }
  
  cat("------------------------------------------------------\n")
  cat("Processing HFD Hybrid ML for Ticker:", ric, "\n")
  cat("------------------------------------------------------\n")
  
  df_uhf <- uhf_data[[ric]]$data
  df_acd <- acd_data[[ric]]$data
  
  # Step A: Merge structural state variables and engineer features
  df_ml <- inner_join(df_uhf, df_acd, by = c("Timestamp", "RIC")) %>%
    mutate(
      target_vol = lead(abs(log_return), 1),
      lambda_i = 1 / expected_duration,
      sigma_lambda = cond_vol_raw * lambda_i,
      lag_abs_ret = abs(log_return)
    ) %>% 
    filter(!is.na(target_vol) & is.finite(lambda_i) & !is.na(sigma_lambda))
  
  if (nrow(df_ml) < 50) {
    cat("Insufficient observations for", ric, "(< 50) after merging - skipping...\n")
    next
  }
  
  feature_cols <- c(
    "expected_duration", "acd_residuals", "diurnal_factor", 
    "cond_vol_adj", "cond_vol_raw", "std_residuals", 
    "diurnal_vol", "lambda_i", "sigma_lambda", "lag_abs_ret"
  )
  
  X <- as.matrix(df_ml[, feature_cols])
  X[!is.finite(X)] <- 0
  y <- df_ml$target_vol
  
  # Step B: Chronological Train/Test Split (70% Train, 30% Test)
  train_size <- floor(0.70 * nrow(df_ml))
  train_idx <- 1:train_size
  test_idx <- (train_size + 1):nrow(df_ml)
  
  dtrain <- xgb.DMatrix(data = X[train_idx, , drop = FALSE], label = y[train_idx])
  dtest  <- xgb.DMatrix(data = X[test_idx, , drop = FALSE], label = y[test_idx])
  
  # Step C: Train Machine Learning Model (XGBoost Regressor)
  xgb_model <- xgb.train(
    params = list(
      booster = "gbtree", 
      objective = "reg:squarederror", 
      eta = 0.05, 
      max_depth = 3
    ),
    data = dtrain, 
    nrounds = 100, 
    evals = list(train = dtrain, eval = dtest), 
    verbose = 0, 
    early_stopping_rounds = 10
  )
  
  # Out-of-Sample Predictions
  ml_pred_test <- predict(xgb_model, dtest)
  garch_pred_test <- df_ml$cond_vol_raw[test_idx]
  y_test <- y[test_idx]
  
  # Step D: Evaluation Metrics
  rmse_ml <- sqrt(mean((y_test - ml_pred_test)^2, na.rm = TRUE))
  rmse_garch <- sqrt(mean((y_test - garch_pred_test)^2, na.rm = TRUE))
  r2_ml <- 1 - (sum((y_test - ml_pred_test)^2) / sum((y_test - mean(y_test))^2))
  r2_garch <- 1 - (sum((y_test - garch_pred_test)^2) / sum((y_test - mean(y_test))^2))
  
  cat(sprintf("OOS Results | HFD Hybrid ML RMSE: %.6f | UHF-GARCH RMSE: %.6f\n", rmse_ml, rmse_garch))
  cat(sprintf("OOS Results | HFD Hybrid ML R2  : %.4f | UHF-GARCH R2  : %.4f\n", r2_ml, r2_garch))
  
  # Step E: Publication-Quality ggplot2 Diagnostic Dashboards
  
  imp_matrix <- xgb.importance(feature_names = feature_cols, model = xgb_model)
  p1 <- ggplot(head(imp_matrix, 8), aes(x = reorder(Feature, Gain), y = Gain)) + 
    geom_col(fill = "steelblue", width = 0.7) + 
    coord_flip() + 
    theme_minimal(base_size = 11) + 
    labs(title = "Feature Importance (Gain)", x = NULL, y = "Gain Score") +
    theme(plot.title = element_text(face = "bold", size = 11))
  
  df_p2 <- data.frame(Time = 1:length(y_test), Actual = y_test, ML = ml_pred_test, GARCH = garch_pred_test)
  p2 <- ggplot(head(df_p2, 200), aes(x = Time)) + 
    geom_line(aes(y = Actual, color = "Actual Vol"), linewidth = 0.8) + 
    geom_line(aes(y = ML, color = "Hybrid ML"), linewidth = 1.2) + 
    scale_color_manual(values = c("Actual Vol" = "gray70", "Hybrid ML" = "firebrick")) +
    theme_minimal(base_size = 11) + 
    labs(title = "OOS Forecast (200 ticks)", x = "Tick", y = "Volatility", color = NULL) +
    theme(plot.title = element_text(face = "bold", size = 11), legend.position = "top")
  
  p3 <- ggplot(df_p2, aes(x = Time)) + 
    geom_line(aes(y = cumsum(abs(Actual - GARCH)), color = "UHF-GARCH"), linewidth = 1.2) + 
    geom_line(aes(y = cumsum(abs(Actual - ML)), color = "Hybrid ML"), linewidth = 1.5) + 
    scale_color_manual(values = c("UHF-GARCH" = "darkblue", "Hybrid ML" = "firebrick")) +
    theme_minimal(base_size = 11) + 
    labs(title = "Cumulative Forecast Loss Trajectory", x = "Tick", y = "Cumulative Error", color = NULL) +
    theme(plot.title = element_text(face = "bold", size = 11), legend.position = "top")
  
  df_p4 <- data.frame(Residuals = y_test - ml_pred_test)
  p4 <- ggplot(df_p4, aes(x = Residuals)) + 
    geom_density(fill = "firebrick", alpha = 0.4, color = "darkred", linewidth = 1) + 
    theme_minimal(base_size = 11) + 
    labs(title = "Residual Density", x = "Prediction Error", y = "Density") +
    theme(plot.title = element_text(face = "bold", size = 11))
  
  diagnostic_dashboard <- (p1 + p2) / (p3 + p4) + 
    plot_annotation(
      title = paste("HFD Econometric-ML Hybrid Diagnostics | Ticker:", ric),
      theme = theme(plot.title = element_text(face = "bold", size = 14, hjust = 0.5))
    )
  
  png_path <- file.path(output_dir_png, paste0("HFD_HybridML_Diagnostics_", gsub("[^A-Za-z0-9]", "_", ric), ".png"))
  ggsave(png_path, diagnostic_dashboard, width = 12, height = 9, dpi = 150)
  
  metrics <- data.frame(
    Ticker = ric, rmse_ml = rmse_ml, rmse_garch = rmse_garch, r2_ml = r2_ml, r2_garch = r2_garch, stringsAsFactors = FALSE
  )
  
  all_hybrid_results[[ric]] <- list(metrics = metrics, importance = imp_matrix, data = df_ml)
}

# 6. Save RDS Summaries to Central RDS Folder
if (length(all_hybrid_results) > 0) {
  rds_output_path <- file.path(output_dir_rds, paste0("hfd_hybrid_ml_results_ALL_", extraction_date, ".rds"))
  saveRDS(all_hybrid_results, file = rds_output_path)
  
  cat("\n======================================================\n")
  cat("HFD HYBRID ML Execution Complete!\n")
  cat("RDS Output Saved   : ", rds_output_path, "\n")
  cat("Plots Exported To  : ", output_dir_png, "\n")
  cat("======================================================\n")
}