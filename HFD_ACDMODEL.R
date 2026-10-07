# ==============================================================================
# Script Name: HFD_ACDMODEL.R
# Pipeline Stage: Stage 2 - High-Frequency Data Pipeline (ACD Model)
# Description: Dynamically locates LSEG HFD Excel file, extracts 'Data_Long', 
#              applies diurnal adjustment to non-zero durations prior to 
#              estimation, fits EACD(1,1) with robust boundary constraints and 
#              fallback proxies, and plots publication-quality ggplot2 dashboards.
# ==============================================================================

# 1. Load Required Libraries
required_packages <- c("readxl", "dplyr", "lubridate", "rugarch", "forecast", "ggplot2", "patchwork")
for (pkg in required_packages) {
  if (!require(pkg, character.only = TRUE)) {
    install.packages(pkg, dependencies = TRUE)
    library(pkg, character.only = TRUE)
  }
}

# 2. Setup Output Directories
output_dir_png <- "Pipeline_Outputs/PNG_Plots/HFD_ACD"
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
# Master Loop: Process, Fit ACD, and Plot ggplot2 Diagnostics Dashboard
# ==============================================================================

unique_rics <- unique(hfd_raw$RIC)
all_acd_results <- list()
options(device.ask.default = FALSE)

for (current_ric in unique_rics) {
  cat("\n------------------------------------------------------\n")
  cat("Processing Ticker:", current_ric, "\n")
  cat("------------------------------------------------------\n")
  
  hfd_ticker <- hfd_raw %>%
    filter(RIC == current_ric) %>%
    filter(!is.na(Timestamp)) %>%
    arrange(Timestamp)
  
  if (nrow(hfd_ticker) < 10) {
    cat("Insufficient observations for", current_ric, "- skipping...\n")
    next
  }
  
  # Step 1: Compute Raw Durations & Filter 0-second durations prior to spline fitting
  hfd_ticker <- hfd_ticker %>%
    mutate(
      duration_raw = as.numeric(difftime(Timestamp, lag(Timestamp), units = "secs")),
      tod_seconds  = hour(Timestamp) * 3600 + minute(Timestamp) * 60 + second(Timestamp)
    ) %>%
    filter(!is.na(duration_raw) & duration_raw > 0)
  
  if (nrow(hfd_ticker) < 10) {
    cat("Insufficient non-zero duration observations for", current_ric, "- skipping...\n")
    next
  }
  
  # Step 2: Diurnal Adjustment via Cubic Spline on Time-of-Day
  spline_fit <- try(smooth.spline(hfd_ticker$tod_seconds, hfd_ticker$duration_raw, df = 6), silent = TRUE)
  
  if (inherits(spline_fit, "try-error")) {
    hfd_ticker$diurnal_factor <- mean(hfd_ticker$duration_raw, na.rm = TRUE)
  } else {
    pred_y <- predict(spline_fit, hfd_ticker$tod_seconds)$y
    hfd_ticker$diurnal_factor <- pmax(1e-4, pred_y)
  }
  
  # Step 3: Compute Diurnally Adjusted Durations
  hfd_ticker <- hfd_ticker %>%
    mutate(adj_duration = duration_raw / diurnal_factor) %>%
    filter(!is.na(adj_duration) & adj_duration > 0)
  
  durations <- hfd_ticker$adj_duration
  
  # Step 4: EACD(1,1) Log-Likelihood with Boundary Constraint Protections
  log_likelihood_eacd <- function(pars, durations) {
    omega <- pars[1]; alpha <- pars[2]; beta  <- pars[3]
    
    if (omega <= 1e-6 || alpha < 0 || beta < 0 || (alpha + beta) >= 0.9999) {
      return(1e10)
    }
    
    n <- length(durations)
    psi <- numeric(n)
    psi[1] <- mean(durations)
    
    for (i in 2:n) {
      psi[i] <- max(1e-6, omega + alpha * durations[i - 1] + beta * psi[i - 1])
    }
    
    ll <- -sum(-log(psi) - (durations / psi))
    if (is.na(ll) || is.infinite(ll)) return(1e10)
    return(ll)
  }
  
  init_params <- c(omega = 0.01, alpha = 0.10, beta = 0.80)
  
  opt_res <- try(optim(
    par     = init_params,
    fn      = log_likelihood_eacd,
    durations = durations,
    method  = "L-BFGS-B",
    lower   = c(1e-5, 1e-5, 1e-5),
    upper   = c(2.0, 0.98, 0.98)
  ), silent = TRUE)
  
  if (inherits(opt_res, "try-error") || opt_res$convergence != 0) {
    fallback_init <- c(omega = 0.05 * mean(durations), alpha = 0.05, beta = 0.85)
    opt_res <- try(optim(
      par     = fallback_init,
      fn      = log_likelihood_eacd,
      durations = durations,
      method  = "L-BFGS-B",
      lower   = c(1e-5, 1e-5, 1e-5),
      upper   = c(2.0, 0.98, 0.98)
    ), silent = TRUE)
  }
  
  # ROBUST FALLBACK WRAPPER: If optim completely fails, use mathematical defaults
  if (inherits(opt_res, "try-error") || opt_res$convergence != 0) {
    cat("Warning: ACD Model optimization failed to converge for", current_ric, "- applying baseline persistence parameters.\n")
    omega_hat <- 0.05 * mean(durations, na.rm = TRUE)
    alpha_hat <- 0.10
    beta_hat  <- 0.80
    log_lik   <- NA
    aic_val   <- NA
    bic_val   <- NA
  } else {
    pars <- opt_res$par
    omega_hat <- pars[1]; alpha_hat <- pars[2]; beta_hat  <- pars[3]
    log_lik <- -opt_res$value
    n <- length(durations)
    aic_val <- 2 * length(pars) - 2 * log_lik
    bic_val <- log(n) * length(pars) - 2 * log_lik
  }
  
  n <- length(durations)
  psi_hat <- numeric(n)
  psi_hat[1] <- mean(durations)
  for (i in 2:n) {
    psi_hat[i] <- omega_hat + alpha_hat * durations[i - 1] + beta_hat * psi_hat[i - 1]
  }
  
  hfd_ticker$expected_duration <- psi_hat
  hfd_ticker$acd_residuals <- hfd_ticker$adj_duration / psi_hat
  
  cat("Fit complete: Omega=", round(omega_hat, 4), 
      " Alpha=", round(alpha_hat, 4), 
      " Beta=", round(beta_hat, 4), 
      " Persistence=", round(alpha_hat + beta_hat, 4), "\n")
  
  # Step 5: Publication-Quality ggplot2 Diagnostic Dashboards
  
  # Plot 1: Diurnal Seasonal Curve
  diurnal_df <- hfd_ticker %>%
    group_by(tod_seconds) %>%
    summarise(diurnal_factor = mean(diurnal_factor, na.rm = TRUE), .groups = "drop") %>%
    arrange(tod_seconds)
  
  p1 <- ggplot(diurnal_df, aes(x = tod_seconds / 3600, y = diurnal_factor)) +
    geom_line(color = "forestgreen", linewidth = 1) +
    theme_minimal(base_size = 11) +
    labs(
      title = "Diurnal Seasonal Curve",
      x = "Time of Day (Hours)",
      y = "Diurnal Multiplier"
    ) +
    theme(plot.title = element_text(face = "bold", size = 11))
  
  # Plot 2: ACD Expected Duration Fit
  plot_sample <- head(hfd_ticker, min(250, nrow(hfd_ticker)))
  max_y <- min(quantile(plot_sample$adj_duration, 0.98, na.rm = TRUE) * 1.5, max(plot_sample$adj_duration, na.rm = TRUE))
  
  p2 <- ggplot(plot_sample, aes(x = Timestamp)) +
    geom_line(aes(y = adj_duration, color = "Observed"), linewidth = 0.6, alpha = 0.7) +
    geom_line(aes(y = expected_duration, color = "ACD Expected"), linewidth = 1) +
    scale_color_manual(values = c("Observed" = "gray60", "ACD Expected" = "darkred")) +
    coord_cartesian(ylim = c(0, max_y)) +
    theme_minimal(base_size = 11) +
    labs(
      title = "ACD(1,1) Expected Duration Fit",
      x = "Time",
      y = "Duration (secs)",
      color = NULL
    ) +
    theme(
      plot.title = element_text(face = "bold", size = 11),
      legend.position = "top",
      legend.margin = margin(0, 0, 0, 0)
    )
  
  # Plot 3: Residual Autocorrelation (Custom ggplot ACF)
  acf_res <- acf(hfd_ticker$acd_residuals, plot = FALSE, lag.max = 20)
  acf_df <- data.frame(Lag = acf_res$lag[,,1], ACF = acf_res$acf[,,1])
  ci_bound <- 2 / sqrt(nrow(hfd_ticker))
  
  p3 <- ggplot(acf_df, aes(x = Lag, y = ACF)) +
    geom_hline(yintercept = 0, color = "gray30") +
    geom_hline(yintercept = c(ci_bound, -ci_bound), linetype = "dashed", color = "blue", alpha = 0.6) +
    geom_segment(aes(xend = Lag, yend = 0), color = "midnightblue", linewidth = 0.9) +
    geom_point(color = "midnightblue", size = 1.5) +
    theme_minimal(base_size = 11) +
    labs(
      title = "ACF of Standardized Residuals",
      x = "Lag",
      y = "ACF"
    ) +
    theme(plot.title = element_text(face = "bold", size = 11))
  
  # Plot 4: Dynamic Trade Intensity Rate (1 / Psi)
  plot_sample <- plot_sample %>% mutate(intensity = 1 / expected_duration)
  max_int <- min(quantile(plot_sample$intensity, 0.98, na.rm = TRUE) * 1.5, max(plot_sample$intensity, na.rm = TRUE))
  
  p4 <- ggplot(plot_sample, aes(x = Timestamp, y = intensity)) +
    geom_line(color = "purple4", linewidth = 1) +
    coord_cartesian(ylim = c(0, max_int)) +
    theme_minimal(base_size = 11) +
    labs(
      title = "Trade Intensity Dynamic Rate",
      x = "Time",
      y = "Intensity (1 / Psi)"
    ) +
    theme(plot.title = element_text(face = "bold", size = 11))
  
  # Combine using patchwork layout
  diagnostic_dashboard <- (p1 + p2) / (p3 + p4) +
    plot_annotation(
      title = paste("ACD Model Diagnostics Dashboard | Ticker:", current_ric),
      theme = theme(plot.title = element_text(face = "bold", size = 14, hjust = 0.5))
    )
  
  # Save High-Resolution Plot to Photo Folder
  png_path <- file.path(output_dir_png, paste0("HFD_ACD_Diagnostics_", gsub("[^A-Za-z0-9]", "_", current_ric), ".png"))
  ggsave(png_path, diagnostic_dashboard, width = 12, height = 9, dpi = 150)
  
  all_acd_results[[current_ric]] <- list(
    data           = hfd_ticker,
    coefficients   = c(omega = omega_hat, alpha = alpha_hat, beta = beta_hat),
    persistence    = alpha_hat + beta_hat,
    AIC            = aic_val,
    BIC            = bic_val,
    log_likelihood = log_lik
  )
}

# Step 6: Save Output Binary RDS Object
if (length(all_acd_results) > 0) {
  rds_output_path <- file.path(output_dir_rds, paste0("hfd_acd_results_ALL_", extraction_date, ".rds"))
  saveRDS(all_acd_results, file = rds_output_path)
  cat("\nProcess complete! ACD Model results exported to RDS successfully.\n")
}