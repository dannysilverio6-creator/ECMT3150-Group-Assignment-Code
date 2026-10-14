# ==============================================================================
# Script Name: EVENT_STUDY.R
# Pipeline Stage: Stage 4 - Event study of the conflict and model comparison plots
# Description: Answers the research question directly: did commodity volatility
#              change after the initial strikes on Iran?
#   LFD (daily): annualised volatility before vs after the event, a
#                Brown-Forsythe test for equal variances, post-event returns,
#                and a GARCH(1,1)-t with a post-event shift in the variance
#                intercept (delta) with robust standard errors.
#   HFD (1-min): mean daily realised volatility before vs after the event and a
#                Welch t-test on log RV.
#   Plots: volatility timelines with the event marked, and every model's
#          out-of-sample forecasts against the realised target.
#
# Outputs (ECMT3150 OUTPUTS/Pipeline_Outputs/):
#   Model_Tables/EVENT_STUDY/{lfd_event_study,hfd_event_study,garch_event_dummy}.csv
#   PNG_Plots/EVENT_STUDY/*.png
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
MODEL_KEY <- "EVENT_STUDY"
dirs <- ecmt_model_dirs(MODEL_KEY)
event_date <- ECMT_EVENT_DATE
# Symmetric comparison window (trading days either side of the event). The
# full pre-event sample starts in 2023, when volatility regimes were different,
# so the short window isolates the change around the event itself.
window_days <- as.integer(Sys.getenv("ECMT3150_EVENT_WINDOW_DAYS", "60"))
cat("Event date (first trading day after the strikes):", format(event_date), "\n")

p_fmt <- function(p) ifelse(is.na(p), NA_character_, ifelse(p < 0.001, "<0.001", sprintf("%.3f", p)))

# Brown-Forsythe test for equal variances (robust to fat tails): one-way ANOVA
# on absolute deviations from each group's median.
bf_test <- function(x, g) {
  dev <- abs(x - ave(x, g, FUN = median))
  tryCatch(stats::oneway.test(dev ~ g, var.equal = TRUE)$p.value, error = function(e) NA_real_)
}

# ==============================================================================
# 2. LFD: daily returns before vs after the event
# ==============================================================================
lfd_file <- ecmt_find_lseg_workbook("LFD")
returns <- ecmt_read_lfd_returns(lfd_file)
lfd_rows <- list(); dummy_rows <- list(); lfd_plot <- list()

for (ticker in ecmt_lfd_tickers(returns)) {
  keep <- !is.na(returns[[ticker]])
  d <- data.frame(Date = returns$Date[keep], R = as.numeric(returns[[ticker]][keep]) * 100)
  if (nrow(d) < 60 || sum(d$Date >= event_date) < 10) {
    cat("LFD", ticker, ": not enough observations around the event - skipped\n")
    next
  }
  d$Post <- as.integer(d$Date >= event_date)
  pre <- d$R[d$Post == 0]; post <- d$R[d$Post == 1]
  cum <- function(n) sum(head(post, n))
  pre_w <- tail(pre, window_days); post_w <- head(post, window_days)

  lfd_rows[[ticker]] <- data.frame(
    Ticker = ticker,
    Pre_Start = format(min(d$Date)), Event_Date = format(event_date), Post_End = format(max(d$Date)),
    N_Pre = length(pre), N_Post = length(post),
    Pre_Ann_Vol_pct = sd(pre) * sqrt(252),
    Post_Ann_Vol_pct = sd(post) * sqrt(252),
    Vol_Ratio_Post_Pre = sd(post) / sd(pre),
    BrownForsythe_p = bf_test(d$R, d$Post),
    Window_Days = window_days,
    Pre_W_Ann_Vol_pct = sd(pre_w) * sqrt(252),
    Post_W_Ann_Vol_pct = sd(post_w) * sqrt(252),
    Vol_Ratio_W = sd(post_w) / sd(pre_w),
    BrownForsythe_W_p = bf_test(c(pre_w, post_w), rep(0:1, c(length(pre_w), length(post_w)))),
    Pre_20D_Return_pct = sum(tail(pre, 20)),
    Post_5D_Return_pct = cum(5),
    Post_20D_Return_pct = cum(20),
    Post_Full_Return_pct = sum(post),
    Max_Abs_Move_First_5D_pct = max(abs(head(post, 5))),
    stringsAsFactors = FALSE
  )

  # EGARCH(1,1)-t with a post-event shift in the log-variance intercept:
  #   log sigma2_t = omega + delta * D_t + alpha * z_{t-1} + gamma * (|z_{t-1}| - E|z|)
  #                  + beta * log sigma2_{t-1}
  # EGARCH is used because delta is unconstrained in sign; in sGARCH rugarch
  # bounds the variance regressor at zero, so a volatility FALL cannot be
  # estimated and the estimate piles up on the boundary.
  # delta > 0 (significant) => the conflict raised volatility.
  # Long-run volatility multiplier = exp(delta / (2 * (1 - beta))).
  spec_d <- ugarchspec(
    variance.model = list(model = "eGARCH", garchOrder = c(1, 1),
                          external.regressors = matrix(d$Post, ncol = 1)),
    mean.model = list(armaOrder = c(0, 0), include.mean = TRUE),
    distribution.model = "std"
  )
  fit_d <- try(suppressWarnings(ugarchfit(spec_d, data = d$R, solver = "hybrid")), silent = TRUE)
  if (!inherits(fit_d, "try-error") && convergence(fit_d) == 0) {
    cf <- coef(fit_d)
    rob <- fit_d@fit$robust.matcoef
    beta <- unname(cf["beta1"]); delta <- unname(cf["vxreg1"])
    dummy_rows[[ticker]] <- data.frame(
      Ticker = ticker, Model = "EGARCH(1,1)-t + post-event dummy",
      Delta_Post_Event = delta,
      Delta_Robust_SE = rob["vxreg1", 2], Delta_t = rob["vxreg1", 3], Delta_p = rob["vxreg1", 4],
      Alpha1 = unname(cf["alpha1"]), Gamma1 = unname(cf["gamma1"]), Beta1 = beta,
      Student_t_df = unname(cf["shape"]),
      LongRun_Vol_Multiplier = if (beta < 1) exp(delta / (2 * (1 - beta))) else NA_real_,
      LogLik = likelihood(fit_d),
      stringsAsFactors = FALSE
    )
    sig <- as.numeric(sigma(fit_d)) * sqrt(252)
    cat(sprintf("  EGARCH event dummy %-8s delta = %.4f (robust t = %.2f, p = %s)\n",
                ticker, delta, rob["vxreg1", 3], p_fmt(rob["vxreg1", 4])))
  } else {
    cat("  Event-dummy EGARCH did not converge for", ticker, "\n")
    sig <- rep(NA_real_, nrow(d))
  }
  lfd_plot[[ticker]] <- data.frame(
    Ticker = ticker, Date = d$Date,
    `EGARCH conditional vol (event dummy)` = sig,
    `22-day realised vol` = zoo::rollapplyr(d$R, 22, sd, fill = NA) * sqrt(252),
    check.names = FALSE
  )
  cat(sprintf("LFD %-8s +/-%d days: vol %.1f%% -> %.1f%% (x%.2f, BF p = %s) | full sample x%.2f\n", ticker,
              window_days, lfd_rows[[ticker]]$Pre_W_Ann_Vol_pct, lfd_rows[[ticker]]$Post_W_Ann_Vol_pct,
              lfd_rows[[ticker]]$Vol_Ratio_W, p_fmt(lfd_rows[[ticker]]$BrownForsythe_W_p),
              lfd_rows[[ticker]]$Vol_Ratio_Post_Pre))
}

# ==============================================================================
# 3. HFD: daily realised volatility before vs after the event
# ==============================================================================
hfd_file <- ecmt_find_lseg_workbook("HFD")
hfd_raw <- ecmt_read_hfd_long(hfd_file)
hfd_rows <- list(); hfd_plot <- list()

for (ric in unique(hfd_raw$RIC)) {
  daily <- ecmt_daily_realised(hfd_raw[hfd_raw$RIC == ric, , drop = FALSE])
  if (nrow(daily) < 15 || sum(daily$Date >= event_date) < 3 || sum(daily$Date < event_date) < 5) {
    cat("HFD", ric, ": not enough days around the event - skipped\n")
    next
  }
  daily$Post <- as.integer(daily$Date >= event_date)
  pre <- daily$Realized_Vol[daily$Post == 0]; post <- daily$Realized_Vol[daily$Post == 1]
  welch_p <- tryCatch(stats::t.test(log(post), log(pre))$p.value, error = function(e) NA_real_)
  last_week_pre <- tail(pre, 5)
  hfd_rows[[ric]] <- data.frame(
    Ticker = ric,
    Pre_Start = format(min(daily$Date)), Event_Date = format(event_date), Post_End = format(max(daily$Date)),
    N_Pre_Days = length(pre), N_Post_Days = length(post),
    Mean_Daily_RV_Pre_pct = mean(pre), Mean_Daily_RV_Post_pct = mean(post),
    RV_Ratio_Post_Pre = mean(post) / mean(pre),
    Welch_t_logRV_p = welch_p,
    Mean_RV_Week_Before_pct = mean(last_week_pre),
    Mean_RV_First_5D_Post_pct = mean(head(post, 5)),
    Peak_Post_RV_pct = max(post), Peak_Post_RV_Date = format(daily$Date[daily$Post == 1][which.max(post)]),
    Avg_Intraday_Returns_per_Day = mean(daily$N_obs),
    RV_Sampling_Minutes = ECMT_RV_MINUTES,
    stringsAsFactors = FALSE
  )
  hfd_plot[[ric]] <- data.frame(Ticker = ric, Date = daily$Date, RV = daily$Realized_Vol,
                                Period = ifelse(daily$Post == 1, "Post-event", "Pre-event"))
  cat(sprintf("HFD %-8s mean RV pre %.2f%% -> post %.2f%% (x%.2f), Welch p = %s\n", ric,
              mean(pre), mean(post), mean(post) / mean(pre), p_fmt(welch_p)))
}

# ==============================================================================
# 4. Plots
# ==============================================================================
theme_ecmt <- theme_minimal(base_size = 11) +
  theme(plot.title = element_text(face = "bold"), legend.position = "top",
        strip.text = element_text(face = "bold"))

if (length(lfd_plot) > 0) {
  pd <- dplyr::bind_rows(lfd_plot)
  pd <- do.call(rbind, lapply(c("EGARCH conditional vol (event dummy)", "22-day realised vol"),
                                           function(v) data.frame(Ticker = pd$Ticker, Date = pd$Date,
                                                                  Series = v, Vol = pd[[v]])))
  g <- ggplot(pd, aes(Date, Vol, colour = Series)) +
    annotate("rect", xmin = event_date, xmax = max(pd$Date), ymin = -Inf, ymax = Inf,
             fill = "firebrick", alpha = 0.06) +
    geom_vline(xintercept = event_date, linetype = "dashed", colour = "firebrick") +
    geom_line(linewidth = 0.6, na.rm = TRUE) +
    facet_wrap(~Ticker, ncol = 1, scales = "free_y") +
    scale_colour_manual(values = c("EGARCH conditional vol (event dummy)" = "#1f4e79",
                                   "22-day realised vol" = "grey55")) +
    labs(title = "Daily volatility around the conflict (annualised %)",
         subtitle = paste("Dashed line / shading: from", format(event_date)),
         x = NULL, y = "Annualised volatility (%)", colour = NULL) +
    theme_ecmt
  ggsave(file.path(dirs$png, "LFD_Event_Volatility.png"), g, width = 11, height = 3 + 2.6 * length(lfd_plot), dpi = 150)
}

if (length(hfd_plot) > 0) {
  ph <- dplyr::bind_rows(hfd_plot)
  g <- ggplot(ph, aes(Date, RV, fill = Period)) +
    geom_col(width = 0.8) +
    geom_vline(xintercept = event_date - 0.5, linetype = "dashed", colour = "firebrick") +
    facet_wrap(~Ticker, ncol = 1, scales = "free_y") +
    scale_fill_manual(values = c("Pre-event" = "grey60", "Post-event" = "firebrick")) +
    labs(title = sprintf("Daily realised volatility (%d-minute returns)", ECMT_RV_MINUTES),
         subtitle = paste("Event:", format(event_date)), x = NULL, y = "Daily RV (%)", fill = NULL) +
    theme_ecmt
  ggsave(file.path(dirs$png, "HFD_Event_RV.png"), g, width = 11, height = 3 + 2.6 * length(hfd_plot), dpi = 150)
}

# Out-of-sample forecasts of every model against the realised target
read_fc <- function(keys) {
  dplyr::bind_rows(lapply(keys, function(k) {
    f <- file.path(ECMT_TABLE_DIR, k, "oos_forecasts.csv")
    if (file.exists(f)) utils::read.csv(f, stringsAsFactors = FALSE) else NULL
  }))
}
plot_oos <- function(fc, title, ylab, file, smooth = 1) {
  if (is.null(fc) || nrow(fc) == 0) return(invisible(NULL))
  fc <- fc[fc$Split == "Test", ]
  fc$Target_Date <- as.Date(fc$Target_Date)
  actual <- fc[!duplicated(fc[, c("Ticker", "Target_Date")]), c("Ticker", "Target_Date", "Actual")]
  if (smooth > 1) {
    actual <- actual %>% dplyr::group_by(Ticker) %>% dplyr::arrange(Target_Date) %>%
      dplyr::mutate(Actual = zoo::rollmeanr(Actual, smooth, fill = NA)) %>% dplyr::ungroup()
  }
  g <- ggplot() +
    geom_line(data = actual, aes(Target_Date, Actual), colour = "grey35", linewidth = 0.7, na.rm = TRUE) +
    geom_point(data = actual, aes(Target_Date, Actual), colour = "grey35", size = 0.9, na.rm = TRUE) +
    geom_line(data = fc, aes(Target_Date, Forecast, colour = Model), linewidth = 0.8) +
    facet_wrap(~Ticker, ncol = 1, scales = "free_y") +
    scale_colour_brewer(palette = "Dark2") +
    labs(title = title,
         subtitle = sprintf("Grey = realised target. Out-of-sample window %s to %s (event: %s)",
                            format(min(fc$Target_Date)), format(max(fc$Target_Date)), format(event_date)),
         x = NULL, y = ylab, colour = NULL) +
    theme_ecmt
  ggsave(file.path(dirs$png, file), g, width = 11, height = 3 + 2.6 * length(unique(fc$Ticker)), dpi = 150)
}
plot_oos(read_fc(c("LFD_GARCH", "LFD_SV", "LFD_XGBOOST")),
         "LFD out-of-sample forecasts: next-day |return| (5-day average of target shown)",
         "|return| (%)", "LFD_OOS_Model_Comparison.png", smooth = 5)
plot_oos(read_fc(c("HFD_REALGARCH", "HFD_HARRV", "HFD_XGBOOST")),
         "HFD out-of-sample forecasts: next-day realised volatility",
         "Daily RV (%)", "HFD_OOS_Model_Comparison.png")

# ==============================================================================
# 5. Save
# ==============================================================================
if (length(lfd_rows) == 0 && length(hfd_rows) == 0) {
  stop("Event study produced no results - nothing was saved.", call. = FALSE)
}
tables <- list(
  lfd_event_study   = dplyr::bind_rows(lfd_rows),
  hfd_event_study   = dplyr::bind_rows(hfd_rows),
  garch_event_dummy = dplyr::bind_rows(dummy_rows)
)
ecmt_write_tables(dirs, tables)
saveRDS(tables, dirs$rds)
cat("\nEvent study complete. Plots in", dirs$png, "\n")
