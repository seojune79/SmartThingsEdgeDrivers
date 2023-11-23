local log = require "log"
local discovery = {}

function discovery.handle_discovery(driver, _should_continue)
  log.info("Starting window shade sample Discovery")

  local metadata = {
    type = "ZIGBEE",
    device_network_id = "aqara-stripdriver",
    label = "aqara-stripdriver",
    profile = "aqara-led-temperature",
    manufacturer = "SmartThings",
    model = "v1",
    vendor_provided_label = nil
  }

  -- tell the cloud to create a new device record, will get synced back down
  -- and `device_added` and `device_init` callbacks will be called
  driver:try_create_device(metadata)
end

return discovery
