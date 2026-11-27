-- Afterlight 2049 Saver window atmosphere. A theme-shipped hyprland.lua replaces
-- the one Omarchy generates from colors.toml, so the borders are set here too.
-- Loaded only while this theme is active; switching themes drops all of it.
-- The rest lives in atmosphere.lua, shared by Day, Night and Saver.

local active_border_color = { colors = { "rgba(9a6a40aa)", "rgba(4c7577aa)" }, angle = 45 } -- the last embers
local inactive_border_color = "rgba(101214aa)"

local ok, atmosphere = pcall(dofile, os.getenv("HOME") .. "/.config/omarchy/themes/afterlight-2049/atmosphere.lua")
if ok then
  atmosphere("saver", active_border_color, inactive_border_color)
else
  hl.config({ general = { col = { active_border = active_border_color, inactive_border = inactive_border_color } } })
end
