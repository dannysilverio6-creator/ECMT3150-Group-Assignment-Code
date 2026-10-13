# ==============================================================================
# Script Name: STAGE2_INSTALLATIONS.R
# Pipeline Stage: Stage 2 - Prerequisites
# Description: Pre-installs all required packages for the Stage 2 volatility 
#              modeling scripts (HAR-RV, Realized GARCH, GARCH, and SV) to 
#              reduce pipeline execution time.
# ==============================================================================

cat("\n======================================================\n")
cat("Starting Stage 2 Package Installations\n")
cat("======================================================\n\n")

# Consolidated list of unique packages from all Stage 2 scripts
required_packages <- c(
  "readxl",    # Data ingestion
  "dplyr",     # Data manipulation
  "tidyr",     # Data manipulation
  "lubridate", # Date/time handling
  "zoo",       # Rolling window calculations
  "ggplot2",   # Plotting
  "patchwork", # Plot layout combination
  "rugarch",   # GARCH & Realized GARCH modeling
  "forecast",  # Forecasting metrics & ACF
  "stochvol"   # Bayesian Stochastic Volatility modeling
)

# Identify missing packages
new_packages <- required_packages[!(required_packages %in% installed.packages()[,"Package"])]

# Install missing packages
if(length(new_packages) > 0) {
  cat("Installing missing packages:", paste(new_packages, collapse = ", "), "\n\n")
  install.packages(new_packages, dependencies = TRUE, repos = "https://cloud.r-project.org")
} else {
  cat("All required packages are already installed.\n")
}

# Verify installation success
verification <- sapply(required_packages, requireNamespace, quietly = TRUE)
if (all(verification)) {
  cat("\n======================================================\n")
  cat("Success: All Stage 2 packages are installed and ready.\n")
  cat("======================================================\n")
} else {
  failed <- names(verification)[!verification]
  cat("\n======================================================\n")
  cat("Warning: The following packages failed to install:\n")
  cat(paste(failed, collapse = ", "), "\n")
  cat("======================================================\n")
}
