# ==============================================================================
# Script Name: HFD_HAR-RV_MODEL.R
# Pipeline Stage: Stage 2 - High-Frequency Volatility Pipeline (HAR-RV Model)
# Description: Dynamically locates LSEG HFD Excel file, aggregates intraday 
#              returns to calculate daily Realized Volatility, fits a 
#              Heterogeneous Autoregressive (HAR-RV) model using Daily, Weekly, 
#              and Monthly volatility components, and outputs publication-quality 
#              ggplot2 / patchwork diagnostic dashboards.
# ==============================================================================

# 1. Load required libraries
required_packages <- c("readxl", "dplyr", "lubridate", "ggplot2", "patchwork", "zoo", "tidyr")
for (pkg in required_packages) {
  if (!require(pkg, character.only = TRUE)) {
    install.packages(pkg, dependencies = TRUE)
    library(pkg, character.only = TRUE)
  }
}

# 2. Setup Output Directories
output_dir_png <- "Pipeline_Outputs/PNG_Plots/HFD_HAR_RV"
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
# Master Loop: Process, Fit HAR-RV, and Plot Diagnostics for EACH Company
# ==============================================================================

unique_rics <- unique(hfd_raw$RIC)
all_harrv_results <- list()

options(device.ask.default = FALSE)

for (current_ric in unique_rics) {
  cat("\n------------------------------------------------------\n")
  cat("Processing HAR-RV for Ticker:", current_ric, "\n")
  cat("------------------------------------------------------\n")
  
  # 5. Filter and clean ticker data
  df_ticker <- hfd_raw %>%
    filter(RIC == current_ric) %>%
    filter(!is.na(Timestamp)) %>%
    arrange(Timestamp)
  
  if (nrow(df_ticker) < 50) {
    cat("Insufficient high-frequency observations for", current_ric, "- skipping...\n")
    next
  }
  
  # Dynamic Price Column Detection (Fallback for 'Close')
  price_col <- if ("Mid" %in% names(df_ticker)) {
    "Mid"
  } else if ("Close" %in% names(df_ticker)) {
    "Close"
  } else if ("TRDPRC_1" %in% names(df_ticker)) {
    "TRDPRC_1"
  } else {
    names(df_ticker)[sapply(df_ticker, is.numeric)][1]
  }
  
  df_ticker$Price <- as.numeric(df_ticker[[price_col]])
  
  # 6. Aggregate High-Frequency Data to Daily Realized Volatility
  daily_data <- df_ticker %>%
    filter(!is.na(Price) & Price > 0) %>%
    mutate(Date = as.Date(Timestamp, tz = "UTC")) %>%
    group_by(Date) %>%
    arrange(Timestamp) %>%
    mutate(
      intraday_ret = log(Price / lag(Price)) * 100
    ) %>%
    summarise(
      RV_pct = sum(intraday_ret^2, na.rm = TRUE),
      N_trades = n(),
      .groups = "drop"
    ) %>%
    filter(N_trades >= 10 & RV_pct > 0) %>%
    mutate(Realized_Vol = sqrt(RV_pct)) %>%
    arrange(Date)
  
  # Minimum requirement: need at least 25 days to compute a 22-day rolling window + lead target
  if (nrow(daily_data) < 30) {
    cat("Insufficient daily aggregated observations (N < 30) for HAR-RV on", current_ric, "- skipping...\n")
    next
  }
  
  # 7. Construct HAR-RV Components (Daily, Weekly=5d, Monthly=22d)
  har_data <- daily_data %>%
    mutate(
      RV_Daily = Realized_Vol,
      RV_Weekly = rollmeanr(Realized_Vol, k = 5, fill = NA),
      RV_Monthly = rollmeanr(Realized_Vol, k = 22, fill = NA),
      # Target is tomorrow's Realized Volatility
      RV_Target = lead(Realized_Vol, n = 1)
    ) %>%
    # Remove NAs generated by rolling windows and the final lead value
    filter(complete.cases(RV_Daily, RV_Weekly, RV_Monthly, RV_Target))
  
  if (nrow(har_data) < 10) {
    cat("Insufficient data points after HAR-RV window rolling for", current_ric, "- skipping...\n")
    next
  }
  
  # 8. Fit HAR-RV Linear Model
  cat("Estimating HAR-RV model for", current_ric, "...\n")
  har_fit <- try(lm(RV_Target ~ RV_Daily + RV_Weekly + RV_Monthly, data = har_data), silent = TRUE)
  
  if (inherits(har_fit, "try-error")) {
    cat("Failed to fit HAR-RV model for", current_ric, "\n")
    next
  }
  
  # Extract fitted values, residuals, and coefficients
  har_data$Predicted_RV <- predict(har_fit)
  har_data$Residuals <- residuals(har_fit)
  
  pars <- coef(har_fit)
  summary_fit <- summary(har_fit)
  r_squared <- summary_fit$r.squared
  adj_r_squared <- summary_fit$adj.r.squared
  
  cat("Fit complete: \n",
      " Intercept =", round(pars["(Intercept)"], 4), "\n",
      " Beta_Daily =", round(pars["RV_Daily"], 4), "\n",
      " Beta_Weekly =", round(pars["RV_Weekly"], 4), "\n",
      " Beta_Monthly =", round(pars["RV_Monthly"], 4), "\n",
      " R-Squared =", round(r_squared, 4), "\n")
  
  # ==============================================================================
  # 9. Publication-Quality ggplot2 Diagnostic Dashboards
  # ==============================================================================
  
  # Plot 1: Time Series of Observed vs HAR Predicted Volatility
  max_y <- max(c(har_data$RV_Target, har_data$Predicted_RV), na.rm = TRUE) * 1.1
  
  p1 <- ggplot(har_data, aes(x = Date)) +
    geom_line(aes(y = RV_Target, color = "Observed RV (Target)"), linewidth = 0.6, alpha = 0.7) +
    geom_line(aes(y = Predicted_RV, color = "HAR-RV Forecast"), linewidth = 1) +
    scale_color_manual(values = c("Observed RV (Target)" = "gray60", "HAR-RV Forecast" = "darkred")) +
    coord_cartesian(ylim = c(0, max_y)) +
    theme_minimal(base_size = 11) +
    labs(
      title = "HAR-RV: 1-Day Ahead Volatility Forecast", 
      x = "Date", 
      y = "Realized Volatility (%)", 
      color = NULL
    ) +
    theme(
      plot.title = element_text(face = "bold", size = 11),
      legend.position = "top",
      legend.margin = margin(0, 0, 0, 0)
    )
  
  # Plot 2: HAR Component Coefficients & Significance
  coef_df <- data.frame(
    Component = c("Daily", "Weekly", "Monthly"),
    Estimate = pars[2:4],
    StdError = summary_fit$coefficients[2:4, 2]
  )
  coef_df$Component <- factor(coef_df$Component, levels = c("Daily", "Weekly", "Monthly"))
  
  p2 <- ggplot(coef_df, aes(x = Component, y = Estimate, fill = Component)) +
    geom_bar(stat = "identity", width = 0.5, color = "black", alpha = 0.8) +
    geom_errorbar(aes(ymin = Estimate - 1.96 * StdError, ymax = Estimate + 1.96 * StdError), width = 0.15, linewidth = 0.8) +
    scale_fill_manual(values = c("Daily" = "steelblue", "Weekly" = "forestgreen", "Monthly" = "goldenrod")) +
    theme_minimal(base_size = 11) +
    labs(
      title = "HAR-RV Component Weights (with 95% CI)",
      x = "Volatility Horizon",
      y = "Coefficient Estimate"
    ) +
    theme(
      plot.title = element_text(face = "bold", size = 11),
      legend.position = "none"
    )
  
  # Plot 3: ACF of Model Residuals
  acf_res <- acf(har_data$Residuals, plot = FALSE, lag.max = 20)
  acf_df <- data.frame(Lag = acf_res$lag[,,1], ACF = acf_res$acf[,,1])
  ci_bound <- 2 / sqrt(nrow(har_data))
  
  p3 <- ggplot(acf_df, aes(x = Lag, y = ACF)) +
    geom_hline(yintercept = 0, color = "gray30") +
    geom_hline(yintercept = c(ci_bound, -ci_bound), linetype = "dashed", color = "blue", alpha = 0.6) +
    geom_segment(aes(xend = Lag, yend = 0), color = "midnightblue", linewidth = 0.9) +
    geom_point(color = "midnightblue", size = 1.5) +
    theme_minimal(base_size = 11) +
    labs(
      title = "ACF of HAR-RV Residuals", 
      x = "Lag", 
      y = "ACF"
    ) +
    theme(plot.title = element_text(face = "bold", size = 11))
  
  # Plot 4: Residuals Density vs Normal Distribution
  p4 <- ggplot(har_data, aes(x = scale(Residuals))) +
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
      title = paste("HAR-RV Diagnostics | Ticker:", current_ric),
      subtitle = paste0("Adj R-Squared: ", round(adj_r_squared, 4)),
      theme = theme(
        plot.title = element_text(face = "bold", size = 14, hjust = 0.5),
        plot.subtitle = element_text(size = 11, hjust = 0.5, color = "gray30")
      )
    )
  
  # Save High-Resolution Plot to PNG Folder
  png_path <- file.path(output_dir_png, paste0("HFD_HARRV_Diagnostics_", gsub("[^A-Za-z0-9]", "_", current_ric), ".png"))
  ggsave(png_path, diagnostic_dashboard, width = 12, height = 9, dpi = 150)
  
  # Store model results
  all_harrv_results[[current_ric]] <- list(
    data = har_data,
    fit = har_fit,
    coefficients = pars,
    r_squared = r_squared,
    adj_r_squared = adj_r_squared,
    AIC = AIC(har_fit),
    BIC = BIC(har_fit)
  )
}

# 10. Save Output Binary RDS Object to Central Folder
if (length(all_harrv_results) > 0) {
  rds_output_path <- file.path(output_dir_rds, paste0("hfd_harrv_results_ALL_", extraction_date, ".rds"))
  saveRDS(all_harrv_results, file = rds_output_path)
  cat("\nProcess complete! HAR-RV models fitted and publication-quality plots rendered for all companies.\n")
}
