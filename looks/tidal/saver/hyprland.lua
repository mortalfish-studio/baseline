-- Cobalt Rain Saver window atmosphere, written by `afterlight look build`.
-- A theme-shipped hyprland.lua replaces the one Omarchy generates, so the borders
-- are set here too; the rest lives in Afterlight's shared atmosphere.lua.

local active_border_color = { colors = { "rgba(3f6da8aa)", "rgba(3e8e97aa)" }, angle = 45 }
local inactive_border_color = "rgba(0c1220aa)"

local ok, atmosphere = pcall(dofile, os.getenv("HOME") .. "/.config/omarchy/themes/afterlight-2049/atmosphere.lua")
if ok then
  atmosphere("saver", active_border_color, inactive_border_color)
else
  hl.config({ general = { col = { active_border = active_border_color, inactive_border = inactive_border_color } } })
end
