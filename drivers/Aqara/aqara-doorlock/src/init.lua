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

local serial_num = 0
local seq_num = 0
local setup_device = nil

my_ds = ds.init()

local function my_secret_data_handler(driver, secret_info)
  -- At time of writing this returns nothind beyond "secret_type = aqara"
  print("----- [my_secret_data_handler] entry")
  my_ds.shared_key = secret_info.shared_key
  my_ds.cloud_public_key = secret_info.cloud_public_key
  my_ds:save()
  print(string.format("----- [my_secret_data_handler] my_ds.shared_key = %s", my_ds.shared_key))
  print(string.format("----- [my_secret_data_handler] my_ds.cloud_public_key = %s", my_ds.cloud_public_key))

  if my_ds.cloud_public_key ~= nil and setup_device ~= nil then
    local raw_data = base64.decode(my_ds.cloud_public_key)
    -- send cloud_pub_key
    setup_device:send(cluster_base.write_manufacturer_specific_attribute(setup_device,
      PRI_CLU, PRI_ATTR, MFG_CODE, data_types.OctetString, "\x3E"..raw_data))
    setup_device = nil
  else
    print("----- [my_secret_data_handler] cloud_pub_key or setup_device is nil")
  end
  print("----- [my_secret_data_handler] exit")
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
      -- local raw_data = base64.decode(my_ds.cloud_public_key)
      local raw_data = base64.decode("SkHRJ+nnz73P+ejuxTcs8l21Nk1WwkODewHyH61AW0CFeRSsPe9UVSTZwmd/42agqXk62QW54O2XDh2TvHLN6g==")
      -- send cloud_public_key
      device:send(cluster_base.write_manufacturer_specific_attribute(device,
        PRI_CLU, PRI_ATTR, MFG_CODE, data_types.OctetString, "\x3E" .. raw_data))
    end
  end
end

local function locks_handler(driver, device, value, zb_rx)
  print("----- [locks_handler] entry")
  local param = value.value
  local command = string.sub(param, 0, 1)

  if command == "\x3E" then
    if setup_device ~= nil then
      print("ongoing setup_device exist")
      return
    end
    -- recv lock_pub_key
    print("----- [locks_handler] recv: 0x3E")
    -- device:set_field(CHECK_TIME, device.thread:call_with_delay(CHECK_TIME, callback_func(driver, device)))
    setup_device = device
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
  elseif command == "\x93" then
    print("----- [locks_handler] recv: 0x93")
    local opts = { cipher = "aes256-ecb", padding = false }
    print("----- [locks_handler/0x93] before base64.decode")
    print(string.format("----- [locks_handler/0x93] my_ds.shared_key = %s", my_ds.shared_key))
    local raw_key = base64.decode(my_ds.shared_key)
    print(string.format("----- [locks_handler/0x93] raw_key = %s", raw_key))
    print("----- [locks_handler/0x93] before decrypt_bytes")
    local raw_data = string.sub(param, 2, string.len(param))
    -- print("----- [locks_handler/0x93] param = "..param)
    print("----- [locks_handler/0x93] raw_data = "..raw_data)
    print("----- [locks_handler/0x93] raw_key = "..raw_key)
    local msg = security.decrypt_bytes(raw_data, raw_key, opts)
    print("----- [locks_handler/0x93] after decrypt_bytes, msg = "..msg)

    local op_code = string.byte(msg, 1)
    serial_num = (string.byte(msg, 4) << 8) + string.byte(msg, 5)
    local text = string.sub(msg, 6, string.len(msg))

    local seq_num = string.byte(text, 3)
    local payload = string.sub(text, 4, string.len(text))


    local func_id = string.byte(payload, 1).."." ..string.byte(payload, 2) .. "." .. ((string.byte(payload, 3) << 8) + (string.byte(payload, 4)))
    print("---------- func_id = " .. func_id)
    local func_val_length = string.byte(payload, 5)
    print("---------- func_val_length = " .. func_val_length)

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
  print("----- [locks_handler] exit")
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
