# ==============================================================================
# Script Name: ECMT3150_COMPILER.R
# Pipeline Stage: Stage 5 - Output Aggregator & Excel Compiler
# Description: Compiles RDS binary outputs from Pipeline_Outputs/RDS_Models
#              into 6 consolidated Excel workbooks inside Pipeline_Outputs/Excel_Summaries.
# ==============================================================================

# 1. Safe Package Installation (CRITICAL FOR BATCH EXECUTION)
required_packages <- c("openxlsx", "dplyr")
for (pkg in required_packages) {
  if (!require(pkg, character.only = TRUE, quietly = TRUE)) {
    install.packages(pkg, dependencies = TRUE, repos = "https://cloud.r-project.org")
    library(pkg, character.only = TRUE)
  }
}

# 2. Setup Output Directories
output_dir_excel <- "Pipeline_Outputs/Excel_Summaries"
output_dir_rds   <- "Pipeline_Outputs/RDS_Models"
dir.create(output_dir_excel, recursive = TRUE, showWarnings = FALSE)

cat("\n======================================================\n")
cat("Pipeline Compiler Initialized\n")
cat("Reading RDS From        : ", output_dir_rds, "\n")
cat("Writing Excel Summaries : ", output_dir_excel, "\n")
cat("======================================================\n\n")

# 3. Helper Function to Find Latest RDS Files in the RDS Directory
get_latest_rds <- function(pattern) {
  files <- list.files(path = c(".", output_dir_rds), pattern = pattern, full.names = TRUE, recursive = TRUE)
  if (length(files) == 0) return(NULL)
  return(files[order(file.info(files)$mtime, decreasing = TRUE)][1])
}

# 4. Master Compilation Wrapper (Keeps script DRY and original structure intact)
compile_model <- function(pattern, process_func, filename, sheet_names) {
  file_path <- get_latest_rds(pattern)
  if (!is.null(file_path)) {
    cat("Compiling:", file_path, "...\n")
    tryCatch({
      data_obj <- readRDS(file_path)
      dfs <- process_func(data_obj)
      
      wb <- createWorkbook()
      wrote_any <- FALSE
      
      for (i in seq_along(sheet_names)) {
        if (!is.null(dfs[[i]]) && is.data.frame(dfs[[i]]) && nrow(dfs[[i]]) > 0) {
          addWorksheet(wb, sheet_names[i])
          
          clean_df <- dfs[[i]]
          if ("Ticker" %in% names(clean_df) && length(sheet_names) == 1) {
            clean_df <- clean_df %>% distinct(Ticker, .keep_all = TRUE)
          } else {
            clean_df <- clean_df %>% distinct()
          }
          
          writeData(wb, sheet_names[i], clean_df)
          wrote_any <- TRUE
        }
      }
      
      if (wrote_any) {
        out_path <- file.path(output_dir_excel, filename)
        tryCatch({
          saveWorkbook(wb, out_path, overwrite = TRUE)
          cat("Saved:", out_path, "\n\n")
        }, error = function(save_err) {
          cat("CRITICAL ERROR saving", out_path, ": Ensure file is not open.\n\n")
        })
      }
    }, error = function(e) {
      cat("CRITICAL ERROR processing", file_path, ":", e$message, "\n\n")
    })
  } else {
    cat("Warning: No RDS file found matching pattern:", pattern, "\n\n")
  }
}

# ------------------------------------------------------------------------------
# 5. Compile Models using the original efficient structure
# ------------------------------------------------------------------------------

# 1. HFD ACD Model
compile_model("hfd_acd_results_ALL_.*\\.rds$", function(data) {
  df_list <- list()
  for (ric in names(data)) {
    tryCatch({ p <- data[[ric]]$coefficients; df_list[[ric]] <- data.frame(Ticker=ric, Omega=as.numeric(p["omega"]), Alpha=as.numeric(p["alpha"]), Beta=as.numeric(p["beta"]), Persistence=as.numeric(data[[ric]]$persistence), LogLikelihood=as.numeric(data[[ric]]$log_likelihood), AIC=as.numeric(data[[ric]]$AIC), BIC=as.numeric(data[[ric]]$BIC), stringsAsFactors=FALSE) }, error=function(e){})
  }
  list(if(length(df_list) > 0) bind_rows(df_list) else NULL)
}, "HFD_ACD_Model_Summary.xlsx", "ACD_Summary")

# 2. HFD UHF-GARCH Model
compile_model("hfd_uhfgarch_results_ALL_.*\\.rds$", function(data) {
  df_list <- list()
  for (ric in names(data)) {
    tryCatch({ p <- data[[ric]]$coefficients; df_list[[ric]] <- data.frame(Ticker=ric, Omega=as.numeric(p["omega"]), Alpha=as.numeric(p["alpha1"]), Beta=as.numeric(p["beta1"]), Persistence=as.numeric(data[[ric]]$persistence), AIC=as.numeric(data[[ric]]$AIC), BIC=as.numeric(data[[ric]]$BIC), stringsAsFactors=FALSE) }, error=function(e){})
  }
  list(if(length(df_list) > 0) bind_rows(df_list) else NULL)
}, "HFD_UHFGARCH_Model_Summary.xlsx", "UHF_Summary")

# 3. HFD Hybrid ML Model
compile_model("hfd_hybrid_ml_results_ALL_.*\\.rds$", function(data) {
  metrics_list <- list(); imp_list <- list()
  for (ric in names(data)) {
    tryCatch({
      if (!is.null(data[[ric]]$metrics)) metrics_list[[ric]] <- data[[ric]]$metrics
      if (!is.null(data[[ric]]$importance) && nrow(data[[ric]]$importance) > 0) { imp <- as.data.frame(data[[ric]]$importance); imp$Ticker <- ric; imp_list[[ric]] <- imp }
    }, error=function(e){})
  }
  list(if(length(metrics_list)>0) bind_rows(metrics_list) else NULL, if(length(imp_list)>0) bind_rows(imp_list) else NULL)
}, "HFD_HybridML_Model_Summary.xlsx", c("OOS_Metrics", "Feature_Importance"))

# 4. LFD ARIMA Model
compile_model("LFD_ARIMA_.*\\.rds$", function(data) {
  df_list <- list()
  for (ric in names(data)) { tryCatch({ if(!is.null(data[[ric]]$summary_df)) df_list[[ric]] <- data[[ric]]$summary_df }, error=function(e){}) }
  list(if(length(df_list) > 0) bind_rows(df_list) else NULL)
}, "LFD_ARIMA_Model_Summary.xlsx", "ARIMA_Summary")

# 5. LFD GARCH Model
compile_model("LFD_GARCH_.*\\.rds$", function(data) {
  df_list <- list()
  for (ric in names(data)) { tryCatch({ if(!is.null(data[[ric]]$summary_df)) df_list[[ric]] <- data[[ric]]$summary_df }, error=function(e){}) }
  list(if(length(df_list) > 0) bind_rows(df_list) else NULL)
}, "LFD_GARCH_Model_Summary.xlsx", "GARCH_Summary")

# 6. LFD HYBRID Model
compile_model("LFD_HYBRID_.*\\.rds$", function(data) {
  metrics_list <- list(); imp_list <- list()
  for (ric in names(data)) {
    tryCatch({
      if (!is.null(data[[ric]]$metrics)) metrics_list[[ric]] <- data[[ric]]$metrics
      if (!is.null(data[[ric]]$importance) && nrow(data[[ric]]$importance) > 0) { imp <- as.data.frame(data[[ric]]$importance); imp$Ticker <- ric; imp_list[[ric]] <- imp }
    }, error=function(e){})
  }
  list(if(length(metrics_list)>0) bind_rows(metrics_list) else NULL, if(length(imp_list)>0) bind_rows(imp_list) else NULL)
}, "LFD_HYBRID_Model_Summary.xlsx", c("OOS_Metrics", "Feature_Importance"))

cat("======================================================\n")
cat("Pipeline Compilation Complete Successfully!\n")
cat("======================================================\n")