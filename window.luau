-- Ports window half: the palette commands, the shortcuts and the status
-- segment.
--
-- The scan itself lives in the host half, inside the block, which writes its
-- counts to tern.kv. This half reads that summary so the status line can
-- answer "is anything of mine listening" without probing again, and opens the
-- block on demand.

local PLUGIN = "tern-ports"
-- The kinds cx:new_block finds, which cx.session:block_types() reports as
-- <plugin>.<manifest block id> with no "plugin." prefix. The doc's
-- `"plugin.kind"` is the data-surface spelling the DOM uses, not what the
-- call takes, and a prefixed kind silently matches nothing.
local BLOCK_KIND = ("%s.ports"):format(PLUGIN)
local BLOCK_KIND_OMP = ("%s.ports-omp"):format(PLUGIN)

-- The block's last summary: { total, omp, ompInternal, version, at }.
local KV_KEY = "last_scan"

-- The action the segment's click runs, and the only place the name is built.
local OPEN_ACTION = ("plugin.%s.open"):format(PLUGIN)

-- Chrome caches formatter results per input, and the status formatter's input
-- is the focused pane, not our kv. So a changed summary needs an explicit
-- refresh; polling is the only way to notice one, and a poll that finds no
-- change costs a cached kv read and nothing else.
local POLL_MS = 5000
local SUMMARY_TTL_SECONDS = 90

local function readSummary()
	local value = tern.kv.get(KV_KEY)
	if type(value) ~= "table" then
		return nil
	end
	local at = value.at or 0
	if at > 0 and os and os.time and (os.time() - at) > SUMMARY_TTL_SECONDS then
		return nil
	end
	return value
end

local function versionOf(summary)
	return summary and summary.version or -1
end

-- The segment counts omp-launched services and stays silent when there are
-- none: a segment per unrelated system port would be noise. A scan that
-- failed reports itself instead of showing a stale zero.
local function statusFor()
	local summary = readSummary()
	if not summary then
		return nil
	end
	if summary.error then
		return { {
			text = "ports ?",
			icon = "md-alert-circle-outline",
			tone = "error",
			command = OPEN_ACTION,
		} }
	end

	local total = summary.total or 0
	local omp = summary.omp or 0
	if total == 0 then
		return nil
	end
	if omp == 0 then
		return { {
			text = ("%d ports"):format(total),
			icon = "md-lan-connect",
			tone = "muted",
			command = OPEN_ACTION,
		} }
	end
	return { {
		text = ("%d omp"):format(omp),
		icon = "md-robot-outline",
		tone = "success",
		command = ("plugin.%s.open"):format(PLUGIN),
	} }
end

-- One-shot timers chained by hand: tern.timer has no interval.
local function poll(seen)
	local summary = readSummary()
	local current = versionOf(summary)
	if current ~= seen then
		-- Called from the timer, never from a formatter, which raises.
		tern.chrome.refresh()
	end
	tern.timer(POLL_MS, function()
		poll(current)
	end)
end

-- Registered at entry load, not under tern.on("window_start"): a reload re-runs
-- the entry but does not fire window_start again, so registrations made there
-- would vanish until the window itself restarted.
--
-- No chords here: cmd+shift+p and cmd+shift+o were already bound, and a
-- shortcut that shadows another plugin's binding is worse than none. The
-- palette and the block's own f/r/a keys reach everything in this plugin.
--
-- The failure mode worth naming: cx:new_block returns nil, with no toast,
-- when the plugin on the current host is not Ready. That is what a command
-- firing before the plugin finished loading looks like, and it was silent,
-- so a dead click looked like a missing feature. Both commands say so now.
local function openBlock(cmdCx, kind, label)
	local pane = cmdCx:new_block(kind)
	if pane == nil then
		cmdCx:toast(
			"error",
			label .. " did not open",
			"no ready plugin on this host — reload with 'tern plugin reload'"
		)
	end
	return pane
end

tern.chrome.status(function()
	return statusFor()
end)

tern.command({
	id = "open",
	title = "Ports",
	icon = "md-lan-connect",
	run = function(cmdCx)
		return openBlock(cmdCx, BLOCK_KIND, "Ports")
	end,
})

tern.command({
	id = "open-omp",
	title = "Ports (omp-launched only)",
	icon = "md-robot-outline",
	run = function(cmdCx)
		return openBlock(cmdCx, BLOCK_KIND_OMP, "Ports (omp-launched only)")
	end,
})

-- The poll chain is started once per instance: a second chain would double
-- every refresh it schedules. The chain starts by a call rather than by the
-- definition above, so the start is guarded.
local started = false

local function startPolling()
	if started then
		return
	end
	started = true
	poll(-1)
end

startPolling()

return {
	summary = readSummary,
	blockKind = BLOCK_KIND,
	ompBlockKind = BLOCK_KIND_OMP,
}
