# ==============================================================================
# Script Name: ECMT3150_COMMON.R
# Purpose    : Shared helpers for every R model script in the pipeline.
#
#   * ONE definition of where inputs and outputs live, so every stage reads
#     and writes the same folders no matter which folder R was started from
#     (VS Code terminal, RStudio, or the Python orchestrator).
#   * ONE loader for the merged LSEG workbooks written by Stage 1
#     (sheets "Historical - Returns" / "Event - Returns" for LFD and
#     "Historical CSV" / "Event CSV" for HFD).
#   * ONE definition of the forecast target and the chronological
#     train/test split, so all models in a branch are scored on the
#     same dates and can be compared fairly.
#
# Folder layout (created automatically):
#
#   <project>/ECMT3150 OUTPUTS/
#       ECMT3150_LSEG_OUTPUTs/          <- Stage 1 workbooks (LSEG_LFD.xlsx, LSEG_HFD.xlsx)
#       Pipeline_Outputs/
#           RDS_Models/<MODEL>.rds      <- full R objects
#           Model_Tables/<MODEL>/*.csv  <- summary, OOS metrics, OOS forecasts
#           PNG_Plots/<MODEL>/*.png     <- diagnostic dashboards
#           Consolidated_Results/       <- Stage 2/3 benchmark workbooks
#           Conclusive_Results/         <- Stage 4 workbook
#       PHOTOS/<MODEL>/                 <- plots sorted by model (Stage 4)
#
# Override the output folder with the environment variable ECMT3150_OUTPUT_DIR.
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. Paths
# ------------------------------------------------------------------------------

ecmt_project_root <- function() {
  env_root <- Sys.getenv("ECMT3150_PROJECT_ROOT", "")
  if (nzchar(env_root) && file.exists(file.path(env_root, "ECMT3150_COMMON.R"))) {
    return(normalizePath(env_root, winslash = "/"))
  }
  if (exists("ECMT_PROJECT_ROOT", inherits = TRUE)) {
    return(normalizePath(get("ECMT_PROJECT_ROOT", inherits = TRUE), winslash = "/"))
  }
  normalizePath(getwd(), winslash = "/")
}

ECMT_ROOT <- ecmt_project_root()

ECMT_OUTPUT_ROOT <- local({
  env_out <- Sys.getenv("ECMT3150_OUTPUT_DIR", "")
  path <- if (nzchar(env_out)) env_out else file.path(ECMT_ROOT, "ECMT3150 OUTPUTS")
  dir.create(path, recursive = TRUE, showWarnings = FALSE)
  normalizePath(path, winslash = "/")
})

ECMT_LSEG_DIR     <- file.path(ECMT_OUTPUT_ROOT, "ECMT3150_LSEG_OUTPUTs")
ECMT_PIPELINE_DIR <- file.path(ECMT_OUTPUT_ROOT, "Pipeline_Outputs")
ECMT_RDS_DIR      <- file.path(ECMT_PIPELINE_DIR, "RDS_Models")
ECMT_TABLE_DIR    <- file.path(ECMT_PIPELINE_DIR, "Model_Tables")
ECMT_PNG_DIR      <- file.path(ECMT_PIPELINE_DIR, "PNG_Plots")

# Fraction of the common modelling sample used for estimation/training.
# Set ECMT3150_SPLIT=event to train on the Historical period and test on the
# Event period instead (only possible with the merged Stage 1 workbooks).
ECMT_TRAIN_FRACTION <- 0.8
ECMT_SEED <- 3150

# First trading day after the initial strikes (Sat 28 Feb 2026). Used by the
# event study and by the optional event split. Override with ECMT3150_EVENT_DATE.
ECMT_EVENT_DATE <- as.Date(Sys.getenv("ECMT3150_EVENT_DATE", "2026-03-02"))

# Out-of-sample forecasts use an EXPANDING estimation window: parameters are
# re-estimated every N test observations using all data up to that origin.
# Daily data: refit monthly (21 trading days). HFD: refit every day (the test
# window is only a couple of weeks long and the models are cheap).
ECMT_REFIT_EVERY_LFD <- as.integer(Sys.getenv("ECMT3150_REFIT_EVERY_LFD", "21"))
ECMT_REFIT_EVERY_HFD <- as.integer(Sys.getenv("ECMT3150_REFIT_EVERY_HFD", "1"))

# Prepare clean output folders for one model. Old files from earlier runs are
# removed first, so a model that fails cannot leave stale results behind for
# the collectors to pick up.
ecmt_model_dirs <- function(model_key) {
  dirs <- list(
    png   = file.path(ECMT_PNG_DIR, model_key),
    table = file.path(ECMT_TABLE_DIR, model_key),
    rds   = file.path(ECMT_RDS_DIR, paste0(model_key, ".rds"))
  )
  unlink(dirs$png, recursive = TRUE)
  unlink(dirs$table, recursive = TRUE)
  if (file.exists(dirs$rds)) file.remove(dirs$rds)
  dir.create(dirs$png, recursive = TRUE, showWarnings = FALSE)
  dir.create(dirs$table, recursive = TRUE, showWarnings = FALSE)
  dir.create(ECMT_RDS_DIR, recursive = TRUE, showWarnings = FALSE)
  dirs
}

ecmt_safe_name <- function(x) gsub("[^A-Za-z0-9]+", "_", x)

ecmt_require <- function(pkgs) {
  missing <- pkgs[!vapply(pkgs, requireNamespace, logical(1), quietly = TRUE)]
  if (length(missing) > 0) {
    message("Installing missing packages: ", paste(missing, collapse = ", "))
    install.packages(missing, repos = "https://cloud.r-project.org")
  }
  still_missing <- pkgs[!vapply(pkgs, requireNamespace, logical(1), quietly = TRUE)]
  if (length(still_missing) > 0) {
    stop("Required R packages are not installed: ", paste(still_missing, collapse = ", "),
         "\nRun STAGE2/S2 INSTALLATIONS.R first.", call. = FALSE)
  }
  for (p in pkgs) suppressPackageStartupMessages(library(p, character.only = TRUE))
  invisible(TRUE)
}

# ------------------------------------------------------------------------------
# 2. Locate the Stage 1 workbook
# ------------------------------------------------------------------------------

# Returns the newest LSEG_<FREQ> workbook. Merged workbooks (LSEG_LFD.xlsx or
# LSEG_LFD_HHMMSS.xlsx when Excel had the file locked) are preferred over the
# single-period intermediates (LSEG_LFD_YYYY-MM-DD.xlsx). Excel lock files
# (~$LSEG_...) and pipeline outputs such as HFD_BENCHMARK.xlsx are ignored.
ecmt_find_lseg_workbook <- function(freq = c("LFD", "HFD")) {
  freq <- match.arg(freq)
  search_dirs <- unique(c(ECMT_LSEG_DIR, ECMT_OUTPUT_ROOT, ECMT_ROOT))
  pattern <- paste0("^LSEG_", freq, "(_[0-9_-]+)?\\.xlsx$")

  candidates <- character(0)
  for (d in search_dirs) {
    if (!dir.exists(d)) next
    recursive <- identical(d, ECMT_LSEG_DIR)
    found <- list.files(d, pattern = pattern, full.names = TRUE,
                        recursive = recursive, ignore.case = TRUE)
    candidates <- c(candidates, found)
    if (length(candidates) > 0) break
  }
  candidates <- candidates[!startsWith(basename(candidates), "~$")]

  if (length(candidates) == 0) {
    stop(sprintf(paste0(
      "No LSEG_%s workbook found.\nLooked in:\n  %s\n",
      "Run STAGE1/LSEG_DATA_EXTRACTION.py first, or copy LSEG_%s.xlsx into\n  %s"),
      freq, paste(search_dirs, collapse = "\n  "), freq, ECMT_LSEG_DIR), call. = FALSE)
  }

  is_merged <- grepl(paste0("^LSEG_", freq, "(_[0-9]{6})?\\.xlsx$"), basename(candidates),
                     ignore.case = TRUE)
  mtime <- file.info(candidates)$mtime
  candidates[order(!is_merged, -as.numeric(mtime))][1]
}

# ------------------------------------------------------------------------------
# 3. Read the workbook sheets
# ------------------------------------------------------------------------------

# Sheets that hold more rows than Excel allows contain only a "Note" column;
# the full table is then in csv_<DATASET>/<file>.csv next to the workbook.
.ecmt_read_sheet_or_csv <- function(path, sheet, csv_dir_tag, csv_name, required_col) {
  df <- readxl::read_excel(path, sheet = sheet, guess_max = 100000)
  if (!(required_col %in% names(df))) {
    csv_path <- file.path(dirname(path), paste0("csv_", csv_dir_tag), csv_name)
    if (!file.exists(csv_path)) {
      stop(sprintf("Sheet '%s' in %s has no '%s' column and %s does not exist.",
                   sheet, basename(path), required_col, csv_path), call. = FALSE)
    }
    message("  Sheet '", sheet, "' was too large for Excel; reading ", csv_path)
    df <- utils::read.csv(csv_path, check.names = FALSE, stringsAsFactors = FALSE)
  }
  df
}

.ecmt_period_sheets <- function(sheets, single_name, merged_suffix) {
  merged <- c(Historical = paste0("Historical", merged_suffix),
              Event      = paste0("Event", merged_suffix))
  merged <- merged[merged %in% sheets]
  if (length(merged) > 0) return(merged)
  if (single_name %in% sheets) return(c(All = single_name))
  stop(sprintf("Workbook has neither %s nor %s sheets. Sheets found: %s",
               paste(paste0(c("Historical", "Event"), merged_suffix), collapse = "/"),
               single_name, paste(sheets, collapse = ", ")), call. = FALSE)
}

.ecmt_dataset_tag <- function(path, freq, period) {
  # Merged workbooks keep the CSVs in csv_<FREQ>_HISTORICAL / csv_<FREQ>_EVENT.
  if (period == "All") paste0(freq, "_", "HISTORICAL") else paste0(freq, "_", toupper(period))
}

# Daily returns in wide layout: Date + one column per RIC, sorted by Date,
# with a Period column ("Historical", "Event" or "All").
ecmt_read_lfd_returns <- function(path) {
  sheets <- readxl::excel_sheets(path)
  use <- .ecmt_period_sheets(sheets, "Returns", " - Returns")
  parts <- lapply(names(use), function(period) {
    df <- .ecmt_read_sheet_or_csv(path, use[[period]], .ecmt_dataset_tag(path, "LFD", period),
                                  "returns_wide.csv", "Date")
    df$Date <- as.Date(df$Date)
    df$Period <- period
    df
  })
  out <- dplyr::bind_rows(parts)
  out <- out[!is.na(out$Date), , drop = FALSE]
  out <- out[order(out$Date), , drop = FALSE]
  out <- out[!duplicated(out$Date), , drop = FALSE]
  rownames(out) <- NULL
  out <- .ecmt_rebuild_missing_returns(path, sheets, names(use), out)
  cat("Read LFD returns from sheet(s):", paste(use, collapse = ", "), "\n")
  cat("  Rows:", nrow(out), "| Dates:", format(min(out$Date)), "to", format(max(out$Date)), "\n")
  out
}

# Instruments whose Returns column is (almost) empty - e.g. because LSEG did
# not publish MID_PRICE for an exchange-traded proxy - get log returns rebuilt
# from the Mid sheet, or from (Bid + Ask) / 2 when Mid is also empty. Prices are
# chained across the Historical and Event periods before differencing.
.ecmt_rebuild_missing_returns <- function(path, sheets, periods, out) {
  tickers <- setdiff(names(out), c("Date", "Period"))
  coverage <- vapply(tickers, function(t) mean(!is.na(out[[t]])), numeric(1))
  weak <- tickers[coverage < 0.5 * max(coverage)]
  if (length(weak) == 0) return(out)

  read_wide <- function(suffix) {
    names_needed <- if (identical(periods, "All")) suffix else paste0(periods, " - ", suffix)
    names_needed <- names_needed[names_needed %in% sheets]
    if (length(names_needed) == 0) return(NULL)
    df <- dplyr::bind_rows(lapply(names_needed, function(sh) {
      x <- readxl::read_excel(path, sheet = sh, guess_max = 100000)
      x$Date <- as.Date(x$Date)
      x
    }))
    df[!duplicated(df$Date), , drop = FALSE]
  }
  mid <- read_wide("Mid"); bid <- read_wide("Bid"); ask <- read_wide("Ask")

  for (t in weak) {
    price <- NULL
    if (!is.null(mid) && t %in% names(mid) && mean(!is.na(mid[[t]])) > 0.5) {
      price <- data.frame(Date = mid$Date, P = as.numeric(mid[[t]]), Source = "Mid")
    } else if (!is.null(bid) && !is.null(ask) && t %in% names(bid) && t %in% names(ask)) {
      q <- merge(bid[, c("Date", t)], ask[, c("Date", t)], by = "Date", suffixes = c("_b", "_a"))
      b <- as.numeric(q[[paste0(t, "_b")]]); a <- as.numeric(q[[paste0(t, "_a")]])
      ok <- is.finite(b) & is.finite(a) & b > 0 & a >= b
      price <- data.frame(Date = q$Date, P = ifelse(ok, (b + a) / 2, NA_real_), Source = "(Bid+Ask)/2")
    }
    if (is.null(price) || sum(!is.na(price$P)) < 50) next
    price <- price[!is.na(price$P), , drop = FALSE]
    price <- price[order(price$Date), , drop = FALSE]
    price$R <- c(NA, diff(log(price$P)))
    out[[t]] <- price$R[match(out$Date, price$Date)]
    cat(sprintf("  Rebuilt returns for %s from %s (%d obs) - the Returns sheet was empty.\n",
                t, price$Source[1], sum(!is.na(out[[t]]))))
  }
  out
}

ecmt_lfd_tickers <- function(returns_df) setdiff(names(returns_df), c("Date", "Period"))

# Intraday data in long layout: RIC, Timestamp (POSIXct UTC), price fields, Period.
ecmt_read_hfd_long <- function(path) {
  sheets <- readxl::excel_sheets(path)
  use <- .ecmt_period_sheets(sheets, "Data_Long", " CSV")
  parts <- lapply(names(use), function(period) {
    df <- .ecmt_read_sheet_or_csv(path, use[[period]], .ecmt_dataset_tag(path, "HFD", period),
                                  "data_long.csv", "RIC")
    time_col <- intersect(c("Timestamp", "Datetime", "Date"), names(df))
    if (length(time_col) == 0) stop("No Timestamp column in sheet ", use[[period]], call. = FALSE)
    df$Timestamp <- as.POSIXct(df[[time_col[1]]], tz = "UTC")
    df$Period <- period
    df
  })
  out <- dplyr::bind_rows(parts)
  out <- out[!is.na(out$Timestamp) & !is.na(out$RIC), , drop = FALSE]
  out <- out[!duplicated(out[, c("RIC", "Timestamp")]), , drop = FALSE]
  out <- out[order(out$RIC, out$Timestamp), , drop = FALSE]
  cat("Read HFD data from sheet(s):", paste(use, collapse = ", "), "\n")
  cat("  Rows:", nrow(out), "| Instruments:", paste(unique(out$RIC), collapse = ", "), "\n")
  out
}

ecmt_price_col <- function(df) {
  for (candidate in c("Mid", "Close", "TRDPRC_1", "MID_PRICE")) {
    if (candidate %in% names(df)) return(candidate)
  }
  numeric_cols <- names(df)[vapply(df, is.numeric, logical(1))]
  numeric_cols <- setdiff(numeric_cols, c("Log return", "Simple return"))
  if (length(numeric_cols) == 0) stop("No numeric price column found.", call. = FALSE)
  numeric_cols[1]
}

# Aggregate one instrument's intraday prices to daily return and realised
# volatility (both in percent). Used by every HFD model so the target is
# identical across Realised GARCH, HAR-RV and XGBoost.
# Price used for intraday returns: the Mid column, with gaps filled from
# (Bid + Ask) / 2 (LSEG leaves MID_PRICE empty for many listed instruments).
ecmt_price_series <- function(df) {
  price <- suppressWarnings(as.numeric(df[[ecmt_price_col(df)]]))
  if (all(c("Bid", "Ask") %in% names(df))) {
    b <- suppressWarnings(as.numeric(df$Bid)); a <- suppressWarnings(as.numeric(df$Ask))
    fill <- is.na(price) & is.finite(b) & is.finite(a) & b > 0 & a >= b
    price[fill] <- (b[fill] + a[fill]) / 2
  }
  price
}

# Realised-measure settings.
#  * Trading day: LSEG timestamps are UTC, and spot metals trade in sessions
#    that open around 22:00-23:00 UTC on the PREVIOUS calendar day. Grouping by
#    UTC calendar date splits every session in two and creates spurious
#    one-hour "Sunday" days. Timestamps are therefore shifted forward by
#    ECMT3150_SESSION_OFFSET_HOURS (default 2) before taking the date, so each
#    Globex-style session maps to its trade date (US/Canadian exchange hours
#    are unaffected).
#  * Sampling: realised variance from 1-minute mid quotes is inflated by
#    microstructure noise (bid-ask bounce). The default samples the last price
#    in each 5-minute interval, the standard choice in the RV literature
#    (Liu, Patton & Sheppard, 2015). Set ECMT3150_RV_MINUTES=1 to use every bar.
ECMT_SESSION_OFFSET_HOURS <- as.numeric(Sys.getenv("ECMT3150_SESSION_OFFSET_HOURS", "2"))
ECMT_RV_MINUTES <- as.integer(Sys.getenv("ECMT3150_RV_MINUTES", "5"))

ecmt_daily_realised <- function(df_ticker) {
  df <- df_ticker[order(df_ticker$Timestamp), , drop = FALSE]
  df$Price <- ecmt_price_series(df)
  df <- df[!is.na(df$Price) & df$Price > 0, , drop = FALSE]
  if (nrow(df) == 0) return(data.frame())
  df$Date <- as.Date(df$Timestamp + ECMT_SESSION_OFFSET_HOURS * 3600, tz = "UTC")
  df$Bucket <- floor(as.numeric(df$Timestamp) / (60 * ECMT_RV_MINUTES))

  daily <- df %>%
    dplyr::group_by(Date, Bucket) %>%
    dplyr::summarise(Price = dplyr::last(Price), Timestamp = dplyr::last(Timestamp),
                     Period = dplyr::first(Period), N_bars = dplyr::n(), .groups = "drop") %>%
    dplyr::group_by(Date) %>%
    dplyr::arrange(Timestamp, .by_group = TRUE) %>%
    dplyr::mutate(intraday_ret = log(Price / dplyr::lag(Price)) * 100) %>%
    dplyr::summarise(
      Daily_Return = sum(intraday_ret, na.rm = TRUE),
      RV_pct       = sum(intraday_ret^2, na.rm = TRUE),
      N_obs        = sum(!is.na(intraday_ret)),
      N_bars       = sum(N_bars),
      Period       = dplyr::first(Period),
      .groups = "drop"
    ) %>%
    dplyr::filter(N_obs >= 10 & RV_pct > 0) %>%
    dplyr::mutate(Realized_Vol = sqrt(RV_pct)) %>%
    dplyr::arrange(Date)
  as.data.frame(daily)
}

# ------------------------------------------------------------------------------
# 4. Common forecasting design
# ------------------------------------------------------------------------------

# HFD: forecast origin t uses information up to day t; the target is the
# next day's realised volatility. HAR components: daily, 5-day, 22-day.
ecmt_hfd_frame <- function(daily) {
  daily %>%
    dplyr::mutate(
      RV_Daily    = Realized_Vol,
      RV_Weekly   = zoo::rollmeanr(Realized_Vol, k = 5, fill = NA),
      RV_Monthly  = zoo::rollmeanr(Realized_Vol, k = 22, fill = NA),
      Target_Date = dplyr::lead(Date, 1),
      RV_Target   = dplyr::lead(Realized_Vol, 1),
      Row_Index   = dplyr::row_number()
    ) %>%
    dplyr::filter(stats::complete.cases(RV_Daily, RV_Weekly, RV_Monthly, RV_Target)) %>%
    as.data.frame()
}

# LFD: returns in percent; the target is next-day absolute return.
ecmt_lfd_frame <- function(dates, ret_pct, period) {
  data.frame(Date = dates, Return = ret_pct, Period = period) %>%
    dplyr::mutate(
      Abs_Return  = abs(Return),
      Vol_Weekly  = zoo::rollmeanr(Abs_Return, k = 5, fill = NA),
      Vol_Monthly = zoo::rollmeanr(Abs_Return, k = 22, fill = NA),
      Target_Date = dplyr::lead(Date, 1),
      Target_Vol  = dplyr::lead(Abs_Return, 1),
      Row_Index   = dplyr::row_number()
    ) %>%
    dplyr::filter(stats::complete.cases(Abs_Return, Vol_Weekly, Vol_Monthly, Target_Vol)) %>%
    as.data.frame()
}

# Chronological split of the common frame. Returns a logical vector (TRUE = test).
ecmt_test_rows <- function(frame) {
  n <- nrow(frame)
  mode <- tolower(Sys.getenv("ECMT3150_SPLIT", "ratio"))
  if (mode == "event" && "Period" %in% names(frame) && any(frame$Period == "Event")) {
    # A row is in the test set when its TARGET falls in the Event period.
    event_start <- min(frame$Date[frame$Period == "Event"])
    is_test <- frame$Target_Date >= event_start
    if (sum(!is_test) >= 10 && sum(is_test) >= 3) return(is_test)
    message("  Event split leaves too few train/test rows; using the ratio split instead.")
  }
  split_idx <- floor(ECMT_TRAIN_FRACTION * n)
  seq_len(n) > split_idx
}

# Expanding-window refit schedule. Returns a list of blocks; each block is the
# set of frame rows forecast with ONE set of parameters, and est_n is the last
# observation (Row_Index) the parameters may use: the forecast origin of the
# block's first row. Training rows form block 0 (parameters from the first
# test origin, as for the XGBoost features).
ecmt_refit_blocks <- function(frame, is_test, every) {
  test_rows <- which(is_test)
  every <- max(1L, as.integer(every))
  starts <- test_rows[seq(1, length(test_rows), by = every)]
  blocks <- list(list(rows = which(!is_test), est_n = frame$Row_Index[test_rows[1]]))
  for (i in seq_along(starts)) {
    end <- if (i < length(starts)) starts[i + 1] - 1 else max(test_rows)
    blocks[[length(blocks) + 1]] <- list(rows = starts[i]:end, est_n = frame$Row_Index[starts[i]])
  }
  blocks
}

# Run an expanding-window forecast exercise.
#   fit_fun(est_n)        -> fitted parameters using observations 1..est_n (or NULL)
#   forecast_fun(p, rows) -> forecasts for those frame rows
# A failed refit reuses the previous parameters. Returns the forecast vector
# with attributes n_fits / n_failed for reporting.
ecmt_blocked_forecasts <- function(frame, blocks, fit_fun, forecast_fun) {
  out <- rep(NA_real_, nrow(frame))
  cache <- list(); last <- NULL; n_fit <- 0L; n_fail <- 0L
  for (b in blocks) {
    if (length(b$rows) == 0) next
    key <- as.character(b$est_n)
    if (is.null(cache[[key]])) {
      p <- tryCatch(fit_fun(b$est_n), error = function(e) NULL)
      if (is.null(p)) { n_fail <- n_fail + 1L; p <- last } else n_fit <- n_fit + 1L
      cache[[key]] <- list(p)
    }
    p <- cache[[key]][[1]]
    if (is.null(p)) next
    last <- p
    out[b$rows] <- forecast_fun(p, b$rows)
  }
  attr(out, "n_fits") <- n_fit
  attr(out, "n_failed") <- n_fail
  out
}

# Forecast-accuracy metrics on the test rows. QLIKE uses variances
# (actual^2 vs forecast^2) and skips non-positive values.
ecmt_metrics <- function(actual, forecast) {
  ok <- is.finite(actual) & is.finite(forecast)
  a <- actual[ok]; f <- forecast[ok]
  q_ok <- a > 0 & f > 0
  ratio <- (a[q_ok]^2) / (f[q_ok]^2)
  data.frame(
    N_Test = length(a),
    RMSE   = sqrt(mean((a - f)^2)),
    MAE    = mean(abs(a - f)),
    QLIKE  = if (any(q_ok)) mean(ratio - log(ratio) - 1) else NA_real_
  )
}

ecmt_metrics_row <- function(model, ticker, frame, is_test, forecast, target_col, target_label) {
  m <- ecmt_metrics(frame[[target_col]][is_test], forecast[is_test])
  cbind(
    data.frame(Model = model, Ticker = ticker, Target = target_label,
               Train_Start = format(min(frame$Target_Date[!is_test])),
               Train_End   = format(max(frame$Target_Date[!is_test])),
               Test_Start  = format(min(frame$Target_Date[is_test])),
               Test_End    = format(max(frame$Target_Date[is_test])),
               N_Train = sum(!is_test), stringsAsFactors = FALSE),
    m
  )
}

ecmt_forecast_rows <- function(model, ticker, frame, is_test, forecast, target_col) {
  data.frame(Model = model, Ticker = ticker,
             Origin_Date = frame$Date, Target_Date = frame$Target_Date,
             Split = ifelse(is_test, "Test", "Train"),
             Actual = frame[[target_col]], Forecast = forecast,
             stringsAsFactors = FALSE)
}

# Write the per-model CSV tables consumed by the Python collectors.
ecmt_write_tables <- function(dirs, tables) {
  for (name in names(tables)) {
    df <- tables[[name]]
    if (is.null(df) || nrow(df) == 0) next
    utils::write.csv(df, file.path(dirs$table, paste0(name, ".csv")), row.names = FALSE)
  }
  cat("Tables written to :", dirs$table, "\n")
}

# ------------------------------------------------------------------------------
# 5. Stochastic volatility: one-step-ahead predictive volatility
# ------------------------------------------------------------------------------

# Bootstrap particle filter for h_t = mu + phi (h_{t-1} - mu) + sigma eta_t,
# y_t = exp(h_t / 2) eps_t, with parameters fixed at their training-sample
# posterior medians. Element t of the result is E[exp(h_t / 2) | y_1..y_{t-1}],
# i.e. a genuine one-step-ahead forecast; element n+1 is the forecast beyond
# the sample. No future data enter any forecast.
ecmt_sv_predictive_vol <- function(y, mu, phi, sigma, n_particles = 3000, seed = ECMT_SEED) {
  set.seed(seed)
  n <- length(y)
  out <- numeric(n + 1)
  h <- stats::rnorm(n_particles, mu, sigma / sqrt(max(1 - phi^2, 1e-4)))
  for (t in seq_len(n)) {
    out[t] <- mean(exp(h / 2))
    lw <- stats::dnorm(y[t], 0, exp(h / 2), log = TRUE)
    w <- exp(lw - max(lw))
    # Systematic resampling
    cw <- cumsum(w / sum(w))
    u <- (stats::runif(1) + 0:(n_particles - 1)) / n_particles
    h <- h[pmin(findInterval(u, cw) + 1L, n_particles)]
    h <- mu + phi * (h - mu) + sigma * stats::rnorm(n_particles)
  }
  out[n + 1] <- mean(exp(h / 2))
  out
}

# Posterior medians of the SV parameters (works for stochvol 2.x and 3.x).
ecmt_sv_params <- function(sv_fit) {
  draws <- as.matrix(sv_fit$para)
  stats::setNames(apply(draws[, c("mu", "phi", "sigma"), drop = FALSE], 2, stats::median),
                  c("mu", "phi", "sigma"))
}

ecmt_draws <- function(x) as.matrix(x)

# ------------------------------------------------------------------------------
# 6. XGBoost helpers (compatible with xgboost 1.7.x and 3.x)
# ------------------------------------------------------------------------------

# Early stopping is done on a validation block taken from the END of the
# training sample (never on the test set). The final model is then refitted
# on the full training sample with the selected number of rounds.
ecmt_xgb_fit <- function(X_train, y_train, params, nrounds = 150,
                         early_stopping_rounds = 15, val_fraction = 0.2) {
  set.seed(ECMT_SEED)
  params$seed <- ECMT_SEED
  n <- nrow(X_train)
  n_val <- floor(val_fraction * n)
  best <- nrounds

  if (n_val >= 5 && (n - n_val) >= 10) {
    fit_idx <- seq_len(n - n_val)
    val_idx <- (n - n_val + 1):n
    d_fit <- xgboost::xgb.DMatrix(X_train[fit_idx, , drop = FALSE], label = y_train[fit_idx])
    d_val <- xgboost::xgb.DMatrix(X_train[val_idx, , drop = FALSE], label = y_train[val_idx])
    eval_arg <- if ("evals" %in% names(formals(xgboost::xgb.train))) "evals" else "watchlist"
    args <- list(params = params, data = d_fit, nrounds = nrounds, verbose = 0,
                 early_stopping_rounds = early_stopping_rounds)
    args[[eval_arg]] <- list(train = d_fit, validation = d_val)
    es_model <- do.call(xgboost::xgb.train, args)
    best <- ecmt_xgb_best_iteration(es_model, nrounds)
  }

  d_train <- xgboost::xgb.DMatrix(X_train, label = y_train)
  model <- xgboost::xgb.train(params = params, data = d_train, nrounds = best, verbose = 0)
  list(model = model, best_iteration = best, n_validation = if (n_val >= 5) n_val else 0L)
}

ecmt_xgb_best_iteration <- function(model, default) {
  candidates <- list(
    function() attributes(model)$best_iteration,
    function() model$best_iteration,
    function() as.integer(xgboost::xgb.attr(model, "best_iteration")) + 1L
  )
  for (f in candidates) {
    value <- tryCatch(f(), error = function(e) NULL)
    if (!is.null(value) && length(value) == 1 && is.finite(as.numeric(value)) && as.numeric(value) > 0) {
      return(as.integer(value))
    }
  }
  as.integer(default)
}

ecmt_xgb_importance <- function(model, features) {
  imp <- tryCatch(as.data.frame(xgboost::xgb.importance(model = model, feature_names = features)),
                  error = function(e) data.frame())
  if (nrow(imp) == 0) {
    imp <- data.frame(Feature = features, Gain = 0, Cover = 0, Frequency = 0)
  }
  imp
}

cat("ECMT3150 common helpers loaded.\n")
cat("  Project root :", ECMT_ROOT, "\n")
cat("  Output root  :", ECMT_OUTPUT_ROOT, "\n")
