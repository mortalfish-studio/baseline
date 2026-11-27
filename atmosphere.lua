-- Afterlight 2049 window atmosphere, shared by the Day, Night and Saver themes.
-- Each theme's hyprland.lua calls this with its mode and border colours. The
-- Baseline panel's tweaks (~/.config/omarchy/afterlight/tweaks.lua, written by
-- `afterlight`) override the defaults below.

local defaults = {
  day = { dim = 0.3, blur = true, blurBrightness = 0.8, terminalOpacity = 0.9, webDim = 0.0, animations = true },
  night = { dim = 0.55, blur = true, blurBrightness = 0.6, terminalOpacity = 0.9, webDim = 0.25, animations = true },
  -- Saver draws nothing just for show: no blur, shadows, transparency or motion.
  saver = { dim = 0.6, blur = false, blurBrightness = 0.6, terminalOpacity = 1.0, webDim = 0.35, animations = false },
}

return function(mode, active_border_color, inactive_border_color)
  local t = {}
  for k, v in pairs(defaults[mode] or defaults.day) do t[k] = v end
  local ok, user = pcall(dofile, os.getenv("HOME") .. "/.config/omarchy/afterlight/tweaks.lua")
  if ok and type(user) == "table" and type(user[mode]) == "table" then
    for k, v in pairs(user[mode]) do
      if t[k] ~= nil and type(v) == type(t[k]) then t[k] = v end
    end
  end

  hl.config({
    general = {
      col = {
        active_border = active_border_color,
        inactive_border = inactive_border_color,
      },
    },

    group = {
      col = {
        border_active = active_border_color,
        border_inactive = inactive_border_color,
      },
    },

    decoration = {
      -- Unfocused windows recede like unlit rooms in a megablock.
      dim_inactive = t.dim > 0,
      dim_strength = t.dim,

      -- Soft, grainy blur behind see-through windows.
      blur = {
        enabled = t.blur,
        size = 5,
        passes = 2,
        new_optimizations = true,
        noise = 0.02,
        vibrancy = 0.2,
        brightness = t.blurBrightness,
      },

      shadow = mode == "saver" and { enabled = false } or nil,
    },

    animations = { enabled = t.animations },
  })

  -- Terminals let the haze through.
  if t.terminalOpacity < 1 then
    local o_ = string.format("%.2f %.2f", t.terminalOpacity, math.max(0.5, t.terminalOpacity - 0.05))
    o.window({ tag = "terminal" }, { opacity = o_ })
  else
    o.window({ tag = "terminal" }, { opacity = "1 1" })
  end

  -- The browser and its web apps: web pages are mostly white or grey, far
  -- brighter than the themed apps, so Night and Saver let them recede into the
  -- dark background (Hyprland has no per-window brightness, so opacity does it).
  if t.webDim > 0 then
    local w = string.format("%.2f %.2f", 1 - t.webDim, 1 - t.webDim)
    o.window("^(google-chrome|chrome-.+)$", { opacity = w })
  end

  if t.animations then
    -- Slower, weightier motion: long ease-outs, no bounce.
    hl.curve("drift", { type = "bezier", points = { { 0.16, 1 }, { 0.3, 1 } } })
    hl.animation({ leaf = "windows", enabled = true, speed = 3.3, bezier = "drift" })
    hl.animation({ leaf = "windowsIn", enabled = true, speed = 3.7, bezier = "drift", style = "popin 96%" })
    hl.animation({ leaf = "windowsOut", enabled = true, speed = 2, bezier = "drift", style = "popin 96%" })
    hl.animation({ leaf = "border", enabled = true, speed = 5.3, bezier = "drift" })
    hl.animation({ leaf = "fade", enabled = true, speed = 2.7, bezier = "drift" })
    hl.animation({ leaf = "layers", enabled = true, speed = 3, bezier = "drift" })
    hl.animation({ leaf = "workspaces", enabled = true, speed = 3.3, bezier = "drift", style = "slidefade 8%" })
  end
end
