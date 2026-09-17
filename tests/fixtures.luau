--!nonstrict
-- Synthetic rows in the exact shape linear-cache.py's `json` command emits.
-- Deliberately not a dump of the real cache: this repo is public, and the
-- filters only care about state/priority/assignee/kind, not about real titles.
--
-- Shaped so the interesting cases exist: an issue that matches "coupon" but is
-- not Urgent (the union bug counted it), an Urgent issue that has nothing to do
-- with coupons (the union bug counted that too), and an Urgent coupon issue
-- assigned to someone else (so "My Issues + Urgent" has something to exclude).

SIM.rows = {
  issues = {
    { kind = "issue", id = "i1", identifier = "DEV-1", title = "Coupon feed drops rows",
      state = "In Progress", priority = "Urgent", assignee = "Lorenzo Micheli", project = "Coupons", team = "DEV" },
    { kind = "issue", id = "i2", identifier = "DEV-2", title = "Coupon import is slow",
      state = "Backlog", priority = "Medium", assignee = "Lorenzo Micheli", project = "Coupons", team = "DEV" },
    { kind = "issue", id = "i3", identifier = "DEV-3", title = "Coupon expiry off by one",
      state = "Todo", priority = "Urgent", assignee = "Saverio Mucci", project = "Coupons", team = "DEV" },
    { kind = "issue", id = "i4", identifier = "DEV-4", title = "Checkout returns 500",
      state = "In Review", priority = "Urgent", assignee = "Lorenzo Micheli", project = "Checkout", team = "DEV" },
    { kind = "issue", id = "i5", identifier = "DEV-5", title = "Rewrite the importer",
      state = "Backlog", priority = "High", assignee = "Carlos Sarmiento", project = "Checkout", team = "DEV" },
    { kind = "issue", id = "i6", identifier = "DEV-6", title = "Drop the legacy table",
      state = "Done", priority = "No priority", assignee = "", project = "Platform", team = "DEV" },
    { kind = "issue", id = "i7", identifier = "MBI-1", title = "Refresh the nightly export",
      state = "Todo", priority = "Medium", assignee = "Lorenzo Micheli", project = "Platform", team = "MBI" },
  },
  projects = {
    { kind = "project", id = "p1", name = "Coupons", state = "started", teams = "DEV" },
    { kind = "project", id = "p2", name = "Checkout", state = "planned", teams = "DEV" },
    { kind = "project", id = "p3", name = "Platform", state = "completed", teams = "DEV, MBI" },
  },
}
