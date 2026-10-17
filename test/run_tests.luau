-- Runs host.luau's logic outside Tern.
--
-- The stub reproduces the one rule that a real test must not paper over: a
-- cx is valid only during the call that produced it, and every await retires
-- it. A stub that keeps cx alive would hide exactly the bug this guards.
--
--   wsl -e bash -lc "cd <repo> && ./luau test/run_tests.luau"


-- ---------------------------------------------------------------- stub ----

local JSON_ARRAY = { __jsonarray = true }

local violations = {}
local renders = 0
local toasts = {}
local processCalls = {}
local kvStore = {}

-- Retiring a cx is normal: every await does it. What is a defect is a block
-- that *reads* a cx after its own await retired it, so retirements are
-- counted for reporting and uses are counted as violations.
local retirements = 0
local liveCx = { alive = true }

local function retireCx()
	liveCx.alive = false
	retirements += 1
	liveCx = { alive = true }
	return liveCx
end

local function makeCx(kind)
	local cx = { kind = kind, alive = true }
	function cx:render()
		if not self.alive then
			table.insert(violations, "render through a retired cx in " .. kind)
			error("cx used after destruction in " .. kind, 0)
		end
		renders += 1
	end
	function cx:save()
		if not self.alive then
			table.insert(violations, "save through a retired cx in " .. kind)
			error("cx used after destruction in " .. kind, 0)
		end
	end
	function cx:toast(level, text, sub)
		if not self.alive then
			table.insert(violations, "toast through a retired cx in " .. kind)
			error("cx used after destruction in " .. kind, 0)
		end
		table.insert(toasts, { level = level, text = text, sub = sub })
	end
	function cx:copy(text)
		if not self.alive then
			error("cx used after destruction in " .. kind, 0)
		end
	end
	function cx:open(target)
		if not self.alive then
			error("cx used after destruction in " .. kind, 0)
		end
	end
	cx.pane = 7
	cx.cwd = "D:/work"
	cx.cols = 100
	cx.rows = 30
	cx.exit = function()
		cx.exited = true
	end
	return cx
end

-- Live cx for whichever call is currently on the stack.
local currentCx = makeCx("current")

local function guard(cx, label)
	return setmetatable(cx, {
		__index = function(t, k)
			local v = rawget(t, k)
			if v ~= nil then
				return v
			end
			if not rawget(cx, "alive") then
				table.insert(violations, ("read %s.%s after await"):format(label, tostring(k)))
				error(("stale cx read of %s.%s (%s)"):format(label, tostring(k), "after await"), 0)
			end
			return rawget(currentCx, k)
		end,
	})
end

-- process.run result the tests control.
local processResult = nil
local raiseNextRun = false

-- Forward declarations: the kv stub is built before the parser exists.
local decode, encodeJson

-- Set while a test wants kv to behave like the real one, which writes JSON
-- and hands back a copy.
local jsonRoundTrip = false

tern = {
	runtime = { os = "windows", jit = false },
	plugin = { id = "tern-ports", dir = ".", data = "." },

	process = {
		-- Two shapes, like the real API: with a callback the result arrives in
		-- it, without one an Awaitable handle comes back that is not a
		-- ProcessResult. A stub that only knew the second shape would let the
		-- block read a handle's fields and think the probe produced nothing.
		run = function(argv, opts, cb)
			if type(opts) == "function" then
				cb = opts
				opts = nil
			end
			table.insert(processCalls, { argv = argv, opts = opts })

			if raiseNextRun then
				raiseNextRun = false
				retireCx()
				if cb then
					currentCx = makeCx("process-callback")
					cb(nil, currentCx)
					return
				end
				error("the program could not be started", 0)
			end

			retireCx()
			local result = processResult or { status = 0, stdout = "[]", stderr = "", timed_out = false }
			currentCx = makeCx("process-callback")
			if cb then
				cb(result, currentCx)
				return
			end
			return { kind = "process", id = 1, __awaitable = true }
		end,
	},

	-- Real tern.kv stores JSON on disk, so a value handed back is a copy, not
	-- the same table. Tests that need that honesty set __jsonRoundTrip.
	kv = {
		get = function(key)
			local value = kvStore[key]
			if jsonRoundTrip and type(value) == "table" then
				return decode(encodeJson(value))
			end
			return value
		end,
		set = function(key, value)
			if jsonRoundTrip and type(value) == "table" then
				kvStore[key] = decode(encodeJson(value))
				return
			end
			kvStore[key] = value
		end,
	},

	json = {
		-- Replaced below by a real parser: Luau has no JSON literal syntax, so
		-- loadstring would fail exactly where the block decodes.
		decode = function()
			error("json.decode stub was not installed")
		end,
		-- An empty Lua table encodes as an object; tagging it keeps `[]` a
		-- list on the way out, which is what the parser needs for arrays. The
		-- marker lives in a shared table rather than at index 0 so it never
		-- shows up in a length or an ipairs walk.
		array = function()
			return setmetatable({}, JSON_ARRAY)
		end,
		null = setmetatable({}, {
			__tostring = function()
				return "null"
			end,
		}),
	},

	timer = {
		cancel = function() end,
	},

	log = {
		debug = function() end,
		info = function() end,
		warn = function() end,
		error = function() end,
	},
}

local timerQueue = {}
function tern.timer(_ms, fn)
	table.insert(timerQueue, fn)
	return { cancel = function() end }
end

-- ui builders, faithful enough to inspect the tree a test asserts on.
local function span(t, s)
	return { t = t, s = s }
end

tern.ui = {
	span = span,
	link = function(t, href, s)
		return { t = t, href = href, s = s }
	end,
	path = function(p)
		return { t = p }
	end,
	text = function(spans)
		return { k = "text", p = { spans = spans } }
	end,
	col = function(children)
		return { k = "col", c = children }
	end,
	lines = function(children)
		return { k = "lines", c = children }
	end,
	row = function(children)
		return { k = "row", c = children }
	end,
	card = function(head, children)
		return { k = "card", p = { head = head }, c = children }
	end,
	section = function(head, children)
		return { k = "section", p = { head = head }, c = children }
	end,
	rule = function(label)
		return { k = "rule", p = { label = label } }
	end,
	badge = function(t, tone)
		return { k = "badge", p = { t = t, tone = tone } }
	end,
	kv = function(items)
		return { k = "kv", p = { items = items } }
	end,
	table = function(cols, rows)
		return { k = "table", p = { cols = cols }, c = rows }
	end,
	meter_cell = function(v)
		return { meter = { value = v } }
	end,
	meter_parts_cell = function(parts)
		return { meter = { parts = parts } }
	end,
	tree = function(nodes)
		return { k = "tree", p = { nodes = nodes } }
	end,
	list = function(items)
		return { k = "list", p = { items = items } }
	end,
	code = function(text)
		return { k = "code", p = { text = text } }
	end,
	diff = function(text)
		return { k = "diff", p = { text = text } }
	end,
	md = function(text)
		return { k = "md", p = { text = text } }
	end,
	meter = function(v, label)
		return { k = "meter", p = { value = v, label = label } }
	end,
	progress = function(v, label)
		return { k = "progress", p = { value = v, label = label } }
	end,
	bars = function(series)
		return { k = "bars", p = { series = series } }
	end,
	spark = function(series)
		return { k = "spark", p = { series = series } }
	end,
	ansi = function(text)
		return { k = "ansi", p = { text = text } }
	end,
	diagnostic = function(d)
		return { k = "diagnostic", p = d }
	end,
	test_summary = function(p, f, s)
		return { k = "test_summary", p = { passed = p, failed = f, skipped = s } }
	end,
	overflow = function(n)
		return { k = "overflow", p = { hidden = n } }
	end,
	node = function(kind, props, children)
		return { k = kind, p = props, c = children }
	end,
	el = function(tag, props, children)
		return { k = tag, p = props, c = children }
	end,
}

local function blockDefine(id, def)
	tern.__blocks = tern.__blocks or {}
	tern.__blocks[id] = def
	return def
end

tern.block = { define = blockDefine }

local Now = os and os.time and os.time() or 1700000000
os = { time = function()
	return Now
end }

-- A small JSON parser, because Luau rejects JSON literal syntax and a stub
-- built on loadstring would fail exactly where the real decode is exercised.
local function parseJson(text)
	local pos = 1
	local len = #text

	local function skip()
		while pos <= len do
			local c = text:sub(pos, pos)
			if c == " " or c == "\t" or c == "\n" or c == "\r" then
				pos += 1
			else
				break
			end
		end
	end

	local function parseValue()
		skip()
		local c = text:sub(pos, pos)
		if c == "{" then
			pos += 1
			local obj = {}
			skip()
			if text:sub(pos, pos) == "}" then
				pos += 1
				return obj
			end
			while true do
				skip()
				local key = parseValue()
				skip()
				pos += 1 -- colon
				obj[key] = parseValue()
				skip()
				local d = text:sub(pos, pos)
				pos += 1
				if d == "}" then
					return obj
				end
				if d ~= "," then
					error("bad object at " .. pos)
				end
			end
		elseif c == "[" then
			pos += 1
			local arr = tern.json.array()
			skip()
			if text:sub(pos, pos) == "]" then
				pos += 1
				return arr
			end
			while true do
				table.insert(arr, parseValue())
				skip()
				local d = text:sub(pos, pos)
				pos += 1
				if d == "]" then
					return arr
				end
				if d ~= "," then
					error(("bad array at %d, saw %q after %d items"):format(pos, d, #arr))
				end
			end
		elseif c == '"' then
			pos += 1
			local out = {}
			while pos <= len do
				local ch = text:sub(pos, pos)
				if ch == '"' then
					pos += 1
					return table.concat(out)
				elseif ch == "\\" then
					local esc = text:sub(pos + 1, pos + 1)
					if esc == "n" then
						table.insert(out, "\n")
					elseif esc == "t" then
						table.insert(out, "\t")
					elseif esc == "r" then
						table.insert(out, "\r")
					elseif esc == "u" then
						table.insert(out, text:sub(pos + 2, pos + 5))
						pos += 4
					else
						table.insert(out, esc)
					end
					pos += 2
				else
					table.insert(out, ch)
					pos += 1
				end
			end
			error("unterminated string")
		elseif c == "t" then
			pos += 4
			return true
		elseif c == "f" then
			pos += 5
			return false
		elseif c == "n" then
			pos += 4
			return tern.json.null
		else
			local num = text:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
			if not num or num == "" then
				error(("bad value %q at %d"):format(c, pos))
			end
			pos += #num
			local n = tonumber(num)
			if n and n % 1 == 0 then
				return n
			end
			return n
		end
	end

	-- _G is a readonly table in Luau, so the parser hands its value reader to
	-- itself through an upvalue rather than a global.
	local nullValue = setmetatable({}, {
		__tostring = function()
			return "null"
		end,
	})
	tern.json.null = nullValue

	skip()
	local first = text:sub(pos, pos)
	local value = parseValue()
	if value == nil then
		value = nullValue
	end
	skip()
	if pos <= len then
		local trailing = text:sub(pos, pos + 30):gsub("\n", "\\n")
		error(("trailing after %q at %d (len %d): %s"):format(first, pos, len, trailing))
	end
	return value
end

decode = parseJson
tern.json.decode = parseJson

-- A real encoder, because the kv round-trip test needs a value to survive a
-- write and a read the way JSON on disk would.
encodeJson = function(value)
	local encodeString
	encodeString = function(s)
		return (tostring(s)
			:gsub('\\', '\\\\')
			:gsub('"', '\\"')
			:gsub('\n', '\\n')
			:gsub('\r', '\\r')
			:gsub('\t', '\\t'))
	end

	local encodeOne
	encodeOne = function(v, seen)
		if type(v) == "string" then
			return '"' .. encodeString(v) .. '"'
		elseif type(v) == "number" then
			if v ~= v or v == math.huge or v == -math.huge then
				return "0"
			end
			return tostring(math.floor(v) == v and v or v)
		elseif type(v) == "boolean" then
			return tostring(v)
		elseif v == tern.json.null then
			return "null"
		elseif type(v) == "table" then
			seen = seen or {}
			if seen[v] then
				return "null"
			end
			seen[v] = true

			local isArray = #v > 0
			local parts = {}
			if isArray then
				for _, item in ipairs(v) do
					table.insert(parts, encodeOne(item, seen))
				end
			else
				local keys = {}
				for k in pairs(v) do
					if type(k) == "string" then
						table.insert(keys, k)
					end
				end
				table.sort(keys)
				for _, k in ipairs(keys) do
					table.insert(parts, '"' .. encodeString(k) .. '":' .. encodeOne(v[k], seen))
				end
			end
			seen[v] = nil
			return (isArray and "[" or "{") .. table.concat(parts, ",") .. (isArray and "]" or "}")
		end
		return "null"
	end

	return encodeOne(value, {})
end

-- ==== STUB-END ====

-- ==== BLOCK ====

-- ------------------------------------------------------------- helpers ----

local passed, failed = 0, 0
local failures = {}

local function test(name, fn)
	local ok, err = pcall(fn)
	if ok then
		passed += 1
		print("ok   " .. name)
	else
		failed += 1
		table.insert(failures, name .. ": " .. tostring(err))
		print("FAIL " .. name .. "\n     " .. tostring(err))
	end
end

local function eq(actual, expected, what)
	if actual ~= expected then
		error(("%s: expected %s, got %s"):format(what, tostring(expected), tostring(actual)), 2)
	end
end

local function contains(haystack, needle, what)
	if type(haystack) ~= "string" or not haystack:find(needle, 1, true) then
		error(("%s: %q not in %q"):format(what, needle, tostring(haystack)), 2)
	end
end

-- Renders a node tree to plain text so assertions can look for content.
-- Renders a node tree to plain text. tern.ui nodes put their content in
-- `t` (a span), `p.spans` / `p.head` (spans lists) or, for a table, `c`
-- (rows of cells), so all three shapes are read here.
local function spansInto(value, out)
	if type(value) == "string" then
		table.insert(out, value)
		return
	end
	if type(value) ~= "table" then
		return
	end
	if type(value.t) == "string" then
		table.insert(out, value.t)
		return
	end
	for _, s in ipairs(value) do
		spansInto(s, out)
	end
end

local function flatten(node, out)
	out = out or {}
	if type(node) ~= "table" then
		return out
	end

	spansInto(node.t, out)

	if type(node.p) == "table" then
		spansInto(node.p.spans, out)
		spansInto(node.p.head, out)
		spansInto(node.p.label, out)
	end

	if node.k == "table" then
		for _, row in ipairs(node.c or {}) do
			for _, cell in ipairs(row) do
				if type(cell) == "table" and cell.meter then
					table.insert(out, "<meter>")
				else
					spansInto(cell, out)
				end
			end
		end
		return out
	end

	for _, child in ipairs(node.c or {}) do
		if type(child) == "table" and child.meter == nil then
			flatten(child, out)
		end
	end
	return out
end

local function viewText(def, state)
	local view = def.view(state, currentCx)
	return table.concat(flatten(view.main), " | ")
end

-- The header is a card; the rows are a sibling table. A test looking for a
-- port has to look in the table, not at the summary line above it.
local function bodyText(def, state)
	local view = def.view(state, currentCx)
	local out = {}
	local function walk(node)
		if type(node) ~= "table" then
			return
		end
		if node.k == "table" then
			flatten(node, out)
			return
		end
		if node.k == "text" then
			flatten(node, out)
			return
		end
		for _, child in ipairs(node.c or {}) do
			walk(child)
		end
	end
	walk(view.main)
	return table.concat(out, " | ")
end

-- --------------------------------------------------------- test cases ----

eq(type(BLOCK_DEF), "table", "host.luau returned its block definition")
local def = BLOCK_DEF

local SAMPLE = [[
[{"port":52800,"addr":"127.0.0.1","family":"ipv4","pid":45748,"proc":"bsk.exe","cmd":"bsk.exe daemon start","cwd":"C:/Users/u/Desktop/blog","cwdSource":"process","started":"2026-10-17T07:00:00Z","chain":["bsk.exe","bash.exe","bash.exe","omp.exe"],"omp":true,"ompPid":48332},
{"port":64106,"addr":"127.0.0.1","family":"ipv4","pid":44156,"proc":"omp.exe","cmd":"omp.exe","cwd":"D:/work","cwdSource":"process","started":"2026-10-17T06:00:00Z","chain":["omp.exe","tern.exe"],"omp":true,"ompPid":44156},
{"port":3306,"addr":"0.0.0.0","family":"ipv4","pid":7996,"proc":"mysqld.exe","cmd":"mysqld.exe","cwd":"","cwdSource":"","started":"","chain":["mysqld.exe","services.exe"],"omp":false,"ompPid":0},
{"port":80,"addr":"0.0.0.0","family":"ipv4","pid":5680,"proc":"httpd.exe","cmd":"httpd.exe","cwd":"C:/Apache","cwdSource":"image","started":"","chain":["httpd.exe"],"omp":false,"ompPid":0}]
]]

-- init defers its first scan, so a test that wants rows has to fire the
-- timer it scheduled, exactly as the block will after opening.
local function settled(args)
	timerQueue = {}
	processCalls = {}
	local state = def.init(guard(makeCx("init"), "init"), args or {}, nil)
	-- init schedules the first scan; firing it publishes a summary, and the
	-- block reads that back the way view does.
	local first = table.remove(timerQueue, 1)
	if first then
		first(makeCx("first-scan"))
	end
	return state
end

test("init returns before the probe runs", function()
	processResult = { status = 0, stdout = SAMPLE, stderr = "", timed_out = false }
	kvStore = {}
	timerQueue = {}
	local state = def.init(guard(makeCx("init"), "init"), {}, nil)
	eq(#processCalls, 0, "init spawned nothing")
	eq(#timerQueue, 1, "init scheduled the first scan instead of running it")

	contains(bodyText(def, state), "scanning", "the block says it is scanning")
end)

test("the block reads its counts back out of the shared summary", function()
	-- Regression: a scan's callback cannot reach the state table Tern copied
	-- from init, so the block drew "scanning" forever while its own summary
	-- said 42. The summary is the channel that works, so view reads it.
	processResult = { status = 0, stdout = SAMPLE, stderr = "", timed_out = false }
	kvStore = {}
	timerQueue = {}
	local state = def.init(guard(makeCx("init"), "init"), {}, nil)
	local first = table.remove(timerQueue, 1)
	first(makeCx("first-scan"))

	eq(kvStore.last_scan.total, 4, "the scan published a summary")
	eq(state.total, nil, "the scan's rows never reached this state table")

	def.view(state, currentCx)
	eq(state.pending, false, "the draw adopted the summary")
	eq(state.total, 4, "and its counts")
	eq(state.omp, 1, "and its omp count")

	local title = def.title(state)
	contains(title, "4 listening", "the title reads from the summary")

	-- A newer scan has to show up without a restart.
	kvStore.last_scan.version = kvStore.last_scan.version + 1
	kvStore.last_scan.total = 9
	kvStore.last_scan.omp = 3
	def.view(state, currentCx)
	eq(state.total, 9, "a newer version is adopted")
	contains(def.title(state), "9 listening", "the title follows")
end)

test("the rows survive the round trip through the summary", function()
	-- The block's state table never receives the scan's rows, so the summary
	-- has to carry them: counts alone left the table blank under a correct
	-- header. The kv stub round-trips through JSON here rather than sharing
	-- the table, so a row the summary drops cannot pass by identity.
	processResult = { status = 0, stdout = SAMPLE, stderr = "", timed_out = false }
	kvStore = {}
	jsonRoundTrip = true
	timerQueue = {}

	local state = def.init(guard(makeCx("init"), "init"), {}, nil)
	local first = table.remove(timerQueue, 1)
	first(makeCx("first-scan"))

	jsonRoundTrip = false
	def.view(state, currentCx)

	eq(type(state.rows), "table", "the block adopted rows")
	eq(#state.rows, 4, "all four rows arrived")
	local body = bodyText(def, state)
	contains(body, "52800", "a real row is drawn")
	contains(body, "mysqld.exe", "and another")
end)

test("the probe is read from its callback, not its return value", function()
	-- Regression: tern.process.run without a callback returns an Awaitable
	-- handle. Treating that as a ProcessResult found no status, so every scan
	-- reported "no rows" and the block opened empty.
	processResult = { status = 0, stdout = SAMPLE, stderr = "", timed_out = false }
	kvStore = {}
	timerQueue = {}
	processCalls = {}
	local state = def.init(guard(makeCx("init"), "init"), {}, nil)
	def.view(state, currentCx)
	local first = table.remove(timerQueue, 1)
	first(makeCx("first-scan"))

	eq(#processCalls, 1, "exactly one probe run")
	local call = processCalls[1]
	eq(type(call), "table", "the run was recorded")

	local summary = kvStore.last_scan
	eq(summary.total, 4, "the callback's result reached the summary")
	eq(summary.omp, 1, "and its omp count")
end)

test("the deferred scan fills the table in", function()
	processResult = { status = 0, stdout = SAMPLE, stderr = "", timed_out = false }
	kvStore = {}
	local state = settled()
	eq(#state.rows, 4, "row count")
	eq(state.error, nil, "no error")
	eq(state.pending, false, "no longer pending")
end)

test("a probe that never reports a status is reported, not crashed on", function()
	-- tern.process.run's type says status is always a number, but a run that
	-- never started reports neither, and formatting that nil took the whole
	-- block down with exit 1.
	processResult = { status = nil, stdout = "", stderr = "no such file", timed_out = false }
	kvStore = {}
	local ok, state = pcall(settled)
	eq(ok, true, "the scan survived a missing status: " .. tostring(state))
	contains(state.error, "no exit status", "the missing field is named")
	contains(state.error, "no such file", "stderr still surfaces")
	contains(bodyText(def, state), "scan failed", "the block renders the failure")
end)

test("every region holds a node, not a bare table", function()
	-- Regression: dock returned `{ text = {...} }`, which is a table with a
	-- key, not a Node, so the dock drew nothing. Each region's value has to
	-- look like a node the way tern.ui builders make one.
	processResult = { status = 0, stdout = SAMPLE, stderr = "", timed_out = false }
	kvStore = {}
	local state = settled()
	local view = def.view(state, currentCx)

	for _, region in ipairs({ "main", "dock" }) do
		local node = view[region]
		eq(type(node), "table", region .. " is a node, not a bare table")
		eq(type(node.k), "string", region .. " node carries a kind")
		if node.k == nil then
			error(region .. " has no kind: it is a plain table")
		end
	end
end)

test("the header is a real node even with nothing scanned yet", function()
	processResult = { status = 0, stdout = "[]", stderr = "", timed_out = false }
	kvStore = {}
	timerQueue = {}
	local state = def.init(guard(makeCx("init"), "init"), {}, nil)
	local view = def.view(state, currentCx)
	eq(type(view.main), "table", "main exists before the first scan")
	eq(view.main.k, "col", "main is a column")
	local children = view.main.c or {}
	eq(#children > 0, true, "the column is not empty")
	eq(children[1].k, "section", "the header is a section node")
end)

test("a probe that never produced a result is reported, not crashed on", function()
	kvStore = {}
	timerQueue = {}
	local s = def.init(guard(makeCx("init"), "init"), {}, nil)
	def.view(s, currentCx)
	raiseNextRun = true
	local first = table.remove(timerQueue, 1)
	local ok = pcall(first, makeCx("first-scan"))
	eq(ok, true, "a probe that yielded no result did not escape")
	contains(s.error, "no result", "the missing result is named")
	contains(bodyText(def, s), "scan failed", "the block renders the failure")
end)

test("publishes counts both plugin halves can read", function()
	processResult = { status = 0, stdout = SAMPLE, stderr = "", timed_out = false }
	kvStore = {}
	local state = settled()
	local summary = kvStore.last_scan
	eq(type(summary), "table", "summary written")
	eq(summary.total, 4, "total")
	eq(summary.omp, 1, "omp-launched services, excluding omp itself")
	eq(summary.ompInternal, 1, "omp's own ports counted separately")
end)

test("launch argument selects the filter", function()
	processResult = { status = 0, stdout = SAMPLE, stderr = "", timed_out = false }
	kvStore = {}
	local state = settled({ "omp" })
	eq(state.filter, "omp", "filter from args")
	local body = bodyText(def, state)
	contains(body, "52800", "omp-launched service listed")
	contains(body, "bsk.exe", "its process is named")
	if body:find("3306", 1, true) then
		error("system port leaked into the omp filter")
	end
	if body:find("64106", 1, true) then
		error("omp's own IPC port leaked into the omp-launched filter")
	end
end)

test("an unknown launch argument falls back to all", function()
	processResult = { status = 0, stdout = SAMPLE, stderr = "", timed_out = false }
	kvStore = {}
	local state = settled({ "nonsense" })
	eq(state.filter, "all", "fallback")
end)

test("a probe failure renders instead of raising", function()
	processResult = { status = 1, stdout = "", stderr = "Get-CimInstance exploded", timed_out = false }
	kvStore = {}
	local ok, state = pcall(settled)
	eq(ok, true, "the scan survived: " .. tostring(state))
	contains(state.error, "exited 1", "status reported")
	contains(state.error, "Get-CimInstance", "stderr surfaced")
	contains(bodyText(def, state), "scan failed", "block says the scan failed")
	contains(viewText(def, state), "0 listening", "header still renders its counts")
	contains(state.error, "Get-CimInstance", "the probe's own words are in the error")
	eq(kvStore.last_scan.error, state.error, "the failure reaches the status line")
end)

test("a timeout is its own message", function()
	processResult = { status = -1, stdout = "", stderr = "", timed_out = true }
	kvStore = {}
	local state = settled()
	contains(state.error, "timed out", "timeout reported")
end)

test("malformed probe output is reported, not crashed on", function()
	processResult = { status = 0, stdout = "not json at all", stderr = "", timed_out = false }
	kvStore = {}
	local state = settled()
	contains(state.error, "not JSON", "parse failure reported")
end)

test("an empty array is a scan with no rows", function()
	processResult = { status = 0, stdout = "[]", stderr = "", timed_out = false }
	kvStore = {}
	local state = settled()
	eq(#state.rows, 0, "no rows")
	eq(state.error, nil, "not an error")
	contains(bodyText(def, state), "nothing is listening", "empty state reads as empty")
end)

test("filter cycles through all, omp-launched and not-omp", function()
	processResult = { status = 0, stdout = SAMPLE, stderr = "", timed_out = false }
	kvStore = {}
	local state = settled()
	local cx = guard(makeCx("key"), "key")

	def.key(state, { name = "f", ctrl = false, alt = false, shift = false, meta = false }, cx)
	eq(kvStore.prefs.filter, "omp", "first press went to the shared store")
	-- The block reads the filter back the way it reads the counts.
	state.filter = kvStore.prefs.filter
	local ompBody = bodyText(def, state)
	if ompBody:find("3306", 1, true) then
		error("omp filter leaked mysqld")
	end

	def.key(state, { name = "f", ctrl = false, alt = false, shift = false, meta = false }, cx)
	eq(kvStore.prefs.filter, "other", "second press went to the shared store")
	state.filter = kvStore.prefs.filter
	local otherBody = bodyText(def, state)
	contains(otherBody, "3306", "mysqld survives the not-omp view")
	if otherBody:find("52800", 1, true) then
		error("the not-omp view leaked the omp-launched bsk port")
	end
	if otherBody:find("64106", 1, true) then
		error("the not-omp view leaked omp's own IPC port")
	end

	def.key(state, { name = "f", ctrl = false, alt = false, shift = false, meta = false }, cx)
	eq(kvStore.prefs.filter, "all", "wraps around")
end)

test("rescan re-runs the probe", function()
	processResult = { status = 0, stdout = SAMPLE, stderr = "", timed_out = false }
	kvStore = {}
	local state = settled()
	local before = #processCalls
	def.key(state, { name = "r", ctrl = false, alt = false, shift = false, meta = false },
		guard(makeCx("key"), "key"))
	eq(#processCalls, before + 1, "one more probe run")
end)

test("auto refresh can be switched off and on", function()
	processResult = { status = 0, stdout = SAMPLE, stderr = "", timed_out = false }
	kvStore = {}
	timerQueue = {}
	local state = settled()
	eq(state.auto, true, "auto on by default")
	eq(#timerQueue, 1, "one timer scheduled")

	def.key(state, { name = "a", ctrl = false, alt = false, shift = false, meta = false },
		guard(makeCx("key"), "key"))
	eq(state.auto, false, "auto off")
	def.key(state, { name = "a", ctrl = false, alt = false, shift = false, meta = false },
		guard(makeCx("key"), "key"))
	eq(state.auto, true, "auto back on")
	eq(#timerQueue, 2, "a timer was scheduled again")
end)

test("the timer chains itself instead of firing once", function()
	processResult = { status = 0, stdout = SAMPLE, stderr = "", timed_out = false }
	kvStore = {}
	timerQueue = {}
	settled()
	local depth = 0
	while #timerQueue > 0 and depth < 5 do
		depth += 1
		local fn = table.remove(timerQueue, 1)
		fn(makeCx("timer"))
	end
	eq(depth, 5, "each fire schedules the next")
end)

test("a fired timer never renders through a retired cx", function()
	processResult = { status = 0, stdout = SAMPLE, stderr = "", timed_out = false }
	kvStore = {}
	timerQueue = {}
	settled()
	-- the deferred scan's cx was retired by the probe's await; the timer must
	-- not reach back for it.
	local ok, err = pcall(function()
		local fn = table.remove(timerQueue, 1)
		fn(makeCx("timer"))
	end)
	eq(ok, true, "timer callback stayed clean: " .. tostring(err))
end)

test("title counts what the block found", function()
	processResult = { status = 0, stdout = SAMPLE, stderr = "", timed_out = false }
	kvStore = {}
	local state = settled()
	def.view(state, currentCx)
	local title = def.title(state)
	contains(title, "4 listening", "total in title")
	contains(title, "1 omp", "omp count in title")
end)

test("an unreadable cwd is marked rather than guessed", function()
	processResult = { status = 0, stdout = SAMPLE, stderr = "", timed_out = false }
	kvStore = {}
	local state = settled()
	local body = bodyText(def, state)
	contains(body, "cwd unreadable", "empty cwd is labelled")
	contains(body, "image dir, cwd unreadable", "image fallback is labelled")
end)

test("a real cwd wins over the image name", function()
	processResult = { status = 0, stdout = SAMPLE, stderr = "", timed_out = false }
	kvStore = {}
	local state = settled()
	local body = bodyText(def, state)
	contains(body, "C:/Users/u/Desktop/blog", "project directory shown")
end)

test("a wrap at a row boundary is rejoined before decoding", function()
	-- netstat and ss hard-wrap, so the probe's own JSON can arrive with a
	-- newline where a row ended. Rejoining must restore it; a break *inside* a
	-- token is not recoverable, which is why the probe emits one line.
	local wrapped = SAMPLE:gsub("\n},%s*{", "\n},\n{")
	processResult = { status = 0, stdout = wrapped, stderr = "", timed_out = false }
	kvStore = {}
	local state = settled()
	eq(state.error, nil, "wrapped JSON parsed: " .. tostring(state.error))
	eq(#state.rows, 4, "all rows survived the wrap")
end)

test("CRLF line endings do not break decoding", function()
	local crlf = SAMPLE:gsub("\n", "\r\n")
	processResult = { status = 0, stdout = crlf, stderr = "", timed_out = false }
	kvStore = {}
	local state = settled()
	eq(state.error, nil, "CRLF parsed: " .. tostring(state.error))
	eq(#state.rows, 4, "all rows survived CRLF")
end)

test("a BOM before the array does not break decoding", function()
	processResult = { status = 0, stdout = "\239\187\191" .. SAMPLE, stderr = "", timed_out = false }
	kvStore = {}
	local state = settled()
	eq(state.error, nil, "BOM stripped")
	eq(#state.rows, 4, "rows parsed")
end)

test("only the view's own actions are handled", function()
	processResult = { status = 0, stdout = SAMPLE, stderr = "", timed_out = false }
	kvStore = {}
	local state = settled()
	local cx = guard(makeCx("event"), "event")
	def.event(state, { ev = "select", id = "x" }, cx)
	eq(state.filter, "all", "a select is not a command")
end)

test("the filter and auto flag survive a restart through the shared store", function()
	-- They cannot live in the block's state: Tern copied what init returned,
	-- so a key handler's write never reached the block. tern.kv is the channel
	-- that does, and init reads it back.
	processResult = { status = 0, stdout = SAMPLE, stderr = "", timed_out = false }
	kvStore = {}

	local state = settled()
	local cx = guard(makeCx("key"), "key")
	def.key(state, { name = "f", ctrl = false, alt = false, shift = false, meta = false }, cx)

	local prefs = kvStore.prefs
	eq(type(prefs), "table", "the filter went to the shared store")
	eq(prefs.filter, "omp", "as the next filter in the cycle")

	-- A fresh block picks it up.
	kvStore = { prefs = prefs }
	local reopened = def.init(guard(makeCx("init"), "init"), {}, nil)
	eq(reopened.filter, "omp", "a reopened block restores the filter")
end)

test("a launch argument overrides the stored filter", function()
	processResult = { status = 0, stdout = SAMPLE, stderr = "", timed_out = false }
	kvStore = { prefs = { filter = "omp", auto = false } }

	local state = def.init(guard(makeCx("init"), "init"), { "other" }, nil)
	eq(state.filter, "other", "the omp-only command lands on its own filter")
	eq(state.auto, false, "while the stored auto flag is still honoured")
end)

test("save persists nothing per-block", function()
	-- Preferences live in tern.kv now, so a second copy in the block's save
	-- payload would be one nothing ever writes to.
	processResult = { status = 0, stdout = SAMPLE, stderr = "", timed_out = false }
	kvStore = {}
	local state = settled()
	eq(def.save(state), nil, "nothing is saved with the block")
end)

test("a probe that finds nothing publishes zeros, not nothing", function()
	processResult = { status = 0, stdout = "[]", stderr = "", timed_out = false }
	kvStore = {}
	settled()
	eq(kvStore.last_scan.total, 0, "zero total")
	eq(kvStore.last_scan.omp, 0, "zero omp")
end)

test("no block read a cx after its own await retired it", function()
	eq(#violations, 0, "violations: " .. table.concat(violations, ", "))
	print(("     (%d awaits retired a cx, none was reused)"):format(retirements))
end)

print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then
	for _, f in ipairs(failures) do
		print("  - " .. f)
	end
	os.exit(1)
end
