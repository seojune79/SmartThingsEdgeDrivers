local security = require "st.security"
local ZigbeeDriver = require "st.zigbee"
local data_types = require "st.zigbee.data_types"
local cluster_base = require "st.zigbee.cluster_base"
local capabilities = require "st.capabilities"
local Battery = capabilities.battery
local Lock = capabilities.lock
local base64 = require "st.base64"

local PRI_CLU = 0xFCC0
local PRI_ATTR = 0xFFF3
local MFG_CODE = 0x115F

local serial_num = 0
local seq_num = 0

local function my_secret_data_handler(driver, device, secret_info)
  -- At time of writing this returns nothind beyond "secret_type = aqara"
  print("----- [my_secret_data_handler] entry")
  local shared_key = secret_info.shared_key
  local cloud_public_key = secret_info.cloud_public_key  

  device:set_field("sharedKey", shared_key, { persist = true })
  device:set_field("cloudPubKey", cloud_public_key, { persist = true })

  print(string.format("----- [my_secret_data_handler] shared_key = %s", device:get_field("sharedKey")))
  print(string.format("----- [my_secret_data_handler] cloud_public_key = %s", device:get_field("cloudPubKey")))

  if cloud_public_key ~= nil then
    local raw_data = base64.decode(cloud_public_key)
    -- send cloud_pub_key
    device:send(cluster_base.write_manufacturer_specific_attribute(device,
      PRI_CLU, PRI_ATTR, MFG_CODE, data_types.OctetString, "\x3E"..raw_data))
  else
    print("----- [my_secret_data_handler] cloud_pub_key is nil")
  end
  print("----- [my_secret_data_handler] exit")
end

local function device_added(self, device)
  device:emit_event(Battery.battery(100))
  device:emit_event(Lock.lock("locked"))
end

local function locks_handler(driver, device, value, zb_rx)
  print("----- [locks_handler] entry")
  local param = value.value
  local command = string.sub(param, 0, 1)

  if command == "\x3E" then
    -- recv lock_pub_key
    print("----- [locks_handler] recv: 0x3E")
    local locks_pub_key = string.sub(param, 2, string.len(param))
    local mn_id = "0AE0"
    local setup_id = "006"
    local product_id = "337dbf83-af55-449c-824b-54ffcbb3afb6"
    local res, err = security.get_aqara_secret(device.zigbee_eui, locks_pub_key, "AqaraDoorlock K100", mn_id, setup_id,
      product_id)
    if res then
      print(res)
    end
  elseif command == "\x93\x99" then
    print("----- [locks_handler] recv: 0x93")
    local shared_key = device:get_field("sharedKey")

    print("----- [locks_handler] recv: 0x93")
    local opts = { cipher = "aes256-ecb", padding = false }
    print("----- [locks_handler/0x93] before base64.decode")
    print(string.format("----- [locks_handler/0x93] shared_key = %s", shared_key))
    local raw_key = base64.decode(shared_key)
    print(string.format("----- [locks_handler/0x93] raw_key = %s", raw_key))
    print("----- [locks_handler/0x93] before decrypt_bytes")
    local raw_data = string.sub(param, 2, string.len(param))
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
  elseif command == "\x93" then
    print("----- [locks_handler] recv: 0x93")

    local shared_key = device:get_field("sharedKey")
    local opts = { cipher = "aes256-ecb", padding = false }
    local raw_key = base64.decode(shared_key)
    local raw_data = string.sub(param, 2, string.len(param))
    local msg = security.decrypt_bytes(raw_data, raw_key, opts)
    -- print(string.format("----- [locks_handler/0x93] shared_key = %s", shared_key))
    -- print(string.format("----- [locks_handler/0x93] raw_key = %s", raw_key))
    -- print("----- [locks_handler/0x93] before decrypt_bytes")
    print("----- [locks_handler/0x93] raw_data = "..raw_data)
    print("----- [locks_handler/0x93] after decrypt_bytes, msg = "..msg)

    -- local op_code = string.byte(msg, 1) -- 0x5b
    serial_num = (string.byte(msg, 3) << 8) + string.byte(msg, 4)
    local text = string.sub(msg, 5, string.len(msg))

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
    elseif func_id == "8.0.2223" then
      -- local value = string.sub(payload, 5, string.len(payload))
      local value = string.sub(payload, 6, func_val_length)
      print("----- [8.0.2223] = "..value)
    elseif func_id == "13.56.85" then
      local value = (string.byte(payload, 6) << 24) + (string.byte(payload, 7) << 16) + (string.byte(payload, 8) << 8) + string.byte(payload, 9)
      print("----- [13.56.85] = "..value)
      device:emit_event(Battery.battery(value))
    elseif func_id == "13.55.85" then
      local value = (string.byte(payload, 6) << 24) + (string.byte(payload, 7) << 16) + (string.byte(payload, 8) << 8) + string.byte(payload, 9)
      print("----- [13.56.85] = "..value)
      -- device:emit_event(Battery.battery(value))
    elseif func_id == "13.88.85" then
      local value = string.byte(payload, 6)
      print("----- [13.88.85] = "..value)
      if value == 0x4 then
        device:emit_event(Lock.lock("locked"))
      elseif value == 0x6 then
        device:emit_event(Lock.lock("unlocked"))
      elseif value == 0x8 then
        device:emit_event(Lock.lock("not fully locked"))
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
    added = device_added
  },
  secret_data_handlers = {
    [security.SECRET_KIND_AQARA] = my_secret_data_handler
  }
}

local aqara_locks_driver = ZigbeeDriver("aqara_locks_k100", aqara_locks_handler)
aqara_locks_driver:run()
