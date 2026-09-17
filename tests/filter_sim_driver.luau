--!nonstrict
-- Asserts what each filter combination actually publishes, against the rows in
-- tests/fixtures.luau (a real dump of the local cache).


local dispatch = SIM.watchers["linear_command"]

local function search(query, view, status)
  dispatch({ action = "search", query = query, view = view, status = status })
  return SIM.published["linear_results"]
end

local failures = 0
local function check(name, ok, detail)
  if ok then
    print(`ok   {name}`)
  else
    failures += 1
    print(`FAIL {name}: {detail or ""}`)
  end
end

local function every(list, predicate)
  for _, item in ipairs(list) do
    if not predicate(item) then
      return false
    end
  end
  return true
end

local lower = function(value) return tostring(value or ""):lower() end

-- 1. A status filter alone narrows to that priority or state.
local r = search("", "All", "Urgent")
check("status alone returns only Urgent rows",
  #r.issues > 0 and every(r.issues, function(i) return lower(i.priority) == "urgent" end),
  `{#r.issues} issues`)
check("status alone pushes the term down to the helper", SIM.lastQuery == "Urgent", SIM.lastQuery)
check("status alone drops projects", #r.projects == 0, `{#r.projects} projects`)

-- 2. The regression: free text + status used to OR into 72 rows. It must now be
-- the intersection, and the helper must see the free text only.
local text = search("coupon", "All", "All")
local textCount = #text.issues
local both = search("coupon", "All", "Urgent")
-- The fixture has 3 coupon issues, 2 of them Urgent, and 2 Urgent issues that
-- are not about coupons. The union the old query produced was 4; the answer is 2.
check("free text + status is an intersection, not a union",
  textCount == 3 and #both.issues == 2,
  `text {textCount}, both {#both.issues}, expected 3 and 2`)
check("free text is not polluted with the filter term", SIM.lastQuery == "coupon", SIM.lastQuery)

-- 3. My Issues filters by assignee rather than OR-ing the name into the query.
SIM.config.my_name = "Lorenzo Micheli"
local mine = search("", "My Issues", "All")
check("My Issues returns only my rows",
  #mine.issues > 0 and every(mine.issues, function(i)
    return lower(i.assignee):find("lorenzo micheli", 1, true) ~= nil
  end),
  `{#mine.issues} issues`)
check("My Issues excludes projects", #mine.projects == 0, `{#mine.projects} projects`)

-- 4. The combination v4 could not express at all.
local mineUrgent = search("", "My Issues", "Urgent")
check("My Issues + Urgent intersects both",
  every(mineUrgent.issues, function(i)
    return lower(i.priority) == "urgent" and lower(i.assignee):find("lorenzo micheli", 1, true) ~= nil
  end),
  `{#mineUrgent.issues} issues`)
check("My Issues + Urgent is a subset of My Issues", #mineUrgent.issues <= #mine.issues,
  `{#mineUrgent.issues} <= {#mine.issues}`)

-- 5. An unset name must not silently filter by a stranger, the way v4's
-- "first assignee in the result set" fallback did.
SIM.config.my_name = ""
local unnamed = search("", "My Issues", "All")
check("My Issues with no configured name shows every issue", #unnamed.issues > 0, `{#unnamed.issues}`)
check("My Issues with no configured name raises the hint", unnamed.needsMyName == true)

-- 6. Projects view returns projects and nothing else.
local projects = search("", "Projects", "All")
check("Projects view returns projects", #projects.projects > 0, `{#projects.projects}`)
check("Projects view returns no issues", #projects.issues == 0, `{#projects.issues}`)

-- 7. A filter change while a read is in flight must not be dropped. The guard
-- that stopped concurrent reads used to drop the newer request outright, which
-- is what clicking two filters in quick succession looked like.
SIM.config.my_name = "Lorenzo Micheli"
SIM.deferred = true
SIM.pending = {}
dispatch({ action = "search", query = "", view = "All", status = "Urgent" })
dispatch({ action = "search", query = "", view = "My Issues", status = "All" })
check("the second read is queued, not run concurrently", #SIM.pending == 1, `{#SIM.pending}`)
SIM.flushOne()
check("finishing the first read starts the queued one", #SIM.pending == 1, `{#SIM.pending}`)
SIM.flushOne()
local queued = SIM.published["linear_results"]
check("the queued filter is the one that lands",
  #queued.issues > 0 and every(queued.issues, function(i)
    return lower(i.assignee):find("lorenzo micheli", 1, true) ~= nil
  end),
  `{#queued.issues} issues`)
check("no read is left hanging", #SIM.pending == 0, `{#SIM.pending}`)
SIM.deferred = false

if failures > 0 then
  error(`{failures} check(s) failed`, 0)
end
print("all checks passed")
