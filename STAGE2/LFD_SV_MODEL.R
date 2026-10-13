# ==============================================================================
# Script Name: LFD_SVMODEL.R
# Pipeline Stage: Stage 2 - Low-Frequency Stochastic Volatility Modeling
# Description: Fits Bayesian Stochastic Volatility (SV) models to daily stock 
#              returns using MCMC, generates diagnostic dashboards for latent 
#              volatility, and saves the models.
# ==============================================================================

# 1. Load Required Packages
required_packages <- c("readxl", "dplyr", "forecast", "ggplot2", "patchwork", "stochvol")
for (pkg in required_packages) {
  if (!require(pkg, character.only = TRUE)) {
    install.packages(pkg, dependencies = TRUE)
    library(pkg, character.only = TRUE)
  }
}

# 2. Setup Output Directories
output_dir_png <- "Pipeline_Outputs/PNG_Plots/LFD_SV"
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

sv_results <- list()
options(device.ask.default = FALSE)

# 5. Master Processing Loop across Tickers
for (company in company_columns) {
  cat("\n------------------------------------------------------\n")
  cat("Processing LFD SV for Ticker:", company, "\n")
  cat("------------------------------------------------------\n")
  
  ret_series <- na.omit(log_returns[[company]]) * 100
  
  if (length(ret_series) < 50) {
    cat("Insufficient observations for", company, "(< 50) - skipping...\n")
    next
  }
  
  # Mean-center returns (standard practice for baseline SV models)
  ret_centered <- ret_series - mean(ret_series)
  
  # Fit Bayesian Stochastic Volatility Model (MCMC)
  cat("Estimating SV model via MCMC...\n")
  sv_fit <- try(svsample(ret_centered, quiet = TRUE), silent = TRUE)
  
  if (inherits(sv_fit, "try-error")) {
    cat("SV estimation failed for", company, "- skipping...\n")
    next
  }
  
  # Extract Posterior Medians for Latent Volatility: exp(h_t / 2)
  vol_est <- apply(exp(sv_fit$latent / 2), 2, median)
  
  # Standardized Residuals
  std_resids <- ret_centered / vol_est
  
  # 30-Day Volatility Forecast
  sv_fc <- predict(sv_fit, steps = 30)
  vol_fc_mean <- apply(exp(sv_fc$h / 2), 2, mean)
  vol_fc_lower <- apply(exp(sv_fc$h / 2), 2, quantile, probs = 0.05)
  vol_fc_upper <- apply(exp(sv_fc$h / 2), 2, quantile, probs = 0.95)
  
  # Publication-Quality ggplot2 Diagnostic Dashboards
  
  # Plot 1: Daily Returns (%)
  df_p1 <- data.frame(Index = seq_along(ret_centered), Return = ret_centered)
  p1 <- ggplot(df_p1, aes(x = Index, y = Return)) + 
    geom_line(color = "gray50", linewidth = 0.5) + 
    theme_minimal(base_size = 11) + 
    labs(title = "Mean-Centered Daily Returns (%)", x = "Time", y = "Return") +
    theme(plot.title = element_text(face = "bold", size = 11))
  
  # Plot 2: Estimated Latent Volatility
  df_p2 <- data.frame(Index = seq_along(vol_est), Volatility = vol_est)
  p2 <- ggplot(df_p2, aes(x = Index, y = Volatility)) + 
    geom_line(color = "darkred", linewidth = 0.8) + 
    theme_minimal(base_size = 11) + 
    labs(title = "Estimated Latent Volatility (Posterior Median)", x = "Time", y = "Volatility (%)") +
    theme(plot.title = element_text(face = "bold", size = 11))
  
  # Plot 3: Squared Standardized Residuals ACF
  p3 <- ggAcf(std_resids^2, lag.max = 20) + 
    theme_minimal(base_size = 11) + 
    labs(title = "ACF of Squared Standardized Residuals", x = "Lag", y = "ACF") +
    theme(plot.title = element_text(face = "bold", size = 11))
  
  # Plot 4: 30-Day Volatility Forecast
  df_p4 <- data.frame(Day = 1:30, Mean = vol_fc_mean, Lower = vol_fc_lower, Upper = vol_fc_upper)
  p4 <- ggplot(df_p4, aes(x = Day, y = Mean)) + 
    geom_ribbon(aes(ymin = Lower, ymax = Upper), fill = "darkblue", alpha = 0.2) +
    geom_line(color = "darkblue", linewidth = 1) + 
    theme_minimal(base_size = 11) + 
    labs(title = "30-Day Volatility Forecast (90% CI)", x = "Horizon (Days)", y = "Forecasted Volatility (%)") +
    theme(plot.title = element_text(face = "bold", size = 11))
  
  # Combine using patchwork layout
  diagnostic_dashboard <- (p1 + p2) / (p3 + p4) + 
    plot_annotation(
      title = paste("LFD Stochastic Volatility Diagnostics | Ticker:", company),
      theme = theme(plot.title = element_text(face = "bold", size = 14, hjust = 0.5))
    )
  
  # Save High-Resolution Plot
  png_path <- file.path(output_dir_png, paste0("LFD_SV_Diagnostics_", gsub("[^A-Za-z0-9]", "_", company), ".png"))
  ggsave(png_path, diagnostic_dashboard, width = 12, height = 9, dpi = 150)
  
  # Extract Coefficients & Summary Statistics
  para_summary <- summary(sv_fit$para)
  
  summary_df <- data.frame(
    Ticker = company,
    Mu_Mean = para_summary$statistics["mu", "Mean"],
    Phi_Mean = para_summary$statistics["phi", "Mean"],
    Sigma_Mean = para_summary$statistics["sigma", "Mean"],
    Mean_30D_Vol_Forecast = mean(vol_fc_mean),
    stringsAsFactors = FALSE
  )
  
  sv_results[[company]] <- list(
    ticker = company, 
    fit = sv_fit, 
    volatility = vol_est,
    forecast = sv_fc, 
    summary_df = summary_df
  )
}

# 6. Save RDS Summaries
if (length(sv_results) > 0) {
  rds_output_path <- file.path(output_dir_rds, paste0("LFD_SV_", extraction_date, ".rds"))
  saveRDS(sv_results, file = rds_output_path)
  
  cat("\n======================================================\n")
  cat("LFD Stochastic Volatility Execution Complete!\n")
  cat("RDS Output Saved   : ", rds_output_path, "\n")
  cat("Plots Exported To  : ", output_dir_png, "\n")
  cat("======================================================\n")
}
