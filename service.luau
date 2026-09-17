--!nonstrict
-- Linear backend. Owns every subprocess (the rofi linear-cache.py helper) and
-- publishes three state keys the widget and panel only read:
--   linear_results  list payload + query/filter echo + loading/sync/error flags
--   linear_detail   the detail object for the currently selected item
--   linear_status   the small summary the bar widget renders
-- Intents arrive on `linear_command`.

local DEFAULT_HELPER = "~/.config/rofi/scripts/linear-cache.py"
local DEFAULT_ENV = "~/.config/rofi/linear.env"

local state = {
  issues = {},
  projects = {},
  loading = false,
  syncing = false,
  error = "",
  updatedAt = 0,
  revision = 0,
  query = "",
  view = "All",
  status = "All",
}

local detail = {
  id = "",
  kind = "",
  loading = false,
  error = "",
  data = nil,
  revision = 0,
}

local listPending = false
local listQueued = false
local listGeneration = 0
local detailGeneration = 0

-- The helper's query is a single positional string it ORs across every column,
-- so appending a status or assignee term to the free text *widens* the result
-- set instead of narrowing it ("coupon Urgent" returned 3 + 69 = 72 rows, not
-- the 0 that actually match both). The filters are therefore applied here, over
-- the rows the helper returned, and the helper only ever sees free text.
local rawIssues = {}
local rawProjects = {}

local function trim(value)
  return noctalia.string.trim(tostring(value or ""))
end

local function shellQuote(value)
  return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
end

local function configString(key, fallback)
  local value = noctalia.getConfig(key)
  if type(value) == "string" and trim(value) ~= "" then
    return trim(value)
  end
  return fallback
end

local function configInt(key, fallback, minimum, maximum)
  local value = tonumber(noctalia.getConfig(key)) or fallback
  if value < minimum then value = minimum end
  if value > maximum then value = maximum end
  return math.floor(value)
end

local function helperPath()
  return noctalia.expandPath(configString("helper_path", DEFAULT_HELPER))
end

local function envPath()
  return noctalia.expandPath(configString("env_path", DEFAULT_ENV))
end

local function resultLimit()
  return configInt("result_limit", 80, 10, 500)
end

-- Every helper invocation goes through `bash -lc` with a single-quoted script,
-- exactly like the v4 plugin did, so the detail/sync calls can source the env
-- file and the list call still survives an empty query argument.
local function bashCommand(script)
  return "bash -lc " .. shellQuote(script)
end

local function sourcedScript(tail)
  local env = shellQuote(envPath())
  return `set -a; [ -f {env} ] && . {env}; set +a; exec {tail}`
end

local function lowerContains(haystack, needle)
  if needle == "" then
    return true
  end
  return tostring(haystack or ""):lower():find(needle:lower(), 1, true) ~= nil
end

-- The status row mixes Linear priority labels ("Urgent", "High") with workflow
-- state names ("Todo", "In Progress", ...), exactly as the v4 panel did, so a
-- row matches if either field carries the term.
local function matchesStatus(item)
  local want = trim(state.status)
  if want == "" or want == "All" then
    return true
  end
  return lowerContains(item.state, want) or lowerContains(item.priority, want)
end

local function matchesView(item)
  if state.view == "Projects" then
    return tostring(item.kind) == "project"
  end
  if state.view == "My Issues" then
    if tostring(item.kind) == "project" then
      return false
    end
    local term = configString("my_name", "")
    -- No configured name means no way to tell your issues from anyone else's.
    -- v4 guessed the first assignee in the result set, which silently filtered
    -- by a stranger; the panel shows a hint instead.
    if term == "" then
      return true
    end
    return lowerContains(item.assignee, term)
  end
  return true
end

local function applyFilters()
  state.issues = {}
  state.projects = {}
  for _, item in ipairs(rawIssues) do
    if matchesView(item) and matchesStatus(item) then
      table.insert(state.issues, item)
    end
  end
  for _, item in ipairs(rawProjects) do
    -- A status term is a priority or an issue workflow state; projects carry
    -- neither, so any active status filter simply excludes them.
    if matchesView(item) and (trim(state.status) == "" or state.status == "All") then
      table.insert(state.projects, item)
    end
  end
end

local function publishResults()
  applyFilters()
  state.revision += 1
  noctalia.state.set("linear_results", {
    issues = state.issues,
    projects = state.projects,
    loading = state.loading,
    syncing = state.syncing,
    error = state.error,
    updatedAt = state.updatedAt,
    revision = state.revision,
    query = state.query,
    view = state.view,
    status = state.status,
    needsMyName = state.view == "My Issues" and configString("my_name", "") == "",
  })
  noctalia.state.set("linear_status", {
    issueCount = #state.issues,
    projectCount = #state.projects,
    loading = state.loading,
    syncing = state.syncing,
    error = state.error,
    updatedAt = state.updatedAt,
  })
end

local function publishDetail()
  detail.revision += 1
  noctalia.state.set("linear_detail", {
    id = detail.id,
    kind = detail.kind,
    loading = detail.loading,
    error = detail.error,
    data = detail.data,
    revision = detail.revision,
  })
end

-- What the helper is actually asked for. Free text wins outright, because
-- mixing it with a filter term is what broke the filters in the first place.
-- With no free text there is nothing to widen, so the active filter is pushed
-- down instead: the helper then returns rows that match it rather than the
-- newest `result_limit` rows, which is what makes a bare "Urgent" or "My
-- Issues" see past the limit. Either way applyFilters() has the final say.
local function effectiveQuery()
  local q = trim(state.query)
  if q ~= "" then
    return q
  end
  if state.view == "My Issues" then
    local term = configString("my_name", "")
    if term ~= "" then
      return term
    end
  end
  if state.view ~= "Projects" and state.status ~= "All" and trim(state.status) ~= "" then
    return state.status
  end
  return ""
end

local function runList(queryOverride)
  -- A filter click while a read is in flight used to be dropped on the floor,
  -- which is most of what "the filters don't work" looked like. Remember that
  -- one is owed and re-run when the current one lands.
  if listPending then
    listQueued = true
    return
  end
  listPending = true
  listQueued = false
  listGeneration += 1
  local generation = listGeneration
  local query = queryOverride or effectiveQuery()
  state.loading = true
  state.error = ""
  publishResults()

  local script = `exec python3 {shellQuote(helperPath())} json {shellQuote(query)} {shellQuote(tostring(resultLimit()))}`
  local started = noctalia.runAsync(bashCommand(script), function(result)
    listPending = false
    if generation ~= listGeneration then
      return
    end
    if listQueued then
      listQueued = false
      runList()
      return
    end
    state.loading = false
    if not result or result.exitCode ~= 0 then
      rawIssues = {}
      rawProjects = {}
      state.error = trim((result and result.stderr) or "")
      if state.error == "" then
        state.error = noctalia.tr("error.list_failed")
      end
      publishResults()
      return
    end
    local raw = trim(result.stdout)
    if raw == "" then
      rawIssues = {}
      rawProjects = {}
      state.updatedAt = noctalia.nowMs()
      publishResults()
      return
    end
    local decoded = noctalia.json.decode(raw)
    if type(decoded) ~= "table" then
      state.error = noctalia.tr("error.parse_list")
      publishResults()
      return
    end
    rawIssues = type(decoded.issues) == "table" and decoded.issues or {}
    rawProjects = type(decoded.projects) == "table" and decoded.projects or {}
    state.error = ""
    state.updatedAt = noctalia.nowMs()
    publishResults()
  end, 30000)

  if not started then
    listPending = false
    state.loading = false
    state.error = noctalia.tr("error.spawn_failed")
    publishResults()
  end
end

local function runDetail(kind, id)
  id = trim(id)
  if id == "" then
    detail.id = ""
    detail.kind = ""
    detail.data = nil
    detail.error = ""
    detail.loading = false
    publishDetail()
    return
  end
  detailGeneration += 1
  local generation = detailGeneration
  detail.id = id
  detail.kind = trim(kind) ~= "" and trim(kind) or "issue"
  detail.data = nil
  detail.error = ""
  detail.loading = true
  publishDetail()

  local script = sourcedScript(
    `python3 {shellQuote(helperPath())} detail {shellQuote(detail.kind)} {shellQuote(id)}`
  )
  local started = noctalia.runAsync(bashCommand(script), function(result)
    if generation ~= detailGeneration then
      return
    end
    detail.loading = false
    if not result or result.exitCode ~= 0 then
      detail.error = trim((result and result.stderr) or "")
      if detail.error == "" then
        detail.error = noctalia.tr("error.detail_failed")
      end
      publishDetail()
      return
    end
    local raw = trim(result.stdout)
    if raw == "" then
      publishDetail()
      return
    end
    local decoded = noctalia.json.decode(raw)
    if type(decoded) ~= "table" then
      detail.error = noctalia.tr("error.parse_detail")
      publishDetail()
      return
    end
    detail.data = decoded
    publishDetail()
  end, 30000)

  if not started then
    detail.loading = false
    detail.error = noctalia.tr("error.spawn_failed")
    publishDetail()
  end
end

local function runSync()
  if state.syncing then
    return
  end
  state.syncing = true
  state.error = ""
  publishResults()

  local script = sourcedScript(`python3 {shellQuote(helperPath())} sync`)
  local started = noctalia.runAsync(bashCommand(script), function(result)
    state.syncing = false
    if not result or result.exitCode ~= 0 then
      state.error = trim((result and result.stderr) or "")
      if state.error == "" then
        state.error = noctalia.tr("error.sync_failed")
      end
      noctalia.notifyError(noctalia.tr("title"), state.error)
      publishResults()
      return
    end
    noctalia.notify(noctalia.tr("title"), noctalia.tr("result.synced"))
    publishResults()
    runList()
  end, 300000)

  if not started then
    state.syncing = false
    state.error = noctalia.tr("error.spawn_failed")
    publishResults()
  end
end

local function openUrl(url)
  url = trim(url)
  if url == "" then
    return
  end
  noctalia.runAsync(`xdg-open {shellQuote(url)}`, function() end, 10000)
end

local function executeCommand(command)
  if type(command) ~= "table" then
    return
  end
  local action = tostring(command.action or "")
  if action == "search" then
    state.query = tostring(command.query or "")
    state.view = tostring(command.view or state.view)
    state.status = tostring(command.status or state.status)
    runList()
  elseif action == "refresh" then
    runList()
  elseif action == "detail" then
    runDetail(command.kind, command.id)
  elseif action == "clear_detail" then
    runDetail("", "")
  elseif action == "sync" then
    runSync()
  elseif action == "open" then
    openUrl(command.url)
  elseif action == "copy" then
    noctalia.copyToClipboard(tostring(command.text or ""))
  end
end

noctalia.state.watch("linear_command", executeCommand)

publishResults()
publishDetail()
runList()

noctalia.setUpdateInterval(configInt("refresh_interval", 300, 30, 3600) * 1000)

function update()
  runList()
end
