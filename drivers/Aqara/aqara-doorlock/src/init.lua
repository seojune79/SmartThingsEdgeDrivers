local Driver = require "st.driver"
local security = require "st.security"
local ds = require "datastore"
local ZigbeeDriver = require "st.zigbee"
local data_types = require "st.zigbee.data_types"
local cluster_base = require "st.zigbee.cluster_base"
local battery_defaults = require "st.zigbee.defaults.battery_defaults"
local clusters = require "st.zigbee.zcl.clusters"
local PowerConfiguration = clusters.PowerConfiguration
local capabilities = require "st.capabilities"
local Battery = capabilities.battery
local Lock = capabilities.lock
local ds = require "datastore"
local log = require "log"
local base64 = require "st.base64"

local PRI_CLU = 0xFCC0
local PRI_ATTR = 0xFFF3
local MFG_CODE = 0x115F

local CHECK_TIME = 5

local seq_num = 0

my_ds = ds.init()

local function my_secret_data_handler(driver, secret_info)
  -- At time of writing this returns nothind beyond "secret_type = aqara"
  print("----- my_secret_data_handler")
  my_ds.shared_key = secret_info.shared_key
  my_ds.cloud_public_key = secret_info.cloud_public_key
  my_ds:save()
  -- print(string.format("-----[my_secret_data_handler] shared_key = %s", secret_info.shared_key))
  -- print(string.format("-----[my_secret_data_handler] cloud_pub_key = %s", secret_info.cloud_public_key))
  print(string.format("----- my_ds.shared_key = %s", my_ds.shared_key))
  print(string.format("----- my_ds.cloud_public_key = %s", my_ds.cloud_public_key))

  if my_ds.cloud_pub_key ~= nil then
    -- send cloud_pub_key
    -- device:send(cluster_base.write_manufacturer_specific_attribute(device,
    --   PRI_CLU, PRI_ATTR, MFG_CODE, data_types.OctetString, "\x3E"..my_ds.cloud_pub_key))
  end
end

local function device_init(driver, device)
  local power_configuration = {
    cluster = PowerConfiguration.ID,
    attribute = PowerConfiguration.attributes.BatteryVoltage.ID,
    minimum_interval = 30,
    maximum_interval = 3600,
    data_type = PowerConfiguration.attributes.BatteryVoltage.base_type,
    reportable_change = 1
  }

  battery_defaults.build_linear_voltage_init(2.6, 9.0)(driver, device)

  device:add_configured_attribute(power_configuration)
  device:add_monitored_attribute(power_configuration)
end

local function device_added(self, device)
  -- device:send(cluster_base.write_manufacturer_specific_attribute(device,
  --   PRI_CLU, PRI_ATTR, MFG_CODE, data_types.OctetString, "\x2B"))
  device:emit_event(Battery.battery(100))
  device:emit_event(Lock.lock("locked"))
end

local callback_func = function(driver, device, cmd)
  return function()
    print(string.format("-----[callback_func] my_ds.cloud_public_key = %s", my_ds.cloud_public_key))
    if my_ds.cloud_public_key ~= nil then
      local raw_data = base64.decode(my_ds.cloud_public_key)
      -- send cloud_public_key
      device:send(cluster_base.write_manufacturer_specific_attribute(device,
        PRI_CLU, PRI_ATTR, MFG_CODE, data_types.OctetString, "\x3E" .. raw_data))
    end
  end
end

local function locks_handler(driver, device, value, zb_rx)
  local param = value.value
  local header = string.sub(param, 0, 1)

  if header == "\x3E" then
    -- recv lock_pub_key
    print("----- pub key")
    device:set_field(CHECK_TIME, device.thread:call_with_delay(CHECK_TIME, callback_func(driver, device)))
    local zigbee_id = device.zigbee_eui
    local locks_pub_key = string.sub(param, 2, string.len(param))
    local mn_id = "0AE0"
    local setup_id = "006"
    local product_id = "337dbf83-af55-449c-824b-54ffcbb3afb6"
    local res, err = security.get_aqara_secret(device.zigbee_eui, locks_pub_key, "AqaraDoorlock K100", mn_id, setup_id,
      product_id)
    if res then
      print(res)
    end
  elseif header == "\x00" then
    local opts = { cipher = "aes256-ecb" }
    local payload = security.decrypt_bytes(string.sub(param, 2, string.len(param)), my_ds.shared_key, opts)

    local op_code = string.byte(payload, 1)
    seq_num = string.byte(payload, 2)
    local payload_data = string.sub(payload, 3, string.len(payload))
    local func_id = string.byte(payload_data, 1) ..
        "." ..
        string.byte(payload_data, 2) .. "." .. ((string.byte(payload_data, 3) << 8) + (string.byte(payload_data, 4)))
    print("---------- func_id = " .. func_id)

    if func_id == "13.41.85" then
      -- device:emit_event(Lock.lock("unlocked"))
    elseif func_id == "13.31.85" then
      if string.byte(5) == 0 then
        device:emit_event(Lock.lock("unlocked"))
      else
        device:emit_event(Lock.lock("locked"))
      end
    end
  end
end

local aqara_locks_handler = {
  NAME = "Aqara Doorlock K100",
  supported_capabilities = {
    Lock,
    Battery,
    capabilities.refresh,
  },
  zigbee_handlers = {
    attr = {
      [PRI_CLU] = {
        [PRI_ATTR] = locks_handler
      }
    }
  },
  lifecycle_handlers = {
    init = device_init,
    added = device_added
  },
  secret_data_handler = my_secret_data_handler,
}

local aqara_locks_driver = ZigbeeDriver("aqara_locks_k100", aqara_locks_handler)
aqara_locks_driver:run()
