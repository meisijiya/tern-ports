-- The timer runs on its own cx, so this is the first place a write is safe.
tern.on("window_start", function(cx)
	tern.timer(20, function()
		local out = {}
		local ok, res = pcall(function()
			return cx.session:block_types()
		end)
		if not ok then
			out.err = tostring(res)
		else
			local kinds = {}
			for _, info in ipairs(res) do
				if type(info) == "table" and info.kind then
					table.insert(kinds, info.kind .. " || " .. tostring(info.title) .. " || palette=" .. tostring(info.palette))
				end
			end
			out.kinds = kinds
		end
		tern.kv.set("__probe", out)
	end)
end)
