-- Ports window half: the palette commands, the shortcuts and the status
-- segment.
--
-- The scan itself lives in the host half, inside the block, which writes its
-- counts to tern.kv. This half reads that summary so the status line can
-- answer "is anything of mine listening" without probing again, and opens the
-- block on demand.

local PLUGIN = "tern-ports"
local BLOCK_KIND = ("plugin.%s.ports"):format(PLUGIN)

-- The block's last summary: { total, omp, ompInternal, version, at }.
local KV_KEY = "last_scan"

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
			command = ("plugin.%s.open"):format(PLUGIN),
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
			command = ("plugin.%s.open"):format(PLUGIN),
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

tern.on("window_start", function(_cx)
	tern.command({
		id = "open",
		title = "Ports",
		icon = "md-lan-connect",
		-- keys, not tern.bind: a command that declares its own chords gets an
		-- action entry that a status segment's `command` can name. tern.bind
		-- only adds a shortcut to the keymap and left the segment's click
		-- with nothing to run.
		keys = { "cmd+shift+p" },
		run = function(cmdCx)
			cmdCx:new_block(BLOCK_KIND)
		end,
	})

	tern.command({
		id = "open-omp",
		title = "Ports (omp-launched only)",
		icon = "md-robot-outline",
		keys = { "cmd+shift+o" },
		run = function(cmdCx)
			cmdCx:new_block(BLOCK_KIND, { "omp" })
		end,
	})

	tern.chrome.status(function()
		return statusFor()
	end)

	poll(-1)
end)

return {
	summary = readSummary,
	blockKind = BLOCK_KIND,
}
