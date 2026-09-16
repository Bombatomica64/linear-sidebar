--!nonstrict
-- Thin bar button. Left click opens the browser panel, middle click refreshes
-- the cached list, right click triggers a Linear sync. All work happens in
-- service.luau; this entry only reads `linear_status`.

local PANEL_ID = "lollo/linear:browser"

local status = noctalia.state.get("linear_status")
  or { issueCount = 0, projectCount = 0, loading = false, syncing = false, error = "" }

local function send(action)
  noctalia.state.set("linear_command", {
    action = action,
    requestId = tostring(noctalia.nowMs()),
  })
end

local function render()
  local hasError = noctalia.string.trim(tostring(status.error or "")) ~= ""
  local busy = status.loading == true or status.syncing == true
  local color = "on_surface"
  if hasError then
    color = "error"
  elseif busy then
    color = "tertiary"
  elseif (tonumber(status.issueCount) or 0) > 0 then
    color = "primary"
  end

  local children = {
    ui.glyph({ name = "git-branch", size = 16, color = color }),
  }
  if status.syncing == true then
    table.insert(children, ui.box({ width = 7, height = 7, radius = 4, fill = "tertiary" }))
  end

  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 5, align = "center" }, children))

  if hasError then
    barWidget.setTooltip(noctalia.tr("widget.error", { error = tostring(status.error) }))
  else
    barWidget.setTooltip(noctalia.tr("widget.tooltip", {
      issues = tostring(tonumber(status.issueCount) or 0),
      projects = tostring(tonumber(status.projectCount) or 0),
    }))
  end
end

noctalia.state.watch("linear_status", function(value)
  if type(value) == "table" then
    status = value
    render()
  end
end)

render()

function update()
  render()
end

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

function onRightClick()
  send("sync")
end

function onMiddleClick()
  send("refresh")
end
