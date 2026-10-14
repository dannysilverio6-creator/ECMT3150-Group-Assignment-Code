# ==============================================================================
# Script Name: S2 INSTALLATIONS.R
# Pipeline Stage: Stage 2 - Prerequisites
# Description: Installs every R package used by the Stage 2 volatility models
#              (HAR-RV, Realized GARCH, GARCH, SV) and the Stage 3 XGBoost
#              hybrids, then verifies they load. Exits with an error if any
#              package is still missing, so the orchestrator stops here
#              instead of failing later inside a model script.
# ==============================================================================

cat("\n======================================================\n")
cat("Starting Stage 2/3 Package Installations\n")
cat("======================================================\n\n")

required_packages <- c(
  "readxl",    # Data ingestion
  "dplyr",     # Data manipulation
  "tidyr",     # Data manipulation
  "lubridate", # Date/time handling
  "zoo",       # Rolling window calculations
  "xts",       # Time-indexed series (required by rugarch realGARCH)
  "ggplot2",   # Plotting
  "patchwork", # Plot layout combination
  "rugarch",   # GARCH & Realized GARCH modeling
  "forecast",  # ACF plots
  "stochvol",  # Bayesian Stochastic Volatility modeling
  "xgboost"    # Stage 3 machine-learning hybrids
)

installed <- rownames(installed.packages())
new_packages <- required_packages[!(required_packages %in% installed)]

if (length(new_packages) > 0) {
  cat("Installing missing packages:", paste(new_packages, collapse = ", "), "\n\n")
  install.packages(new_packages, dependencies = TRUE, repos = "https://cloud.r-project.org")
} else {
  cat("All required packages are already installed.\n")
}

verification <- vapply(required_packages, requireNamespace, logical(1), quietly = TRUE)
cat("\nPackage versions:\n")
for (p in required_packages[verification]) {
  cat(sprintf("  %-10s %s\n", p, as.character(utils::packageVersion(p))))
}

if (all(verification)) {
  cat("\n======================================================\n")
  cat("Success: All Stage 2/3 packages are installed and ready.\n")
  cat("======================================================\n")
} else {
  failed <- names(verification)[!verification]
  cat("\n======================================================\n")
  cat("ERROR: The following packages failed to install:\n")
  cat(paste(failed, collapse = ", "), "\n")
  cat("======================================================\n")
  quit(status = 1)
}
