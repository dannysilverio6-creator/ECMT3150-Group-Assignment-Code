# ==============================================================================
# Script Name: LFD_HYBRIDML.R
# Pipeline Stage: Stage 3 - Low-Frequency Econometric Machine Learning Hybrid
# ==============================================================================

required_packages <- c("readxl", "dplyr", "rugarch", "xgboost", "zoo", "ggplot2", "patchwork")
for (pkg in required_packages) {
  if (!require(pkg, character.only = TRUE)) {
    install.packages(pkg, dependencies = TRUE)
    library(pkg, character.only = TRUE)
  }
}

output_dir_png <- "Pipeline_Outputs/PNG_Plots/LFD_HYBRID"
output_dir_rds <- "Pipeline_Outputs/RDS_Models"
dir.create(output_dir_png, recursive = TRUE, showWarnings = FALSE)
dir.create(output_dir_rds, recursive = TRUE, showWarnings = FALSE)

# Removed the strict '^' anchor and added ignoring of open temporary Excel files
lfd_files <- list.files(path = ".", pattern = "LSEG_LFD_.*\\.xlsx$", full.names = TRUE, recursive = TRUE)
lfd_files <- lfd_files[!grepl("~\\$", lfd_files)]

if (length(lfd_files) == 0) {
  stop("Error: No 'LSEG_LFD_*.xlsx' file found. Ensure Stage 1 extraction ran successfully.")
}

target_file <- lfd_files[order(file.info(lfd_files)$mtime, decreasing = TRUE)][1]
extraction_date <- sub("^.*LSEG_LFD_(.*)\\.xlsx$", "\\1", basename(target_file))
if (nchar(extraction_date) == 0 || grepl("\\.xlsx", extraction_date)) {
  extraction_date <- format(Sys.Date(), "%Y-%m-%d")
}

cat("\n======================================================\n")
cat("Located LFD File  :", target_file, "\n")
cat("Extraction Date   :", extraction_date, "\n")
cat("======================================================\n\n")

sheets <- excel_sheets(target_file)
target_sheet <- if ("Returns" %in% sheets) "Returns" else sheets[1]
log_returns <- read_excel(target_file, sheet = target_sheet)

date_col <- if ("Date" %in% names(log_returns)) "Date" else names(log_returns)[1]
log_returns <- log_returns %>% mutate(Date = as.Date(as.POSIXct(.data[[date_col]])))

company_columns <- setdiff(names(log_returns), c("Date", date_col))
all_hybrid_results <- list()

options(device.ask.default = FALSE)

for (company in company_columns) {
  cat("\n------------------------------------------------------\n")
  cat("Processing LFD Hybrid ML Model for Ticker:", company, "\n")
  
  tryCatch({
    df_series <- data.frame(
      Date = log_returns$Date,
      Return = as.numeric(log_returns[[company]])
    ) %>% filter(!is.na(Return) & is.finite(Return)) %>% arrange(Date)
    
    n_rows <- nrow(df_series)
    cat("Found", n_rows, "valid rows of daily data.\n")
    
    if (n_rows < 25) {
      cat("Insufficient observations for", company, "(< 25) - skipping...\n")
      next
    }
    
    ret_pct <- df_series$Return * 100
    
    garch_spec <- ugarchspec(
      variance.model = list(model = "sGARCH", garchOrder = c(1, 1)),
      mean.model = list(armaOrder = c(0, 0), include.mean = TRUE),
      distribution.model = "norm"
    )
    
    garch_fit <- try(ugarchfit(spec = garch_spec, data = ret_pct, solver = "hybrid"), silent = TRUE)
    
    if (inherits(garch_fit, "try-error") || garch_fit@fit$convergence != 0) {
      cat("  -> GARCH failed. Injecting safe expanding-window volatility proxy...\n")
      df_series$garch_vol <- sapply(1:n_rows, function(i) sd(ret_pct[1:max(2, i)], na.rm = TRUE))
      df_series$garch_vol[is.na(df_series$garch_vol) | df_series$garch_vol == 0] <- mean(abs(ret_pct), na.rm = TRUE)
      df_series$garch_res <- ret_pct / df_series$garch_vol
    } else {
      df_series$garch_vol <- as.numeric(sigma(garch_fit))
      df_series$garch_res <- as.numeric(residuals(garch_fit, standardize = TRUE))
    }
    
    abs_ret <- abs(df_series$Return * 100)
    mean_abs <- mean(abs_ret, na.rm = TRUE)
    
    df_ml <- df_series %>%
      mutate(
        abs_ret = abs_ret,
        target_vol = lead(abs_ret, 1),
        lag_abs_ret_1 = abs_ret,
        lag_abs_ret_2 = lag(abs_ret, 1, default = mean_abs),
        lag_ret_1     = Return * 100,
        lag_ret_2     = lag(Return * 100, 1, default = 0),
        lag_garch_vol = garch_vol,
        garch_std_res = garch_res,
        roll_sd_5     = zoo::rollapply(abs_ret, width = 5, FUN = sd, fill = mean_abs, align = "right"),
        roll_sd_20    = zoo::rollapply(abs_ret, width = min(20, n_rows), FUN = sd, fill = mean_abs, align = "right")
      ) %>%
      filter(!is.na(target_vol))
    
    feature_cols <- c("lag_abs_ret_1", "lag_abs_ret_2", "lag_ret_1", "lag_ret_2",
                      "lag_garch_vol", "garch_std_res", "roll_sd_5", "roll_sd_20")
    
    X <- as.matrix(df_ml[, feature_cols])
    X[is.na(X) | !is.finite(X)] <- 0
    y <- as.numeric(df_ml$target_vol)
    
    train_size <- max(10, floor(0.70 * nrow(df_ml)))
    train_idx  <- 1:train_size
    test_idx   <- (train_size + 1):nrow(df_ml)
    
    if (length(test_idx) < 5) {
      cat("  -> Dataset too small for OOS testing. Skipping...\n")
      next
    }
    
    X_train <- X[train_idx, , drop = FALSE]; y_train <- y[train_idx]
    X_test  <- X[test_idx, , drop = FALSE];  y_test  <- y[test_idx]
    
    dtrain <- xgb.DMatrix(data = X_train, label = y_train)
    dtest  <- xgb.DMatrix(data = X_test, label = y_test)
    
    xgb_model <- xgb.train(
      params = list(booster = "gbtree", objective = "reg:squarederror", eta = 0.05, max_depth = 3),
      data = dtrain,
      nrounds = 50,
      evals = list(train = dtrain, eval = dtest),
      verbose = 0,
      early_stopping_rounds = 5
    )
    
    ml_pred_test <- predict(xgb_model, dtest)
    garch_pred_test <- df_ml$lag_garch_vol[test_idx]
    test_dates <- df_ml$Date[test_idx]
    
    rmse_ml    <- sqrt(mean((y_test - ml_pred_test)^2, na.rm = TRUE))
    rmse_garch <- sqrt(mean((y_test - garch_pred_test)^2, na.rm = TRUE))
    r2_ml      <- 1 - (sum((y_test - ml_pred_test)^2) / sum((y_test - mean(y_test))^2))
    r2_garch   <- 1 - (sum((y_test - garch_pred_test)^2) / sum((y_test - mean(y_test))^2))
    
    imp_matrix <- xgb.importance(feature_names = feature_cols, model = xgb_model)
    p1 <- if (!is.null(imp_matrix) && nrow(imp_matrix) > 0) {
      ggplot(head(imp_matrix, 8), aes(x = reorder(Feature, Gain), y = Gain)) +
        geom_col(fill = "#2b5c8f", width = 0.7) + coord_flip() + theme_minimal() + labs(title = "Feature Importance")
    } else { ggplot() + theme_minimal() + labs(title = "Feature Importance (N/A)") }
    
    df_p2 <- data.frame(Date = rep(test_dates, 3), Value = c(y_test, garch_pred_test, ml_pred_test), Model = rep(c("Actual Vol", "Daily GARCH", "Hybrid ML"), each = length(test_dates)))
    p2 <- ggplot(df_p2, aes(x = Date, y = Value, color = Model)) + geom_line() +
      scale_color_manual(values = c("Actual Vol" = "gray65", "Daily GARCH" = "#1f4e78", "Hybrid ML" = "#c0392b")) +
      theme_minimal() + labs(title = "OOS Volatility Forecast", y = "Vol (%)")
    
    df_p3 <- data.frame(Date = rep(test_dates, 2), Loss = c(cumsum(abs(y_test - garch_pred_test)), cumsum(abs(y_test - ml_pred_test))), Model = rep(c("Daily GARCH", "Hybrid ML"), each = length(test_dates)))
    p3 <- ggplot(df_p3, aes(x = Date, y = Loss, color = Model)) + geom_line() +
      scale_color_manual(values = c("Daily GARCH" = "#1f4e78", "Hybrid ML" = "#c0392b")) + theme_minimal() + labs(title = "Cumulative Forecast Loss")
    
    res_ml <- na.omit(y_test - ml_pred_test)
    p4 <- if (length(res_ml) > 1) {
      ggplot(data.frame(Residual = res_ml), aes(x = Residual)) + geom_density(fill = "#c0392b", alpha = 0.3) + theme_minimal() + labs(title = "Residual Density")
    } else { ggplot() + theme_minimal() + labs(title = "Residual Density (N/A)") }
    
    dash <- (p1 + p2) / (p3 + p4) + plot_annotation(title = paste("LFD Hybrid Diagnostics | Ticker:", company))
    ggsave(file.path(output_dir_png, paste0("LFD_HYBRID_Diagnostics_", gsub("[^A-Za-z0-9]", "_", company), ".png")), dash, width = 12, height = 9, dpi = 150)
    
    metrics_summary <- data.frame(Ticker = company, RMSE_ML = rmse_ml, RMSE_GARCH = rmse_garch, R2_ML = r2_ml, R2_GARCH = r2_garch)
    all_hybrid_results[[company]] <- list(metrics = metrics_summary, importance = imp_matrix)
    cat("  -> Success: Processed and saved dashboard.\n")
    
  }, error = function(e) {
    cat("  -> CRITICAL ERROR for", company, ":", e$message, "\n")
  })
}

if (length(all_hybrid_results) > 0) {
  rds_path <- file.path(output_dir_rds, paste0("LFD_HYBRID_", extraction_date, ".rds"))
  saveRDS(all_hybrid_results, file = rds_path)
  cat("\n======================================================\n")
  cat("LFD HYBRID Execution Complete! Saved RDS to:", rds_path, "\n")
  cat("======================================================\n")
} else {
  cat("\nWARNING: No valid LFD Hybrid models were generated.\n")
}