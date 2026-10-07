# ==============================================================================
# Script Name: HFD_UHFGARCH.R
# Pipeline Stage: Stage 2 - High-Frequency Volatility Pipeline (UHF-GARCH)
# Description: Dynamically locates LSEG HFD Excel file, processes intraday 
#              returns and durations, fits Ultra-High-Frequency GARCH(1,1)
#              with diurnal seasonality, and outputs publication-quality 
#              ggplot2 / patchwork diagnostic dashboards[cite: 4].
# ==============================================================================

# 1. Load required libraries
required_packages <- c("readxl", "dplyr", "lubridate", "rugarch", "forecast", "ggplot2", "patchwork")
for (pkg in required_packages) {
  if (!require(pkg, character.only = TRUE)) {
    install.packages(pkg, dependencies = TRUE)
    library(pkg, character.only = TRUE)
  }
}

# 2. Setup Output Directories
output_dir_png <- "Pipeline_Outputs/PNG_Plots/HFD_UHFGARCH"
output_dir_rds <- "Pipeline_Outputs/RDS_Models"
dir.create(output_dir_png, recursive = TRUE, showWarnings = FALSE)
dir.create(output_dir_rds, recursive = TRUE, showWarnings = FALSE)

# 3. Dynamic File Detection inside output directories
hfd_files <- list.files(
  path = ".", 
  pattern = ".*HFD.*\\.xlsx$", 
  full.names = TRUE, 
  recursive = TRUE,
  ignore.case = TRUE
)

if (length(hfd_files) == 0) {
  stop("Error: No HFD Excel file found inside LSEG_outputs or working directory.")
}

# Pick the most recently modified HFD file
target_file <- hfd_files[order(file.info(hfd_files)$mtime, decreasing = TRUE)][1]
extraction_date <- sub("^.*?(?:HFD_|HFD_)(.*?)\\.xlsx$", "\\1", basename(target_file))
if (nchar(extraction_date) == 0 || grepl("\\.xlsx", extraction_date)) {
  extraction_date <- format(Sys.Date(), "%Y-%m-%d")
}

cat("\n======================================================\n")
cat("Located HFD File :", target_file, "\n")
cat("Extraction Date  :", extraction_date, "\n")
cat("======================================================\n\n")

# 4. Read High-Frequency Trade Data from 'Data_Long' sheet
sheets <- excel_sheets(target_file)
target_sheet <- if ("Data_Long" %in% sheets) "Data_Long" else sheets[1]

cat("Reading sheet:", target_sheet, "...\n")
hfd_raw <- read_excel(target_file, sheet = target_sheet)

# Clean timestamp & RIC assignment
if ("Timestamp" %in% names(hfd_raw)) {
  hfd_raw <- hfd_raw %>% mutate(Timestamp = as.POSIXct(Timestamp))
} else if ("Datetime" %in% names(hfd_raw)) {
  hfd_raw <- hfd_raw %>% mutate(Timestamp = as.POSIXct(Datetime))
} else {
  names(hfd_raw)[1] <- "Timestamp"
  hfd_raw$Timestamp <- as.POSIXct(hfd_raw$Timestamp)
}

if (!("RIC" %in% names(hfd_raw))) {
  hfd_raw$RIC <- "UNKNOWN"
}

# Ensure numeric Close prices
hfd_raw <- hfd_raw %>% mutate(Close = as.numeric(Close))

# ==============================================================================
# Master Loop: Process, Fit, and Plot UHF-GARCH for EACH Company
# ==============================================================================

unique_rics <- unique(hfd_raw$RIC)
all_garch_results <- list()

options(device.ask.default = FALSE)

for (current_ric in unique_rics) {
  cat("\n------------------------------------------------------\n")
  cat("Processing UHF-GARCH for Ticker:", current_ric, "\n")
  cat("------------------------------------------------------\n")
  
  # 5. Filter and clean ticker data
  df_ticker <- hfd_raw %>%
    filter(RIC == current_ric) %>%
    filter(!is.na(Timestamp) & !is.na(Close)) %>%
    arrange(Timestamp)
  
  if (nrow(df_ticker) < 50) {
    cat("Insufficient observations for", current_ric, "- skipping...\n")
    next
  }
  
  # 6. Compute Intraday Log Returns and Durations (x_i = Delta t_i in seconds)
  df_ticker <- df_ticker %>%
    mutate(
      log_return = c(NA, diff(log(Close))),
      duration_raw = as.numeric(difftime(Timestamp, lag(Timestamp), units = "secs")),
      tod_seconds = hour(Timestamp) * 3600 + minute(Timestamp) * 60 + second(Timestamp)
    ) %>%
    filter(!is.na(log_return) & !is.na(duration_raw) & duration_raw > 0)
  
  # Time-deformed return rate per unit time: r_tilde = r_i / sqrt(x_i)
  df_ticker <- df_ticker %>%
    mutate(return_rate = log_return / sqrt(duration_raw / 60))
  
  # 7. Diurnal Seasonal Adjustment for Volatility
  spline_fit <- try(smooth.spline(df_ticker$tod_seconds, abs(df_ticker$return_rate), df = 6), silent = TRUE)
  
  if (inherits(spline_fit, "try-error")) {
    df_ticker$diurnal_vol <- 1
  } else {
    df_ticker$diurnal_vol <- predict(spline_fit, df_ticker$tod_seconds)$y
    # Floor diurnal factor to avoid division by zero
    df_ticker$diurnal_vol <- pmax(df_ticker$diurnal_vol, 1e-4)
  }
  
  # Seasonally adjusted return series: r_adj = r_tilde / s(t)
  df_ticker <- df_ticker %>%
    mutate(adj_return = return_rate / diurnal_vol)
  
  # 8. UHF-GARCH(1,1) Model Specification & Fitting
  garch_spec <- ugarchspec(
    variance.model = list(model = "sGARCH", garchOrder = c(1, 1)),
    mean.model = list(armaOrder = c(0, 0), include.mean = FALSE),
    distribution.model = "std"
  )
  
  garch_fit <- try(ugarchfit(spec = garch_spec, data = df_ticker$adj_return, solver = "hybrid"), silent = TRUE)
  
  if (inherits(garch_fit, "try-error") || garch_fit@fit$convergence != 0) {
    cat("UHF-GARCH convergence failed for", current_ric, "- trying standard GARCH...\n")
    garch_spec_norm <- ugarchspec(
      variance.model = list(model = "sGARCH", garchOrder = c(1, 1)),
      mean.model = list(armaOrder = c(0, 0), include.mean = FALSE),
      distribution.model = "norm"
    )
    garch_fit <- try(ugarchfit(spec = garch_spec_norm, data = df_ticker$adj_return), silent = TRUE)
  }
  
  if (inherits(garch_fit, "try-error") || garch_fit@fit$convergence != 0) {
    cat("Failed to fit GARCH model for", current_ric, "\n")
    next
  }
  
  # Extract fitted conditional volatility and residuals
  df_ticker$cond_vol_adj <- as.numeric(sigma(garch_fit))
  df_ticker$cond_vol_raw <- df_ticker$cond_vol_adj * df_ticker$diurnal_vol * sqrt(df_ticker$duration_raw / 60)
  df_ticker$std_residuals <- as.numeric(residuals(garch_fit, standardize = TRUE))
  df_ticker$annualized_vol <- df_ticker$cond_vol_adj * sqrt(252 * 390) * 100
  
  pars <- coef(garch_fit)
  cat("Fit complete: Omega=", round(pars["omega"], 6), 
      " Alpha=", round(pars["alpha1"], 4), 
      " Beta=", round(pars["beta1"], 4), "\n")
  
  # ==============================================================================
  # 9. Publication-Quality ggplot2 Diagnostic Dashboards
  # ==============================================================================
  
  # Plot 1: Intraday Volatility Seasonal Curve
  diurnal_df <- df_ticker %>%
    group_by(tod_seconds) %>%
    summarise(diurnal_vol = mean(diurnal_vol, na.rm = TRUE), .groups = "drop") %>%
    arrange(tod_seconds)
  
  p1 <- ggplot(diurnal_df, aes(x = tod_seconds / 3600, y = diurnal_vol)) +
    geom_line(color = "darkgreen", linewidth = 1.0) +
    theme_minimal(base_size = 11) +
    labs(title = "Intraday Volatility Seasonal Curve", x = "Time of Day (Hours)", y = "Diurnal Volatility Factor") +
    theme(plot.title = element_text(face = "bold", size = 11))
  
  # Plot 2: UHF-GARCH Conditional Volatility Fit
  plot_sample <- head(df_ticker, min(300, nrow(df_ticker)))
  max_y <- min(quantile(abs(plot_sample$log_return), 0.98, na.rm = TRUE) * 2, max(abs(plot_sample$log_return), na.rm = TRUE))
  
  df_p2 <- data.frame(
    Timestamp = rep(plot_sample$Timestamp, 2),
    Value = c(abs(plot_sample$log_return), plot_sample$cond_vol_raw),
    Series = rep(c("|Observed Return|", "GARCH Cond Vol"), each = nrow(plot_sample))
  )
  
  p2 <- ggplot(df_p2, aes(x = Timestamp, y = Value, color = Series, linewidth = Series)) +
    geom_line() +
    scale_color_manual(values = c("|Observed Return|" = "gray75", "GARCH Cond Vol" = "darkred")) +
    scale_linewidth_manual(values = c("|Observed Return|" = 0.8, "GARCH Cond Vol" = 1.2)) +
    coord_cartesian(ylim = c(0, max_y)) +
    theme_minimal(base_size = 11) +
    labs(title = "UHF-GARCH Conditional Volatility Fit", x = "Time", y = "|Return| & Cond Volatility", color = NULL, linewidth = NULL) +
    theme(
      plot.title = element_text(face = "bold", size = 11),
      legend.position = "top",
      legend.margin = margin(0, 0, 0, 0)
    )
  
  # Plot 3: Standardized Residual ACF
  p3 <- ggAcf(df_ticker$std_residuals, lag.max = 20) +
    theme_minimal(base_size = 11) +
    labs(title = "ACF of Standardized Residuals", x = "Lag", y = "ACF") +
    theme(plot.title = element_text(face = "bold", size = 11))
  
  # Plot 4: Annualized Dynamic Volatility Rate (%)
  max_vol <- min(quantile(plot_sample$annualized_vol, 0.98, na.rm = TRUE) * 1.5, max(plot_sample$annualized_vol, na.rm = TRUE))
  
  p4 <- ggplot(plot_sample, aes(x = Timestamp, y = annualized_vol)) +
    geom_line(color = "darkviolet", linewidth = 1.2) +
    coord_cartesian(ylim = c(0, max_vol)) +
    theme_minimal(base_size = 11) +
    labs(title = "Dynamic Annualized Volatility Rate", x = "Time", y = "Annualized Volatility (%)") +
    theme(plot.title = element_text(face = "bold", size = 11))
  
  # Combine using patchwork layout
  diagnostic_dashboard <- (p1 + p2) / (p3 + p4) +
    plot_annotation(
      title = paste("UHF-GARCH Diagnostics | Ticker:", current_ric),
      theme = theme(plot.title = element_text(face = "bold", size = 14, hjust = 0.5))
    )
  
  png_path <- file.path(output_dir_png, paste0("HFD_UHF_Diagnostics_", gsub("[^A-Za-z0-9]", "_", current_ric), ".png"))
  ggsave(png_path, diagnostic_dashboard, width = 12, height = 9, dpi = 150)
  
  # Store model results
  all_garch_results[[current_ric]] <- list(
    data = df_ticker,
    fit = garch_fit,
    coefficients = pars,
    persistence = sum(pars[c("alpha1", "beta1")], na.rm = TRUE),
    AIC = infocriteria(garch_fit)[1],
    BIC = infocriteria(garch_fit)[2]
  )
}

# 10. Save Output Binary RDS Object to Central Folder
if (length(all_garch_results) > 0) {
  rds_output_path <- file.path(output_dir_rds, paste0("hfd_uhfgarch_results_ALL_", extraction_date, ".rds"))
  saveRDS(all_garch_results, file = rds_output_path)
  cat("\nProcess complete! UHF-GARCH models fitted and publication-quality plots rendered for all companies.\n")
}