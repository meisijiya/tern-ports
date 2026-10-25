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

-- Half a period: two chains less than this apart must not both probe.
local LEASE_MS = AUTO_REFRESH_MS / 2

-- Both halves read and write this one key in tern.kv; the window half's status
-- segment has no other way to see what the block found.
local KV_KEY = "last_scan"

-- The block's own copy of the summary, for a block that is frozen. The live
-- summary keeps moving for the status segment, and a frozen block shows this
-- one instead.
local BLOCK_KEY = "last_block_scan"

-- The filter and the auto flag, which a key handler cannot store in the state
-- table it was handed.
local PREF_KEY = "prefs"

-- When the last scan ran. A plugin reload leaves the old chain's timer alive,
-- and two chains would probe twice as often; the lease lets one of them
-- through. It has to live in tern.kv, because a module-level variable dies
-- with the reload that reset it.
local LEASE_KEY = "publisher_lease"

local FILTER_ALL = "all"
local FILTER_OMP = "omp"
local FILTER_OTHER = "other"

local FILTERS = { FILTER_ALL, FILTER_OMP, FILTER_OTHER }

local FILTER_LABELS = {
	[FILTER_ALL] = "all",
	[FILTER_OMP] = "omp-launched",
	[FILTER_OTHER] = "not omp",
}

-- The filter cycle, in one place: the key handler and the action have to
-- agree on what the next filter is.
local function nextFilter(filter)
	for i, name in ipairs(FILTERS) do
		if name == filter then
			return FILTERS[i % #FILTERS + 1]
		end
	end
	return FILTER_ALL
end

-- The shared store, read defensively.
--
-- Both plugin halves write this one file, and a write that is interrupted
-- leaves it half-written: the reader then gets a parse error instead of a
-- value. This half is the one that rewrites the file every fifteen seconds,
-- so it can read its own half-written file, and the window half reads the
-- same file while the write is in flight.
--
-- The second return says whether the read worked: false means the store
-- raised, true means it answered, with a value or with nothing. A failed read
-- is not a fact, so each caller decides what it means; what no caller may do
-- is let it escape, because an exception in the middle of a scan leaves the
-- publisher half-published and takes the chain down with it.
local function readStored(key)
	local ok, value = pcall(tern.kv.get, key)
	if not ok then
		return nil, false
	end
	return value, true
end

-- The stored preferences, with a default for anything absent. Both init and
-- view read through here: a preference the view never looks up is a
-- preference only a restart can show.
--
-- A store that cannot be read leaves the defaults in place. init runs while
-- the plugin loads, and a raise there would take the whole plugin down over a
-- preference that has a perfectly good default.
local function readPrefs()
	local prefs = readStored(PREF_KEY)
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

-- The shared publisher.
--
-- The window half's status segment reads the summary this publishes, and it
-- has no block of its own to read from. A scan that belonged to a block died
-- with the block, and the segment went silent ninety seconds later, once the
-- summary passed the window half's TTL. So the scan belongs to the host
-- half, and a block is only one of its readers.
local publisher = {
	rows = {},
	error = nil,
	pending = false,
	scannedAt = 0,
	version = -1,
	timer = nil,
}

-- The clock is the only thing that ages a summary, and a test may freeze it.
local function nowSeconds()
	return os and os.time and os.time() or 0
end

-- The counts both halves show: everything listening, the omp processes among
-- them, and the omp processes this host started itself.
local function countRows(rows)
	local total, omp, ompInternal = 0, 0, 0
	for _, row in ipairs(rows or {}) do
		total += 1
		if isOmpSelf(row) then
			ompInternal += 1
		elseif row.omp == true then
			omp += 1
		end
	end
	return total, omp, ompInternal
end

-- Both plugin halves share tern.kv, so the counts land where the window
-- half's status segment can read them. The version lets that half notice a
-- change without diffing the counts.
local function publishSummary(state)
	local total, omp, ompInternal = countRows(state.rows)

	-- The previous version is what tells the window half that the summary
	-- changed. A read that failed says nothing about it, so the state
	-- advances its own version instead: the number only has to move forward
	-- for a reader to notice that something was published.
	local previous, ok = readStored(KV_KEY)
	local version
	if ok then
		local last = 0
		if type(previous) == "table" and type(previous.version) == "number" then
			last = previous.version
		end
		version = last + 1
	else
		version = math.max(state.version or 0, 0) + 1
	end

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
		at = nowSeconds(),
	})

	-- The state keeps the version it published, so a later reader can tell
	-- which summary this state stands for.
	state.version = version
end

-- The block's own copy of the summary.
--
-- While the block follows the scan it shows the live summary. While it is
-- frozen it shows this copy, which the freeze took and only a manual rescan
-- moves. A time-stamped rule could not tell the two apart: an automatic
-- publish overwrites the summary a manual rescan wrote, and by the time the
-- block drew, the marker that said "manual" was gone.
local function publishBlockCopy()
	-- A store that cannot be read counts as no live summary: the copy is
	-- then taken from the publisher's own rows, which is what the live
	-- summary would have said anyway.
	local summary = readStored(KV_KEY)
	if type(summary) ~= "table" then
		-- A block frozen before the first scan has no live summary to copy.
		-- The publisher's own rows are the closest thing to the counts it
		-- had; the live summary is left alone, because the window half reads
		-- it and must not see a summary nobody scanned for.
		local total, omp, ompInternal = countRows(publisher.rows)
		summary = {
			total = total,
			omp = omp,
			ompInternal = ompInternal,
			error = publisher.error,
			rows = publisher.rows,
			version = (publisher.version or 0) + 1,
			at = nowSeconds(),
		}
	end
	tern.kv.set(BLOCK_KEY, summary)
end

-- The probe is asynchronous, so a scan resolves later and the state is filled
-- in then. A scan still running leaves the previous rows visible rather than
-- blanking the table, so a refresh does not flicker.
--
-- A manual scan is the one that moves a frozen block: the person at the
-- keyboard asked for it, so it updates the block's copy of the summary as
-- well as the live one.
local function scan(state, manual)
	-- The pending flag says a probe is running, not that there are no rows
	-- yet. It used to mean the latter, which made it true only for the very
	-- first scan: the block said "scanning" once and then never again, and
	-- nothing could tell a running probe from a finished one.
	state.pending = true
	collect(function(rows, err)
		state.rows = rows
		state.error = err
		state.pending = false
		state.scannedAt = nowSeconds()
		publishSummary(state)
		-- The block's copy is what a frozen block shows, so a manual scan has
		-- to write it. A first publish fills it in as well: a block that
		-- opened with no copy would wait for a scan that never came.
		--
		-- A store that cannot be read counts as no copy: writing one is a
		-- write, and a copy one round old beats no copy at all.
		if manual or type(readStored(BLOCK_KEY)) ~= "table" then
			publishBlockCopy()
		end
	end)
end

-- When the last scan ran, in tern.kv, because a plugin reload leaves the
-- previous chain's timer alive: two chains would probe twice as often.
local function takeLease()
	tern.kv.set(LEASE_KEY, nowSeconds())
end

-- A lease that cannot be read is no lease: the round goes ahead. Probing
-- twice costs a child process, while refusing to probe because the store is
-- broken would stop the publisher, and the status segment with it.
local function leaseBlocks()
	local lease = readStored(LEASE_KEY)
	if type(lease) ~= "number" then
		return false
	end
	return (nowSeconds() - lease) * 1000 < LEASE_MS
end

-- A round the lease holds back is not a failure: the other chain is already
-- doing the work, and this one still has to keep its own chain alive.
local function tryScan(state)
	if leaseBlocks() then
		state.pending = false
		return false
	end
	takeLease()
	scan(state)
	return true
end

-- A manual scan: the lease does not hold it back. The lease keeps two
-- automatic chains from doubling the probe rate; it does not overrule the
-- person at the keyboard.
local function manualScan()
	-- The manual scan runs from a key handler and from an action, and an
	-- exception there would escape into Tern's own handling: the block would
	-- stop answering keys, with nothing on screen to say why.
	local ok, err = pcall(function()
		takeLease()
		scan(publisher, true)
	end)
	if not ok then
		tern.log.warn("ports: the manual scan failed: " .. tostring(err))
	end
end

local function stopTimer(state)
	if state.timer then
		state.timer:cancel()
		state.timer = nil
	end
end

-- The 15-second chain, self-chained because tern.timer is one-shot.
--
-- The chain belongs to the publisher, not to a block: a chain scoped to a
-- block stops when the block closes, and the status segment needs the scan
-- to outlive the block. It runs whatever the auto flag says, because the
-- auto flag is the block's — it says whether the block follows the scan, not
-- whether the scan happens.
--
-- The callback receives a fresh cx, and Tern re-renders the block when its
-- state changes, so the scan needs no render call of its own. Holding a cx
-- here would be the classic way to end up using a retired one.
local function refreshTimer(state)
	-- A second chain would probe twice as often, so an existing one is
	-- dropped before a new one is armed.
	stopTimer(state)
	state.timer = tern.timer(AUTO_REFRESH_MS, function()
		state.timer = nil
		-- This chain is the status segment's only lifeline: a raise here
		-- would skip the re-arm below and stop the chain for good, and the
		-- segment would go quiet once the summary aged out. The probe spawns
		-- a child process and the store is shared, so either can raise, and
		-- a failed round is a fault to report rather than a reason to stop.
		local ok, err = pcall(tryScan, state)
		if not ok then
			tern.log.warn("ports: a scan round failed: " .. tostring(err))
		end
		refreshTimer(state)
	end)
end

-- The publisher's work unit: a scan, and the chain that keeps it going.
--
-- The scan runs from a timer because the probe is a child process, and a
-- module that spawns one while it loads can be turned down by the host's
-- load budget.
local function publisherTick()
	-- The entry's first round and the block's request both come through here,
	-- so the guard has to sit here as well as in the chain: a raise from the
	-- entry's timer would leave the publisher with no chain at all.
	local ok, err = pcall(tryScan, publisher)
	if not ok then
		tern.log.warn("ports: the publisher tick failed: " .. tostring(err))
	end
	refreshTimer(publisher)
end

-- The block asks for a scan rather than making one: the publisher owns the
-- probe, the chain and the lease, and a block with a chain of its own would
-- double the probe rate every time one was opened.
local function requestScan()
	publisher.pending = true
	tern.timer(1, publisherTick)
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
--
-- "auto" here means that this block follows the scan. It does not mean the
-- scan runs or stops: the publisher always scans, so that the status segment
-- has fresh counts whether or not a block is open.
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
			--
			-- The block owns no scan of its own: it asks the publisher for one.
			-- The rows, the error and the pending flag are the publisher's, and
			-- the view reads them from it on every draw.
			--
			-- They used to be looked up through this table's metatable, which
			-- was wrong twice over: the view wrote the same three keys when it
			-- adopted a summary, so the metatable was never asked again and
			-- the publisher's pending flag stopped reaching the block; and
			-- Tern copies what init returned, so a copy has no metatable at
			-- all, and the block would show "nothing is listening" instead of
			-- "scanning" while the first probe ran.
			local state = {
				filter = filter,
				auto = auto,
				version = -1,
			}

			-- The request goes through a timer for the same reason the scan
			-- does: init has to return before a child process is started.
			requestScan()

			return state
		end,

		-- Tern's view is a pure render: writing state here is not persisted, so
		-- the scan is scheduled from init and the block reads its result back out
		-- of tern.kv, which both halves share and which does survive.
		--
		-- Everything the block shows is therefore recomputed on every draw from
		-- the store and from the publisher, and written into the state table
		-- afterwards for whoever reads it next.
		view = function(state, _cx)
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

			-- Adopt the newest summary: the scan's callback cannot reach this
			-- state table, but tern.kv is shared by both halves and every window.
			--
			-- A block that follows the scan reads the live summary. A frozen one
			-- reads its own copy, which only a manual rescan moves: the live
			-- summary has to keep moving for the status segment, and a rule that
			-- compared timestamps could not tell a manual publish from an
			-- automatic one once the later of them had overwritten the other.
			--
			-- The read is guarded for the same reason the publisher's reads are:
			-- this half rewrites the store every fifteen seconds, so a read can
			-- land on a half-written file and raise. A failed read says nothing
			-- about the scan, so the block keeps what it has instead of
			-- blanking itself.
			local summary, readOk = readStored(state.auto and KV_KEY or BLOCK_KEY)

			-- The rows and the error come from the summary when there is one,
			-- and from the publisher when there is not: the first scan has not
			-- published anything yet, and the publisher already knows what it
			-- found.
			local rows = publisher.rows
			local scanError = publisher.error

			if readOk and type(summary) == "table" then
				if type(summary.rows) == "table" then
					rows = summary.rows
				end
				scanError = summary.error
				state.version = summary.version
				state.total = summary.total
				state.omp = summary.omp
				state.ompInternal = summary.ompInternal
			end

			-- The pending flag is the publisher's, and only while this block
			-- follows the scan: the publisher is the one that knows a probe is
			-- running, and the block says "scanning" while it runs. A frozen
			-- block does not follow the scan, so it has nothing to be scanned
			-- for and keeps its counts.
			state.pending = state.auto and publisher.pending or false
			state.rows = rows
			state.error = scanError

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
				writePrefs(nextFilter(state.filter), state.auto)
				return true
			elseif key.name == "r" or key.name == "f5" then
				-- A manual scan moves the block's copy of the summary as well
				-- as the live one, so a frozen block still shows fresh counts.
				manualScan()
				return true
			elseif key.name == "a" then
				local auto = not state.auto
				-- Freezing takes a copy of the live summary, so the block keeps
				-- the counts it had at the moment it was frozen. The publisher
				-- keeps running either way: the auto flag says whether this
				-- block follows the scan, not whether the scan happens, and the
				-- status segment reads the live summary.
				if not auto then
					publishBlockCopy()
				end
				writePrefs(state.filter, auto)
				state.auto = auto
				return true
			end

			return true
		end,

		-- Only the view's own selects reach here; a rejected key still counts as
		-- handled so the pane never wedges on an action it cannot perform.
		--
		-- Nothing in the view emits an action today — the header's keys are
		-- the block's key handler, not selects — so these two paths are the
		-- block's action surface and are reached programmatically.
		event = function(state, ev, _cx)
			if ev.ev ~= "action" then
				return
			end
			local act = ev.act
			if act == "rescan" then
				manualScan()
			elseif act == "filter" then
				-- The same thing the f key does. The filter lives in the shared
				-- store, because a write to this table does not reach the block
				-- and the view puts the stored one back on screen: a local
				-- write alone looked like it worked and was undone by the next
				-- draw.
				local filter = nextFilter(state.filter)
				writePrefs(filter, state.auto)
				state.filter = filter
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

-- The host entry: the publisher starts by itself, with no block open.
--
-- The window half's status segment reads the summary the publisher writes,
-- and it lives in a window where no block was ever opened, so the scan
-- cannot depend on one. A scan that belonged to a block died with the block,
-- and the segment went quiet ninety seconds later, once the summary passed
-- the window half's TTL.
--
-- The first scan is armed on a timer rather than run inline: the probe is a
-- child process, and a module that spawns one while it loads can be turned
-- down by the host's load budget.
tern.timer(1, publisherTick)
