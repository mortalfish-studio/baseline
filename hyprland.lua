-- Afterlight 2049 window atmosphere. A theme-shipped hyprland.lua replaces
-- the one Omarchy generates from colors.toml, so the borders are set here too.
-- Loaded only while this theme is active; switching themes drops all of it.
-- The rest lives in atmosphere.lua, shared by Day, Night and Saver.

local active_border_color = { colors = { "rgba(f29a4aee)", "rgba(6db5b9ee)" }, angle = 45 } -- sodium amber into teal
local inactive_border_color = "rgba(2a3038aa)"

local ok, atmosphere = pcall(dofile, os.getenv("HOME") .. "/.config/omarchy/themes/afterlight-2049/atmosphere.lua")
if ok then
  atmosphere("day", active_border_color, inactive_border_color)
else
  hl.config({ general = { col = { active_border = active_border_color, inactive_border = inactive_border_color } } })
end
