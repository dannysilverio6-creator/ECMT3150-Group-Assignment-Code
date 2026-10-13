# ==============================================================================
# Script Name: HFD_XGBOOST_MODEL.R
# Pipeline Stage: Stage 2 - High-Frequency Machine Learning Pipeline
# Description: Dynamically locates LSEG HFD Excel file, aggregates intraday data,
#              extracts HAR-RV lags (Daily, Weekly, Monthly RV) and Realized 
#              GARCH conditional volatility as features. Trains an XGBoost 
#              regression model to predict 1-day ahead Realized Volatility.
#              Outputs publication-quality diagnostic dashboards and RDS models.
# ==============================================================================

# 1. Load Required Libraries
required_packages <- c("readxl", "dplyr", "lubridate", "rugarch", "xgboost", "ggplot2", "patchwork", "zoo", "tidyr")
for (pkg in required_packages) {
  if (!require(pkg, character.only = TRUE)) {
    install.packages(pkg, dependencies = TRUE)
    library(pkg, character.only = TRUE)
  }
}

# 2. Setup Output Directories
output_dir_png <- "Pipeline_Outputs/PNG_Plots/HFD_XGBOOST"
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
# Master Loop: Feature Engineering, XGBoost Training, and Diagnostics
# ==============================================================================

unique_rics <- unique(hfd_raw$RIC)
all_xgb_results <- list()
options(device.ask.default = FALSE)

for (current_ric in unique_rics) {
  cat("\n------------------------------------------------------\n")
  cat("Processing XGBoost Hybrid for Ticker:", current_ric, "\n")
  cat("------------------------------------------------------\n")
  
  df_ticker <- hfd_raw %>%
    filter(RIC == current_ric, !is.na(Timestamp)) %>%
    arrange(Timestamp)
  
  # Dynamic Price Column Detection
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
  
  # Step 1: Aggregate High-Frequency Data to Daily Realized Volatility
  daily_data <- df_ticker %>%
    filter(!is.na(Price) & Price > 0) %>%
    mutate(Date = as.Date(Timestamp, tz = "UTC")) %>%
    group_by(Date) %>%
    arrange(Timestamp) %>%
    mutate(intraday_ret = log(Price / lag(Price)) * 100) %>%
    summarise(
      Daily_Return = sum(intraday_ret, na.rm = TRUE),
      RV_pct = sum(intraday_ret^2, na.rm = TRUE),
      N_trades = n(),
      .groups = "drop"
    ) %>%
    filter(N_trades >= 10 & RV_pct > 0) %>%
    mutate(Realized_Vol = sqrt(RV_pct)) %>%
    arrange(Date)
  
  if (nrow(daily_data) < 40) {
    cat("Insufficient daily aggregated observations for", current_ric, "- skipping...\n")
    next
  }
  
  # Step 2: Fit Realized GARCH to extract Conditional Volatility (Sigma) Feature
  cat("  -> Extracting Realized GARCH Conditional Volatility...\n")
  spec_realgarch <- ugarchspec(
    mean.model = list(armaOrder = c(0, 0), include.mean = TRUE),
    variance.model = list(model = "realGARCH", garchOrder = c(1, 1))
  )
  
  garch_fit <- try(
    ugarchfit(spec = spec_realgarch, data = daily_data$Daily_Return, realizedVol = daily_data$Realized_Vol, solver = "hybrid"), 
    silent = TRUE
  )
  
  if (inherits(garch_fit, "try-error") || convergence(garch_fit) != 0) {
    cat("  -> RealGARCH failed. Falling back to sGARCH(1,1) for feature extraction...\n")
    spec_sgarch <-
