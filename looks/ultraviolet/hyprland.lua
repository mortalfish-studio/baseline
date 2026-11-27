-- Ultraviolet Day window atmosphere, written by `afterlight look build`.
-- A theme-shipped hyprland.lua replaces the one Omarchy generates, so the borders
-- are set here too; the rest lives in Afterlight's shared atmosphere.lua.

local active_border_color = { colors = { "rgba(a585ffee)", "rgba(56c6ffee)" }, angle = 45 }
local inactive_border_color = "rgba(1b172daa)"

local ok, atmosphere = pcall(dofile, os.getenv("HOME") .. "/.config/omarchy/themes/afterlight-2049/atmosphere.lua")
if ok then
  atmosphere("day", active_border_color, inactive_border_color)
else
  hl.config({ general = { col = { active_border = active_border_color, inactive_border = inactive_border_color } } })
end
