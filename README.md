# nfldoinkeR-data

Release data for [Off the Upright](https://offtheupright.com): NFL kicks that hit an upright or the crossbar ("doinks"), with the kickers and teams tables they reference. This repository holds only the build code. The data lives in [Releases](https://github.com/ke1v3y/nfldoinkeR-data/releases).

The R package [nfldoinkeR](https://github.com/ke1v3y/nfldoinkeR) reads these releases. You can also read the files directly.

## Scope

Regular-season and postseason games only, with doinks from 1974 on. Preseason and the Hall of Fame Game records are excluded. Off the Upright is a living project with an active effort to record every doink in NFL history; coverage is complete from 1996 onward with some high profile games extending back to the first game played with the goalposts at the back of the endzone. Video links and notes are not included. The Off the Upright API at [offtheupright.com/developers](https://offtheupright.com/developers) remains the source for live data and preseason doinks.

## Files

Every release carries the same ten assets.

| Table | Files | One row per |
| --- | --- | --- |
| doinks | `doinks.rds`, `doinks.parquet`, `doinks.csv.gz` | doink in an official game (regular season and playoffs; preseason and Hall of Fame games excluded) |
| kickers | `kickers.rds`, `kickers.parquet`, `kickers.csv.gz` | kicker |
| teams | `teams.rds`, `teams.parquet`, `teams.csv.gz` | team abbreviation per era (`first_year` to `last_year`) |

`manifest.json` records the build time, the source `data_version`, `format_revision` and `terms_version`, the season range, row counts, each file's size and sha256, and the pipeline commit and run that built it.

Columns are those served by the Off the Upright API at build time; the API's [OpenAPI document](https://offtheupright.com/developers/openapi.json) describes them, and `format_revision` in the manifest says which revision a release carries. `doinks.kicker_id` joins to `kickers.kicker_id`. Some abbreviations name different teams in different eras (`STL` is the Cardinals to 1987 and the Rams from 1995), so join `doinks.kicking_team` to `teams.abbreviation` with `season` between `first_year` and `last_year`; an empty `last_year` means the team is current.

`nflverse_game_id` joins to `nflreadr::load_schedules()` and `kickers.gsis_id` to `nflreadr::load_players()`. Every non-empty id is checked against nflverse before a release is published. nflverse has no schedule rows before 1999, so `nflverse_game_id` is empty for every earlier game.

Coverage: all completed regular-season and postseason games from 1999 on are matched to an `nflverse_game_id`; tentative date games do not carry an id yet.

## Two kinds of release

- **`latest`** is replaced on every build that changes the data. Use it for current data.
- **`vYYYY.MM.DD`** is a dated release, created once and never changed. Cite one of these. A second release on the same UTC date is `vYYYY.MM.DD.2`, then `.3`.

```r
# current data
doinks <- nflreadr::load_from_url(
  "https://github.com/ke1v3y/nfldoinkeR-data/releases/download/latest/doinks.rds",
  nflverse = TRUE
)
```

Builds run on Tuesdays from August through February and on the 1st of the month from March through July. Builds without data changes don't get published.

## Licence and attribution

The released data is licensed [CC-BY-4.0](LICENSE). Attribute it as:

> Off the Upright, offtheupright.com

To cite a specific release:

> Off the Upright. NFL doink data, release vYYYY.MM.DD. https://github.com/ke1v3y/nfldoinkeR-data/releases/tag/vYYYY.MM.DD. Licensed CC-BY-4.0.
