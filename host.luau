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

-- The filter and the auto flag, which a key handler cannot store in the state
-- table it was handed.
local PREF_KEY = "prefs"

local FILTER_ALL = "all"
local FILTER_OMP = "omp"
local FILTER_OTHER = "other"

local FILTERS = { FILTER_ALL, FILTER_OMP, FILTER_OTHER }

local FILTER_LABELS = {
	[FILTER_ALL] = "all",
	[FILTER_OMP] = "omp-launched",
	[FILTER_OTHER] = "not omp",
}

-- The stored preferences, with a default for anything absent. Both init and
-- view read through here: a preference the view never looks up is a
-- preference only a restart can show.
local function readPrefs()
	local prefs = tern.kv.get(PREF_KEY)
	if type(prefs) ~= "table" then
		prefs = {}
	end
	if
		prefs.filter ~= FILTER_ALL
		and prefs.filter ~= FILTER_OMP
		and prefs.filter ~= FILTER_OTHER
	then
		prefs.filter = FILTER_ALL
	end
	if type(prefs.auto) ~= "boolean" then
		prefs.auto = true
	end
	return prefs
end

local function writePrefs(filter, auto)
	tern.kv.set(PREF_KEY, { filter = filter, auto = auto })
end

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

-- tern.process.run has two shapes: without a callback it returns an
-- Awaitable, which in a plugin VM is not a value to read but a handle to wait
-- on. A block is host-side, so the callback form is the one that hands back a
-- ProcessResult. Taking the return value directly is what made the block exit
-- 1 with no rows.
--
-- Everything is read defensively as well: a run that never started reports
-- neither status nor streams, and a scan that cannot describe its own failure
-- must still render.
local function describe(detail)
	if #detail > 300 then
		return detail:sub(1, 300) .. "..."
	end
	return detail
end

local function collect(done)
	tern.process.run(PROBE, { timeout_ms = PROBE_TIMEOUT_MS }, function(result, _cx)
		if type(result) ~= "table" then
			done({}, "probe returned no result")
			return
		end

		local stdout = type(result.stdout) == "string" and result.stdout or ""
		local stderr = type(result.stderr) == "string" and result.stderr or ""

		if result.timed_out then
			done({}, ("probe timed out after %dms"):format(PROBE_TIMEOUT_MS))
			return
		end

		local status = result.status
		if type(status) ~= "number" then
			local detail = stderr
			if #detail == 0 then
				detail = stdout
			end
			done({}, "probe produced no exit status" .. (#detail > 0 and (": " .. describe(detail)) or ""))
			return
		end

		if status ~= 0 then
			local detail = stderr
			if #detail == 0 then
				detail = stdout
			end
			done({}, ("probe exited %d"):format(status) .. (#detail > 0 and (": " .. describe(detail)) or ""))
			return
		end

		local rows, err = parse(stdout)
		done(rows or {}, err)
	end)
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

-- Reading another process's working directory needs VM_READ, so it works for
-- processes this user owns and returns nothing for the rest. That used to fall
-- back to the process name, which made this column a copy of PROCESS with a
-- suffix on it — repetition reading as data. A dash says the answer is missing;
-- why it is missing is the note's job.
local function projectOf(row)
	if type(row.cwd) == "string" and row.cwd ~= "" then
		return row.cwd
	end
	return "-"
end

-- The image directory is a guess, so the row says so instead of presenting an
-- install path as the service's project.
local function cwdNote(row)
	if type(row.cwdSource) == "string" and row.cwdSource == "image" then
		return " (install dir, guessed)"
	end
	if type(row.cwd) == "string" and row.cwd == "" then
		return " (needs admin)"
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
		rows = state.rows,
		version = version,
		at = os and os.time and os.time() or 0,
	})
end

-- The probe is asynchronous, so a scan resolves later and the state is filled
-- in then. A scan still running leaves the previous rows visible rather than
-- blanking the table, so a refresh does not flicker.
local function scan(state)
	state.pending = #(state.rows or {}) == 0
	collect(function(rows, err)
		state.rows = rows
		state.error = err
		state.pending = false
		state.scannedAt = os and os.time and os.time() or 0
		publishSummary(state)
	end)
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


-- The keys, on one line, wherever the block is showing rows or not. They used
-- to live only in the dock and in the empty-table message, which left a block
-- full of ports with no way to discover any of them.
local function hints(state)
	return ("f filter  ·  r rescan  ·  a auto %s"):format(state.auto and "on" or "off")
end

local function header(state)
	local rows = visibleRows(state)
	local filter = FILTER_LABELS[state.filter] or state.filter

	-- Counts come from the summary the scan published, not from the row list:
	-- the rows themselves never reach this state table, but the summary does.
	local omp = state.omp or 0
	local self_ = state.ompInternal or 0
	local total = state.total or 0
	local services = math.max(total - omp - self_, 0)

	local parts = {}
	if state.pending then
		table.insert(parts, "scanning")
	else
		table.insert(parts, ("%d listening"):format(total))
	end
	table.insert(parts, ("filter %s"):format(filter))

	if not state.pending then
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
	end

	local text = table.concat(parts, "  ·  ")
	if state.error then
		text ..= "   " .. state.error
	end
	return { text, "", hints(state) }
end

-- Returns a list of nodes either way: tern.ui.col walks numeric keys, so a
-- branch that returned `{ text = ... }` would silently lose its siblings.
local function tableView(state)
	local rows = visibleRows(state)

	if #rows == 0 then
		local message = if state.error
			then "scan failed — see the header for the probe's own message"
			elseif state.pending
				then "scanning…"
				elseif #(state.rows or {}) == 0
					then "nothing is listening"
					else "no row matches this filter"
		return { tern.ui.text({ message }) }
	end

	-- The lowest priority hides first, so the two numbers the table is read for
	-- carry the highest and are never dropped. They still truncate when
	-- everything is on screen and nothing is left to give — so everything else
	-- is droppable, and in the order that costs least: SOURCE first, because
	-- "system" repeated down a column says least about any single row; then
	-- the project path, which is the longest text on the row.
	--
	-- grow gives the numbers a wide share, because a visible column still cuts
	-- 60825 to "608…" when it is the one that ran out of room.
	local cols = {
		{ id = "port", head = "PORT", align = "end", grow = 6, priority = 60 },
		{ id = "pid", head = "PID", align = "end", grow = 6, priority = 60 },
		{ id = "proc", head = "PROCESS", grow = 4, priority = 30 },
		{ id = "addr", head = "ADDRESS", grow = 4, priority = 30 },
		{ id = "project", head = "PROJECT / CWD", grow = 3, priority = 10 },
		{ id = "source", head = "SOURCE", grow = 1, priority = 0 },
	}

	-- Keyed by column id and filled in column order, because a table pairs
	-- positionally: reordering cols without reordering the cells put the
	-- address under PROCESS and the pid under ADDRESS, and every row read as a
	-- plausible lie.
	local function cellsFor(row)
		local source = if isOmpSelf(row)
			then "omp internal"
			elseif row.omp == true
				then "omp"
				else "system"

		return {
			port = { tern.ui.span(tostring(row.port), "key") },
			-- { t, tone } is the span shape; a bare second element is another
			-- span, which rendered the literal word "muted" after the address.
			addr = { tern.ui.span(addrOf(row), "muted") },
			source = { tern.ui.span(source, "muted") },
			proc = row.proc ~= "" and row.proc or "(gone)",
			pid = { tern.ui.span(tostring(row.pid), "muted") },
			project = { projectOf(row) .. cwdNote(row) },
		}
	end

	local cells = {}
	for _, row in ipairs(rows) do
		local byId = cellsFor(row)
		local ordered = {}
		for _, col in ipairs(cols) do
			table.insert(ordered, byId[col.id])
		end
		table.insert(cells, ordered)
	end

	return {
		tern.ui.table(cols, cells),
	}
end

-- A region's value must be a Node, so the dock is a text node rather than a
-- bare table: a table with a `text` key is not a node and drew nothing.
local function dockView(state)
	-- Only keys that are implemented. o and k were advertised here for a
	-- while with nothing behind them: opening a port and ending a process are
	-- both worth having, and neither should ship as a promise.
	return tern.ui.text({
		"",
		("auto %s"):format(state.auto and "on" or "off"),
	})
end

-- The manifest declares one kind per view, and cx:new_block only finds kinds
-- the manifest declares, so the omp-only view needs its own kind here rather
-- than an argument to the plain one. Both share this definition: the only
-- difference is the filter init starts on.
local function definePorts(initialFilter)
	return {
		init = function(cx, args, _saved)
			-- An argument wins, then the kind's own filter, then the stored
			-- one: the omp-only kind has to land on its filter whatever the
			-- last session left behind, or opening it shows the plain view.
			local filter = args and args[1] or nil
			local prefs = readPrefs()
			if filter == nil then
				filter = initialFilter or prefs.filter
			end
			-- An argument is a caller-supplied string, so it gets the same check
			-- readPrefs applies: a typo must fall back to all, not become a
			-- filter that matches nothing.
			if filter ~= FILTER_ALL and filter ~= FILTER_OMP and filter ~= FILTER_OTHER then
				filter = FILTER_ALL
			end
			local auto = prefs.auto

			-- Publish the choice, because view reads the preferences from here and
			-- would otherwise put the stored one back on screen the moment the
			-- block first drew.
			if prefs.filter ~= filter or prefs.auto ~= auto then
				writePrefs(filter, auto)
			end

			-- init returns synchronously and the probe is a two-second child
			-- process, so the scan runs from a timer rather than inline: doing it
			-- inline is what made the block exit 1 before it ever drew.
			--
			-- The callback cannot hand its rows back to this state table — Tern
			-- has already copied what init returned, so a scan resolved into the
			-- local never reached the block. The summary goes to tern.kv instead,
			-- and view reads it back, which is the one path both halves share.
			local state = {
				rows = {},
				filter = filter,
				auto = auto,
				error = nil,
				pending = true,
				version = -1,
				timer = nil,
			}

			tern.timer(1, function()
				scan(state)
				if state.auto then
					refreshTimer(state)
				end
			end)

			return state
		end,

		-- Tern's view is a pure render: writing state here is not persisted, so
		-- the scan is scheduled from init and the block reads its result back out
		-- of tern.kv, which both halves share and which does survive.
		view = function(state, _cx)
			-- Adopt the newest summary: the scan's callback cannot reach this
			-- state table, but tern.kv is shared by both halves and every window.
			local summary = tern.kv.get(KV_KEY)

			-- The preferences travel the same road, for the same reason: the key
			-- handler can only write to tern.kv, so reading it back here is what
			-- makes f and a do anything without reopening the block.
			--
			-- Only a preference that differs from what is on screen is adopted, so
			-- the filter a launch argument chose is not immediately overridden by
			-- the store the block was opened on top of.
			local prefs = readPrefs()
			if prefs.filter ~= state.filter then
				state.filter = prefs.filter
			end
			if prefs.auto ~= state.auto then
				state.auto = prefs.auto
			end

			if type(summary) == "table" and (summary.version or -1) ~= state.version then
				state.version = summary.version
				state.total = summary.total
				state.omp = summary.omp
				state.ompInternal = summary.ompInternal
				state.error = summary.error
				if type(summary.rows) == "table" then
					state.rows = summary.rows
				end
				state.pending = false
			end

			return {
				main = tern.ui.col({
					-- A section rather than a card: card takes children, and an
					-- empty table there is what left the header with nothing to
					-- draw.
					tern.ui.section(header(state), {}),
					-- tableView returns a list, and col walks numeric keys, so the
					-- nodes have to be spliced in rather than nested.
					table.unpack(tableView(state)),
				}),
				dock = dockView(state),
			}
		end,

		title = function(state)
			return ("Ports  %d listening · %d omp"):format(state.total or 0, state.omp or 0)
		end,

		-- A key handler's writes to `state` do not reach the block either: Tern
		-- copied the table init returned, exactly as the scan's rows were lost.
		-- The filter and the auto flag therefore go through tern.kv, the one
		-- channel both halves share, and init reads them back.
		key = function(state, key, cx)
			-- Every key that changes something re-renders and saves; returning
			-- false would leave a view stale, so there is no false path here.
			if key.name == "f" then
				local nextFilter = FILTER_ALL
				for i, name in ipairs(FILTERS) do
					if name == state.filter then
						nextFilter = FILTERS[i % #FILTERS + 1]
						break
					end
				end
				writePrefs(nextFilter, state.auto)
				return true
			elseif key.name == "r" or key.name == "f5" then
				scan(state)
				return true
			elseif key.name == "a" then
				local auto = not state.auto
				writePrefs(state.filter, auto)
				-- The timer is the one thing the handler can still do directly:
				-- the block's own timer handle is not shared.
				state.auto = auto
				if auto then
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

		-- Preferences already live in tern.kv, so there is nothing to persist
		-- per-block: the returned table would be a second copy that the key
		-- handler's writes never reached.
		save = function(_state)
			return nil
		end,
	}
end

-- The plain view: whatever filter was last in use.
tern.block.define("ports", definePorts(nil))

-- The omp-only view.
tern.block.define("ports-omp", definePorts(FILTER_OMP))
