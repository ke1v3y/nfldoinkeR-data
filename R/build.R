#!/usr/bin/env Rscript
# nfldoinkeR-data: pull OTU's exports, type them, verify against nflverse,
# write release assets and a manifest. Exits 0 with release_needed=false
# when nothing changed; any verification failure stops the run before
# anything is written, so the previous release stands.

suppressPackageStartupMessages({
  library(httr2); library(readr); library(arrow)
  library(jsonlite); library(nflreadr); library(digest)
})

base  <- Sys.getenv("OTU_BASE_URL", "https://offtheupright.com")
key   <- Sys.getenv("OTU_API_KEY")
force <- identical(Sys.getenv("FORCE_RELEASE"), "true")
ua    <- sprintf("nfldoinkeR-data/%s (+https://github.com/%s)",
                 Sys.getenv("GITHUB_RUN_ID", "local"),
                 Sys.getenv("GITHUB_REPOSITORY", "local/nfldoinkeR-data"))
if (!nzchar(key)) stop("OTU_API_KEY is not set")

notice  <- function(...) cat("::notice::", sprintf(...), "\n", sep = "")
warning_line <- function(...) cat("::warning::", sprintf(...), "\n", sep = "")

# 401 and other 4xx throw at once (httr2 default); only 429/5xx are retried.
otu_get <- function(path) {
  request(paste0(base, path)) |>
    req_user_agent(ua) |>
    req_headers(Authorization = paste("Bearer", key)) |>
    req_retry(max_tries = 3, backoff = function(i) 10,
              is_transient = function(r) resp_status(r) %in% c(429L, 500L, 502L, 503L, 504L)) |>
    req_perform()
}

# ---- status and change detection -------------------------------------
status          <- otu_get("/api/v1/status") |> resp_body_json()
data_version    <- as.character(status$data_version)
format_revision <- as.integer(status$format_revision)
terms_version   <- as.integer(status$terms_version)

prev <- tryCatch(fromJSON("prev/manifest.json"), error = function(e) NULL)
if (!force && !is.null(prev) &&
    identical(as.character(prev$data_version), data_version) &&
    identical(as.integer(prev$format_revision), format_revision)) {
  notice("data_version %s and format_revision %d unchanged; no release", data_version, format_revision)
  writeLines("false", "release_needed")
  quit(save = "no", status = 0)
}

# ---- pull ------------------------------------------------------------
read_otu_csv <- function(path) {
  txt <- otu_get(path) |> resp_body_string()
  read_csv(I(txt), col_types = cols(.default = col_character()),
           na = c(""), show_col_types = FALSE)
}
doinks  <- read_otu_csv("/api/v1/export")
kickers <- read_otu_csv("/export/v1/kickers.csv")
teams   <- read_otu_csv("/export/v1/teams.csv")

# ---- type ------------------------------------------------------------
type_cols <- function(df, ints = character(), dates = character(), lgls = character()) {
  for (c in intersect(ints,  names(df))) df[[c]] <- as.integer(df[[c]])
  for (c in intersect(dates, names(df))) df[[c]] <- as.Date(df[[c]])
  for (c in intersect(lgls,  names(df))) df[[c]] <- df[[c]] %in% c("1", "true", "TRUE")
  df
}
doinks  <- type_cols(doinks,
                     ints  = c("doink_id", "season", "distance", "away_score", "home_score", "kicker_id"),
                     dates = "game_date",
                     lgls  = "is_official")
kickers <- type_cols(kickers, ints = "kicker_id", lgls = "is_position_kicker")
teams   <- type_cols(teams,   ints = c("franchise_id", "first_year", "last_year"))

# ---- scope -----------------------------------------------------------
# The scope assertion is an allowlist of official week labels, not a list of
# preseason labels: the stored preseason spellings are not visible from here,
# and a denylist with the wrong spellings could never fail. An unknown label
# stops the run and is named, so a new official label shows up loudly too.
official_weeks <- c(as.character(1:18), "Wild Card", "Divisional", "Conference", "Super Bowl")
if ("is_official" %in% names(doinks)) {
  dropped <- sum(!doinks$is_official)
  if (dropped > 0) notice("dropped %d non-official doinks (weeks: %s)", dropped,
                          paste(sort(unique(doinks$week[!doinks$is_official])), collapse = ", "))
  doinks <- doinks[doinks$is_official, ]
}
bad_weeks <- setdiff(unique(doinks$week), official_weeks)
if (length(bad_weeks)) stop("non-official week labels after the official filter: ", paste(bad_weeks, collapse = ", "))
doinks <- doinks[order(doinks$game_date, doinks$doink_id), ]

# ---- referential checks ---------------------------------------------
missing_kickers <- setdiff(unique(doinks$kicker_id), kickers$kicker_id)
if (length(missing_kickers)) stop("kicker_id not in kickers: ", paste(missing_kickers, collapse = ", "))
missing_teams <- setdiff(unique(doinks$kicking_team), teams$abbreviation)
if (length(missing_teams)) stop("kicking_team not in teams: ", paste(missing_teams, collapse = ", "))

# ---- tripwire against nflverse --------------------------------------
sched   <- nflreadr::load_schedules()
keyed   <- doinks$nflverse_game_id[!is.na(doinks$nflverse_game_id)]
absent  <- setdiff(unique(keyed), sched$game_id)
if (length(absent)) stop("nflverse_game_id absent from load_schedules(): ", paste(head(absent, 20), collapse = ", "))
unkeyed_modern <- sum(is.na(doinks$nflverse_game_id) & doinks$season >= 1999)
if (unkeyed_modern > 0) warning_line("%d doinks from 1999 on have no nflverse_game_id", unkeyed_modern)

players  <- nflreadr::load_players()
bad_gsis <- setdiff(unique(na.omit(kickers$gsis_id)), players$gsis_id)
if (length(bad_gsis)) stop("gsis_id absent from load_players(): ", paste(bad_gsis, collapse = ", "))

# ---- write -----------------------------------------------------------
dir.create("out", showWarnings = FALSE)
stamp <- Sys.time(); attr(stamp, "tzone") <- "UTC"
write_set <- function(df, name) {
  plain <- as.data.frame(df)
  attr(df, "nflverse_timestamp") <- stamp
  attr(df, "nflverse_type")      <- paste0(name, " via nfldoinkeR-data")
  class(df) <- c("nflverse_data", "tbl_df", "tbl", "data.frame")
  saveRDS(df, file.path("out", paste0(name, ".rds")))
  arrow::write_parquet(plain, file.path("out", paste0(name, ".parquet")))
  readr::write_csv(plain, file.path("out", paste0(name, ".csv.gz")), na = "")
  nrow(df)
}
rows <- list(doinks  = write_set(doinks,  "doinks"),
             kickers = write_set(kickers, "kickers"),
             teams   = write_set(teams,   "teams"))

files <- list.files("out", full.names = TRUE)
manifest <- list(
  built_at        = format(stamp, "%Y-%m-%dT%H:%M:%SZ"),
  data_version    = data_version,
  format_revision = format_revision,
  terms_version   = terms_version,
  source = list(doinks  = paste0(base, "/api/v1/export"),
                kickers = paste0(base, "/export/v1/kickers.csv"),
                teams   = paste0(base, "/export/v1/teams.csv")),
  seasons = list(min = min(doinks$season), max = max(doinks$season)),
  nflverse_join = list(joinable_from = 1999L,
                       doinks_keyed = sum(!is.na(doinks$nflverse_game_id)),
                       doinks_unkeyed_1999_on = unkeyed_modern),
  rows  = rows,
  files = lapply(setNames(files, basename(files)), function(f)
            list(bytes = file.size(f), sha256 = digest(f, algo = "sha256", file = TRUE))),
  pipeline = list(repo = Sys.getenv("GITHUB_REPOSITORY"), commit = Sys.getenv("GITHUB_SHA"),
                  run_id = Sys.getenv("GITHUB_RUN_ID")),
  license = "CC-BY-4.0",
  attribution = "Off the Upright, https://offtheupright.com"
)
write_json(manifest, "out/manifest.json", auto_unbox = TRUE, pretty = TRUE)
notice("built %d doinks, %d kickers, %d teams at data_version %s", rows$doinks, rows$kickers, rows$teams, data_version)
writeLines("true", "release_needed")
