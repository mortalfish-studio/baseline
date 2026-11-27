-- Cobalt Rain Day window atmosphere, written by `afterlight look build`.
-- A theme-shipped hyprland.lua replaces the one Omarchy generates, so the borders
-- are set here too; the rest lives in Afterlight's shared atmosphere.lua.

local active_border_color = { colors = { "rgba(4d9bffee)", "rgba(48c4d2ee)" }, angle = 45 }
local inactive_border_color = "rgba(15213aaa)"

local ok, atmosphere = pcall(dofile, os.getenv("HOME") .. "/.config/omarchy/themes/afterlight-2049/atmosphere.lua")
if ok then
  atmosphere("day", active_border_color, inactive_border_color)
else
  hl.config({ general = { col = { active_border = active_border_color, inactive_border = inactive_border_color } } })
end
