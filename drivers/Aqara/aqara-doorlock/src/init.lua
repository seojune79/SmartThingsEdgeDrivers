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

local function dump(str)
  return (str:gsub('.', function(c)
    return string.format('%02X', string.byte(c))
  end))
end

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
      PRI_CLU, PRI_ATTR, MFG_CODE, data_types.OctetString, "\x3E" .. raw_data))
  else
    print("----- [my_secret_data_handler] cloud_pub_key is nil")
  end
  print("----- [my_secret_data_handler] exit")
end

local function device_added(self, device)
  device:emit_event(Battery.battery(100))
  device:emit_event(Lock.lock("locked"))
end

local function toValue(payload, start, length)
  local ret = 0
  for i = start, start + length - 1 do
    ret = (ret << 8) + string.byte(payload, i)
  end
  return ret
end

local function locks_handler(driver, device, value, zb_rx)
  print("----- [locks_handler] entry")
  local param = value.value
  local command = string.sub(param, 0, 1)
  print("----- [locks_handler/test] param = " .. dump(param))

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
  elseif command == "\x93" then
    print("----- [locks_handler] recv: 0x93")
    local shared_key = device:get_field("sharedKey")
    local opts = { cipher = "aes256-ecb", padding = false }
    local raw_key = base64.decode(shared_key)
    local raw_data = string.sub(param, 2, string.len(param))
    local msg = security.decrypt_bytes(raw_data, raw_key, opts)
    serial_num = toValue(msg, 3, 2)
    local text = string.sub(msg, 5, string.len(msg))
    seq_num = string.byte(text, 3)
    local payload = string.sub(text, 4, string.len(text))

    -- local func_id = string.byte(payload, 1).."." ..string.byte(payload, 2) .. "." .. ((string.byte(payload, 3) << 8) + (string.byte(payload, 4)))
    local func_idA = toValue(payload, 1, 1)
    local func_idB = toValue(payload, 2, 1)
    local func_idC = toValue(payload, 3, 2)
    local func_id = func_idA .. "." .. func_idB .. "." .. func_idC
    local func_val_length = string.byte(payload, 5)
    print("---------- func_id = " .. func_id.." / length = "..func_val_length)

    if func_id == "8.0.2264" then -- 도어락 로컬 로그
      local log = string.sub(payload, 6, 5 + func_val_length)
      print("----- [8.0.2264] log = "..string.format("%s", log))
    elseif func_id == "8.0.2223" then -- firmware version
      local version = string.sub(payload, 6, 5 + func_val_length)
      device:emit_event(capabilities.firmwareUpdate.currentVersion({ value = version }))
      local new_ver = device:get_latest_state("main", capabilities.firmwareUpdate.ID,
        capabilities.firmwareUpdate.currentVersion.NAME) or 0
      print("----- [8.0.2223] new ver = " .. new_ver)
    else -- value가 숫자타입인 경우
      local value = toValue(payload, 6, func_val_length)
      print("----- ["..func_id.."] = "..value)

      if func_id == "13.31.85" then -- 열림/잠금 상태
        if value == 0 then
          device:emit_event(Lock.lock("unlocked"))
        elseif value == 1 then
          device:emit_event(Lock.lock("locked"))
        end
      elseif func_id == "13.88.85" then
        if value == 0x4 then
          device:emit_event(Lock.lock("locked"))
        elseif value == 0x6 then
          device:emit_event(Lock.lock("unlocked"))
        end
      elseif func_id == "13.17.85" then -- 문 이벤트
        if value == 2 then
          device:emit_event(Lock.lock("not fully locked"))
        end
      elseif func_id == "13.56.85" then -- 배터리 잔량(%)
        device:emit_event(Battery.battery(value))
      end
    end
  end
  print("----- [lock_handler] serial_num = " .. serial_num .. " / seq_num = " .. seq_num)
  print("----- [locks_handler] exit")
end

local function toHex(value, length)
  local ret = string.char(0xFF & value)
  for i = length, 2, -1 do
    ret = string.char(0xFF & (value >> 8 * (i - 1))) .. ret
  end
  return ret
end


local function send_msg(device, funcA, funcB, funcC, length, value)
  local payload = toHex(funcA, 1) .. toHex(funcB, 1) .. toHex(funcC, 2) .. toHex(length, 1) .. toHex(value, length)
  print("----- [send_msg] payload = " .. dump(payload))
  seq_num = seq_num + 1
  print("----- [send_msg] seq_num = " .. seq_num)
  local text = "\x00\x02" .. toHex(seq_num, 1) .. payload
  print("----- [send_msg] text = " .. dump(text))
  serial_num = serial_num + 1
  print("----- [send_msg] serial_num = " .. serial_num)
  local raw_data = "\x5B" .. toHex(string.len(text), 1) .. toHex(serial_num, 2) .. text
  print("----- [send_msg] raw_data = " .. dump(raw_data))
  for i = 1, 4 - (string.len(raw_data) % 4) do
    raw_data = raw_data .. "\x00"
  end
  print("----- [send_msg] raw_data + 0x00 ... = " .. dump(raw_data))

  local shared_key = device:get_field("sharedKey")
  local opts = { cipher = "aes256-ecb", padding = false }
  local raw_key = base64.decode(shared_key)
  local result = security.encrypt_bytes(raw_data, raw_key, opts)
  print("----- [send_msg] result = encrypt(raw_data) = " .. dump(result))
  local msg = "\x93" .. result
  print("----- [send_msg] msg = " .. dump(msg))
  device:send(cluster_base.write_manufacturer_specific_attribute(device,
    PRI_CLU, PRI_ATTR, MFG_CODE, data_types.OctetString, msg))
end

local function unlock_cmd_handler(driver, device, cmd)
  send_msg(device, 4, 17, 85, 1, 1) -- remote unlock by automation style
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
  capability_handlers = {
    [capabilities.lock.ID] = {
      [capabilities.lock.commands.unlock.NAME] = unlock_cmd_handler
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
