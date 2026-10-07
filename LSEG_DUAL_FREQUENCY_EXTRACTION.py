# ==============================================================================
#  LSEG WORKSPACE DATA EXTRACTION TOOL                    dual-frequency version 3
# ==============================================================================
#
#  WHAT THIS SCRIPT DOES
#  ---------------------
#  Downloads historical price data from LSEG Workspace for a list of companies,
#  cleans it, and saves a structured Excel workbook together with CSV copies.
#
#  QUICK START
#  -----------
#  1. Open LSEG Workspace and log in. The script connects through it.
#  2. Edit the USER SETTINGS section below. Most of the time you only change:
#         INSTRUMENTS             which companies
#         START_DATE, END_DATE    which period
#         LFD/HFD settings        daily and 1-minute frequencies
#  3. (Optional) Set PREVIEW_ONLY = True and run once. The script checks your
#     settings and prints the request plan without downloading anything.
#  4. Set PREVIEW_ONLY = False and run:   python LSEG_EXTRACTION_v2.py
#
#  COMMON CHANGES AT A GLANCE
#  --------------------------
#  I want to ...                            Change this
#  ---------------------------------------  ------------------------------------
#  add or remove a company                  INSTRUMENTS              (section 1)
#  read a long list of companies from file  INSTRUMENTS_FILE         (section 1)
#  change the sample period                 START_DATE, END_DATE     (section 2)
#  get the last N years up to today         START_DATE = "5Y"
#                                           END_DATE   = "today"     (section 2)
#  switch to weekly or monthly data         INTERVAL = "weekly"      (section 3)
#  download intraday bars (e.g. 5-minute)   INTERVAL = "5min"        (section 3)
#  add bid/ask or other variables           FIELDS                   (section 4)
#  get prices not adjusted for splits       ADJUSTMENTS              (section 4)
#  use simple instead of log returns        RETURN_TYPE = "simple"   (section 5)
#  check settings without downloading       PREVIEW_ONLY = True      (section 7)
#
#  Ready-made example configurations are listed at the end of the settings.
#
#  WHAT YOU GET
#  ------------
#  A folder for each run inside OUTPUT_FOLDER, containing:
#
#  LSEG_LFD_<date>.xlsx and LSEG_HFD_<date>.xlsx           the two main workbooks:
#      README        settings used for this run and a guide to every sheet
#      Companies     one row per company: status, observations, coverage
#      Close, Open, High, Low, Volume, ...
#                    one sheet per field in WIDE layout:
#                    rows = dates, columns = companies (good for charts)
#      Returns       period returns from the closing price, same layout
#      Statistics    descriptive statistics for each company and variable
#      Missing_Data  share of missing values for each company and field
#      Data_Long     all data in LONG (tidy) layout: one row per
#                    company-date (good for R, Stata, pandas, pivot tables)
#      Request_Log   every request sent to LSEG, its status and row count
#
#  csv/              CSV copies of every table above
#  csv/by_company/   the raw download for each company, with LSEG field codes
#
#  REQUIREMENTS
#  ------------
#  pip install lseg-data pandas numpy openpyxl
#
# ==============================================================================


# ==============================================================================
#                                USER SETTINGS
# ==============================================================================


# ------------------------------------------------------------------------------
# 1. COMPANIES
# ------------------------------------------------------------------------------
#
# Each company is identified by its RIC (Refinitiv Instrument Code): the ticker
# followed by a suffix for the exchange on which it trades.
#
#     Suffix   Exchange                        Example
#     ------   -----------------------------   --------------------------
#     .O       NASDAQ                          AAPL.O    Apple
#     .N       New York Stock Exchange         JPM.N     JPMorgan Chase
#     .AX      Australian Securities Exchange  BHP.AX    BHP Group
#     .L       London Stock Exchange           HSBA.L    HSBC
#     .DE      Xetra (Germany)                 SAPG.DE   SAP
#     .T       Tokyo Stock Exchange            7203.T    Toyota
#
#     Indices start with a dot:  .SPX (S&P 500), .AXJO (S&P/ASX 200)
#     Exchange rates end in "=": AUD= (AUD/USD), EUR= (EUR/USD)
#
# HOW TO FIND A RIC
#     Type the company name into the LSEG Workspace search bar. The RIC is
#     shown next to the name, e.g. "Apple Inc   AAPL.O".
#
# FORMAT
#     "RIC": "Label",
#
#     - The RIC (left) is what is sent to LSEG. It must be exact.
#     - The label (right) only appears in the Excel output. Leave it empty
#       ("") and the company name is fetched from LSEG automatically
#       (when FETCH_COMPANY_NAMES = True), otherwise the RIC is used.
#     - To drop a company, delete its line or put # at the start of the line.
#     - Every line ends with a comma.
#     - A plain list also works:  INSTRUMENTS = ["AAPL.O", "MSFT.O"]
#
# ------------------------------------------------------------------------------

INSTRUMENTS = {
    "AAPL.O": "Apple",
    "MSFT.O": "Microsoft",
    "GOOG.O": "Alphabet",
    "AMZN.O": "Amazon",
    "META.O": "Meta Platforms",
    "NVDA.O": "NVIDIA",
    "TSLA.O": "Tesla",
    "JPM.N":  "JPMorgan Chase",
    "BAC.N":  "Bank of America",
    "WMT.N":  "Walmart",
}

# OPTIONAL - READ THE COMPANIES FROM A FILE
#     For long lists, put the RICs in a CSV or Excel file with a header row.
#     The column "RIC" is required; the column "Name" is optional:
#
#         RIC,Name
#         BHP.AX,BHP Group
#         CBA.AX,Commonwealth Bank
#
#     Then give the file name, e.g. INSTRUMENTS_FILE = "companies.csv".
#     A relative name is looked up in the folder that holds this script.
#     When a file is given, INSTRUMENTS above is ignored.

INSTRUMENTS_FILE = None

# Fetch company names from LSEG for any company without a label (True/False).
FETCH_COMPANY_NAMES = True


# ------------------------------------------------------------------------------
# 2. DATE RANGE
# ------------------------------------------------------------------------------
#
# START_DATE can be written in either of two ways:
#     (a) a fixed date, YYYY-MM-DD                        "2020-01-01"
#     (b) a look-back period, counted back from END_DATE:
#             "90D" = 90 days       "12W" = 12 weeks
#             "18M" = 18 months     "5Y"  = 5 years
#
# END_DATE can be written in either of two ways:
#     (a) a fixed date, YYYY-MM-DD                        "2025-12-31"
#     (b) "today"
#
# EXAMPLES
#     Calendar year 2024          START_DATE = "2024-01-01"
#                                 END_DATE   = "2024-12-31"
#
#     Last five years to today    START_DATE = "5Y"
#                                 END_DATE   = "today"
#
#     Five years ending 2019      START_DATE = "5Y"
#                                 END_DATE   = "2019-12-31"
#
# NOTES
#     - Fixed dates make the download reproducible. "today" changes every
#       time the script runs, so record the dates you actually used
#       (they are written to the README sheet of every workbook).
#     - For intraday data the whole END_DATE day is included.
#     - LSEG keeps intraday history for a limited period only (typically
#       about a year for minute bars). Older intraday requests return nothing.
#     - "M" here means MONTHS of look-back. It is unrelated to INTERVAL = "1M".
#
# ------------------------------------------------------------------------------

START_DATE = "2025-09-30"

END_DATE = "2026-09-30"


# ------------------------------------------------------------------------------
# 3. FREQUENCY
# ------------------------------------------------------------------------------
#
# This version automatically downloads TWO datasets in one run:
#
#   LFD = Low Frequency Data
#         Default: daily observations ("daily")
#
#   HFD = High Frequency Data
#         Default: one-minute bars ("1min")
#
# You can change the two frequencies independently:
#
#     LFD_INTERVAL = "daily"
#     HFD_INTERVAL = "1min"
#
# Other supported HFD examples include "5min", "10min", "30min" and "hourly".
#
# IMPORTANT:
# Minute-by-minute history is normally subject to a much shorter LSEG
# historical availability window than daily data. To keep the output
# manageable, HFD_START_DATE defaults to "30D" rather than using the full
# LFD sample period. You can change this to "7D", "14D", "60D", etc.
#
# If LSEG does not provide the requested minute history, the HFD workbook
# will show the failed/empty requests in Request_Log rather than silently
# substituting daily data.
#
# Both workbooks retain the same sheets, formatting, field layout, returns,
# statistics, missing-data reporting and long-format structure as the
# original single-frequency script.
#
# ------------------------------------------------------------------------------
LFD_INTERVAL = "daily"
HFD_INTERVAL = "1min"

# LFD uses the full START_DATE -> END_DATE period.
LFD_START_DATE = START_DATE
LFD_END_DATE = END_DATE

# HFD is deliberately shorter because 1-minute data produces many rows.
# Default: the most recent 30 calendar days ending at HFD_END_DATE.
# Examples:
#     "7D"  = last 7 calendar days
#     "14D" = last 14 calendar days
#     "30D" = last 30 calendar days
#     "60D" = last 60 calendar days
# Using "30D" keeps the high-frequency workbook much smaller while still
# providing enough observations for most intraday analysis.
HFD_START_DATE = "30D"
HFD_END_DATE = END_DATE

# Date used in the final workbook filenames. None = date the script runs.
OUTPUT_DATE = None

# ------------------------------------------------------------------------------
# 4. DATA FIELDS
# ------------------------------------------------------------------------------
#
#     Field code    Sheet name   Meaning
#     -----------   ----------   -----------------------------------------------
#     TRDPRC_1      Close        last traded price of the period (the close)
#     OPEN_PRC      Open         first traded price of the period
#     HIGH_1        High         highest traded price of the period
#     LOW_1         Low          lowest traded price of the period
#     ACVOL_UNS     Volume       number of shares (units) traded
#     BID           Bid          best bid at the end of the period
#     ASK           Ask          best ask at the end of the period
#     MID_PRICE     Mid          mid-point of bid and ask
#     VWAP          VWAP         volume-weighted average price
#     NUM_MOVES     Trades       number of trades
#     TRNOVR_UNS    Turnover     value traded, in the trading currency
#
# NOTES
#     - Not every field exists for every instrument. Indices usually have no
#       volume; exchange rates have BID/ASK/MID_PRICE but no TRDPRC_1.
#       Unavailable fields simply appear as blank (see the Missing_Data sheet).
#     - FIELDS = [] requests LSEG's default field set for each instrument,
#       which is a quick way to discover what is available.
#     - Fields not in the table above still work; their sheet is named after
#       the field code. You can add a friendly name in FIELD_DICTIONARY
#       further down this file.
#
# ------------------------------------------------------------------------------

FIELDS = [
    "TRDPRC_1",
    "OPEN_PRC",
    "HIGH_1",
    "LOW_1",
    "ACVOL_UNS",
]

# ADJUSTMENTS - how prices are adjusted for corporate actions.
#     None           LSEG default (adjusted for splits and other capital
#                    changes, so prices are comparable over time)
#     "unadjusted"   prices exactly as they traded on the day
#
# Neither setting adds back dividends, so returns below are PRICE returns.

ADJUSTMENTS = None


# ------------------------------------------------------------------------------
# 5. RETURNS
# ------------------------------------------------------------------------------
#
# COMPUTE_RETURNS = True adds a "Returns" sheet and return statistics.
#
# RETURN_TYPE
#     "log"      r_t = ln(P_t / P_{t-1})   additive over time
#     "simple"   R_t = P_t / P_{t-1} - 1   additive across portfolio weights
#
# RETURN_PRICE_FIELD is the price used (normally TRDPRC_1, the close).
# For exchange rates, which have no traded price, use "MID_PRICE".
#
# Returns are computed separately for each company from its own consecutive
# observations, so differing trading calendars (e.g. ASX and NYSE holidays)
# do not create artificial gaps. The first observation of each company has
# no return. A missing price makes both adjacent returns missing.
#
# ------------------------------------------------------------------------------

COMPUTE_RETURNS = True

RETURN_TYPE = "log"

RETURN_PRICE_FIELD = "TRDPRC_1"


# ------------------------------------------------------------------------------
# 6. REQUEST SETTINGS  (advanced - usually leave as they are)
# ------------------------------------------------------------------------------
#
# TIME_BATCH_DAYS
#     LSEG limits how many rows a single request can return, so long date
#     ranges are split into windows of this many calendar days.
#     "auto" picks a size that suits INTERVAL:
#         1min: 30    5min: 120    10min: 180    30min / hourly: 365
#         daily: 1095 (about 3 years)    weekly: 3650    monthly+: 7300+
#     Or give a whole number, e.g. HFD_TIME_BATCH_DAYS = 15.
#     If the Request_Log sheet reports "possible truncation", lower the
#     relevant batch setting.
#
# REQUEST_DELAY_SECONDS   pause between requests, to respect rate limits
# MAX_RETRIES             retries for a failed request before moving on
#
# ------------------------------------------------------------------------------

# Separate batch controls are used because minute data is much larger.
# "auto" selects a sensible size for each frequency.
LFD_TIME_BATCH_DAYS = "auto"
HFD_TIME_BATCH_DAYS = "auto"

REQUEST_DELAY_SECONDS = 1
MAX_RETRIES = 2


# ------------------------------------------------------------------------------
# 7. OUTPUT
# ------------------------------------------------------------------------------
#
# OUTPUT_FOLDER            folder for both LFD and HFD results. A relative name
#                          is created next to this script.
# TIMESTAMPED_RUN_FOLDER   True  = each dual-frequency run gets its own
#                                  timestamped subfolder.
#                          False = files go straight into OUTPUT_FOLDER.
# SAVE_CSV                 also save CSV copies of every table
# PREVIEW_ONLY             True = check settings and print the request plan,
#                          but do not connect to LSEG or download anything
#
# ------------------------------------------------------------------------------

OUTPUT_FOLDER = "LSEG_Output"

TIMESTAMPED_RUN_FOLDER = True

SAVE_CSV = True

PREVIEW_ONLY = False


# ------------------------------------------------------------------------------
# EXAMPLE CONFIGURATIONS  (copy the lines you need over the settings above)
# ------------------------------------------------------------------------------
#
# (A) ASX big-four banks, monthly, last ten years
#
#     INSTRUMENTS = {
#         "CBA.AX": "Commonwealth Bank",
#         "WBC.AX": "Westpac",
#         "NAB.AX": "National Australia Bank",
#         "ANZ.AX": "ANZ Group",
#     }
#     START_DATE = "10Y"
#     END_DATE   = "today"
#     INTERVAL   = "monthly"
#
# (B) Equity indices, daily, fixed sample for an assignment
#
#     INSTRUMENTS = {
#         ".SPX":  "S&P 500",
#         ".AXJO": "S&P/ASX 200",
#         ".FTSE": "FTSE 100",
#     }
#     START_DATE = "2015-01-01"
#     END_DATE   = "2024-12-31"
#     INTERVAL   = "daily"
#     FIELDS     = ["TRDPRC_1", "OPEN_PRC", "HIGH_1", "LOW_1"]
#
# (C) Five-minute bars for two stocks over the last month
#
#     INSTRUMENTS = {"AAPL.O": "Apple", "MSFT.O": "Microsoft"}
#     START_DATE  = "1M"
#     END_DATE    = "today"
#     INTERVAL    = "5min"
#
# (D) Exchange rates, weekly, last three years
#
#     INSTRUMENTS = {"AUD=": "AUD/USD", "EUR=": "EUR/USD", "JPY=": "USD/JPY"}
#     START_DATE  = "3Y"
#     END_DATE    = "today"
#     INTERVAL    = "weekly"
#     FIELDS      = ["BID", "ASK", "MID_PRICE"]
#     RETURN_PRICE_FIELD = "MID_PRICE"
#
# ==============================================================================
#                              END OF USER SETTINGS
# ==============================================================================



# ==============================================================================
#  EVERYTHING BELOW THIS LINE RUNS THE EXTRACTION.
#  You do not need to edit it to change companies, dates or frequency.
# ==============================================================================

import math
import os
import re
import sys
import time
import warnings
from types import SimpleNamespace

import numpy as np
import pandas as pd
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
from openpyxl.utils import get_column_letter

try:
    import lseg.data as ld
except ImportError:  # PREVIEW_ONLY runs still work without the library
    ld = None

# pandas warns when combining tables in which a column is entirely blank;
# that is expected here (e.g. BID missing for one company), so hide it.
warnings.filterwarnings(
    "ignore", category=FutureWarning, message=".*empty or all-NA entries.*"
)

SCRIPT_VERSION = "3.0"


# ==============================================================================
# REFERENCE TABLES
# ==============================================================================

# ------------------------------------------------------------------------------
# Supported INTERVAL codes and how each one is handled
#
#   kind              "interday" (a day or longer) or "intraday"
#   label             readable name used in folder/file names and the README
#   batch_days        calendar days per request when TIME_BATCH_DAYS = "auto"
#   periods_per_year  used to annualise return statistics (None = intraday)
#   period_days       approximate length of one period (coverage checks)
# ------------------------------------------------------------------------------

def _interval(kind, label, batch_days, periods_per_year, period_days):
    return {
        "kind": kind,
        "label": label,
        "batch_days": batch_days,
        "periods_per_year": periods_per_year,
        "period_days": period_days,
    }


_MIN1 = _interval("intraday", "1-minute", 30, None, 1)
_MIN5 = _interval("intraday", "5-minute", 120, None, 1)
_MIN10 = _interval("intraday", "10-minute", 180, None, 1)
_MIN30 = _interval("intraday", "30-minute", 365, None, 1)
_HOUR = _interval("intraday", "hourly", 365, None, 1)
_DAY = _interval("interday", "daily", 1095, 252, 1)
_WEEK = _interval("interday", "weekly", 3650, 52, 7)
_MONTH = _interval("interday", "monthly", 7300, 12, 31)
_QUARTER = _interval("interday", "quarterly", 18250, 4, 92)
_HALF = _interval("interday", "half-yearly", 18250, 2, 183)
_YEAR = _interval("interday", "yearly", 18250, 1, 366)

INTERVALS = {
    "1min": _MIN1, "minute": _MIN1,
    "5min": _MIN5,
    "10min": _MIN10,
    "30min": _MIN30,
    "60min": _HOUR, "hourly": _HOUR, "1h": _HOUR,
    "daily": _DAY, "1D": _DAY, "1d": _DAY,
    "weekly": _WEEK, "1W": _WEEK, "7D": _WEEK, "7d": _WEEK,
    "monthly": _MONTH, "1M": _MONTH,
    "quarterly": _QUARTER, "3M": _QUARTER,
    "6M": _HALF,
    "yearly": _YEAR, "1Y": _YEAR, "12M": _YEAR,
}


# ------------------------------------------------------------------------------
# Excel number formats
# ------------------------------------------------------------------------------

PRICE_FORMAT = "#,##0.00##"      # 2 to 4 decimals, so FX rates keep precision
COUNT_FORMAT = "#,##0"
RETURN_FORMAT = "0.000%"
PERCENT_FORMAT = "0.00%"
STAT_FORMAT = "#,##0.0000"
SMALL_STAT_FORMAT = "0.000000"


# ------------------------------------------------------------------------------
# Field dictionary: LSEG field code -> (sheet name, Excel format, description)
# Add your own fields here to give them a friendly sheet name.
# ------------------------------------------------------------------------------

FIELD_DICTIONARY = {
    "TRDPRC_1":   ("Close", PRICE_FORMAT,
                   "Last traded price of the period (the closing price for daily bars)"),
    "OPEN_PRC":   ("Open", PRICE_FORMAT, "First traded price of the period"),
    "HIGH_1":     ("High", PRICE_FORMAT, "Highest traded price of the period"),
    "LOW_1":      ("Low", PRICE_FORMAT, "Lowest traded price of the period"),
    "ACVOL_UNS":  ("Volume", COUNT_FORMAT,
                   "Accumulated volume: number of shares (units) traded"),
    "BID":        ("Bid", PRICE_FORMAT, "Best bid price at the end of the period"),
    "ASK":        ("Ask", PRICE_FORMAT, "Best ask price at the end of the period"),
    "MID_PRICE":  ("Mid", PRICE_FORMAT, "Mid-point of bid and ask"),
    "VWAP":       ("VWAP", PRICE_FORMAT, "Volume-weighted average price"),
    "NUM_MOVES":  ("Trades", COUNT_FORMAT, "Number of trades in the period"),
    "TRNOVR_UNS": ("Turnover", COUNT_FORMAT,
                   "Value traded in the period, in the trading currency"),
}


# ------------------------------------------------------------------------------
# Workbook layout
# ------------------------------------------------------------------------------

EXCEL_MAX_ROWS = 1_048_576          # Excel's hard limit, including the header
FORMAT_CELL_LIMIT = 3_000_000       # skip per-cell number formats above this

NAVY = "1F3864"
TAB_COLOURS = {
    "README": "404040",
    "Companies": NAVY,
    "field": "2E75B6",
    "Returns": "548235",
    "Statistics": "C55A11",
    "Missing_Data": "BF9000",
    "Data_Long": "7030A0",
    "Request_Log": "7F7F7F",
}

HEADER_FONT = Font(bold=True, color="FFFFFF")
HEADER_FILL = PatternFill("solid", start_color=NAVY, end_color=NAVY)
HEADER_ALIGNMENT = Alignment(horizontal="center", vertical="center", wrap_text=True)
HEADER_BORDER = Border(bottom=Side(style="medium", color="000000"))

LOG_COLUMNS = [
    "RIC", "Name", "Window", "Request Start", "Request End", "Status", "Rows",
    "First Observation", "Last Observation", "Attempts", "Note",
]


# ==============================================================================
# ERRORS
# ==============================================================================

class SettingsError(Exception):
    """A USER SETTING is invalid. The message explains how to fix it."""


class ExtractionError(Exception):
    """The extraction cannot continue (e.g. no connection, no data)."""


class RequestFailed(Exception):
    """A single LSEG request failed after all retries."""

    def __init__(self, message, attempts):
        super().__init__(message)
        self.attempts = attempts


# ==============================================================================
# SMALL HELPERS
# ==============================================================================

def banner(title):
    print("\n" + "=" * 80)
    print(title)
    print("=" * 80)


def short_text(value, limit=200):
    """Collapse whitespace and truncate long error messages."""
    text = " ".join(str(value).split())
    return text if len(text) <= limit else text[: limit - 3] + "..."


def safe_filename(text):
    """Turn a RIC or label into something safe for a file name (.AXJO -> AXJO)."""
    cleaned = re.sub(r"[^A-Za-z0-9_-]+", "_", str(text)).strip("_")
    return cleaned or "item"


def script_folder():
    """Folder of this script; falls back to the working folder in Jupyter."""
    try:
        return os.path.dirname(os.path.abspath(__file__))
    except NameError:
        return os.getcwd()


def script_name():
    try:
        return os.path.basename(__file__)
    except NameError:
        return "LSEG extraction script"


def fmt_date(value, intraday=False):
    if value is None or pd.isna(value):
        return "-"
    return value.strftime("%Y-%m-%d %H:%M" if intraday else "%Y-%m-%d")


def find_code(code, codes):
    """Case-insensitive lookup of a field code among the returned codes."""
    for candidate in codes:
        if candidate.upper() == str(code).strip().upper():
            return candidate
    return None


# ==============================================================================
# STEP 1 - READ AND VALIDATE THE USER SETTINGS
# ==============================================================================

def load_instruments(folder):
    """Return an ordered {RIC: label} dictionary from INSTRUMENTS(_FILE)."""

    if INSTRUMENTS_FILE:
        path = INSTRUMENTS_FILE
        if not os.path.isabs(path):
            path = os.path.join(folder, path)
        if not os.path.exists(path):
            raise SettingsError(f"INSTRUMENTS_FILE not found:\n    {path}")

        if path.lower().endswith((".xlsx", ".xls")):
            table = pd.read_excel(path, dtype=str)
        else:
            table = pd.read_csv(path, dtype=str)
        table = table.fillna("")

        columns = {str(c).strip().lower(): c for c in table.columns}
        if "ric" not in columns:
            raise SettingsError(
                f"INSTRUMENTS_FILE must have a column headed 'RIC'.\n"
                f"Columns found: {list(table.columns)}"
            )
        rics = table[columns["ric"]].tolist()
        names = (table[columns["name"]].tolist() if "name" in columns
                 else [""] * len(rics))
        pairs = list(zip(rics, names))

    elif isinstance(INSTRUMENTS, dict):
        pairs = list(INSTRUMENTS.items())

    elif isinstance(INSTRUMENTS, (list, tuple)):
        pairs = [(ric, "") for ric in INSTRUMENTS]

    else:
        raise SettingsError(
            'INSTRUMENTS must be a dictionary such as {"AAPL.O": "Apple"} '
            'or a list such as ["AAPL.O", "MSFT.O"].'
        )

    instruments = {}
    for ric, name in pairs:
        ric = str(ric).strip()
        if not ric:
            continue
        if ric in instruments:
            print(f"Note: {ric} is listed more than once; it is downloaded once.")
            continue
        instruments[ric] = str(name or "").strip()

    if not instruments:
        raise SettingsError("No companies were specified in INSTRUMENTS.")

    return instruments


def resolve_interval(value):
    """Return (LSEG interval code, interval information)."""
    text = str(value).strip()
    if text in INTERVALS:
        return text, INTERVALS[text]

    # Accept word forms in any capitalisation ("Daily", "MONTHLY").
    for code in INTERVALS:
        if code.isalpha() and code.lower() == text.lower():
            return code, INTERVALS[code]

    hint = ""
    if text.lower() == "1m":
        hint = '\nFor monthly data use "1M" (capital M); for 1-minute bars use "1min".'
    raise SettingsError(
        f'INTERVAL = "{value}" is not recognised.{hint}\n'
        f"Valid values:\n"
        f'    interday : "daily" / "1D", "weekly" / "1W", "monthly" / "1M",\n'
        f'               "quarterly" / "3M", "6M", "yearly" / "1Y"\n'
        f'    intraday : "1min", "5min", "10min", "30min", "hourly" / "1h"'
    )


def parse_end_date(value, intraday):
    """Return (END_DATE as a date, end timestamp actually sent to LSEG)."""
    text = str(value).strip()
    now = pd.Timestamp.now()

    if text.lower() == "today":
        end_date = now.normalize()
        return end_date, (now.floor("min") if intraday else end_date)

    try:
        end_date = pd.to_datetime(text, format="%Y-%m-%d")
    except (ValueError, TypeError):
        raise SettingsError(
            f'END_DATE = "{value}" is not valid. Use YYYY-MM-DD or "today".'
        ) from None

    # Intraday: include the whole of END_DATE (up to midnight that night).
    request_end = end_date + pd.Timedelta(days=1) if intraday else end_date
    return end_date, request_end


_LOOKBACK = re.compile(r"^(\d+)\s*([DWMY])$", re.IGNORECASE)


def parse_start_date(value, end_date):
    """START_DATE is either YYYY-MM-DD or a look-back such as '5Y' or '18M'."""
    text = str(value).strip()

    match = _LOOKBACK.match(text)
    if match:
        number, unit = int(match.group(1)), match.group(2).upper()
        offset = {
            "D": pd.DateOffset(days=number),
            "W": pd.DateOffset(weeks=number),
            "M": pd.DateOffset(months=number),
            "Y": pd.DateOffset(years=number),
        }[unit]
        return (end_date - offset).normalize()

    try:
        return pd.to_datetime(text, format="%Y-%m-%d")
    except (ValueError, TypeError):
        raise SettingsError(
            f'START_DATE = "{value}" is not valid.\n'
            f'Use YYYY-MM-DD (e.g. "2020-01-01") or a look-back '
            f'(e.g. "90D", "12W", "18M", "5Y").'
        ) from None


def resolve_batch_days(interval, value):
    if isinstance(value, str) and value.strip().lower() == "auto":
        return interval["batch_days"], "auto"
    try:
        days = int(value)
    except (TypeError, ValueError):
        raise SettingsError('TIME_BATCH_DAYS value must be "auto" or a whole number.') from None
    if days < 1:
        raise SettingsError("TIME_BATCH_DAYS must be at least 1.")
    return days, "manual"


def resolve_fields():
    if FIELDS is None:
        return []
    items = [FIELDS] if isinstance(FIELDS, str) else list(FIELDS)
    fields = []
    for item in items:
        item = str(item).strip()
        if item and item not in fields:
            fields.append(item)
    return fields


def resolve_settings(interval_value=None, start_value=None, end_value=None,
                    batch_days_value=None):
    """Validate one frequency's settings and collect them in cfg."""
    cfg = SimpleNamespace()
    cfg.script_folder = script_folder()

    cfg.instruments = load_instruments(cfg.script_folder)
    cfg.rics = list(cfg.instruments)
    cfg.names = {ric: (label or ric) for ric, label in cfg.instruments.items()}

    # These values are passed in by the LFD/HFD runner.
    interval_value = INTERVAL if interval_value is None else interval_value
    start_value = START_DATE if start_value is None else start_value
    end_value = END_DATE if end_value is None else end_value

    cfg.interval_code, cfg.interval = resolve_interval(interval_value)
    cfg.interval_setting = interval_value
    cfg.start_setting = start_value
    cfg.end_setting = end_value
    cfg.is_intraday = cfg.interval["kind"] == "intraday"
    cfg.date_col = "Timestamp" if cfg.is_intraday else "Date"
    cfg.periods_per_year = cfg.interval["periods_per_year"]

    cfg.gap_tolerance_days = max(7, 3 * cfg.interval["period_days"])

    cfg.end_date, cfg.request_end = parse_end_date(end_value, cfg.is_intraday)
    cfg.start_date = parse_start_date(start_value, cfg.end_date)
    if cfg.start_date >= cfg.request_end:
        raise SettingsError(
            f"END_DATE ({fmt_date(cfg.end_date)}) must be after "
            f"START_DATE ({fmt_date(cfg.start_date)})."
        )
    if cfg.end_date > pd.Timestamp.now().normalize():
        print(f"Note: END_DATE {fmt_date(cfg.end_date)} is in the future; "
              f"data can only run to today.")

    if batch_days_value is None:
        batch_days_value = (LFD_TIME_BATCH_DAYS if interval_value == LFD_INTERVAL
                            else HFD_TIME_BATCH_DAYS)
    cfg.batch_days, cfg.batch_mode = resolve_batch_days(cfg.interval, batch_days_value)
    cfg.fields = resolve_fields()
    cfg.adjustments = str(ADJUSTMENTS).strip() if ADJUSTMENTS else None

    cfg.return_col = None
    cfg.return_type = None
    if COMPUTE_RETURNS:
        cfg.return_type = str(RETURN_TYPE).strip().lower()
        if cfg.return_type not in ("log", "simple"):
            raise SettingsError('RETURN_TYPE must be "log" or "simple".')
        cfg.return_col = "Log return" if cfg.return_type == "log" else "Simple return"

    return cfg


def create_time_windows(start, end, days):
    """Split [start, end] into consecutive windows of at most `days` days.

    Neighbouring windows share their boundary date so that nothing is lost;
    the resulting duplicate rows are removed during cleaning.
    """
    windows = []
    current = start
    while current < end:
        following = min(current + pd.Timedelta(days=days), end)
        windows.append((current, following))
        current = following
    return windows


def print_settings(cfg, windows):
    banner("SETTINGS")

    field_text = ", ".join(
        f"{f} ({FIELD_DICTIONARY[f.upper()][0]})" if f.upper() in FIELD_DICTIONARY else f
        for f in cfg.fields
    ) or "LSEG default field set"
    returns_text = (f"{cfg.return_type} returns from {RETURN_PRICE_FIELD}"
                    if cfg.return_col else "not computed")
    source = f'file "{INSTRUMENTS_FILE}"' if INSTRUMENTS_FILE else "INSTRUMENTS"

    print(f"Companies        : {len(cfg.rics)}  (from {source})")
    print(f'Frequency        : {cfg.interval["label"]}  (INTERVAL = "{cfg.interval_setting}")')
    print(f"Period           : {fmt_date(cfg.start_date)} to {fmt_date(cfg.end_date)}"
          f'  (START_DATE = "{cfg.start_setting}", END_DATE = "{cfg.end_setting}")')
    print(f"Fields           : {field_text}")
    print(f"Adjustments      : {cfg.adjustments or 'LSEG default'}")
    print(f"Returns          : {returns_text}")
    print(f"Request windows  : {len(windows)} per company, up to "
          f"{cfg.batch_days:,} calendar days each ({cfg.batch_mode})")
    print(f"Total requests   : {len(windows) * len(cfg.rics):,}"
          f"  (pause of {REQUEST_DELAY_SECONDS} s between requests)")
    if cfg.is_intraday:
        print("Timestamps       : UTC")

    print("\nCompanies:")
    for number, ric in enumerate(cfg.rics, start=1):
        label = cfg.instruments[ric] or "(name fetched from LSEG)"
        print(f"  {number:3}. {ric:<14} {label}")

    print("\nRequest windows:")
    shown = windows if len(windows) <= 8 else windows[:4] + [None] + windows[-3:]
    for item in shown:
        if item is None:
            print("        ...")
            continue
        number = windows.index(item) + 1
        print(f"  {number:3}. {fmt_date(item[0], cfg.is_intraday)}  to  "
              f"{fmt_date(item[1], cfg.is_intraday)}")


# ==============================================================================
# STEP 2 - DOWNLOAD
# ==============================================================================

def fetch_company_names(cfg):
    """Fill in company names from LSEG for RICs that were given no label."""
    missing = [ric for ric, label in cfg.instruments.items() if not label]
    if not missing or not FETCH_COMPANY_NAMES:
        return
    print(f"\nFetching company names for {len(missing)} instrument(s) ...")
    try:
        table = ld.get_data(universe=missing, fields=["TR.CommonName"])
        for _, row in table.iterrows():
            ric, name = str(row.iloc[0]).strip(), row.iloc[-1]
            if ric in cfg.names and isinstance(name, str) and name.strip():
                cfg.names[ric] = name.strip()
    except Exception as error:
        print(f"    Could not fetch names ({short_text(error)}); RICs are used.")


def request_history(ric, start_text, end_text, cfg):
    """Send one get_history request, retrying on failure.

    Returns (result, number of attempts). Raises RequestFailed.
    """
    arguments = {
        "universe": ric,
        "interval": cfg.interval_code,
        "start": start_text,
        "end": end_text,
    }
    if cfg.fields:
        arguments["fields"] = cfg.fields
    if cfg.adjustments:
        arguments["adjustments"] = cfg.adjustments

    attempts = 0
    while True:
        attempts += 1
        try:
            return ld.get_history(**arguments), attempts
        except Exception as error:
            message = short_text(error)
            # Retrying cannot fix an unknown RIC or field.
            permanent = any(word in message.lower()
                            for word in ("not found", "invalid", "unable to resolve"))
            if permanent or attempts > MAX_RETRIES:
                raise RequestFailed(message, attempts) from error
            wait = max(2.0, float(REQUEST_DELAY_SECONDS)) * attempts
            print(f"      attempt {attempts} failed ({message}); "
                  f"retrying in {wait:.0f} s")
            time.sleep(wait)


def to_naive_datetime(values, intraday):
    """Convert to timezone-free datetimes (Excel cannot store time zones).

    Timezone-aware values are converted to UTC first. Interday dates are
    reduced to the date alone.
    """
    converted = pd.to_datetime(values, errors="coerce", utc=True).dt.tz_localize(None)
    return converted if intraday else converted.dt.normalize()


def to_numeric_if_possible(values):
    """Numbers become float64; genuinely textual columns are left unchanged."""
    try:
        return pd.to_numeric(values).astype("float64")
    except (ValueError, TypeError):
        return values


def standardise_result(result, ric, cfg):
    """Turn one get_history result into a flat table: RIC, date, fields."""
    if result is None:
        return None
    frame = result.copy() if isinstance(result, pd.DataFrame) else pd.DataFrame(result)
    if frame.empty:
        return None

    # Single-instrument requests normally return flat columns; flatten
    # defensively in case a (RIC, field) column index is returned.
    if isinstance(frame.columns, pd.MultiIndex):
        frame.columns = [column[-1] for column in frame.columns]
    frame.columns = [str(column) for column in frame.columns]
    frame = frame.drop(columns=[c for c in (cfg.date_col, "RIC") if c in frame.columns])

    frame.index.name = cfg.date_col
    frame = frame.reset_index()
    frame[cfg.date_col] = to_naive_datetime(frame[cfg.date_col], cfg.is_intraday)

    for column in frame.columns:
        if column != cfg.date_col:
            frame[column] = to_numeric_if_possible(frame[column])

    frame.insert(0, "RIC", ric)
    return frame


def coverage_note(first_observation, window_start, earlier_data, cfg):
    """Explain a window whose data starts well after the requested start."""
    gap = (first_observation.normalize() - window_start.normalize()).days
    if gap <= cfg.gap_tolerance_days:
        return ""
    if earlier_data:
        return (f"Possible truncation: data starts {gap} days after the window "
                f"start although earlier windows returned data. Lower "
                f"TIME_BATCH_DAYS and run again.")
    return (f"Data starts {gap} days after the window start. Normal if the "
            f"security began trading then; otherwise lower TIME_BATCH_DAYS.")


def download_all(cfg, windows, folders):
    """Download every company over every window.

    Returns (list of per-company tables, request log table).
    """
    frames, log_rows = [], []
    total = len(cfg.rics) * len(windows)
    sent = 0

    for company_number, ric in enumerate(cfg.rics, start=1):
        print(f"\n[{company_number}/{len(cfg.rics)}] {ric}   {cfg.names[ric]}")
        company_frames = []

        for window_number, (window_start, window_end) in enumerate(windows, start=1):
            sent += 1
            time_format = "%Y-%m-%dT%H:%M:%S" if cfg.is_intraday else "%Y-%m-%d"
            start_text = window_start.strftime(time_format)
            end_text = window_end.strftime(time_format)

            entry = dict.fromkeys(LOG_COLUMNS, None)
            entry.update({
                "RIC": ric,
                "Name": cfg.names[ric],
                "Window": f"{window_number} of {len(windows)}",
                "Request Start": window_start,
                "Request End": window_end,
                "Rows": 0,
                "Attempts": 0,
                "Note": "",
            })

            try:
                result, entry["Attempts"] = request_history(ric, start_text, end_text, cfg)
                frame = standardise_result(result, ric, cfg)

                if frame is None or frame.empty:
                    entry["Status"] = "Empty"
                    entry["Note"] = ("No observations in this window (before listing, "
                                     "after delisting, or beyond LSEG's history).")
                    outcome = "empty"
                else:
                    first = frame[cfg.date_col].min()
                    entry["Status"] = "OK"
                    entry["Rows"] = len(frame)
                    entry["First Observation"] = first
                    entry["Last Observation"] = frame[cfg.date_col].max()
                    entry["Note"] = coverage_note(first, window_start,
                                                  bool(company_frames), cfg)
                    company_frames.append(frame)
                    outcome = f"{len(frame):,} rows"
                    if entry["Note"].startswith("Possible truncation"):
                        outcome += "  (possible truncation - see Request_Log)"

            except Exception as error:
                entry["Status"] = "Failed"
                entry["Attempts"] = getattr(error, "attempts", entry["Attempts"] or 1)
                entry["Note"] = short_text(error, 250)
                outcome = f"FAILED: {short_text(error, 90)}"

            log_rows.append(entry)
            print(f"    window {window_number}/{len(windows)}  "
                  f"{fmt_date(window_start, cfg.is_intraday)} to "
                  f"{fmt_date(window_end, cfg.is_intraday)}   {outcome}")

            if sent < total:
                time.sleep(REQUEST_DELAY_SECONDS)

        if company_frames:
            company_data = pd.concat(company_frames, ignore_index=True)
            frames.append(company_data)
            if SAVE_CSV:
                company_data.to_csv(
                    os.path.join(folders.raw, f"{safe_filename(ric)}.csv"), index=False
                )
        else:
            print(f"    WARNING: no data obtained for {ric}.")

    request_log = pd.DataFrame(log_rows, columns=LOG_COLUMNS)
    for column in ("Request Start", "Request End", "First Observation", "Last Observation"):
        request_log[column] = pd.to_datetime(request_log[column])
    return frames, request_log


# ==============================================================================
# STEP 3 - CLEAN AND ORGANISE
# ==============================================================================

def clean_data(frames, cfg):
    """Combine companies, remove duplicates and empty rows, and sort."""
    data = pd.concat(frames, ignore_index=True)
    report = {"rows_downloaded": len(data)}

    before = len(data)
    data = data.dropna(subset=[cfg.date_col])
    report["invalid_dates"] = before - len(data)

    # One observation per company and date. Duplicates arise where
    # neighbouring request windows overlap; the later request is kept.
    before = len(data)
    data = data.drop_duplicates(subset=["RIC", cfg.date_col], keep="last")
    report["duplicates"] = before - len(data)

    # Rows in which every field is blank carry no information.
    value_columns = [c for c in data.columns if c not in ("RIC", cfg.date_col)]
    before = len(data)
    if value_columns:
        data = data.dropna(subset=value_columns, how="all")
    report["empty_rows"] = before - len(data)

    # Companies in the order they were listed, then chronological.
    order = {ric: position for position, ric in enumerate(cfg.rics)}
    data = (
        data.assign(_order=data["RIC"].map(order))
        .sort_values(["_order", cfg.date_col])
        .drop(columns="_order")
        .reset_index(drop=True)
    )
    report["rows_final"] = len(data)
    return data, report


def ordered_field_codes(data, cfg):
    """Returned field columns: requested order first, then any extras."""
    present = [c for c in data.columns if c not in ("RIC", cfg.date_col)]
    ordered = []
    for field in cfg.fields:
        code = find_code(field, present)
        if code and code not in ordered:
            ordered.append(code)
    return ordered + [c for c in present if c not in ordered]


def build_labels(codes, cfg):
    """Map field codes to readable, unique column names (TRDPRC_1 -> Close)."""
    reserved = {"RIC", "Name", cfg.date_col, cfg.return_col}
    labels = {}
    for code in codes:
        entry = FIELD_DICTIONARY.get(code.upper())
        label = entry[0] if entry else code
        if label in reserved or label in labels.values():
            label = f"{label} ({code})"
        labels[code] = label
    return labels


def field_format(code):
    entry = FIELD_DICTIONARY.get(code.upper())
    return entry[1] if entry else PRICE_FORMAT


def field_description(code):
    entry = FIELD_DICTIONARY.get(code.upper())
    return entry[2] if entry else "See the LSEG Data Item Browser for a definition."


def add_returns(data, cfg):
    """Add a return column, computed within each company."""
    if not cfg.return_col:
        return data
    price = pd.to_numeric(data[cfg.price_col], errors="coerce")
    price = price.where(price > 0)                     # log needs positive prices
    previous = price.groupby(data["RIC"]).shift(1)     # previous obs, same company
    with np.errstate(divide="ignore", invalid="ignore"):
        ratio = price / previous
        data[cfg.return_col] = np.log(ratio) if cfg.return_type == "log" else ratio - 1
    return data


def to_wide(data, value_column, cfg):
    """Long -> wide: one row per date, one column per company."""
    wide = data.pivot(index=cfg.date_col, columns="RIC", values=value_column)
    wide = wide.reindex(columns=[ric for ric in cfg.rics if ric in wide.columns])
    wide = wide.sort_index()
    wide.columns.name = None
    return wide.reset_index()


def build_company_table(data, request_log, cfg):
    counts = data.groupby("RIC").size()
    longest = int(counts.max()) if len(counts) else 0
    effective_end = min(cfg.end_date, pd.Timestamp.now().normalize())
    rows = []

    for ric in cfg.rics:
        subset = data[data["RIC"] == ric]
        log = request_log[request_log["RIC"] == ric]
        failed = int((log["Status"] == "Failed").sum())
        truncated = log["Note"].astype(str).str.startswith("Possible truncation").any()
        n = len(subset)
        first = subset[cfg.date_col].min() if n else pd.NaT
        last = subset[cfg.date_col].max() if n else pd.NaT

        if n == 0:
            status = ("NO DATA - requests failed (see Request_Log)" if failed
                      else "NO DATA - check the RIC, dates and fields")
        elif failed:
            status = "INCOMPLETE - some requests failed (see Request_Log)"
        elif truncated:
            status = "CHECK - possible truncation (see Request_Log)"
        else:
            remarks = []
            if (first.normalize() - cfg.start_date).days > cfg.gap_tolerance_days:
                remarks.append("starts later")
            if (effective_end - last.normalize()).days > cfg.gap_tolerance_days:
                remarks.append("ends earlier")
            status = "OK" + (f" - history {' and '.join(remarks)}" if remarks else "")

        row = {
            "RIC": ric,
            "Name": cfg.names[ric],
            "Status": status,
            "Observations": n,
            "Coverage vs Longest": n / longest if longest else np.nan,
            "First Observation": first,
            "Last Observation": last,
        }
        if cfg.price_col:
            prices = pd.to_numeric(subset[cfg.price_col], errors="coerce").dropna()
            first_price = prices.iloc[0] if len(prices) else np.nan
            last_price = prices.iloc[-1] if len(prices) else np.nan
            row[f"First {cfg.price_col}"] = first_price
            row[f"Last {cfg.price_col}"] = last_price
            row["Price Change"] = (last_price / first_price - 1
                                   if len(prices) and first_price > 0 else np.nan)
        row["Requests OK"] = int((log["Status"] == "OK").sum())
        row["Requests Empty"] = int((log["Status"] == "Empty").sum())
        row["Requests Failed"] = failed
        rows.append(row)

    return pd.DataFrame(rows)


def build_missing_table(data, cfg, value_columns):
    """Share of blank values for each company and field (0.05 = 5%)."""
    rows = []
    for ric in cfg.rics + [None]:
        subset = data if ric is None else data[data["RIC"] == ric]
        row = {
            "RIC": "ALL" if ric is None else ric,
            "Name": "All companies" if ric is None else cfg.names[ric],
            "Observations": len(subset),
        }
        for column in value_columns:
            row[column] = subset[column].isna().mean() if len(subset) else np.nan
        rows.append(row)
    return pd.DataFrame(rows)


def build_statistics(data, cfg, variables):
    """Descriptive statistics for every company and variable.

    Grouped by variable, so companies can be compared line by line.
    """
    columns = ["Variable", "RIC", "Name", "N", "Mean", "Std Dev", "Min", "25%",
               "Median", "75%", "Max", "Skewness", "Excess Kurtosis"]
    annualise = bool(cfg.return_col and cfg.periods_per_year)
    if annualise:
        columns += ["Annualised Mean", "Annualised Volatility"]

    rows = []
    for variable in variables:
        for ric in cfg.rics:
            values = pd.to_numeric(data.loc[data["RIC"] == ric, variable],
                                   errors="coerce").dropna()
            if values.empty:
                continue
            row = {
                "Variable": variable, "RIC": ric, "Name": cfg.names[ric],
                "N": len(values),
                "Mean": values.mean(),
                "Std Dev": values.std(),
                "Min": values.min(),
                "25%": values.quantile(0.25),
                "Median": values.median(),
                "75%": values.quantile(0.75),
                "Max": values.max(),
                "Skewness": values.skew(),
                "Excess Kurtosis": values.kurt(),
            }
            if annualise and variable == cfg.return_col:
                row["Annualised Mean"] = values.mean() * cfg.periods_per_year
                row["Annualised Volatility"] = values.std() * math.sqrt(cfg.periods_per_year)
            rows.append(row)

    return pd.DataFrame(rows, columns=columns)


# ==============================================================================
# STEP 4 - DESCRIBE THE WORKBOOK
# ==============================================================================

def unique_sheet_name(name, used):
    """Excel sheet names: max 31 characters, no []:*?/\\ and unique."""
    base = re.sub(r"[\[\]:*?/\\]", "_", str(name)).strip()[:31] or "Sheet"
    candidate, counter = base, 2
    while candidate.lower() in used:
        suffix = f" ({counter})"
        candidate = base[: 31 - len(suffix)] + suffix
        counter += 1
    used.add(candidate.lower())
    return candidate


def build_sheet_specs(cfg, data, tables):
    """List every sheet with its table, description and formatting."""
    used = {"readme"}
    specs = []

    def add(name, df, description, csv_name, tab, formats=None, freeze="B2", post=None):
        specs.append({
            "name": unique_sheet_name(name, used),
            "df": df,
            "description": description,
            "csv": csv_name,
            "tab": tab,
            "formats": formats or {},
            "freeze": freeze,
            "post": post,
        })

    label_formats = {cfg.labels[c]: field_format(c) for c in cfg.labels}
    if cfg.return_col:
        label_formats[cfg.return_col] = RETURN_FORMAT

    # Companies overview
    company_formats = {
        "Observations": COUNT_FORMAT,
        "Coverage vs Longest": PERCENT_FORMAT,
        "Price Change": PERCENT_FORMAT,
    }
    if cfg.price_col:
        company_formats[f"First {cfg.price_col}"] = label_formats[cfg.price_col]
        company_formats[f"Last {cfg.price_col}"] = label_formats[cfg.price_col]
    add("Companies", tables["companies"],
        "One row per company: download status, number of observations, coverage "
        "relative to the longest series, first and last dates, first and last "
        "price, price change over the sample, and request counts. Start here.",
        "companies.csv", TAB_COLOURS["Companies"], company_formats, freeze="C2")

    # One wide sheet per field
    for code, label in cfg.labels.items():
        wide = tables["wide"].get(label)
        if wide is None:
            continue
        add(label, wide,
            f"{label} ({code}) in wide layout: one row per "
            f"{'timestamp' if cfg.is_intraday else 'date'}, one column per company "
            f"(RIC). {field_description(code)}.",
            f"wide_{safe_filename(label).lower()}.csv", TAB_COLOURS["field"],
            {ric: field_format(code) for ric in wide.columns[1:]})

    # Returns
    if cfg.return_col and tables.get("returns") is not None:
        formula = ("ln(P_t / P_{t-1})" if cfg.return_type == "log"
                   else "P_t / P_{t-1} - 1")
        add("Returns", tables["returns"],
            f"{cfg.return_col}s = {formula}, computed from {cfg.price_col} "
            f"({RETURN_PRICE_FIELD}) within each company. Wide layout. "
            f"Values are decimals displayed as percentages.",
            "returns_wide.csv", TAB_COLOURS["Returns"],
            {ric: RETURN_FORMAT for ric in tables["returns"].columns[1:]})

    # Statistics
    add("Statistics", tables["statistics"],
        "Descriptive statistics for each variable and company (grouped by "
        "variable for easy comparison). Excess kurtosis = kurtosis - 3."
        + (f" Annualised figures use {cfg.periods_per_year} periods per year: "
           f"mean x {cfg.periods_per_year}, standard deviation x "
           f"sqrt({cfg.periods_per_year})." if cfg.return_col and cfg.periods_per_year
           else ""),
        "statistics.csv", TAB_COLOURS["Statistics"], {"N": COUNT_FORMAT},
        freeze="D2", post=format_statistics_rows)

    # Missing data
    add("Missing_Data", tables["missing"],
        "Share of blank values for each company (rows) and field (columns), on "
        "dates where the company has at least one value. The last row pools all "
        "companies. Dates with no trading at all are not counted as missing.",
        "missing_data.csv", TAB_COLOURS["Missing_Data"],
        {"Observations": COUNT_FORMAT,
         **{label: PERCENT_FORMAT for label in cfg.labels.values()}},
        freeze="C2")

    # Long data
    add("Data_Long", data,
        "All data in long (tidy) layout: one row per company and "
        f"{'timestamp' if cfg.is_intraday else 'date'}. Best format for R, "
        "Stata, pandas, regressions and pivot tables. Use the filter arrows "
        "in the header row to select companies or dates.",
        "data_long.csv", TAB_COLOURS["Data_Long"], label_formats, freeze="D2")

    # Request log
    add("Request_Log", tables["request_log"],
        "Every request sent to LSEG: company, date window, status (OK, Empty, "
        "Failed), rows received, attempts and notes. Check here if a company "
        "has missing or incomplete data.",
        "request_log.csv", TAB_COLOURS["Request_Log"],
        {"Rows": COUNT_FORMAT}, freeze="C2")

    return specs


def build_readme(cfg, data, report, request_log, specs, notes, windows):
    """Sections of the README sheet as (title, [(label, text), ...])."""
    status = request_log["Status"].value_counts()
    observed = data[cfg.date_col]
    intraday = cfg.is_intraday

    run_information = [
        ("Extracted on", pd.Timestamp.now().strftime("%Y-%m-%d %H:%M")),
        ("Script", f"{script_name()} (version {SCRIPT_VERSION})"),
        ("Data source", "LSEG Workspace, via the lseg.data Python library (get_history)"),
        ("Companies requested", len(cfg.rics)),
        ("Companies with data", int(data["RIC"].nunique())),
        ("Frequency", f'{cfg.interval["label"]}   (INTERVAL = "{cfg.interval_setting}")'),
        ("Requested period",
         f"{fmt_date(cfg.start_date)} to {fmt_date(cfg.end_date)}   "
         f'(START_DATE = "{cfg.start_setting}", END_DATE = "{cfg.end_setting}")'),
        ("Observed period",
         f"{fmt_date(observed.min(), intraday)} to {fmt_date(observed.max(), intraday)}"),
        ("Fields requested", ", ".join(cfg.fields) or "LSEG default field set"),
        ("Price adjustments",
         cfg.adjustments or "LSEG default (adjusted for splits and capital changes)"),
        ("Returns",
         f"{cfg.return_col}s from {cfg.price_col}" if cfg.return_col else "Not computed"),
        ("Time stamps", "UTC" if intraday else "Trading dates (no time of day)"),
        ("Request windows",
         f"{len(windows)} per company, up to {cfg.batch_days:,} calendar days each"),
        ("Requests",
         f"{int(status.get('OK', 0))} OK, {int(status.get('Empty', 0))} empty, "
         f"{int(status.get('Failed', 0))} failed"),
        ("Rows downloaded", f"{report['rows_downloaded']:,}"),
        ("Duplicates removed",
         f"{report['duplicates']:,}   (from overlapping request windows)"),
        ("Empty rows removed",
         f"{report['empty_rows']:,}   (dates on which every field was blank)"),
        ("Rows in final dataset", f"{report['rows_final']:,}"),
    ]

    sheet_guide = [("README", "This page: settings of this run and a guide to the workbook.")]
    sheet_guide += [(spec["name"], spec["description"]) for spec in specs]

    variables = [("RIC", "Refinitiv Instrument Code identifying the company."),
                 ("Name", "Company label from the settings, or the name fetched from LSEG."),
                 (cfg.date_col, "Observation time stamp (UTC)." if intraday
                  else "Trading date of the observation.")]
    variables += [(label, f"{code}: {field_description(code)}")
                  for code, label in cfg.labels.items()]
    if cfg.return_col:
        formula = ("ln(P_t / P_{t-1})" if cfg.return_type == "log" else "P_t / P_{t-1} - 1")
        variables.append((cfg.return_col,
                          f"{formula}, where P is {cfg.price_col}. Price return: "
                          f"dividends are not included."))

    general_notes = [
        "Blank cells in the wide sheets mean the company has no observation at "
        "that time (for example, exchange holidays differ across markets). They "
        "are deliberately not filled in.",
        "Returns use each company's own consecutive observations. The first "
        "observation of each company has no return, and a missing price makes "
        "both neighbouring returns missing.",
        "Every data sheet is a plain table starting in cell A1, so it can be read "
        "directly: R readxl::read_excel(path, sheet = \"Data_Long\"), Stata "
        "import excel, or pandas pd.read_excel(path, sheet_name=\"Data_Long\").",
    ]
    if SAVE_CSV:
        general_notes.append(
            "CSV copies of every table are in the csv folder next to this workbook; "
            "csv/by_company holds the raw download with LSEG field codes.")
    if intraday:
        general_notes.append("Time stamps are in UTC, not local exchange time.")
        general_notes.append(
            "This is the high-frequency workbook. HFD uses minute bars and "
            "LSEG may impose a shorter historical availability window than for "
            "daily data. Empty/failed windows are recorded in Request_Log."
        )
    all_notes = [(f"Note {i}", text) for i, text in enumerate(notes + general_notes, 1)]

    how_to_change = [
        ("Companies", "Edit INSTRUMENTS in section 1 of the script (RIC on the left, "
                      "label on the right), or point INSTRUMENTS_FILE to a CSV/Excel list."),
        ("Dates", 'Edit LFD_START_DATE/LFD_END_DATE and HFD_START_DATE/HFD_END_DATE '
                  'in section 3. LFD inherits the main period; HFD defaults to the most '
                  'recent 30 calendar days ("30D") to keep minute data manageable.'),
        ("Frequency", 'Edit LFD_INTERVAL and HFD_INTERVAL in section 3. LFD defaults '
                      'to "daily" and HFD defaults to "1min".'),
        ("Variables", "Edit FIELDS in section 4 (e.g. add BID and ASK)."),
        ("Returns", 'Edit section 5: RETURN_TYPE = "log" or "simple".'),
    ]

    return [
        ("RUN INFORMATION", run_information),
        ("SHEETS IN THIS WORKBOOK", sheet_guide),
        ("VARIABLES", variables),
        ("NOTES", all_notes),
        ("HOW TO CHANGE COMPANIES, DATES OR FREQUENCY", how_to_change),
    ]


# ==============================================================================
# STEP 5 - WRITE THE EXCEL WORKBOOK AND CSV FILES
# ==============================================================================

def column_width(series, header, intraday):
    if pd.api.types.is_datetime64_any_dtype(series):
        return 18 if intraday else 12
    header_width = min(len(str(header)) + 3, 24)
    sample = series.dropna().head(300)
    if pd.api.types.is_numeric_dtype(series) and not pd.api.types.is_bool_dtype(series):
        largest = float(sample.abs().max()) if len(sample) else 0.0
        value_width = min(18, len(f"{largest:,.2f}") + 3)
    else:
        value_width = max((len(str(value)) for value in sample), default=6) + 2
    return max(9, min(60, max(header_width, value_width)))


def style_table(ws, df, spec, cfg):
    """Header style, frozen panes, filters, column widths and number formats."""
    n_rows, n_cols = len(df), len(df.columns)

    for column in range(1, n_cols + 1):
        cell = ws.cell(row=1, column=column)
        cell.font = HEADER_FONT
        cell.fill = HEADER_FILL
        cell.alignment = HEADER_ALIGNMENT
        cell.border = HEADER_BORDER
    ws.row_dimensions[1].height = 32

    if spec["freeze"]:
        ws.freeze_panes = spec["freeze"]
    if n_rows and n_cols:
        ws.auto_filter.ref = f"A1:{get_column_letter(n_cols)}{n_rows + 1}"

    for index, column in enumerate(df.columns, start=1):
        ws.column_dimensions[get_column_letter(index)].width = column_width(
            df[column], column, cfg.is_intraday)

    # Date columns get an explicit format (pandas' own setting is not
    # applied reliably by every pandas version).
    formats = dict(spec["formats"])
    for column in df.columns:
        if pd.api.types.is_datetime64_any_dtype(df[column]):
            formats.setdefault(column, "yyyy-mm-dd hh:mm" if cfg.is_intraday
                               else "yyyy-mm-dd")

    if n_rows * n_cols <= FORMAT_CELL_LIMIT:
        for index, column in enumerate(df.columns, start=1):
            number_format = formats.get(column)
            if not number_format:
                continue
            for (cell,) in ws.iter_rows(min_row=2, max_row=n_rows + 1,
                                        min_col=index, max_col=index):
                cell.number_format = number_format

    if spec["post"] and n_rows * n_cols <= FORMAT_CELL_LIMIT:
        spec["post"](ws, df, cfg)

    ws.sheet_properties.tabColor = spec["tab"]


def format_statistics_rows(ws, df, cfg):
    """Returns are small numbers, so their rows get more decimals."""
    position = {column: i for i, column in enumerate(df.columns, start=1)}
    for row_number, variable in enumerate(df["Variable"], start=2):
        is_return = variable == cfg.return_col
        for column in df.columns[4:]:
            if column.startswith("Annualised"):
                number_format = PERCENT_FORMAT
            elif column in ("Skewness", "Excess Kurtosis"):
                number_format = "0.0000"
            else:
                number_format = SMALL_STAT_FORMAT if is_return else STAT_FORMAT
            ws.cell(row=row_number, column=position[column]).number_format = number_format


def write_readme_sheet(ws, sections, cfg):
    ws["A1"] = "LSEG Workspace Data Extraction"
    ws["A1"].font = Font(bold=True, size=16, color=NAVY)
    ws["A2"] = (f"{len(cfg.rics)} companies  |  {cfg.interval['label']}  |  "
                f"{fmt_date(cfg.start_date)} to {fmt_date(cfg.end_date)}")
    ws["A2"].font = Font(italic=True, color="595959")

    row = 4
    for title, items in sections:
        for column in (1, 2):
            cell = ws.cell(row=row, column=column)
            cell.fill = HEADER_FILL
            cell.font = HEADER_FONT
        ws.cell(row=row, column=1, value=title)
        row += 1
        for label, text in items:
            left = ws.cell(row=row, column=1, value=label)
            left.font = Font(bold=True)
            left.alignment = Alignment(vertical="top", wrap_text=True)
            right = ws.cell(row=row, column=2, value=text)
            right.alignment = Alignment(vertical="top", wrap_text=True, horizontal="left")
            row += 1
        row += 1

    ws.column_dimensions["A"].width = 26
    ws.column_dimensions["B"].width = 115
    ws.sheet_view.showGridLines = False
    ws.sheet_properties.tabColor = TAB_COLOURS["README"]


def write_workbook(path, cfg, specs, readme_sections):
    with pd.ExcelWriter(path, engine="openpyxl") as writer:
        book = writer.book
        write_readme_sheet(book.create_sheet("README"), readme_sections, cfg)

        for spec in specs:
            df = spec["df"]
            if spec.get("too_large"):
                pd.DataFrame({"Note": [
                    f"This table has {len(df):,} rows, more than Excel allows. "
                    f"The complete table is in csv/{spec['csv']}."
                ]}).to_excel(writer, sheet_name=spec["name"], index=False)
                book[spec["name"]].column_dimensions["A"].width = 100
                book[spec["name"]].sheet_properties.tabColor = spec["tab"]
                continue
            df.to_excel(writer, sheet_name=spec["name"], index=False)
            style_table(book[spec["name"]], df, spec, cfg)

        # Open on the README sheet.
        for ws in book.worksheets:
            ws.sheet_view.tabSelected = ws.title == "README"
        book.active = 0


def save_workbook(path, cfg, specs, readme_sections):
    """Write the workbook; if the file is open in Excel, save under a new name."""
    try:
        write_workbook(path, cfg, specs, readme_sections)
        return path
    except PermissionError:
        alternative = path.replace(".xlsx", f"_{pd.Timestamp.now():%H%M%S}.xlsx")
        print(f"\nCould not overwrite {os.path.basename(path)} "
              f"(is it open in Excel?). Saving as {os.path.basename(alternative)}.")
        write_workbook(alternative, cfg, specs, readme_sections)
        return alternative


def prepare_output_folders(cfg, run_folder=None):
    """Prepare the shared run folder and a frequency-specific CSV folder."""
    base = (OUTPUT_FOLDER if os.path.isabs(OUTPUT_FOLDER)
            else os.path.join(cfg.script_folder, OUTPUT_FOLDER))

    if run_folder is None:
        run = (os.path.join(base, f"{pd.Timestamp.now():%Y-%m-%d_%H%M%S}_dual_frequency")
               if TIMESTAMPED_RUN_FOLDER else base)
    else:
        run = run_folder

    frequency_tag = "HFD" if cfg.is_intraday else "LFD"
    csv_folder = os.path.join(run, f"csv_{frequency_tag}")
    raw_folder = os.path.join(csv_folder, "by_company")

    folders = SimpleNamespace(run=run, csv=csv_folder, raw=raw_folder)
    os.makedirs(folders.run, exist_ok=True)
    if SAVE_CSV:
        os.makedirs(folders.raw, exist_ok=True)
    return folders


def connect():
    banner("CONNECTING TO LSEG WORKSPACE")
    print("LSEG Workspace must be open and you must be logged in.")
    try:
        ld.open_session()
    except Exception as error:
        raise ExtractionError(
            f"Could not connect to LSEG Workspace:\n    {short_text(error, 400)}\n\n"
            f"Check that Workspace is running and logged in, then try again."
        ) from error
    print("Connected.")


def disconnect():
    try:
        ld.close_session()
        print("\nLSEG session closed.")
    except Exception as error:
        print(f"\nWarning: the LSEG session did not close cleanly ({short_text(error)}).")


# ==============================================================================
# MAIN
# ==============================================================================

def run_frequency(cfg, frequency_tag, folders):
    """Run the original extraction pipeline once for one frequency."""
    windows = create_time_windows(cfg.start_date, cfg.request_end, cfg.batch_days)
    print_settings(cfg, windows)

    # ---- Download ------------------------------------------------------------
    fetch_company_names(cfg)
    banner(f"DOWNLOADING {frequency_tag} DATA")
    frames, request_log = download_all(cfg, windows, folders)

    if not frames:
        log_path = os.path.join(folders.run, f"{frequency_tag}_request_log.csv")
        request_log.to_csv(log_path, index=False)
        print("\n" + request_log[["RIC", "Window", "Status", "Note"]].to_string(index=False))
        raise ExtractionError(
            f"No {frequency_tag} data was downloaded for any company.\n"
            f"The reasons for each request are in:\n    {log_path}"
        )

    # ---- Clean and organise -------------------------------------------------
    banner(f"CLEANING AND ORGANISING {frequency_tag} DATA")
    data, report = clean_data(frames, cfg)
    notes = []

    codes = ordered_field_codes(data, cfg)
    not_returned = [f for f in cfg.fields if find_code(f, codes) is None]
    if not_returned:
        notes.append(f"Requested but not returned by LSEG for any company: "
                     f"{', '.join(not_returned)}.")

    cfg.labels = build_labels(codes, cfg)
    data = data.rename(columns=cfg.labels)
    data.insert(1, "Name", data["RIC"].map(cfg.names))
    field_columns = list(cfg.labels.values())

    price_code = find_code(RETURN_PRICE_FIELD, codes)
    cfg.price_col = cfg.labels[price_code] if price_code else None
    if cfg.return_col and cfg.price_col is None:
        notes.append(f"Returns were not computed: {RETURN_PRICE_FIELD} was not "
                     f"returned. Set RETURN_PRICE_FIELD to an available price "
                     f"field (e.g. MID_PRICE for exchange rates).")
        cfg.return_col = None
    data = add_returns(data, cfg)

    print(f"Rows downloaded       : {report['rows_downloaded']:,}")
    print(f"Duplicates removed    : {report['duplicates']:,}")
    print(f"Empty rows removed    : {report['empty_rows']:,}")
    print(f"Rows in final dataset : {report['rows_final']:,}")

    # ---- Build tables -------------------------------------------------------
    tables = {"wide": {}}
    empty_fields = []
    for label in field_columns:
        if data[label].notna().any():
            tables["wide"][label] = to_wide(data, label, cfg)
        else:
            empty_fields.append(label)
    if empty_fields:
        notes.append(f"No values for any company, so no sheet was created: "
                     f"{', '.join(empty_fields)}.")

    tables["returns"] = to_wide(data, cfg.return_col, cfg) if cfg.return_col else None
    tables["companies"] = build_company_table(data, request_log, cfg)
    tables["missing"] = build_missing_table(data, cfg, field_columns)
    numeric_columns = [c for c in field_columns
                       if pd.api.types.is_numeric_dtype(data[c]) and c not in empty_fields]
    variables = ([cfg.return_col] if cfg.return_col else []) + numeric_columns
    tables["statistics"] = build_statistics(data, cfg, variables)
    tables["request_log"] = request_log

    specs = build_sheet_specs(cfg, data, tables)
    for spec in specs:
        if len(spec["df"]) >= EXCEL_MAX_ROWS:
            spec["too_large"] = True
            notes.append(f"Sheet {spec['name']} has {len(spec['df']):,} rows, more "
                         f"than Excel allows; the full table is in csv/{spec['csv']}.")

    readme = build_readme(cfg, data, report, request_log, specs, notes, windows)

    # ---- Save ---------------------------------------------------------------
    banner(f"SAVING {frequency_tag}")
    for spec in specs:
        if SAVE_CSV or spec.get("too_large"):
            os.makedirs(folders.csv, exist_ok=True)
            spec["df"].to_csv(os.path.join(folders.csv, spec["csv"]), index=False)

    if SAVE_CSV:
        print(f"{frequency_tag} CSV files : {folders.csv}")

    # User-requested filename:
    #     LSEG_LFD_YYYY-MM-DD.xlsx
    #     LSEG_HFD_YYYY-MM-DD.xlsx
    output_date = (OUTPUT_DATE if OUTPUT_DATE
                   else pd.Timestamp.now().strftime("%Y-%m-%d"))
    workbook_name = f"LSEG_{frequency_tag}_{output_date}.xlsx"

    print("Writing Excel workbook ...")
    workbook_path = save_workbook(os.path.join(folders.run, workbook_name),
                                  cfg, specs, readme)
    print(f"{frequency_tag} Excel file : {workbook_path}")

    # ---- Summary ------------------------------------------------------------
    banner(f"{frequency_tag} SUMMARY")
    overview = tables["companies"][["RIC", "Name", "Status", "Observations",
                                     "First Observation", "Last Observation"]].copy()
    for column in ("First Observation", "Last Observation"):
        overview[column] = overview[column].map(lambda v: fmt_date(v, cfg.is_intraday))
    print(overview.to_string(index=False))

    for note in notes:
        print(f"\nNote: {note}")

    return workbook_path


def main():
    banner(f"LSEG WORKSPACE DATA EXTRACTION TOOL  (version {SCRIPT_VERSION})")
    print("This run produces TWO workbooks: Low Frequency (daily) and "
          "High Frequency (1-minute).")

    # ---- 1. Shared settings -------------------------------------------------
    # Resolve the instruments once so the same company list is used for both
    # workbooks. The original settings/validation functions are then reused.
    shared_cfg = resolve_settings(
        interval_value=LFD_INTERVAL,
        start_value=LFD_START_DATE,
        end_value=LFD_END_DATE,
        batch_days_value=LFD_TIME_BATCH_DAYS,
    )
    hfd_cfg = resolve_settings(
        interval_value=HFD_INTERVAL,
        start_value=HFD_START_DATE,
        end_value=HFD_END_DATE,
        batch_days_value=HFD_TIME_BATCH_DAYS,
    )

    print("\n" + "=" * 80)
    print("DUAL-FREQUENCY REQUEST PLAN")
    print("=" * 80)
    print(f"LFD: {shared_cfg.interval['label']} | "
          f"{fmt_date(shared_cfg.start_date)} to {fmt_date(shared_cfg.end_date)}")
    print(f"HFD: {hfd_cfg.interval['label']} | "
          f"{fmt_date(hfd_cfg.start_date)} to {fmt_date(hfd_cfg.end_date)}")
    print(f"Companies: {len(shared_cfg.rics)}")
    print(f"Output names: LSEG_LFD_{OUTPUT_DATE or pd.Timestamp.now():%Y-%m-%d}.xlsx "
          f"and LSEG_HFD_{OUTPUT_DATE or pd.Timestamp.now():%Y-%m-%d}.xlsx")

    if PREVIEW_ONLY:
        banner("PREVIEW ONLY")
        print("The settings are valid. Nothing was downloaded.")
        print("Set PREVIEW_ONLY = False to run both extractions.")
        return

    if ld is None:
        raise SettingsError("The lseg-data library is not installed.\n"
                            "Install it with:  pip install lseg-data")

    # One shared output folder keeps the two workbooks together while each
    # workbook retains the original visual/layout structure.
    base = (OUTPUT_FOLDER if os.path.isabs(OUTPUT_FOLDER)
            else os.path.join(shared_cfg.script_folder, OUTPUT_FOLDER))
    if TIMESTAMPED_RUN_FOLDER:
        run_folder = os.path.join(
            base, f"{pd.Timestamp.now():%Y-%m-%d_%H%M%S}_dual_frequency"
        )
    else:
        run_folder = base
    os.makedirs(run_folder, exist_ok=True)

    # ---- 2. Connect once ----------------------------------------------------
    connect()
    try:
        # Fetch names once and copy them into both configurations.
        fetch_company_names(shared_cfg)
        hfd_cfg.names = shared_cfg.names.copy()
        hfd_cfg.instruments = shared_cfg.instruments.copy()

        # ---- 3. LFD ----------------------------------------------------------
        lfd_folders = prepare_output_folders(shared_cfg, run_folder=run_folder)
        run_frequency(shared_cfg, "LFD", lfd_folders)

        # ---- 4. HFD ----------------------------------------------------------
        hfd_folders = prepare_output_folders(hfd_cfg, run_folder=run_folder)
        run_frequency(hfd_cfg, "HFD", hfd_folders)

    finally:
        disconnect()

    banner("COMPLETE")
    print(f"Results folder: {run_folder}")
    print("Created:")
    output_date = OUTPUT_DATE or pd.Timestamp.now().strftime("%Y-%m-%d")
    print(f"  LSEG_LFD_{output_date}.xlsx")
    print(f"  LSEG_HFD_{output_date}.xlsx")


if __name__ == "__main__":
    try:
        main()
    except SettingsError as error:
        banner("SETTINGS ERROR")
        print(error)
        print("\nCorrect the USER SETTINGS at the top of this script and run it again.")
        sys.exit(1)
    except ExtractionError as error:
        banner("EXTRACTION STOPPED")
        print(error)
        sys.exit(1)