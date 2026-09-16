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
local listGeneration = 0
local detailGeneration = 0

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

local function publishResults()
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

-- Mirrors Main.qml's myIssueTerm(): the configured name wins, otherwise fall
-- back to the first assignee visible in the current result set.
local function myIssueTerm()
  local configured = configString("my_name", "")
  if configured ~= "" then
    return configured
  end
  for _, issue in ipairs(state.issues) do
    local assignee = trim(issue.assignee)
    if assignee ~= "" then
      return assignee
    end
  end
  return ""
end

-- Mirrors Main.qml's effectiveQuery(): free text + status term + view term,
-- space joined, all fed to the helper's single positional query argument.
local function effectiveQuery()
  local parts = {}
  local q = trim(state.query)
  if q ~= "" then
    table.insert(parts, q)
  end
  if state.status ~= "All" and trim(state.status) ~= "" then
    table.insert(parts, state.status)
  end
  if state.view == "My Issues" then
    local term = myIssueTerm()
    if term ~= "" then
      table.insert(parts, term)
    end
  elseif state.view == "Projects" then
    table.insert(parts, "project")
  end
  return table.concat(parts, " ")
end

local function runList(queryOverride)
  if listPending then
    return
  end
  listPending = true
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
    state.loading = false
    if not result or result.exitCode ~= 0 then
      state.issues = {}
      state.projects = {}
      state.error = trim((result and result.stderr) or "")
      if state.error == "" then
        state.error = noctalia.tr("error.list_failed")
      end
      publishResults()
      return
    end
    local raw = trim(result.stdout)
    if raw == "" then
      state.issues = {}
      state.projects = {}
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
    state.issues = type(decoded.issues) == "table" and decoded.issues or {}
    state.projects = type(decoded.projects) == "table" and decoded.projects or {}
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
    -- Projects view with no free text asks the helper for everything, like
    -- Main.qml's showProjects() did with load("").
    if state.view == "Projects" and trim(state.query) == "" and state.status == "All" then
      runList("")
    else
      runList()
    end
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
