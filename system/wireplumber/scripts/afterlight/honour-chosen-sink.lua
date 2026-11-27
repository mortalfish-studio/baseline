-- Afterlight: honour the output you picked even when its jack reads empty.
--
-- WirePlumber leaves an output out of the running for default when its port
-- says "not available". This laptop's headphone jack sensor never reports a
-- plug, so Headphones could never become the default. When the output you
-- chose (default.configured.audio.sink, set by Baseline's selector or any
-- mixer) is one of the names below and still exists, it wins anyway.
-- Everything else is left to WirePlumber's normal choice.

log = Log.open_topic ("s-default-nodes")

local FORCEABLE = {
  ["alsa_output.platform-sound.HiFi__Headphones__sink"] = true,
}

SimpleEventHook {
  name = "afterlight/honour-chosen-sink",
  after = { "default-nodes/find-best-default-node",
            "default-nodes/find-selected-default-node",
            "default-nodes/find-stored-default-node" },
  before = { "default-nodes/apply-default-node" },
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "select-default-node" },
      Constraint { "default-node.type", "=", "audio.sink" },
    },
  },
  execute = function (event)
    local source = event:get_source ()
    local metadata = source:call ("get-object-manager", "metadata"):lookup {
      Constraint { "metadata.name", "=", "default" } }
    if not metadata then return end
    local raw = metadata:find (0, "default.configured.audio.sink")
    if not raw then return end
    local chosen = Json.Raw (raw):parse ().name
    if not chosen or not FORCEABLE [chosen] then return end

    local node = source:call ("get-object-manager", "node"):lookup {
      Constraint { "node.name", "=", chosen } }
    if not node then return end

    log:info ("afterlight: keeping chosen sink " .. chosen)
    event:set_data ("selected-node-priority", 100000)
    event:set_data ("selected-node", chosen)
  end
}:register ()
