# ==============================================================================
# Script Name: HFD_REALIZED_GARCH.R
# Pipeline Stage: Stage 2 - High-Frequency Data Pipeline (Realized GARCH Model)
# Description: Dynamically locates LSEG HFD Excel file, extracts 'Data_Long', 
#              aggregates intraday returns to daily frequency to compute Realized 
#              Volatility, fits a Realized GARCH(1,1) model with robust fallback 
#              protections, and plots publication-quality ggplot2 dashboards.
# ==============================================================================

# 1. Load Required Libraries
required_packages <- c("readxl", "dplyr", "lubridate", "rugarch", "forecast", "ggplot2", "patchwork", "tidyr")
for (pkg in required_packages) {
  if (!require(pkg, character.only = TRUE)) {
    install.packages(pkg, dependencies = TRUE)
    library(pkg, character.only = TRUE)
  }
}

# 2. Setup Output Directories
output_dir_png <- "Pipeline_Outputs/PNG_Plots/HFD_Realized_GARCH"
output_dir_rds <- "Pipeline_Outputs/RDS_Models"
dir.create(output_dir_png, recursive = TRUE, showWarnings = FALSE)
dir.create(output_dir_rds, recursive = TRUE, showWarnings = FALSE)

# 3. Dynamic File Detection
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

target_file <- hfd_files[order(file.info(hfd_files)$mtime, decreasing = TRUE)][1]
extraction_date <- sub("^.*?(?:HFD_|HFD_)(.*?)\\.xlsx$", "\\1", basename(target_file))
if (nchar(extraction_date) == 0 || grepl("\\.xlsx", extraction_date)) {
  extraction_date <- format(Sys.Date(), "%Y-%m-%d")
}

cat("\n======================================================\n")
cat("Located HFD File :", target_file, "\n")
cat("Extraction Date  :", extraction_date, "\n")
cat("======================================================\n\n")

# 4. Ingest Trade Data
sheets <- excel_sheets(target_file)
target_sheet <- if ("Data_Long" %in% sheets) "Data_Long" else sheets[1]

cat("Reading sheet:", target_sheet, "...\n")
hfd_raw <- read_excel(target_file, sheet = target_sheet)

# Timestamp standardisation
if ("Timestamp" %in% names(hfd_raw)) {
  hfd_raw <- hfd_raw %>% mutate(Timestamp = as.POSIXct(Timestamp, tz = "UTC"))
} else if ("Datetime" %in% names(hfd_raw)) {
  hfd_raw <- hfd_raw %>% mutate(Timestamp = as.POSIXct(Datetime, tz = "UTC"))
} else {
  names(hfd_raw)[1] <- "Timestamp"
  hfd_raw$Timestamp <- as.POSIXct(hfd_raw$Timestamp, tz = "UTC")
}

if (!("RIC" %in% names(hfd_raw))) {
  hfd_raw$RIC <- "UNKNOWN"
}

# ==============================================================================
# Master Loop: Process Intraday Data, Fit Realized GARCH, and Plot Diagnostics
# ==============================================================================

unique_rics <- unique(hfd_raw$RIC)
all_garch_results <- list()
options(device.ask.default = FALSE)

for (current_ric in unique_rics) {
  cat("\n------------------------------------------------------\n")
  cat("Processing Ticker:", current_ric, "\n")
  cat("------------------------------------------------------\n")
  
  hfd_ticker <- hfd_raw %>%
    filter(RIC == current_ric) %>%
    filter(!is.na(Timestamp)) %>%
    arrange(Timestamp)
  
  if (nrow(hfd_ticker) < 50) {
    cat("Insufficient observations for", current_ric, "- skipping...\n")
    next
  }
  
  # Step 1: Dynamic Price Column Detection
  price_col <- if ("Mid" %in% names(hfd_ticker)) {
    "Mid"
  } else if ("Close" %in% names(hfd_ticker)) {
    "Close"
  } else if ("TRDPRC_1" %in% names(hfd_ticker)) {
    "TRDPRC_1"
  } else {
    names(hfd_ticker)[sapply(hfd_ticker, is.numeric)][1]
  }
  
  hfd_ticker$Price <- as.numeric(hfd_ticker[[price_col]])
  
  # Step 2: Aggregate High-Frequency Data to Daily Frequency
  # Calculate Intraday Returns, Daily Returns, and Realized Variance (RV)
  # Returns are scaled by 100 to percentage terms to assist optimization
  daily_data <- hfd_ticker %>%
    filter(!is.na(Price) & Price > 0) %>%
    mutate(Date = as.Date(Timestamp, tz = "UTC")) %>%
    group_by(Date) %>%
    arrange(Timestamp) %>%
    mutate(
      intraday_ret = log(Price / lag(Price)) * 100
    ) %>%
    summarise(
      Daily_Return = sum(intraday_ret, na.rm = TRUE),
      RV_pct = sum(intraday_ret^2, na.rm = TRUE),
      N_trades = n(),
      .groups = "drop"
    ) %>%
    filter(N_trades >= 10 & RV_pct > 0)
  
  if (nrow(daily_data) < 30) {
    cat("Insufficient daily aggregated observations (N < 30) for", current_ric, "- skipping...\n")
    next
  }
  
  # rugarch Realized GARCH uses Realized Volatility (sqrt of Variance) natively
  daily_data$Realized_Vol <- sqrt(daily_data$RV_pct)
  
  # Step 3: Define and Fit Realized GARCH(1,1) Model
  spec_realgarch <- ugarchspec(
    mean.model = list(armaOrder = c(0, 0), include.mean = TRUE),
    variance.model = list(model = "realGARCH", garchOrder = c(1, 1))
  )
  
  cat("Estimating Realized GARCH(1,1) model for", current_ric, "...\n")
  opt_res <- try(
    ugarchfit(
      spec = spec_realgarch, 
      data = daily_data$Daily_Return, 
      realizedVol = daily_data$Realized_Vol, 
      solver = "hybrid"
    ), 
    silent = TRUE
  )
  
  # ROBUST FALLBACK WRAPPER: If realGARCH fails, fit standard sGARCH(1,1)
  is_realgarch <- TRUE
  if (inherits(opt_res, "try-error") || convergence(opt_res) != 0) {
    cat("Warning: Realized GARCH optimization failed to converge for", current_ric, "- falling back to standard sGARCH(1,1).\n")
    
    spec_sgarch <- ugarchspec(
      mean.model = list(armaOrder = c(0, 0), include.mean = TRUE),
      variance.model = list(model = "sGARCH", garchOrder = c(1, 1))
    )
    
    opt_res <- try(ugarchfit(spec = spec_sgarch, data = daily_data$Daily_Return, solver = "hybrid"), silent = TRUE)
    is_realgarch <- FALSE
  }
  
  if (inherits(opt_res, "try-error") || convergence(opt_res) != 0) {
    cat("Critical Warning: Both Realized GARCH and fallback sGARCH failed for", current_ric, "- skipping plot generation.\n")
    next
  }
  
  # Extract fitted Conditional Volatility and Standardized Residuals
  daily_data$Sigma <- as.numeric(sigma(opt_res))
  daily_data$Std_Residuals <- as.numeric(residuals(opt_res, standardize = TRUE))
  
  coefs <- coef(opt_res)
  log_lik <- likelihood(opt_res)
  info_crits <- infocriteria(opt_res)
  
  cat("Fit complete! Log-Likelihood:", round(log_lik, 2), 
      "| AIC:", round(info_crits[1], 4), 
      "| Model:", ifelse(is_realgarch, "Realized GARCH", "Standard GARCH"), "\n")
  
  # Step 4: Publication-Quality ggplot2 Diagnostic Dashboards
  
  # Plot 1: Daily Returns with Conditional Volatility Bands (95% CI)
  p1 <- ggplot(daily_data, aes(x = Date)) +
    geom_line(aes(y = Daily_Return, color = "Daily Return"), linewidth = 0.6) +
    geom_line(aes(y = 1.96 * Sigma, color = "95% Volatility Band"), linewidth = 0.8, linetype = "dashed") +
    geom_line(aes(y = -1.96 * Sigma, color = "95% Volatility Band"), linewidth = 0.8, linetype = "dashed") +
    scale_color_manual(values = c("Daily Return" = "gray50", "95% Volatility Band" = "darkred")) +
    theme_minimal(base_size = 11) +
    labs(
      title = "Daily Returns & Conditional Volatility Bounds",
      x = "Date",
      y = "Return (%)",
      color = NULL
    ) +
    theme(
      plot.title = element_text(face = "bold", size = 11),
      legend.position = "top",
      legend.margin = margin(0, 0, 0, 0)
    )
  
  # Plot 2: Realized Volatility vs Expected (Conditional) Volatility
  max_vol <- max(c(daily_data$Realized_Vol, daily_data$Sigma), na.rm = TRUE)
  
  p2 <- ggplot(daily_data, aes(x = Date)) +
    geom_line(aes(y = Realized_Vol, color = "Observed Realized Vol"), linewidth = 0.7, alpha = 0.6) +
    geom_line(aes(y = Sigma, color = "Conditional Vol (Sigma)"), linewidth = 1) +
    scale_color_manual(values = c("Observed Realized Vol" = "steelblue", "Conditional Vol (Sigma)" = "forestgreen")) +
    coord_cartesian(ylim = c(0, max_vol * 1.1)) +
    theme_minimal(base_size = 11) +
    labs(
      title = paste(ifelse(is_realgarch, "Realized GARCH", "sGARCH"), "Volatility Fit"),
      x = "Date",
      y = "Volatility (%)",
      color = NULL
    ) +
    theme(
      plot.title = element_text(face = "bold", size = 11),
      legend.position = "top",
      legend.margin = margin(0, 0, 0, 0)
    )
  
  # Plot 3: Residual Autocorrelation (Custom ggplot ACF)
  acf_res <- acf(daily_data$Std_Residuals^2, plot = FALSE, lag.max = 20)
  acf_df <- data.frame(Lag = acf_res$lag[,,1], ACF = acf_res$acf[,,1])
  ci_bound <- 2 / sqrt(nrow(daily_data))
  
  p3 <- ggplot(acf_df, aes(x = Lag, y = ACF)) +
    geom_hline(yintercept = 0, color = "gray30") +
    geom_hline(yintercept = c(ci_bound, -ci_bound), linetype = "dashed", color = "blue", alpha = 0.6) +
    geom_segment(aes(xend = Lag, yend = 0), color = "midnightblue", linewidth = 0.9) +
    geom_point(color = "midnightblue", size = 1.5) +
    theme_minimal(base_size = 11) +
    labs(
      title = "ACF of Squared Standardized Residuals",
      x = "Lag",
      y = "ACF"
    ) +
    theme(plot.title = element_text(face = "bold", size = 11))
  
  # Plot 4: Standardized Residuals Density vs Normal Distribution
  p4 <- ggplot(daily_data, aes(x = Std_Residuals)) +
    geom_histogram(aes(y = after_stat(density)), bins = 30, fill = "purple4", color = "white", alpha = 0.6) +
    geom_density(color = "purple4", linewidth = 1) +
    stat_function(fun = dnorm, args = list(mean = 0, sd = 1), color = "black", linetype = "dashed", linewidth = 1) +
    theme_minimal(base_size = 11) +
    labs(
      title = "Standardized Residuals Density",
      x = "Standardized Residuals",
      y = "Density"
    ) +
    theme(plot.title = element_text(face = "bold", size = 11))
  
  # Combine using patchwork layout
  diagnostic_dashboard <- (p1 + p2) / (p3 + p4) +
    plot_annotation(
      title = paste("Volatility Model Diagnostics Dashboard | Ticker:", current_ric),
      theme = theme(plot.title = element_text(face = "bold", size = 14, hjust = 0.5))
    )
  
  # Save High-Resolution Plot to Photo Folder
  png_path <- file.path(output_dir_png, paste0("HFD_RealGARCH_Diagnostics_", gsub("[^A-Za-z0-9]", "_", current_ric), ".png"))
  ggsave(png_path, diagnostic_dashboard, width = 12, height = 9, dpi = 150)
  
  all_garch_results[[current_ric]] <- list(
    data           = daily_data,
    model_type     = ifelse(is_realgarch, "Realized GARCH", "Standard GARCH"),
    fit_object     = opt_res,
    coefficients   = coefs,
    AIC            = info_crits[1],
    BIC            = info_crits[2],
    log_likelihood = log_lik
  )
}

# Step 5: Save Output Binary RDS Object
if (length(all_garch_results) > 0) {
  rds_output_path <- file.path(output_dir_rds, paste0("hfd_realgarch_results_ALL_", extraction_date, ".rds"))
  saveRDS(all_garch_results, file = rds_output_path)
  cat("\nProcess complete! Realized GARCH Model results exported to RDS successfully.\n")
}
