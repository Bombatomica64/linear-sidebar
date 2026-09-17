--!nonstrict
-- Stub host for service.luau. Concatenated ahead of the real service (see
-- tests/run.sh) rather than required, because the entry points are chunks the
-- Noctalia host loads, not modules.
--
-- runAsync is answered synchronously from a canned helper payload, so the whole
-- filter path - effectiveQuery, the helper's OR-matching, applyFilters - runs
-- exactly as it does in the shell, against real rows dumped from the cache.

SIM = {
  config = {},
  published = {},
  lastQuery = nil,
  rows = { issues = {}, projects = {} },
  deferred = false,
  pending = {},
}

-- Runs the callback for the read that is currently in flight, one at a time, so
-- a test can interleave a filter change with an outstanding request.
function SIM.flushOne()
  local next = table.remove(SIM.pending, 1)
  if next then
    next()
    return true
  end
  return false
end
-- exported as a global for the fixtures and the driver, which are separate chunks

-- Reproduces linear-cache.py's search_rows(): every term is OR'd across every
-- column, which is the behaviour that made appending a filter term widen the
-- result set instead of narrowing it.
local function helperSearch(term)
  local fields = { "identifier", "title", "state", "priority", "assignee", "project", "team", "name", "teams" }
  local function matches(item)
    if term == "" then
      return true
    end
    local parts = {}
    for word in term:gmatch("%S+") do
      table.insert(parts, word:lower())
    end
    table.insert(parts, term:lower())
    for _, part in ipairs(parts) do
      for _, field in ipairs(fields) do
        local value = item[field]
        if type(value) == "string" and value:lower():find(part, 1, true) then
          return true
        end
      end
    end
    return false
  end
  local issues, projects = {}, {}
  for _, item in ipairs(SIM.rows.issues) do
    if matches(item) then table.insert(issues, item) end
  end
  for _, item in ipairs(SIM.rows.projects) do
    if matches(item) then table.insert(projects, item) end
  end
  return { issues = issues, projects = projects }
end

local json = {}
function json.decode(text)
  return SIM.decoded
end
function json.encode(value)
  return ""
end

noctalia = {
  json = json,
  string = {
    trim = function(value)
      return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
    end,
  },
  state = {
    set = function(key, value)
      SIM.published[key] = value
    end,
    get = function(key)
      return SIM.published[key]
    end,
    watch = function(key, fn)
      SIM.watchers = SIM.watchers or {}
      SIM.watchers[key] = fn
    end,
  },
  getConfig = function(key)
    return SIM.config[key]
  end,
  expandPath = function(path)
    return path
  end,
  nowMs = function()
    return 0
  end,
  tr = function(key)
    return key
  end,
  notify = function() end,
  notifyError = function() end,
  copyToClipboard = function() end,
  setUpdateInterval = function() end,
  runAsync = function(command, callback)
    -- The whole script is single-quoted once for `bash -lc` and each argument
    -- again inside it, so a literal quote reaches here as '\''. Collapse those
    -- to a placeholder before splitting, then take the argument after `json`.
    local flat = command:gsub("'\\''", "\1")
    local query = flat:match("json%s+\1(.-)\1") or ""
    SIM.lastQuery = query
    -- Deferred mode keeps the read "in flight" so the queueing path is
    -- reachable: a filter click during a read used to be dropped silently.
    local finish = function()
      SIM.decoded = helperSearch(query)
      callback({ exitCode = 0, stdout = "{}", stderr = "" })
    end
    if SIM.deferred then
      table.insert(SIM.pending, finish)
    else
      finish()
    end
    return true
  end,
}
