# ==============================================================================
# Script Name: LFD_XGBOOST_MODEL.R
# Pipeline Stage: Stage 2 - Low-Frequency Machine Learning Pipeline
# Description: Dynamically locates LSEG LFD Excel file, extracts daily returns,
#              fits standard GARCH(1,1) and Stochastic Volatility (SV) models
#              to extract conditional/latent volatility features. Trains an 
#              XGBoost regression model to predict 1-day ahead absolute returns 
#              (proxy for daily volatility). Outputs diagnostic dashboards.
# ==============================================================================

# 1. Load Required Libraries
required_packages <- c("readxl", "dplyr", "lubridate", "rugarch", "stochvol", "xgboost", "ggplot2", "patchwork", "zoo", "tidyr")
for (pkg in required_packages) {
  if (!require(pkg, character.only = TRUE)) {
    install.packages(pkg, dependencies = TRUE)
    library(pkg, character.only = TRUE)
  }
}

# 2. Setup Output Directories (routed to ECMT3150 OUTPUTS)
output_dir_png <- "../ECMT3150 OUTPUTS/Pipeline_Outputs/PNG_Plots/LFD_XGBOOST"
output_dir_rds <- "../ECMT3150 OUTPUTS/Pipeline_Outputs/RDS_Models"
dir.create(output_dir_png, recursive = TRUE, showWarnings = FALSE)
dir.create(output_dir_rds, recursive = TRUE, showWarnings = FALSE)

# 3. Dynamic File Search for LFD Excel Data
search_path <- if (dir.exists("../ECMT3150 OUTPUTS/ECMT3150_LSEG_OUTPUTs")) {
  "../ECMT3150 OUTPUTS/ECMT3150_LSEG_OUTPUTs"
} else if (dir.exists("../ECMT3150 OUTPUTS")) {
  "../ECMT3150 OUTPUTS"
} else {
  ".."
}

lfd_files <- list.files(
  path = search_path, 
  pattern = ".*LSEG_LFD.*\\.xlsx$", 
  full.names = TRUE, 
  recursive = TRUE,
  ignore.case = TRUE
)

if (length(lfd_files) == 0) {
  stop("Error: No 'LSEG_LFD_*.xlsx' file found inside ECMT3150 OUTPUTS or working directories.")
}

target_file <- lfd_files[order(file.info(lfd_files)$mtime, decreasing = TRUE)][1]
extraction_date <- sub("^.*LSEG_LFD_(.*)\\.xlsx$", "\\1", basename(target_file))

cat("\n======================================================\n")
cat("Located LFD File  :", target_file, "\n")
cat("Extraction Date   :", extraction_date, "\n")
cat("======================================================\n\n")
# 4. Load Data & Read Returns Sheet
log_returns <- read_excel(target_file, sheet = "Returns")
date_col <- if ("Date" %in% names(log_returns)) "Date" else names(log_returns)[1]
log_returns[[date_col]] <- as.Date(log_returns[[date_col]])

company_columns <- setdiff(names(log_returns), date_col)
all_xgb_results <- list()
options(device.ask.default = FALSE)

# ==============================================================================
# Master Loop: Feature Engineering, XGBoost Training, and Diagnostics
# ==============================================================================

for (company in company_columns) {
  cat("\n------------------------------------------------------\n")
  cat("Processing XGBoost Hybrid for Ticker:", company, "\n")
  cat("------------------------------------------------------\n")
  
  # Prepare Daily Series
  df_ticker <- data.frame(
    Date = log_returns[[date_col]],
    Return = as.numeric(log_returns[[company]]) * 100 # Scale to percentage for model stability
  ) %>% filter(!is.na(Return))
  
  if (nrow(df_ticker) < 50) {
    cat("Insufficient observations for", company, "(< 50) - skipping...\n")
    next
  }
  
  # Step 1: Fit Standard GARCH(1,1) to extract Conditional Volatility Feature
  cat("  -> Extracting GARCH(1,1) Conditional Volatility...\n")
  garch_spec <- ugarchspec(
    variance.model = list(model = "sGARCH", garchOrder = c(1, 1)),
    mean.model = list(armaOrder = c(0, 0), include.mean = TRUE),
    distribution.model = "norm"
  )
  
  garch_fit <- try(ugarchfit(spec = garch_spec, data = df_ticker$Return, solver = "hybrid"), silent = TRUE)
  
  if (!inherits(garch_fit, "try-error") && convergence(garch_fit) == 0) {
    df_ticker$GARCH_Sigma <- as.numeric(sigma(garch_fit))
  } else {
    cat("  -> GARCH failed. Using 5-day rolling standard deviation as fallback.\n")
    df_ticker$GARCH_Sigma <- rollapply(df_ticker$Return, width = 5, FUN = sd, fill = NA, align = "right")
  }
  
  # Step 2: Fit Stochastic Volatility (SV) to extract Latent Volatility Feature
  cat("  -> Extracting SV Latent Volatility (MCMC)...\n")
  ret_centered <- df_ticker$Return - mean(df_ticker$Return)
  sv_fit <- try(svsample(ret_centered, quiet = TRUE), silent = TRUE)
  
  if (!inherits(sv_fit, "try-error")) {
    df_ticker$SV_Vol <- apply(exp(sv_fit$latent / 2), 2, median)
  } else {
    cat("  -> SV estimation failed. Using 22-day rolling standard deviation as fallback.\n")
    df_ticker$SV_Vol <- rollapply(df_ticker$Return, width = 22, FUN = sd, fill = NA, align = "right")
  }
  
  # Step 3: Construct Historical Lags & Prepare Target Proxy
  cat("  -> Engineering Historical Features & XGBoost Matrix...\n")
  ml_data <- df_ticker %>%
    mutate(
      Abs_Return = abs(Return),
      # Mimicking HAR structure using absolute returns for LFD
      Vol_Weekly = rollmeanr(Abs_Return, k = 5, fill = NA),
      Vol_Monthly = rollmeanr(Abs_Return, k = 22, fill = NA),
      # Target is tomorrow's absolute return (standard LFD proxy for daily volatility)
      Target_Vol = lead(Abs_Return, n = 1) 
    ) %>%
    filter(complete.cases(Abs_Return, Vol_Weekly, Vol_Monthly, GARCH_Sigma, SV_Vol, Target_Vol))
  
  if (nrow(ml_data) < 30) {
    cat("Insufficient rows after lag creation for", company, "- skipping...\n")
    next
  }
  
  # Step 4: Time-Series Train/Test Split (80% Train, 20% Test)
  split_idx <- floor(0.8 * nrow(ml_data))
  train_data <- ml_data[1:split_idx, ]
  test_data <- ml_data[(split_idx + 1):nrow(ml_data), ]
  
  features <- c("Abs_Return", "Vol_Weekly", "Vol_Monthly", "GARCH_Sigma", "SV_Vol")
  
  dtrain <- xgb.DMatrix(data = as.matrix(train_data[, features]), label = train_data$Target_Vol)
  dtest  <- xgb.DMatrix(data = as.matrix(test_data[, features]), label = test_data$Target_Vol)
  
  # Step 5: Train XGBoost Model
  xgb_params <- list(
    objective = "reg:squarederror",
    eta = 0.05,
    max_depth = 4,
    subsample = 0.8,
    colsample_bytree = 0.8
  )
  
  cat("  -> Training XGBoost Model...\n")
  xgb_model <- xgb.train(
    params = xgb_params,
    data = dtrain,
    nrounds = 150,
    watchlist = list(train = dtrain, eval = dtest),
    early_stopping_rounds = 15,
    verbose = 0
  )
  
  # Generate Predictions
  test_data$XGB_Forecast <- predict(xgb_model, dtest)
  
  # Compute Evaluation Metrics
  rmse <- sqrt(mean((test_data$Target_Vol - test_data$XGB_Forecast)^2))
  mae <- mean(abs(test_data$Target_Vol - test_data$XGB_Forecast))
  cat(sprintf("  -> Out-of-Sample Performance: RMSE = %.4f | MAE = %.4f\n", rmse, mae))
  
  # Step 6: Publication-Quality ggplot2 Dashboards
  
  # Plot 1: Feature Importance
  importance_matrix <- xgb.importance(feature_names = features, model = xgb_model)
  p1 <- ggplot(importance_matrix, aes(x = reorder(Feature, Gain), y = Gain, fill = Feature)) +
    geom_bar(stat = "identity", color = "black", alpha = 0.8) +
    coord_flip() +
    scale_fill_brewer(palette = "Set1") +
    theme_minimal(base_size = 11) +
    labs(title = "XGBoost Feature Importance (Gain)", x = "Feature", y = "Relative Importance") +
    theme(plot.title = element_text(face = "bold", size = 11), legend.position = "none")
  
  # Plot 2: Out-of-Sample Forecast vs Actual (Time Series)
  max_y <- max(c(test_data$Target_Vol, test_data$XGB_Forecast)) * 1.1
  p2 <- ggplot(test_data, aes(x = Date)) +
    geom_line(aes(y = Target_Vol, color = "Actual |Return| (Target)"), linewidth = 0.8, alpha = 0.6) +
    geom_line(aes(y = XGB_Forecast, color = "XGBoost Forecast"), linewidth = 1.0) +
    scale_color_manual(values = c("Actual |Return| (Target)" = "gray50", "XGBoost Forecast" = "darkblue")) +
    coord_cartesian(ylim = c(0, max_y)) +
    theme_minimal(base_size = 11) +
    labs(title = "Out-of-Sample: 1-Day Ahead Volatility Forecast", x = "Date", y = "Volatility Proxy (%)", color = NULL) +
    theme(plot.title = element_text(face = "bold", size = 11), legend.position = "top", legend.margin = margin(0,0,0,0))
  
  # Plot 3: Scatter Plot of Forecast vs Actual
  p3 <- ggplot(test_data, aes(x = Target_Vol, y = XGB_Forecast)) +
    geom_point(color = "midnightblue", alpha = 0.6, size = 2) +
    geom_abline(slope = 1, intercept = 0, linetype = "dashed", color = "black", linewidth = 0.8) +
    coord_cartesian(xlim = c(0, max_y), ylim = c(0, max_y)) +
    theme_minimal(base_size = 11) +
    labs(title = "Prediction Accuracy (Forecast vs Actual)", x = "Actual Volatility Proxy", y = "Forecasted Volatility") +
    theme(plot.title = element_text(face = "bold", size = 11))
  
  # Plot 4: Prediction Residuals over Time
  test_data$Residual <- test_data$Target_Vol - test_data$XGB_Forecast
  p4 <- ggplot(test_data, aes(x = Date, y = Residual)) +
    geom_hline(yintercept = 0, color = "black", linetype = "dashed") +
    geom_line(color = "darkred", linewidth = 0.8) +
    geom_point(color = "darkred", size = 1.5) +
    theme_minimal(base_size = 11) +
    labs(title = "Out-of-Sample Prediction Errors", x = "Date", y = "Residual (Actual - Forecast)") +
    theme(plot.title = element_text(face = "bold", size = 11))
  
  # Combine using patchwork layout
  diagnostic_dashboard <- (p1 + p2) / (p3 + p4) +
    plot_annotation(
      title = paste("LFD XGBoost Hybrid (GARCH + SV) | Ticker:", company),
      subtitle = sprintf("Out-of-Sample Testing | RMSE: %.4f | MAE: %.4f", rmse, mae),
      theme = theme(
        plot.title = element_text(face = "bold", size = 14, hjust = 0.5),
        plot.subtitle = element_text(size = 11, hjust = 0.5, color = "gray30")
      )
    )
  
  # Save High-Resolution Plot
  png_path <- file.path(output_dir_png, paste0("LFD_XGBOOST_Diagnostics_", gsub("[^A-Za-z0-9]", "_", company), ".png"))
  ggsave(png_path, diagnostic_dashboard, width = 12, height = 9, dpi = 150)
  
  # Store model results
  all_xgb_results[[company]] <- list(
    train_data = train_data,
    test_data = test_data,
    model = xgb_model,
    feature_importance = importance_matrix,
    metrics = data.frame(Ticker = company, RMSE = rmse, MAE = mae, Best_Iteration = xgb_model$best_iteration)
  )
}

# Step 7: Save Output Binary RDS Object
if (length(all_xgb_results) > 0) {
  rds_output_path <- file.path(output_dir_rds, paste0("LFD_XGBOOST_results_ALL_", extraction_date, ".rds"))
  saveRDS(all_xgb_results, file = rds_output_path)
  cat("\nProcess complete! LFD XGBoost Models trained and diagnostic plots rendered.\n")
}
