-- Home workspaces. Each core app always opens on its own workspace, whether it
-- starts at login, from a key, or after being closed:
--   1 term · 2 web · 3 code · 4 chat · 5 video · 6 music
-- Workspaces 3 and 4 belong to your coding and chat apps, chosen in Baseline >
-- Setup > Apps (`afterlight apps`), which writes hypr/baseline_apps.lua.
-- The bar names these slots (mortalfish.workspaces); Super+1..6 go to them.

local homes = {
  { "1", { class = "^foot$" } },                                   -- term: the terminal
  { "2", { class = "^(google-chrome|chrome-outlook[.]office[.]com__mail_-Default)$" } }, -- web: browser and email
  { "5", { class = "^chrome-youtube[.]com__-Default$" } },          -- video: YouTube
  { "6", { class = "^(chrome-jopilafkghibglefecikcmpaoolnpcjg-Default|chrome-cinhimbnkkaeohfgghhklpknlkffjgod-Default|chrome-music[.]youtube[.]com__-Default|chrome-music[.]apple[.]com__-Default)$" } }, -- music: Beatport, YouTube Music, Apple Music
}

for _, home in ipairs(homes) do
  o.window(home[2], { workspace = home[1] })
end

-- Start the six at login, each landing on its home via the rules above.
o.launch_on_start("omarchy-launch-terminal")
o.launch_on_start("omarchy-launch-browser")
o.launch_on_start("omarchy-launch-webapp https://youtube.com/")
o.launch_on_start("google-chrome-stable --profile-directory=Default --app-id=jopilafkghibglefecikcmpaoolnpcjg")

pcall(require, "hypr.baseline_apps")

-- The Razer mouse's side buttons and wheel tilt, written by `afterlight mouse` (Baseline > System > Mouse).
pcall(require, "hypr.mouse")

-- Volume keys: the Sonos room while Sonos is picked in Baseline's Player tab,
-- otherwise the laptop, through Omarchy's own volume command (baseline-volume).
local volume = os.getenv("HOME") .. "/.local/bin/baseline-volume"
o.rebind("XF86AudioRaiseVolume", "Volume up", volume .. " raise", { locked = true, repeating = true })
o.rebind("XF86AudioLowerVolume", "Volume down", volume .. " lower", { locked = true, repeating = true })
o.rebind("XF86AudioMute", "Mute", volume .. " mute-toggle", { locked = true })
o.rebind("ALT + XF86AudioRaiseVolume", "Volume up precise", volume .. " +1", { locked = true, repeating = true })
o.rebind("ALT + XF86AudioLowerVolume", "Volume down precise", volume .. " -1", { locked = true, repeating = true })

-- Baseline Studio (the picture library and look maker): a centred float.
o.window({ title = "^Baseline Studio$" }, { float = true, center = true, size = { 1240, 840 } })
