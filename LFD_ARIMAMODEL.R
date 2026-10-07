# ==============================================================================
# Script Name: LFD_ARIMAMODEL.R
# Pipeline Stage: Stage 2 - Low-Frequency ARIMA Price Modeling
# Description: Fits optimal ARIMA models to daily stock returns, 
#              generates diagnostic dashboards, and saves the models.
# ==============================================================================

# 1. Load Required Packages
required_packages <- c("readxl", "dplyr", "forecast", "ggplot2", "patchwork")
for (pkg in required_packages) {
  if (!require(pkg, character.only = TRUE)) {
    install.packages(pkg, dependencies = TRUE)
    library(pkg, character.only = TRUE)
  }
}

# 2. Setup Output Directories
output_dir_png <- "Pipeline_Outputs/PNG_Plots/LFD_ARIMA"
output_dir_rds <- "Pipeline_Outputs/RDS_Models"
dir.create(output_dir_png, recursive = TRUE, showWarnings = FALSE)
dir.create(output_dir_rds, recursive = TRUE, showWarnings = FALSE)

# 3. Dynamic Search for Low-Frequency Excel Data
lfd_files <- list.files(
  path = ".", 
  pattern = "^LSEG_LFD_.*\\.xlsx$", 
  full.names = TRUE, 
  recursive = TRUE
)

if (length(lfd_files) == 0) {
  stop("Error: No 'LSEG_LFD_*.xlsx' file found inside working directory or subfolders.")
}

target_file <- lfd_files[order(file.info(lfd_files)$mtime, decreasing = TRUE)][1]

extraction_date <- sub("^.*LSEG_LFD_(.*)\\.xlsx$", "\\1", basename(target_file))
if (extraction_date == basename(target_file) || nchar(extraction_date) == 0) {
  extraction_date <- format(Sys.Date(), "%Y-%m-%d")
}

cat("\n======================================================\n")
cat("Located LFD File  :", target_file, "\n")
cat("Extraction Date   :", extraction_date, "\n")
cat("======================================================\n\n")

# 4. Load Raw Data
log_returns <- read_excel(target_file, sheet = "Returns")
date_col <- if ("Date" %in% names(log_returns)) "Date" else names(log_returns)[1]
company_columns <- setdiff(names(log_returns), date_col)

arima_results <- list()
options(device.ask.default = FALSE)

# 5. Master Processing Loop across Tickers
for (company in company_columns) {
  cat("\n------------------------------------------------------\n")
  cat("Processing LFD ARIMA for Ticker:", company, "\n")
  cat("------------------------------------------------------\n")
  
  ret_series <- na.omit(log_returns[[company]]) * 100
  
  if (length(ret_series) < 50) {
    cat("Insufficient observations for", company, "(< 50) - skipping...\n")
    next
  }
  
  # Fit Auto-ARIMA
  best_arima <- auto.arima(ret_series, ic = "aic", trace = FALSE)
  arima_fc <- forecast(best_arima, h = 30)
  
  # Publication-Quality ggplot2 Diagnostic Dashboards
  
  # Plot 1: Daily Returns (%)
  df_p1 <- data.frame(Index = seq_along(ret_series), Return = ret_series)
  p1 <- ggplot(df_p1, aes(x = Index, y = Return)) + 
    geom_line(color = "darkblue", linewidth = 0.5) + 
    theme_minimal(base_size = 11) + 
    labs(title = "Daily Returns (%)", x = "Time", y = "Return") +
    theme(plot.title = element_text(face = "bold", size = 11))
  
  # Plot 2: ARIMA Fitted Values
  df_p2 <- data.frame(Index = seq_along(best_arima$fitted), Fitted = as.numeric(best_arima$fitted))
  p2 <- ggplot(df_p2, aes(x = Index, y = Fitted)) + 
    geom_line(color = "darkred", linewidth = 0.8) + 
    theme_minimal(base_size = 11) + 
    labs(title = "ARIMA Fitted Values", x = "Time", y = "Fitted Return") +
    theme(plot.title = element_text(face = "bold", size = 11))
  
  # Plot 3: Residuals ACF
  p3 <- ggAcf(residuals(best_arima), lag.max = 20) + 
    theme_minimal(base_size = 11) + 
    labs(title = "Residuals ACF", x = "Lag", y = "ACF") +
    theme(plot.title = element_text(face = "bold", size = 11))
  
  # Plot 4: 30-Day Mean Forecast
  p4 <- autoplot(arima_fc) + 
    theme_minimal(base_size = 11) + 
    labs(title = "30-Day Mean Forecast", x = "Time", y = "Forecasted Return") +
    theme(plot.title = element_text(face = "bold", size = 11))
  
  # Combine using patchwork layout
  diagnostic_dashboard <- (p1 + p2) / (p3 + p4) + 
    plot_annotation(
      title = paste("LFD ARIMA Diagnostics | Ticker:", company),
      theme = theme(plot.title = element_text(face = "bold", size = 14, hjust = 0.5))
    )
  
  # Save High-Resolution Plot
  png_path <- file.path(output_dir_png, paste0("LFD_ARIMA_Diagnostics_", gsub("[^A-Za-z0-9]", "_", company), ".png"))
  ggsave(png_path, diagnostic_dashboard, width = 12, height = 9, dpi = 150)
  
  # Extract Coefficients & Summary Statistics
  summary_df <- data.frame(
    Ticker = company,
    ARIMA_Order = as.character(best_arima),
    AIC = best_arima$aic,
    BIC = best_arima$bic,
    Mean_30D_Forecast = mean(arima_fc$mean),
    stringsAsFactors = FALSE
  )
  
  arima_results[[company]] <- list(
    ticker = company, 
    fit = best_arima, 
    forecast = arima_fc, 
    summary_df = summary_df
  )
}

# 6. Save RDS Summaries (Excel compilation handled by COMPILER.R)
if (length(arima_results) > 0) {
  rds_output_path <- file.path(output_dir_rds, paste0("LFD_ARIMA_", extraction_date, ".rds"))
  saveRDS(arima_results, file = rds_output_path)
  
  cat("\n======================================================\n")
  cat("LFD ARIMA Execution Complete!\n")
  cat("RDS Output Saved   : ", rds_output_path, "\n")
  cat("Plots Exported To  : ", output_dir_png, "\n")
  cat("======================================================\n")
}