--!nonstrict
-- Linear browser panel: search box, view filter, status filter, result list and
-- a detail pane. It never spawns a process: every intent goes to service.luau
-- through the `linear_command` state key.

local STATUSES = { "All", "Urgent", "High", "Todo", "In Progress", "In Review", "Backlog" }
local VIEWS = { "All", "My Issues", "Projects" }
local SEARCH_DEBOUNCE_MS = 160

local results = noctalia.state.get("linear_results")
  or { issues = {}, projects = {}, loading = false, syncing = false, error = "", updatedAt = 0 }
local detail = noctalia.state.get("linear_detail")
  or { id = "", kind = "", loading = false, error = "", data = nil }

local searchText = tostring(results.query or "")
local viewFilter = tostring(results.view or "All")
local statusFilter = tostring(results.status or "All")
local inputGeneration = 0

local selectedId = ""
local selectedItem = nil

local searchDueAt = 0
local dirty = true
local render

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local function trim(value)
  return noctalia.string.trim(tostring(value or ""))
end

local function frameTick(enabled)
  if type(panel.setNeedsFrameTick) == "function" then
    panel.setNeedsFrameTick(enabled)
  end
end

local function send(action, values)
  local command = { action = action, requestId = tostring(noctalia.nowMs()) }
  if type(values) == "table" then
    for key, value in pairs(values) do
      command[key] = value
    end
  end
  noctalia.state.set("linear_command", command)
end

local function requestSearch()
  searchDueAt = 0
  frameTick(false)
  send("search", { query = searchText, view = viewFilter, status = statusFilter })
end

local function scheduleSearch()
  searchDueAt = noctalia.nowMs() + SEARCH_DEBOUNCE_MS
  frameTick(true)
end

-- ── Item shaping (ported from Panel.qml's helper functions) ─────────────────

local function resultsList()
  local issues = type(results.issues) == "table" and results.issues or {}
  local projects = type(results.projects) == "table" and results.projects or {}
  local list = {}
  for _, item in ipairs(issues) do
    table.insert(list, item)
  end
  for _, item in ipairs(projects) do
    table.insert(list, item)
  end
  return list
end

-- ── Linear's colors ────────────────────────────────────────────────────────
--
-- Literal hex rather than palette roles: these are Linear's own state and
-- priority colors, and the point is that a row looks the same shade of urgent
-- here as it does in the app. Everything structural (selection, text, chrome)
-- still uses theme roles, so the panel follows the active Noctalia theme.
--
-- The cache carries state and priority as plain strings - linear-cache.py
-- stores `state { name }` and `priorityLabel`, not the API's `state { color }` -
-- so the mapping is by name, and an unrecognised name falls back to the muted
-- role rather than guessing.

local PRIORITY_COLORS = {
  urgent = "#e5484d",
  high = "#f76808",
  medium = "#f2c94c",
  low = "#7c92a8",
}

local STATE_COLORS = {
  backlog = "#95a2b3",
  todo = "#c7cbd1",
  ["in progress"] = "#f2c94c",
  started = "#f2c94c",
  ["in review"] = "#4cb782",
  done = "#5e6ad2",
  completed = "#5e6ad2",
  canceled = "#818a96",
  cancelled = "#818a96",
  duplicate = "#818a96",
  planned = "#95a2b3",
}

local MUTED = "on_surface_variant"

local function priorityColor(value)
  return PRIORITY_COLORS[tostring(value or ""):lower()] or MUTED
end

local function stateColor(value)
  return STATE_COLORS[tostring(value or ""):lower()] or MUTED
end

-- Urgent and High are the two that have to be spottable while scrolling, so
-- they get the weight as well as the color.
local function priorityIsHot(value)
  local key = tostring(value or ""):lower()
  return key == "urgent" or key == "high"
end

-- The stripe down the left edge of a row: an issue is keyed by priority, a
-- project by its own state, since projects have no priority.
local function accentColor(item)
  if tostring(item.kind) == "project" then
    return stateColor(item.state)
  end
  return priorityColor(item.priority)
end

local function itemUrl(item)
  if type(item) ~= "table" then
    return ""
  end
  local url = trim(item.url)
  if url ~= "" then
    return url
  end
  if tostring(item.kind) == "project" then
    return "https://linear.app/projects/" .. tostring(item.id or "")
  end
  return "https://linear.app/issue/" .. tostring(item.identifier or "")
end

local function itemRef(item)
  if type(item) ~= "table" then
    return ""
  end
  if tostring(item.kind) == "project" then
    return tr("item.project")
  end
  return trim(item.identifier)
end

local function itemTitle(item)
  if type(item) ~= "table" then
    return ""
  end
  if tostring(item.kind) == "project" then
    return trim(item.name)
  end
  return trim(item.title)
end

local function detailObject()
  if type(detail.data) == "table" then
    return detail.data
  end
  return selectedItem
end

local function selectItem(item)
  selectedItem = item
  selectedId = type(item) == "table" and tostring(item.id or "") or ""
  if selectedId == "" then
    send("clear_detail")
  else
    send("detail", { kind = tostring(item.kind or "issue"), id = selectedId })
  end
  dirty = true
end

-- ── Keyboard navigation (ported from Panel.qml's handleNavigation/moveSelection) ──
-- Down/Up move the highlight by 1, PageDown/PageUp by 6, Enter/Return
-- (re)loads detail for the highlighted row. Mirrors Main.qml's moveSelection:
-- when nothing is selected the implicit start is the first row, so the very
-- first Down lands on the *second* row — same quirk as the original.
local function moveSelection(delta)
  local list = resultsList()
  local count = #list
  if count == 0 then
    return
  end
  local start = 1
  if selectedId ~= "" then
    for i, item in ipairs(list) do
      if tostring(item.id or "") == selectedId then
        start = i
        break
      end
    end
  end
  local target = start + delta
  if target < 1 then
    target = 1
  elseif target > count then
    target = count
  end
  selectItem(list[target])
end

local function activateSelection()
  if selectedId == "" then
    return
  end
  for _, item in ipairs(resultsList()) do
    if tostring(item.id or "") == selectedId then
      selectItem(item)
      return
    end
  end
end

-- ── UI ─────────────────────────────────────────────────────────────────────

local function filterButton(label, selected, onClick)
  return ui.button({
    key = "flt-" .. label,
    text = label,
    controlSize = "sm",
    selected = selected,
    variant = selected and "primary" or "outline",
    onClick = onClick,
  })
end

local function headerRow()
  local count = tr("panel.counts", {
    issues = tostring(#(results.issues or {})),
    projects = tostring(#(results.projects or {})),
  })
  return ui.row({ gap = 8, align = "center" }, {
    ui.glyph({ name = "git-branch", size = 22, color = "primary" }),
    ui.column({ gap = 0, flexGrow = 1 }, {
      ui.label({ text = tr("title"), fontSize = 17, fontWeight = "bold" }),
      ui.label({ text = count, color = "on_surface_variant", fontSize = 11 }),
    }),
    ui.button({
      text = results.syncing == true and tr("actions.syncing") or tr("actions.sync"),
      glyph = "refresh",
      variant = "outline",
      controlSize = "sm",
      enabled = results.syncing ~= true,
      onClick = function()
        send("sync")
      end,
    }),
    ui.button({
      glyph = "close",
      variant = "ghost",
      controlSize = "sm",
      onClick = function()
        panel.close()
      end,
    }),
  })
end

local function searchRow()
  return ui.row({ gap = 6, align = "center" }, {
    ui.input({
      key = `search-{inputGeneration}`,
      value = searchText,
      placeholder = tr("panel.search_placeholder"),
      flexGrow = 1,
      onChange = "onSearchChange",
      onSubmit = "onSearchSubmit",
    }),
    ui.button({
      glyph = "backspace",
      variant = "ghost",
      controlSize = "sm",
      tooltip = tr("actions.clear"),
      enabled = searchText ~= "",
      onClick = function()
        searchText = ""
        inputGeneration += 1
        requestSearch()
        dirty = true
      end,
    }),
  })
end

local function viewRow()
  local buttons = {}
  for _, view in ipairs(VIEWS) do
    local label = tr("views." .. view:gsub("%s", "_"):lower())
    table.insert(buttons, filterButton(label, viewFilter == view, function()
      viewFilter = view
      requestSearch()
      dirty = true
    end))
  end
  table.insert(buttons, ui.spacer({ flexGrow = 1 }))
  table.insert(buttons, ui.label({
    text = results.loading == true and tr("panel.loading") or "",
    color = "on_surface_variant",
    fontSize = 11,
  }))
  return ui.row({ gap = 4, align = "center" }, buttons)
end

local function statusRow()
  local buttons = {}
  for _, status in ipairs(STATUSES) do
    local label = tr("statuses." .. status:gsub("%s", "_"):lower())
    table.insert(buttons, filterButton(label, statusFilter == status, function()
      statusFilter = status
      requestSearch()
      dirty = true
    end))
  end
  return ui.row({ gap = 4, align = "center" }, buttons)
end

-- Meta chips, interleaved with dot separators so the colors survive. A single
-- concatenated string could not be colored piecewise, which is why the row is a
-- container now rather than the ui.button it used to be.
local function metaChips(item)
  local chips = {}
  local function chip(text, color, weight)
    text = trim(text)
    if text == "" then
      return
    end
    if #chips > 0 then
      table.insert(chips, ui.label({ text = "·", color = MUTED, fontSize = 11 }))
    end
    table.insert(chips, ui.label({
      text = text,
      color = color,
      fontSize = 11,
      fontWeight = weight or "normal",
      maxLines = 1,
    }))
  end

  if tostring(item.kind) == "project" then
    chip(item.state, stateColor(item.state), "medium")
    chip(item.teams, MUTED)
    return chips
  end

  chip(item.state, stateColor(item.state), "medium")
  local priority = trim(item.priority)
  if priority == "" then
    chip(tr("item.no_priority"), MUTED)
  else
    chip(priority, priorityColor(priority), priorityIsHot(priority) and "bold" or "normal")
  end
  chip(item.assignee, MUTED)
  chip(item.project, MUTED)
  return chips
end

local function resultRow(item)
  local id = tostring(item.id or "")
  local selected = id == selectedId
  local ref = itemRef(item)

  local heading = { }
  if ref ~= "" then
    table.insert(heading, ui.label({
      text = ref,
      color = tostring(item.kind) == "project" and MUTED or "primary",
      fontSize = 12,
      fontWeight = "bold",
      maxLines = 1,
    }))
  end
  table.insert(heading, ui.label({
    text = itemTitle(item),
    fontSize = 12,
    color = "on_surface",
    flexGrow = 1,
    maxLines = 1,
  }))

  -- onClick on the container makes the whole row the click target and puts it
  -- in the tab order, which is what a ui.button gave us before.
  return ui.row({
    key = "res-" .. id,
    gap = 8,
    padding = 8,
    radius = 8,
    align = "stretch",
    -- Fill only, no border: a clickable container joins the tab order, so the
    -- host draws its own focus outline on whichever row it last focused. A
    -- border here would be a second cursor that disagrees with that one.
    fill = selected and "primary/0.28" or "surface_variant/0.35",
    onClick = function()
      selectItem(item)
      render()
    end,
  }, {
    ui.box({ width = 3, radius = 2, fill = accentColor(item) }),
    ui.glyph({
      name = tostring(item.kind) == "project" and "folder" or "circle-dot",
      size = 15,
      color = accentColor(item),
    }),
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.row({ gap = 6, align = "center" }, heading),
      ui.row({ gap = 6, align = "center" }, metaChips(item)),
    }),
  })
end

local function listPane()
  local items = resultsList()
  local children = {}
  if #items == 0 then
    table.insert(children, ui.column({ align = "center", padding = 24, gap = 6 }, {
      ui.glyph({ name = "search-off", size = 36, color = "on_surface_variant" }),
      ui.label({
        text = results.loading == true and tr("panel.loading") or tr("panel.no_results"),
        color = "on_surface_variant",
        textAlign = "center",
      }),
    }))
  else
    for _, item in ipairs(items) do
      table.insert(children, resultRow(item))
    end
  end
  -- flexGrow (not width) is what actually splits the two panes; a fixed width
  -- on the scroll collapses instead of holding the requested size.
  return ui.scroll({ key = "linear-results", flexGrow = 6, gap = 6, align = "stretch" }, children)
end

local function detailPane()
  local object = detailObject()
  if type(object) ~= "table" then
    return ui.column({ flexGrow = 4, padding = 16, align = "center", justify = "center" }, {
      ui.label({ text = tr("panel.select_hint"), color = "on_surface_variant", textAlign = "center" }),
    })
  end

  local children = {
    ui.row({ gap = 8, align = "center" }, {
      ui.box({ width = 3, height = 20, radius = 2, fill = accentColor(object) }),
      ui.label({ text = itemRef(object), color = "primary", fontWeight = "bold", fontSize = 13 }),
      ui.label({ text = itemTitle(object), fontWeight = "bold", fontSize = 15, flexGrow = 1, maxLines = 3 }),
    }),
    ui.row({ gap = 6, align = "center" }, metaChips(object)),
  }
  if detail.loading == true then
    table.insert(children, ui.label({ text = tr("panel.detail_loading"), color = "on_surface_variant" }))
  end
  if trim(detail.error) ~= "" then
    table.insert(children, ui.label({ text = trim(detail.error), color = "error", maxLines = 3 }))
  end
  table.insert(children, ui.separator({}))

  local description = trim(object.description)
  if description == "" then
    description = tr("panel.no_description")
  end
  table.insert(children, ui.scroll({ key = "linear-detail", flexGrow = 1, gap = 6 }, {
    ui.markdown({ text = description }),
  }))

  local url = itemUrl(object)
  table.insert(children, ui.row({ gap = 6, align = "center" }, {
    ui.button({
      text = tr("actions.open"),
      glyph = "external-link",
      variant = "primary",
      controlSize = "sm",
      enabled = url ~= "",
      onClick = function()
        send("open", { url = url })
      end,
    }),
    ui.button({
      text = tr("actions.copy_url"),
      glyph = "copy",
      variant = "outline",
      controlSize = "sm",
      enabled = url ~= "",
      onClick = function()
        send("copy", { text = url })
      end,
    }),
    ui.spacer({ flexGrow = 1 }),
  }))

  -- align = "stretch" is load-bearing. A column's children are *not* stretched
  -- across the cross axis by default on 5.1.0 - they shrink-wrap and center - so
  -- the description used to wrap inside a ~260px ribbon centered in a ~555px
  -- pane, and the action buttons sat centered with it. Nothing about the scroll
  -- could fix that from the inside: neither flexGrow nor an explicit width on
  -- the scroll changed anything, because the constraint was the parent's.
  -- listPane never had the bug: it is a direct child of the horizontal split
  -- row, where the same flexGrow is the main axis.
  return ui.column({ flexGrow = 4, gap = 6, padding = 8, align = "stretch" }, children)
end

render = function()
  dirty = false
  local children = { headerRow(), searchRow(), viewRow() }
  if viewFilter ~= "Projects" then
    table.insert(children, statusRow())
  end
  if results.needsMyName == true then
    table.insert(children, ui.label({
      text = tr("panel.needs_my_name"),
      color = "on_surface_variant",
      fontSize = 11,
      maxLines = 2,
    }))
  end
  if trim(results.error) ~= "" then
    table.insert(children, ui.label({ text = trim(results.error), color = "error", maxLines = 3 }))
  end
  table.insert(children, ui.row({ gap = 8, flexGrow = 1, align = "stretch" }, {
    listPane(),
    ui.separator({ orientation = "vertical" }),
    detailPane(),
  }))
  panel.render(ui.column({ flexGrow = 1, gap = 8, padding = 12 }, children))
end

-- ── Wiring ─────────────────────────────────────────────────────────────────

noctalia.state.watch("linear_results", function(value)
  if type(value) ~= "table" then
    return
  end
  results = value
  -- Keep the selection pointing at the freshest copy of the row, and drop it
  -- when the new result set no longer contains it.
  if selectedId ~= "" then
    local found = nil
    for _, item in ipairs(resultsList()) do
      if tostring(item.id or "") == selectedId then
        found = item
        break
      end
    end
    selectedItem = found or selectedItem
  end
  dirty = true
end)

noctalia.state.watch("linear_detail", function(value)
  if type(value) == "table" then
    detail = value
    dirty = true
  end
end)

panel.setWantsSecondTicks(true)

function onOpen(_context)
  send("refresh")
  render()
end

function update()
  if searchDueAt > 0 and noctalia.nowMs() >= searchDueAt then
    requestSearch()
    dirty = true
  end
  if dirty then
    render()
  end
end

function onSearchChange(value)
  searchText = tostring(value or "")
  scheduleSearch()
end

function onSearchSubmit(value)
  if value ~= nil then
    searchText = tostring(value)
  end
  requestSearch()
  dirty = true
end

-- capture_keys in plugin.toml lists only non-printable chords (down/up/
-- prior/next/return/enter), so the host still routes plain typing to the
-- focused search ui.input before consulting this callback. "prior"/"next"
-- are the chord names for PageUp/PageDown.
function onKey(chord, pressed)
  if not pressed then
    return
  end
  if chord == "down" then
    moveSelection(1)
  elseif chord == "up" then
    moveSelection(-1)
  elseif chord == "next" then
    moveSelection(6)
  elseif chord == "prior" then
    moveSelection(-6)
  elseif chord == "return" or chord == "enter" then
    activateSelection()
  end
end

render()
