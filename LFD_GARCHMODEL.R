# ==============================================================================
# Script Name: LFD_GARCHMODEL.R
# Pipeline Stage: Stage 2 - Low-Frequency GARCH Volatility Modeling
# Description: Fits GARCH(1,1) on daily returns from LSEG_LFD_*.xlsx,
#              exports publication-quality ggplot2 diagnostic dashboards, 
#              and saves LFD_GARCH_*.rds output[cite: 3].
# ==============================================================================

# 1. Load Required Packages
required_packages <- c("readxl", "dplyr", "rugarch", "forecast", "ggplot2", "patchwork")
for (pkg in required_packages) {
  if (!require(pkg, character.only = TRUE)) {
    install.packages(pkg, dependencies = TRUE)
    library(pkg, character.only = TRUE)
  }
}

# 2. Output Directories
output_dir_png <- "Pipeline_Outputs/PNG_Plots/LFD_GARCH"
output_dir_rds <- "Pipeline_Outputs/RDS_Models"
dir.create(output_dir_png, recursive = TRUE, showWarnings = FALSE)
dir.create(output_dir_rds, recursive = TRUE, showWarnings = FALSE)

# 3. Dynamic File Search for LFD Excel Data
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

cat("\n======================================================\n")
cat("Located LFD File  :", target_file, "\n")
cat("Extraction Date   :", extraction_date, "\n")
cat("======================================================\n\n")

# 4. Load Data & Read Returns Sheet
log_returns <- read_excel(target_file, sheet = "Returns")
log_returns <- log_returns %>% mutate(Date = as.Date(Date))

company_columns <- setdiff(names(log_returns), "Date")
garch_results <- list()
summary_rows <- list()

options(device.ask.default = FALSE)

# 5. Fit GARCH(1,1) Models across all Tickers
for (company in company_columns) {
  cat("Processing LFD GARCH Volatility for:", company, "...\n")
  
  ret_series <- na.omit(log_returns[[company]])
  ret_pct <- ret_series * 100
  
  if (length(ret_pct) < 50) {
    cat("Insufficient observations for", company, "- skipping...\n")
    next
  }
  
  # Fit Standard GARCH(1,1)
  garch_spec <- ugarchspec(
    variance.model = list(model = "sGARCH", garchOrder = c(1, 1)),
    mean.model = list(armaOrder = c(0, 0), include.mean = TRUE),
    distribution.model = "norm"
  )
  
  garch_fit <- try(ugarchfit(spec = garch_spec, data = ret_pct, solver = "hybrid"), silent = TRUE)
  
  if (inherits(garch_fit, "try-error") || garch_fit@fit$convergence != 0) {
    cat("GARCH convergence failed for", company, "\n")
    next
  }
  
  # Diagnostics and Forecasting
  info_crit <- infocriteria(garch_fit)
  garch_fc <- ugarchforecast(garch_fit, n.ahead = 30)
  pred_vol <- as.numeric(sigma(garch_fc))
  
  # Step 6: ggplot2 Publication-Quality Diagnostic Dashboards
  
  # Plot 1: Daily Returns %
  df_p1 <- data.frame(Index = seq_along(ret_pct), Return = ret_pct)
  p1 <- ggplot(df_p1, aes(x = Index, y = Return)) +
    geom_line(color = "darkblue", linewidth = 0.5) +
    theme_minimal(base_size = 11) +
    labs(title = "Daily Returns Series", x = "Time (Days)", y = "Return (%)") +
    theme(plot.title = element_text(face = "bold", size = 11))
  
  # Plot 2: Conditional Volatility Fit
  cond_vol <- as.numeric(sigma(garch_fit))
  df_p2 <- data.frame(Index = seq_along(cond_vol), Volatility = cond_vol)
  p2 <- ggplot(df_p2, aes(x = Index, y = Volatility)) +
    geom_line(color = "darkred", linewidth = 1.0) +
    theme_minimal(base_size = 11) +
    labs(title = "GARCH Conditional Volatility Fit", x = "Time (Days)", y = "Volatility (%)") +
    theme(plot.title = element_text(face = "bold", size = 11))
  
  # Plot 3: Standardized Residual ACF
  std_res <- residuals(garch_fit, standardize = TRUE)
  p3 <- ggAcf(std_res, lag.max = 20) +
    theme_minimal(base_size = 11) +
    labs(title = "Standardized Residual ACF", x = "Lag", y = "ACF") +
    theme(plot.title = element_text(face = "bold", size = 11))
  
  # Plot 4: 30-Day Out-of-Sample Volatility Forecast
  df_p4 <- data.frame(Horizon = 1:length(pred_vol), Volatility = pred_vol)
  p4 <- ggplot(df_p4, aes(x = Horizon, y = Volatility)) +
    geom_line(color = "darkred", linewidth = 1.2) +
    geom_point(color = "darkred", size = 2) +
    theme_minimal(base_size = 11) +
    labs(title = "30-Day Ahead Volatility Forecast", x = "Forecast Horizon (Days)", y = "Volatility (%)") +
    theme(plot.title = element_text(face = "bold", size = 11))
  
  # Combine using patchwork layout
  diagnostic_dashboard <- (p1 + p2) / (p3 + p4) +
    plot_annotation(
      title = paste("LFD GARCH Model Diagnostics | Ticker:", company),
      theme = theme(plot.title = element_text(face = "bold", size = 14, hjust = 0.5))
    )
  
  # Save High-Resolution Plot
  png_path <- file.path(output_dir_png, paste0("LFD_GARCH_Diagnostics_", gsub("[^A-Za-z0-9]", "_", company), ".png"))
  ggsave(png_path, diagnostic_dashboard, width = 12, height = 9, dpi = 150)
  
  # Extract Coefficients & Summary Statistics
  pars <- coef(garch_fit)
  
  summary_rows[[company]] <- data.frame(
    Ticker = company,
    Mu = unname(pars["mu"]),
    Omega = unname(pars["omega"]),
    Alpha1 = unname(pars["alpha1"]),
    Beta1 = unname(pars["beta1"]),
    Persistence = unname(pars["alpha1"] + pars["beta1"]),
    AIC = info_crit["Akaike", ],
    BIC = info_crit["Bayes", ],
    Mean_30D_Vol_Forecast = mean(pred_vol)
  )
  
  garch_results[[company]] <- list(
    ticker = company,
    fit = garch_fit,
    forecast = garch_fc,
    predicted_sigma = pred_vol,
    summary_df = summary_rows[[company]],
    extraction_date = extraction_date
  )
}

# 6. Save RDS Summaries (Excel compilation handled by COMPILER.R)
if (length(garch_results) > 0) {
  rds_output_path <- file.path(output_dir_rds, paste0("LFD_GARCH_", extraction_date, ".rds"))
  saveRDS(garch_results, file = rds_output_path)
  
  cat("\n======================================================\n")
  cat("LFD GARCH Execution Complete!\n")
  cat("RDS Output Saved   : ", rds_output_path, "\n")
  cat("Plots Exported To  : ", output_dir_png, "\n")
  cat("======================================================\n")
}