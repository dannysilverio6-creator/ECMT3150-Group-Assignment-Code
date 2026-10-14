# ==============================================================================
# Script Name: HFD_RealisedGARCH_MODEL.R
# Pipeline Stage: Stage 2 - High-Frequency Data Pipeline (Realized GARCH Model)
# Description: Reads the intraday data in LSEG_HFD.xlsx (Historical CSV + Event
#              CSV sheets), aggregates intraday returns to daily returns and
#              daily Realized Volatility, fits a Realized GARCH(1,1) model with
#              a standard GARCH(1,1) fallback, plots ggplot2 dashboards, and
#              evaluates one-day-ahead out-of-sample volatility forecasts on
#              the common HFD test window.
#
# NOTE: rugarch's realGARCH requires xts inputs. Passing plain numeric
# vectors makes ugarchfit fail, which previously caused every ticker to fall
# back silently to sGARCH.
#
# Outputs (ECMT3150 OUTPUTS/Pipeline_Outputs/):
#   RDS_Models/HFD_REALGARCH.rds
#   Model_Tables/HFD_REALGARCH/{summary,oos_metrics,oos_forecasts}.csv
#   PNG_Plots/HFD_REALGARCH/HFD_RealGARCH_Diagnostics_<ticker>.png
# ==============================================================================

# ---- 0. Locate the project folder and load the shared helpers ----------------
ECMT_PROJECT_ROOT <- local({
  starts <- Sys.getenv("ECMT3150_PROJECT_ROOT", "")
  file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
  if (length(file_arg) > 0) starts <- c(starts, dirname(gsub("~\\+~", " ", sub("^--file=", "", file_arg[1]))))
  ofile <- tryCatch(sys.frame(1)$ofile, error = function(e) NULL)
  if (!is.null(ofile)) starts <- c(starts, dirname(ofile))
  if (requireNamespace("rstudioapi", quietly = TRUE) && rstudioapi::isAvailable()) {
    p <- tryCatch(rstudioapi::getSourceEditorContext()$path, error = function(e) "")
    if (nzchar(p)) starts <- c(starts, dirname(p))
  }
  starts <- c(starts, getwd())
  root <- NULL
  for (s in starts[nzchar(starts)]) {
    d <- normalizePath(s, winslash = "/", mustWork = FALSE)
    for (i in 1:4) {
      if (file.exists(file.path(d, "ECMT3150_COMMON.R"))) { root <- d; break }
      d <- dirname(d)
    }
    if (!is.null(root)) break
  }
  if (is.null(root)) stop("Cannot find ECMT3150_COMMON.R - run this script from inside the project folder.")
  root
})
source(file.path(ECMT_PROJECT_ROOT, "ECMT3150_COMMON.R"))

# ---- 1. Packages and output folders ------------------------------------------
ecmt_require(c("readxl", "dplyr", "zoo", "xts", "rugarch", "ggplot2", "patchwork"))
MODEL_KEY <- "HFD_REALGARCH"
dirs <- ecmt_model_dirs(MODEL_KEY)

# ---- 2. Locate and read the HFD workbook --------------------------------------
target_file <- ecmt_find_lseg_workbook("HFD")
cat("\n======================================================\n")
cat("Located HFD File :", target_file, "\n")
cat("======================================================\n\n")

hfd_raw <- ecmt_read_hfd_long(target_file)

spec_realgarch <- ugarchspec(
  mean.model = list(armaOrder = c(0, 0), include.mean = TRUE),
  variance.model = list(model = "realGARCH", garchOrder = c(1, 1))
)
spec_sgarch <- ugarchspec(
  mean.model = list(armaOrder = c(0, 0), include.mean = TRUE),
  variance.model = list(model = "sGARCH", garchOrder = c(1, 1))
)

# Fit Realized GARCH, falling back to sGARCH if it fails to converge.
fit_realgarch <- function(ret, rv, dates) {
  x_ret <- xts::xts(ret, order.by = dates)
  x_rv <- xts::xts(rv, order.by = dates)
  fit <- try(suppressWarnings(ugarchfit(spec = spec_realgarch, data = x_ret,
                                        realizedVol = x_rv, solver = "hybrid")), silent = TRUE)
  if (!inherits(fit, "try-error") && convergence(fit) == 0) {
    return(list(fit = fit, spec = spec_realgarch, realised = TRUE))
  }
  fit <- try(suppressWarnings(ugarchfit(spec = spec_sgarch, data = x_ret, solver = "hybrid")), silent = TRUE)
  if (!inherits(fit, "try-error") && convergence(fit) == 0) {
    return(list(fit = fit, spec = spec_sgarch, realised = FALSE))
  }
  NULL
}

unique_rics <- unique(hfd_raw$RIC)
all_garch_results <- list()
summary_rows <- list()
metric_rows <- list()
forecast_rows <- list()
options(device.ask.default = FALSE)

# ---- 3. Master loop ------------------------------------------------------------
for (current_ric in unique_rics) {
  cat("\n------------------------------------------------------\n")
  cat("Processing Ticker:", current_ric, "\n")
  cat("------------------------------------------------------\n")

  hfd_ticker <- hfd_raw[hfd_raw$RIC == current_ric, , drop = FALSE]
  if (nrow(hfd_ticker) < 50) {
    cat("Insufficient observations for", current_ric, "- skipping...\n")
    next
  }

  # Step 1: intraday -> daily return and realised volatility (percent)
  daily_data <- ecmt_daily_realised(hfd_ticker)
  if (nrow(daily_data) < 30) {
    cat("Insufficient daily aggregated observations (N < 30) for", current_ric, "- skipping...\n")
    next
  }

  # Step 2: full-sample Realized GARCH(1,1) (with sGARCH fallback)
  cat("Estimating Realized GARCH(1,1) model for", current_ric, "...\n")
  full <- fit_realgarch(daily_data$Daily_Return, daily_data$Realized_Vol, daily_data$Date)
  if (is.null(full)) {
    cat("Critical Warning: Both Realized GARCH and fallback sGARCH failed for", current_ric, "- skipping.\n")
    next
  }
  if (!full$realised) {
    cat("Warning: Realized GARCH did not converge for", current_ric, "- using standard sGARCH(1,1).\n")
  }
  opt_res <- full$fit
  model_type <- ifelse(full$realised, "Realized GARCH", "Standard GARCH")

  daily_data$Sigma <- as.numeric(sigma(opt_res))
  daily_data$Std_Residuals <- as.numeric(residuals(opt_res, standardize = TRUE))
  coefs <- coef(opt_res)
  log_lik <- likelihood(opt_res)
  info_crits <- infocriteria(opt_res)
  cat("Fit complete! Log-Likelihood:", round(log_lik, 2),
      "| AIC:", round(info_crits[1], 4), "| Model:", model_type, "\n")

  # Step 3: out-of-sample one-day-ahead forecasts on the common HFD frame,
  # re-estimated every ECMT_REFIT_EVERY_HFD test days (expanding window).
  # Each refit uses days up to the forecast origin only; the filter then gives
  # sigma_{t+1} from information up to day t.
  frame <- ecmt_hfd_frame(daily_data)
  sigma_next <- rep(NA_real_, nrow(frame))
  if (nrow(frame) >= 10) {
    is_test <- ecmt_test_rows(frame)
    blocks <- ecmt_refit_blocks(frame, is_test, ECMT_REFIT_EVERY_HFD)
    used_realised <- logical(0)
    sigma_next <- ecmt_blocked_forecasts(
      frame, blocks,
      fit_fun = function(est_n) {
        fit_realgarch(daily_data$Daily_Return[1:est_n], daily_data$Realized_Vol[1:est_n],
                      daily_data$Date[1:est_n])
      },
      forecast_fun = function(tr, rows) {
        used_realised <<- c(used_realised, tr$realised)
        fixed_spec <- tr$spec
        setfixed(fixed_spec) <- as.list(coef(tr$fit))
        last <- max(frame$Row_Index[rows]) + 1
        idx <- 1:last
        x_ret <- xts::xts(daily_data$Daily_Return[idx], order.by = daily_data$Date[idx])
        filt <- if (tr$realised) {
          ugarchfilter(fixed_spec, data = x_ret,
                       realizedVol = xts::xts(daily_data$Realized_Vol[idx], order.by = daily_data$Date[idx]))
        } else {
          ugarchfilter(fixed_spec, data = x_ret)
        }
        as.numeric(sigma(filt))[frame$Row_Index[rows] + 1]
      }
    )
    if (any(is.finite(sigma_next[is_test]))) {
      oos_model_type <- if (all(used_realised)) "Realized GARCH" else if (!any(used_realised))
        "Standard GARCH" else sprintf("Mixed (%d/%d Realized)", sum(used_realised), length(used_realised))
      metric_rows[[current_ric]] <- cbind(
        ecmt_metrics_row("HFD_Realised_GARCH", current_ric, frame, is_test, sigma_next,
                         "RV_Target", "Next-day realised volatility (%)"),
        OOS_Model_Type = oos_model_type,
        Refits = attr(sigma_next, "n_fits"), Refit_Failures = attr(sigma_next, "n_failed")
      )
      forecast_rows[[current_ric]] <- ecmt_forecast_rows("HFD_Realised_GARCH", current_ric, frame,
                                                         is_test, sigma_next, "RV_Target")
      cat(sprintf("  OOS (%s to %s, n=%d, %d refits, %s): RMSE = %.4f | MAE = %.4f\n",
                  metric_rows[[current_ric]]$Test_Start, metric_rows[[current_ric]]$Test_End,
                  metric_rows[[current_ric]]$N_Test, attr(sigma_next, "n_fits"), oos_model_type,
                  metric_rows[[current_ric]]$RMSE, metric_rows[[current_ric]]$MAE))
    } else {
      cat("  Training-sample fit failed - no OOS forecasts for", current_ric, "\n")
    }
  } else {
    cat("  Fewer than 10 usable days after the 22-day HAR window - no OOS forecasts.\n")
  }

  # Step 4: diagnostic dashboard
  p1 <- ggplot(daily_data, aes(x = Date)) +
    geom_line(aes(y = Daily_Return, color = "Daily Return"), linewidth = 0.6) +
    geom_line(aes(y = 1.96 * Sigma, color = "95% Volatility Band"), linewidth = 0.8, linetype = "dashed") +
    geom_line(aes(y = -1.96 * Sigma, color = "95% Volatility Band"), linewidth = 0.8, linetype = "dashed") +
    scale_color_manual(values = c("Daily Return" = "gray50", "95% Volatility Band" = "darkred")) +
    theme_minimal(base_size = 11) +
    labs(title = "Daily Returns & Conditional Volatility Bounds", x = "Date", y = "Return (%)", color = NULL) +
    theme(plot.title = element_text(face = "bold", size = 11), legend.position = "top",
          legend.margin = margin(0, 0, 0, 0))

  max_vol <- max(c(daily_data$Realized_Vol, daily_data$Sigma), na.rm = TRUE)
  p2 <- ggplot(daily_data, aes(x = Date)) +
    geom_line(aes(y = Realized_Vol, color = "Observed Realized Vol"), linewidth = 0.7, alpha = 0.6) +
    geom_line(aes(y = Sigma, color = "Conditional Vol (Sigma)"), linewidth = 1) +
    scale_color_manual(values = c("Observed Realized Vol" = "steelblue", "Conditional Vol (Sigma)" = "forestgreen")) +
    coord_cartesian(ylim = c(0, max_vol * 1.1)) +
    theme_minimal(base_size = 11) +
    labs(title = paste(ifelse(full$realised, "Realized GARCH", "sGARCH"), "Volatility Fit"),
         x = "Date", y = "Volatility (%)", color = NULL) +
    theme(plot.title = element_text(face = "bold", size = 11), legend.position = "top",
          legend.margin = margin(0, 0, 0, 0))

  acf_res <- acf(daily_data$Std_Residuals^2, plot = FALSE, lag.max = 20)
  acf_df <- data.frame(Lag = acf_res$lag[, , 1], ACF = acf_res$acf[, , 1])
  ci_bound <- 2 / sqrt(nrow(daily_data))
  p3 <- ggplot(acf_df, aes(x = Lag, y = ACF)) +
    geom_hline(yintercept = 0, color = "gray30") +
    geom_hline(yintercept = c(ci_bound, -ci_bound), linetype = "dashed", color = "blue", alpha = 0.6) +
    geom_segment(aes(xend = Lag, yend = 0), color = "midnightblue", linewidth = 0.9) +
    geom_point(color = "midnightblue", size = 1.5) +
    theme_minimal(base_size = 11) +
    labs(title = "ACF of Squared Standardized Residuals", x = "Lag", y = "ACF") +
    theme(plot.title = element_text(face = "bold", size = 11))

  p4 <- ggplot(daily_data, aes(x = Std_Residuals)) +
    geom_histogram(aes(y = after_stat(density)), bins = 30, fill = "purple4", color = "white", alpha = 0.6) +
    geom_density(color = "purple4", linewidth = 1) +
    stat_function(fun = dnorm, args = list(mean = 0, sd = 1), color = "black", linetype = "dashed", linewidth = 1) +
    theme_minimal(base_size = 11) +
    labs(title = "Standardized Residuals Density", x = "Standardized Residuals", y = "Density") +
    theme(plot.title = element_text(face = "bold", size = 11))

  diagnostic_dashboard <- (p1 + p2) / (p3 + p4) +
    plot_annotation(
      title = paste("Volatility Model Diagnostics Dashboard | Ticker:", current_ric),
      subtitle = paste("Full-sample model:", model_type),
      theme = theme(plot.title = element_text(face = "bold", size = 14, hjust = 0.5),
                    plot.subtitle = element_text(size = 11, hjust = 0.5, color = "gray30"))
    )
  png_path <- file.path(dirs$png, paste0("HFD_RealGARCH_Diagnostics_", ecmt_safe_name(current_ric), ".png"))
  ggsave(png_path, diagnostic_dashboard, width = 12, height = 9, dpi = 150)

  coef_or_na <- function(name) if (name %in% names(coefs)) unname(coefs[name]) else NA_real_
  summary_rows[[current_ric]] <- data.frame(
    Ticker = current_ric,
    Model_Type = model_type,
    Omega = coef_or_na("omega"),
    Alpha1 = coef_or_na("alpha1"),
    Beta1 = coef_or_na("beta1"),
    LogLikelihood = log_lik,
    AIC = info_crits[1],
    BIC = info_crits[2],
    N_Days = nrow(daily_data),
    Sample_Start = format(min(daily_data$Date)),
    Sample_End = format(max(daily_data$Date)),
    stringsAsFactors = FALSE
  )

  all_garch_results[[current_ric]] <- list(
    data           = daily_data,
    model_type     = model_type,
    fit_object     = opt_res,
    coefficients   = coefs,
    AIC            = info_crits[1],
    BIC            = info_crits[2],
    log_likelihood = log_lik,
    summary_df     = summary_rows[[current_ric]],
    oos_metrics    = metric_rows[[current_ric]],
    # One-step-ahead sigma for every origin date (used as an XGBoost feature)
    feature_series = data.frame(Date = frame$Date, RG_Sigma = sigma_next),
    source_file    = target_file
  )
}

# ---- 5. Save outputs -----------------------------------------------------------
if (length(all_garch_results) == 0) {
  stop("HFD Realised GARCH produced no results for any ticker - nothing was saved.", call. = FALSE)
}

saveRDS(all_garch_results, file = dirs$rds)
ecmt_write_tables(dirs, list(
  summary       = dplyr::bind_rows(summary_rows),
  oos_metrics   = dplyr::bind_rows(metric_rows),
  oos_forecasts = dplyr::bind_rows(forecast_rows)
))
cat("\nProcess complete! Realized GARCH results saved to", dirs$rds, "\n")
