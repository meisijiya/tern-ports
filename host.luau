-- Ports block: lists the machine's listening TCP ports and marks which of
-- them an omp process started.
--
-- The ancestry comes from the probe, not from a heuristic here. A row whose
-- chain lost an intermediate parent reports omp=false, and the filter says
-- "unattributed" rather than claiming the row is not omp-launched.

local IS_WINDOWS = tern.runtime.os == "windows"

local PROBE = if IS_WINDOWS
	then {
		"powershell.exe",
		"-NoProfile",
		"-NonInteractive",
		"-ExecutionPolicy",
		"Bypass",
		"-File",
		tern.plugin.dir .. "\\scripts\\ports.ps1",
	}
	else { "sh", tern.plugin.dir .. "/scripts/ports.sh" }

local PROBE_TIMEOUT_MS = 20000
local AUTO_REFRESH_MS = 15000

-- Both halves read and write this one key in tern.kv; the window half's status
-- segment has no other way to see what the block found.
local KV_KEY = "last_scan"

local FILTER_ALL = "all"
local FILTER_OMP = "omp"
local FILTER_OTHER = "other"

local FILTERS = { FILTER_ALL, FILTER_OMP, FILTER_OTHER }

local FILTER_LABELS = {
	[FILTER_ALL] = "all",
	[FILTER_OMP] = "omp-launched",
	[FILTER_OTHER] = "not omp",
}

--!strict
local function stripBom(text)
	return (text:gsub("^\239\187\191", ""))
end

-- netstat and ss hard-wrap long rows, which lands a newline inside the JSON
-- array. The probe emits one document, so rejoining the wrapped rows is safe.
local function unwrap(text)
	return (text:gsub("\r\n", "\n"):gsub("\n%s*\n", "\n"))
end

local function parse(text)
	local raw = unwrap(stripBom(text))
	if raw == "" then
		return nil, "probe produced no output"
	end
	local ok, value = pcall(tern.json.decode, raw)
	if not ok then
		return nil, "probe output was not JSON: " .. tostring(value):sub(1, 200)
	end
	if type(value) ~= "table" then
		return nil, "probe produced no rows"
	end
	-- One row decodes to an object keyed by field name; no key means no rows.
	if value.port == nil and value[1] == nil then
		return {}, nil
	end
	return value, nil
end

-- A failed scan is a state the block renders, not a block that fails to open,
-- so collection never raises.
local function collect()
	local result = tern.process.run(PROBE, { timeout_ms = PROBE_TIMEOUT_MS })
	if result.timed_out then
		return {}, ("probe timed out after %dms"):format(PROBE_TIMEOUT_MS)
	end
	if result.status ~= 0 then
		local detail = stripBom(result.stderr or "")
		if #detail == 0 then
			detail = stripBom(result.stdout or "")
		end
		if #detail > 300 then
			detail = detail:sub(1, 300) .. "..."
		end
		local message = ("probe exited %d"):format(result.status)
		if #detail > 0 then
			message ..= ": " .. detail
		end
		return {}, message
	end
	return parse(result.stdout)
end

local function isOmpSelf(row)
	return row.omp == true and row.proc == "omp.exe"
end

-- Three views, because the two questions are different: what did my agents
-- start, and what else on this machine do I maintain. "not omp" keeps
-- databases and tool servers, which are services too.
local function matches(row, filter)
	if filter == FILTER_OMP then
		return row.omp == true and not isOmpSelf(row)
	elseif filter == FILTER_OTHER then
		return row.omp ~= true
	end
	return true
end

local function projectOf(row)
	if type(row.cwd) == "string" and row.cwd ~= "" then
		return row.cwd
	end
	if type(row.proc) == "string" and row.proc ~= "" then
		return row.proc
	end
	return ("pid %s"):format(tostring(row.pid))
end

-- The image directory is a guess, so the row says so instead of presenting an
-- install path as the service's project.
local function cwdNote(row)
	if type(row.cwdSource) == "string" and row.cwdSource == "image" then
		return " (image dir, cwd unreadable)"
	end
	if type(row.cwd) == "string" and row.cwd == "" then
		return " (cwd unreadable)"
	end
	return ""
end

local function ancestryOf(row)
	if type(row.chain) ~= "table" then
		return ""
	end
	return table.concat(row.chain, " < ")
end

local function addrOf(row)
	if row.family == "ipv6" then
		return ("[%s]"):format(tostring(row.addr))
	end
	return tostring(row.addr)
end

-- Both plugin halves share tern.kv, so the counts land where the window
-- half's status segment can read them. The version lets that half notice a
-- change without diffing the counts.
local function publishSummary(state)
	local total, omp, ompInternal = 0, 0, 0
	for _, row in ipairs(state.rows or {}) do
		total += 1
		if isOmpSelf(row) then
			ompInternal += 1
		elseif row.omp == true then
			omp += 1
		end
	end

	local previous = tern.kv.get(KV_KEY)
	local version = (type(previous) == "table" and previous.version or 0) + 1

	-- Not wrapped in pcall on purpose: a swallowed write would leave the status
	-- line showing counts from an older scan, which reads as "nothing changed"
	-- rather than "the summary is broken".
	tern.kv.set(KV_KEY, {
		total = total,
		omp = omp,
		ompInternal = ompInternal,
		error = state.error,
		version = version,
		at = os and os.time and os.time() or 0,
	})
end

local function scan(state)
	local rows, err = collect()
	state.rows = rows
	state.error = err
	state.scannedAt = os and os.time and os.time() or 0
	publishSummary(state)
	return state
end

local function refreshTimer(state)
	-- tern.timer is one-shot; a repeat has to chain itself.
	-- The callback receives a fresh cx, and Tern re-renders the block when its
	-- state changes, so the scan needs no render call of its own. Holding a cx
	-- here would be the classic way to end up using a retired one.
	state.timer = tern.timer(AUTO_REFRESH_MS, function()
		scan(state)
		refreshTimer(state)
	end)
end

local function stopTimer(state)
	if state.timer then
		state.timer:cancel()
		state.timer = nil
	end
end

local function visibleRows(state)
	local out = {}
	for _, row in ipairs(state.rows or {}) do
		if matches(row, state.filter) then
			table.insert(out, row)
		end
	end
	return out
end

local function countBy(state)
	local omp, services, self_ = 0, 0, 0
	for _, row in ipairs(state.rows or {}) do
		if isOmpSelf(row) then
			self_ += 1
		elseif row.omp == true then
			omp += 1
		else
			services += 1
		end
	end
	return omp, services, self_
end

local function header(state)
	local rows = visibleRows(state)
	local omp, services, self_ = countBy(state)
	local filter = FILTER_LABELS[state.filter] or state.filter
	local total = #(state.rows or {})

	local parts = {
		("%d listening"):format(total),
		("filter %s"):format(filter),
	}

	if state.filter ~= FILTER_OMP and omp > 0 then
		table.insert(parts, ("%d omp-launched"):format(omp))
	end
	if state.filter ~= FILTER_ALL and self_ > 0 then
		table.insert(parts, ("%d omp internal"):format(self_))
	end
	if state.filter ~= FILTER_OTHER and services > 0 then
		table.insert(parts, ("%d unattributed"):format(services))
	end
	table.insert(parts, ("showing %d"):format(#rows))

	local text = table.concat(parts, "  ·  ")
	if state.error then
		text ..= "   " .. state.error
	end
	return { text }
end

-- Returns a list of nodes either way: tern.ui.col walks numeric keys, so a
-- branch that returned `{ text = ... }` would silently lose its siblings.
local function tableView(state)
	local rows = visibleRows(state)

	if #rows == 0 then
		local message = if state.error
			then "scan failed — see the header for the probe's own message"
			elseif #(state.rows or {}) == 0
				then "nothing is listening"
				else "no row matches this filter"
		return {
			tern.ui.text({ message, "", "f  filter   r  rescan   a  toggle auto" }),
		}
	end

	local cols = {
		{ id = "port", head = "PORT", align = "end" },
		{ id = "addr", head = "ADDRESS", priority = 2 },
		{ id = "source", head = "SOURCE", priority = 1 },
		{ id = "proc", head = "PROCESS" },
		{ id = "pid", head = "PID", align = "end" },
		{ id = "project", head = "PROJECT / CWD", grow = 2 },
	}

	local cells = {}
	for _, row in ipairs(rows) do
		local source = if isOmpSelf(row)
			then { tern.ui.span("omp internal", "muted") }
			elseif row.omp == true
				then { tern.ui.span("omp", "success") }
				else { tern.ui.span("system", "muted") }

		table.insert(cells, {
			{ tern.ui.span(tostring(row.port), "key") },
			{ addrOf(row), "muted" },
			source,
			row.proc ~= "" and row.proc or "(gone)",
			{ tern.ui.span(tostring(row.pid), "muted") },
			{ projectOf(row) .. cwdNote(row) },
		})
	end

	return {
		tern.ui.table(cols, cells),
	}
end

local function dockView(state)
	return {
		text = {
			"r  rescan",
			"  f  filter",
			"  o  open in browser",
			"  k  end process",
			"  a  toggle auto",
			"",
			("auto %s"):format(state.auto and "on" or "off"),
		},
	}
end

return tern.block.define("ports", {
	init = function(cx, args, _saved)
		local state = {
			rows = {},
			filter = args and args[1] or FILTER_ALL,
			auto = true,
			error = nil,
			timer = nil,
		}
		if state.filter ~= FILTER_OMP and state.filter ~= FILTER_OTHER then
			state.filter = FILTER_ALL
		end

		scan(state)
		if state.auto then
			refreshTimer(state)
		end
		return state
	end,

	view = function(state, _cx)
		return {
			main = tern.ui.col({
				tern.ui.card(header(state), {}),
				-- tableView returns a list, and col walks numeric keys, so the
				-- nodes have to be spliced in rather than nested.
				table.unpack(tableView(state)),
			}),
			dock = dockView(state),
		}
	end,

	title = function(state)
		local omp = countBy(state)
		local total = #(state.rows or {})
		return ("Ports  %d listening · %d omp"):format(total, omp)
	end,

	key = function(state, key, _cx)
		-- Every key that changes something re-renders and saves; returning
		-- false would leave a view stale, so there is no false path here.
		if key.name == "f" then
			for i, name in ipairs(FILTERS) do
				if name == state.filter then
					state.filter = FILTERS[i % #FILTERS + 1]
					break
				end
			end
			return true
		elseif key.name == "r" or key.name == "f5" then
			scan(state)
			return true
		elseif key.name == "a" then
			state.auto = not state.auto
			if state.auto then
				refreshTimer(state)
			else
				stopTimer(state)
			end
			return true
		end

		return true
	end,

	-- Only the view's own selects reach here; a rejected key still counts as
	-- handled so the pane never wedges on an action it cannot perform.
	event = function(state, ev, _cx)
		if ev.ev ~= "action" then
			return
		end
		local act = ev.act
		if act == "rescan" then
			scan(state)
		elseif act == "filter" then
			state.filter = nextFilter(state.filter)
		end
	end,

	resize = function(state, _cols, _rows, _cx)
		-- Tern re-renders on resize by itself; nothing to do but stay valid.
		return
	end,

	save = function(state)
		return { filter = state.filter, auto = state.auto }
	end,
})
