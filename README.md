# linear-sidebar

A Linear issue and project browser for the [Noctalia](https://github.com/noctalia-dev/noctalia-shell)
bar — a bar widget that opens a searchable panel over your local rofi Linear
SQLite cache. No network calls in the hot path: search and detail both read the
cache, and syncing is an explicit action.

- Debounced search across issue numbers, titles, projects and statuses
- View filter: **All** / **My Issues** / **Projects**
- Status filter: **All**, **Urgent**, **High**, **Todo**, **In Progress**, **In Review**, **Backlog**
- Filters intersect: *My Issues* + *Urgent* + free text narrows on all three at once
- Linear's own priority and state colors on every row — Urgent is red, High orange
- Detail pane with a markdown-flattened description, **Open in Linear** and **Copy link**
- Full keyboard navigation over the result list
- Manual sync (right click the bar widget) and periodic auto-refresh

## Requirements

### Noctalia v5 or newer

This is a **v5 Luau plugin** (`plugin_api = 13`). Noctalia v4 used a completely
different, incompatible QML plugin system — a v4 install will not load this
plugin, and there is no compatibility shim. Check with:

```sh
noctalia --version
```

### The rofi Linear cache helper

The plugin does not talk to the Linear API itself. It shells out to the
`linear-cache.py` helper from the rofi Linear setup, which maintains a local
SQLite cache:

| purpose | command |
| --- | --- |
| list | `python3 <helper> json <query> <limit>` → `{"issues": [...], "projects": [...]}` |
| detail | env sourced, then `python3 <helper> detail <kind> <id>` → JSON object |
| sync | env sourced, then `python3 <helper> sync` |

Defaults:

- helper: `~/.config/rofi/scripts/linear-cache.py`
- env file: `~/.config/rofi/linear.env` (holds `LINEAR_API_KEY`)

Both are configurable (see [Settings](#settings)). Every invocation runs through
`bash -lc`, so the detail and sync calls can `set -a; . <env file>` first, and
the list call survives an empty query argument.

`python3` and `bash` must be on `PATH` — they are declared as plugin
dependencies.

## Install

Clone the repo and symlink it into the Noctalia plugin directory:

```sh
git clone https://github.com/Bombatomica64/linear-sidebar.git ~/Playground/linear-sidebar
ln -s ~/Playground/linear-sidebar ~/.local/share/noctalia/plugins/linear

noctalia msg config-reload
noctalia msg plugins enable lollo/linear
```

Then add the `linear` widget to a bar section in your Noctalia settings.

Verify the plugin parses cleanly at any time with:

```sh
noctalia plugins lint ~/.local/share/noctalia/plugins/linear
```

After editing `plugin.toml` (manifest, panel or widget registration), a
`config-reload` is not enough — the plugin has to be re-registered:

```sh
noctalia msg plugins disable lollo/linear && noctalia msg plugins enable lollo/linear
```

## Usage

### Bar widget

| action | effect |
| --- | --- |
| left click | toggle the browser panel |
| middle click | refresh the cached list |
| right click | run a Linear sync |

The glyph is colored by state: `primary` when results are loaded, `tertiary`
while loading or syncing (with a dot badge during a sync), `error` on failure.
The tooltip shows the issue and project counts, or the error.

### Keyboard shortcuts

Active while the browser panel is open:

| key | action |
| --- | --- |
| <kbd>Down</kbd> | move selection down one row |
| <kbd>Up</kbd> | move selection up one row |
| <kbd>PageDown</kbd> | move selection down six rows |
| <kbd>PageUp</kbd> | move selection up six rows |
| <kbd>Enter</kbd> / <kbd>Return</kbd> | load the highlighted row's detail |
| typing | goes to the search box (debounced ~160 ms) |

Only non-printable chords are captured, so plain typing still reaches the
focused search input — the host routes printable keys to the text field before
consulting `capture_keys`.

> **Note on chord names.** In `plugin.toml`, PageUp and PageDown are spelled
> **`prior`** and **`next`** — the X11/Hyprland keysym names. `"pageup"` and
> `"pagedown"` are rejected by `noctalia plugins lint`; the working names were
> found by brute-forcing the linter. The full list is:
>
> ```toml
> capture_keys = ["down", "up", "prior", "next", "return", "enter"]
> ```

## Settings

| key | type | default | meaning |
| --- | --- | --- | --- |
| `refresh_interval` | int, seconds (30–3600) | `300` | how often the cached list is re-read automatically |
| `result_limit` | int (10–500) | `80` | maximum rows requested from the cache helper |
| `my_name` | string | `""` | assignee name used by the *My Issues* filter; while it is empty that filter shows every issue and the panel says so |
| `helper_path` | string | `~/.config/rofi/scripts/linear-cache.py` | path to the `linear-cache.py` helper |
| `env_path` | string | `~/.config/rofi/linear.env` | env file sourced before detail and sync calls |

## Architecture

| file | role |
| --- | --- |
| `plugin.toml` | manifest: settings schema, widget, panel (1500×900 floating, centered), service, `capture_keys` |
| `service.luau` | owns every subprocess; publishes `linear_results`, `linear_detail`, `linear_status`; consumes `linear_command` |
| `widget.luau` | bar button; reads `linear_status`, posts `linear_command` intents |
| `panel.luau` | search box, view filter, status filter, result list, detail pane; posts `linear_command` intents and handles `onKey` |
| `translations/en.json` | all user-facing strings, via `noctalia.tr` |

Each entry runs in its own Luau VM, so `noctalia.state` is the only channel
between them. No entry other than `service.luau` ever spawns a process.

## Porting notes (v4 → v5)

This started as a QML plugin for Noctalia v4 and was rewritten for the v5 Luau
API. The behavioural differences worth knowing:

- `refreshInterval` was **milliseconds** in v4 (`300000`). It is now
  `refresh_interval` in **seconds** (`300`, the same 5 minutes), because v5
  settings express it as a bounded int. The service multiplies by 1000 for
  `noctalia.setUpdateInterval`.
- `helper_path` and `env_path` were hardcoded in v4's `Main.qml`; they are
  settings now.
- The separate "All" reset button and the Todo / My Issues shortcut buttons
  collapsed into the view and status filter rows, which express the same states.
- The panel is a fixed 1500×900 floating panel rather than QML
  `contentPreferredWidth/Height` scaling against `Style.uiScaleRatio`. A panel
  cannot resize itself — the size is read once from the manifest — so changing
  it means editing `width`/`height` in `plugin.toml`.
- The result list formatting and the markdown flattening in the detail pane are
  line-for-line ports of the v4 originals. **Query assembly is not**: see
  *Filtering* below.
- Keyboard navigation was dropped in the first v5 pass (the API appeared to
  expose no key hook) and later restored once `capture_keys` + `onKey` were
  found.

## Filtering

`linear-cache.py` takes one positional query string and ORs it across every
column, per whitespace-separated word. v4 built that string by concatenating the
free text, the status term and the assignee name — so each filter *widened* the
result set instead of narrowing it. Searching `coupon` with **Urgent** selected
returned every coupon issue **plus** every urgent issue.

So the helper now only ever sees free text, and the view and status filters are
applied in `service.luau` over the rows it returned:

- a status matches when it is a substring of the row's workflow state *or* its
  priority label, because the row mixes both ("Urgent", "In Progress")
- *My Issues* matches on `assignee` against the `my_name` setting
- *Projects* keeps only projects; any active status filter excludes projects,
  which carry neither a priority nor an issue workflow state

When there is no free text the active filter is pushed down to the helper as the
query, so a bare **Urgent** sees past `result_limit` instead of filtering the
newest 80 rows. `applyFilters()` still has the final say either way.

## Colors

Each row carries a stripe and a colored glyph keyed to its **priority** (issues)
or its **state** (projects), and the state and priority chips under the title are
colored to match:

| priority | | state | |
| --- | --- | --- | --- |
| Urgent | `#e5484d` | Backlog / Planned | `#95a2b3` |
| High | `#f76808` | Todo | `#c7cbd1` |
| Medium | `#f2c94c` | In Progress | `#f2c94c` |
| Low | `#7c92a8` | In Review | `#4cb782` |
| No priority | muted role | Done / Completed | `#5e6ad2` |
| | | Canceled / Duplicate | `#818a96` |

These are literal hex, not palette roles, because the point is that a row looks
the same shade of urgent here as it does in Linear. Everything structural —
selection, chrome, body text — still uses theme roles, so the panel follows the
active Noctalia theme.

The mapping is by **name**: `linear-cache.py` stores `state { name }` and
`priorityLabel`, not the API's `state { color }`, so the cache carries no color
of its own. A state name that is not in the table falls back to the muted role
rather than being guessed at — add a row to `STATE_COLORS` in `panel.luau` for a
custom workflow state.

## Tests

```sh
./tests/run.sh          # needs `luau` on PATH
```

Concatenates a stubbed host, a fixture and `service.luau` into one script and
runs the real filter path against it — the entry points are chunks the Noctalia
host loads, not modules, so they are concatenated rather than required. The stub
reimplements the helper's OR matching, so the union-vs-intersection regression is
caught in the test rather than in the panel. It can also hold a read in flight,
which covers the queueing path: a filter click during a read used to be dropped.

## License

MIT — see [LICENSE](LICENSE).
