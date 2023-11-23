local clusters = require "st.zigbee.zcl.clusters"
local cluster_base = require "st.zigbee.cluster_base"
local capabilities = require "st.capabilities"
local data_types = require "st.zigbee.data_types"
local utils = require "st.utils"
local switch_defaults = require "st.zigbee.defaults.switch_defaults"
local discovery = require "aqara-strip/discovery"
local OnOff = clusters.OnOff
local ColorControl = clusters.ColorControl
local Level = clusters.Level

local PRI_CLU = 0xFCC0
local PRI_ATTR = 0x0009
local MFG_CODE = 0x115F
local OP_MODE_ATTR = 0x0509
local SUB_MODE_ATTR = 0x050F

local CURRENT_X = "current_x_value" -- y value from xyY color space
local CURRENT_Y = "current_y_value" -- x value from xyY color space
local Y_TRISTIMULUS_VALUE = "y_tristimulus_value" -- Y tristimulus value which is used to convert color xyY -> RGB -> HSV
local HUESAT_TIMER = "huesat_timer"
local TARGET_HUE = "target_hue"
local TARGET_SAT = "target_sat"
local MODE_STATUS = "init_status"
local RGBW_MODE = 0x0003
local COLOR_TEMP_MODE = 0x0001
local SUPPORTED_MODES = { "rgbw", "dualColorTemperature" }
local FINGERPRINTS = { mfr = "LUMI", model = "lumi.dimmer.rcbac1" }

local is_aqara_products = function(opts, driver, device, ...)
  return device:get_manufacturer() == FINGERPRINTS.mfr and device:get_model() == FINGERPRINTS.model
end

local function isRGBW_MODE(device)
  local lastMode = device:get_latest_state("main", capabilities.mode.ID, capabilities.mode.mode.NAME) or 0
  local ret = false
  if lastMode == SUPPORTED_MODES[1] then ret = true end
  return ret
end

local function store_xyY_values(device, x, y, Y)
  device:set_field(Y_TRISTIMULUS_VALUE, Y)
  device:set_field(CURRENT_X, x)
  device:set_field(CURRENT_Y, y)
end

local query_device = function(device)
  return function()
    device:send(ColorControl.attributes.CurrentX:read(device))
    device:send(ColorControl.attributes.CurrentY:read(device))
  end
end

local function set_color_handler(driver, device, cmd)
  print("----- [set_color_handler]")
  -- Cancel the hue/sat timer if it's running, since setColor includes both hue and saturation
  local huesat_timer = device:get_field(HUESAT_TIMER)
  if huesat_timer ~= nil then
    device.thread:cancel_timer(huesat_timer)
    device:set_field(HUESAT_TIMER, nil)
  end

  local hue = (cmd.args.color.hue ~= nil and cmd.args.color.hue > 99) and 99 or cmd.args.color.hue
  local sat = cmd.args.color.saturation

  local x, y, Y = utils.safe_hsv_to_xy(hue, sat)
  store_xyY_values(device, x, y, Y)
  switch_defaults.on(driver, device, cmd)

  device:send(ColorControl.commands.MoveToColor(device, x, y, 0x0000))

  device:set_field(TARGET_HUE, nil)
  device:set_field(TARGET_SAT, nil)
  device.thread:call_with_delay(2, query_device(device))
end

-- local huesat_timer_callback = function(driver, device, cmd)
--   return function()
--     local hue = device:get_field(TARGET_HUE)
--     local sat = device:get_field(TARGET_SAT)
--     hue = hue ~= nil and hue or device:get_latest_state("main", capabilities.colorControl.ID, capabilities.colorControl.hue.NAME)
--     sat = sat ~= nil and sat or device:get_latest_state("main", capabilities.colorControl.ID, capabilities.colorControl.saturation.NAME)
--     cmd.args = {
--       color = {
--         hue = hue,
--         saturation = sat
--       }
--     }
--     set_color_handler(driver, device, cmd)
--   end
-- end

-- local function set_hue_sat_helper(driver, device, cmd, hue, sat)
--   local huesat_timer = device:get_field(HUESAT_TIMER)
--   if huesat_timer ~= nil then
--     device.thread:cancel_timer(huesat_timer)
--     device:set_field(HUESAT_TIMER, nil)
--   end
--   if hue ~= nil and sat ~= nil then
--     cmd.args = {
--       color = {
--         hue = hue,
--         saturation = sat
--       }
--     }
--     set_color_handler(driver, device, cmd)
--   else
--     if hue ~= nil then
--       device:set_field(TARGET_HUE, hue)
--     elseif sat ~= nil then
--       device:set_field(TARGET_SAT, sat)
--     end
--     device:set_field(HUESAT_TIMER, device.thread:call_with_delay(0.2, huesat_timer_callback(driver, device, cmd)))
--   end
-- end

-- local function set_hue_handler(driver, device, cmd)
--   print("----- [set_hue_handler]")
--   set_hue_sat_helper(driver, device, cmd, cmd.args.hue, device:get_field(TARGET_SAT))
-- end

-- local function set_saturation_handler(driver, device, cmd)
--   print("----- [set_saturation_handler]")
--   set_hue_sat_helper(driver, device, cmd, device:get_field(TARGET_HUE), cmd.args.saturation)
-- end

local function current_x_attr_handler(driver, device, value, zb_rx)
  print("-----[current_x_attr_handler]")
  local Y_tristimulus = device:get_field(Y_TRISTIMULUS_VALUE)
  local y = device:get_field(CURRENT_Y)
  local x = value.value

  if y then
    local hue, saturation = utils.safe_xy_to_hsv(x, y, Y_tristimulus)

    device:emit_event(capabilities.colorControl.hue(hue))
    device:emit_event(capabilities.colorControl.saturation(saturation))
  end

  device:set_field(CURRENT_X, x)
end

local function current_y_attr_handler(driver, device, value, zb_rx)
  print("-----[current_y_attr_handler]")
  local Y_tristimulus = device:get_field(Y_TRISTIMULUS_VALUE)
  local x = device:get_field(CURRENT_X)
  local y = value.value

  if x then
    local hue, saturation = utils.safe_xy_to_hsv(x, y, Y_tristimulus)

    device:emit_event(capabilities.colorControl.hue(hue))
    device:emit_event(capabilities.colorControl.saturation(saturation))
  end

  device:set_field(CURRENT_Y, y)
end

local function set_mode_handler(driver, device, command)
  local set_enum = command.args.mode
  local set_mode = RGBW_MODE
  print("----- [set_mode_handler] command.args.mode = "..set_enum)
  if set_enum == SUPPORTED_MODES[2] then
    set_mode = COLOR_TEMP_MODE
  end
  device:send(cluster_base.write_manufacturer_specific_attribute(device,
    PRI_CLU, OP_MODE_ATTR, MFG_CODE, data_types.Uint32, set_mode))
end

local function do_refresh(driver, device)
  print("----- [do_refresh] entry")
  if isRGBW_MODE(device) then
    device:send(OnOff.attributes.OnOff:read(device))
    device:send(Level.attributes.CurrentLevel:read(device))
    device:send(ColorControl.attributes.ColorTemperatureMireds:read(device))
    device:send(ColorControl.attributes.CurrentX:read(device))
    device:send(ColorControl.attributes.CurrentY:read(device))
  else
    device:send(OnOff.attributes.OnOff:read(device):to_endpoint(0x01))
    device:send(Level.attributes.CurrentLevel:read(device):to_endpoint(0x01))
    device:send(ColorControl.attributes.ColorTemperatureMireds:read(device):to_endpoint(0x01))
    device:send(OnOff.attributes.OnOff:read(device):to_endpoint(0x02))
    device:send(Level.attributes.CurrentLevel:read(device):to_endpoint(0x02))
    device:send(ColorControl.attributes.ColorTemperatureMireds:read(device):to_endpoint(0x02))
  end
end

local function component_to_endpoint(device, component_id)
  local endpoint = 2
  if component_id == "main" then endpoint = 1 end
  return endpoint
end

local function endpoint_to_component(device, ep)
  local component = "sub"
  if ep == 1 then component = "main" end
  return component
end

local function device_init(driver, device)
  device:set_component_to_endpoint_fn(component_to_endpoint)
  device:set_endpoint_to_component_fn(endpoint_to_component)
end

local function device_added(driver, device)
  device:emit_event(capabilities.mode.supportedModes(SUPPORTED_MODES, {visibility = {displayed = false}}))
  -- Set private attribute
  device:send(cluster_base.write_manufacturer_specific_attribute(device,
    PRI_CLU, PRI_ATTR, MFG_CODE, data_types.Uint8, 1))
  device:send(cluster_base.read_manufacturer_specific_attribute(device,
    PRI_CLU, OP_MODE_ATTR, MFG_CODE))
end

local function set_restore_powerState(device)
  device:send(cluster_base.write_manufacturer_specific_attribute(device,
    PRI_CLU, 0x0201, MFG_CODE, data_types.Boolean, device.preferences["stse.restorePowerState"]))
end

local function set_light_fadeInTimeState(device)
  local fadeInTime = device.preferences["stse.lightFadeInTimeInSec"] * 10
  device:send(clusters.Level.attributes.OnTransitionTime:write(device, fadeInTime):to_endpoint(0x01))
  if not isRGBW_MODE(device) then
    device:send(clusters.Level.attributes.OnTransitionTime:write(device, fadeInTime):to_endpoint(0x02))
  end
end

local function set_light_fadeOutTimeState(device)
  local fadeOutTime = device.preferences["stse.lightFadeOutTimeInSec"] * 10
  device:send(clusters.Level.attributes.OffTransitionTime:write(device, fadeOutTime):to_endpoint(0x01))
  if not isRGBW_MODE(device) then
    device:send(clusters.Level.attributes.OffTransitionTime:write(device, fadeOutTime):to_endpoint(0x02))
  end
end

local function device_info_changed(driver, device, event, args)
  if device.profile.id ~= args.old_st_store.profile.id then
    -- do_refresh(driver, device)
    set_restore_powerState(device)
    set_light_fadeInTimeState(device)
    set_light_fadeOutTimeState(device)
  end
  if device.preferences ~= nil then
    if device.preferences["stse.restorePowerState"] ~= nil and device.preferences["stse.restorePowerState"] ~= args.old_st_store.preferences["stse.restorePowerState"] then
      set_restore_powerState(device)
    end
    if device.preferences["stse.lightFadeInTimeInSec"] ~= nil and device.preferences["stse.lightFadeInTimeInSec"] ~= args.old_st_store.preferences["stse.lightFadeInTimeInSec"] then
      set_light_fadeInTimeState(device)
    end
    if device.preferences["stse.lightFadeOutTimeInSec"] ~= nil and device.preferences["stse.lightFadeOutTimeInSec"] ~= args.old_st_store.preferences["stse.lightFadeOutTimeInSec"] then
      set_light_fadeOutTimeState(device)
    end
  end
end

local function op_mode_handler(driver, device, value)
  print(string.format("----- [op_mode_handler] entry"))
  local current_mode = value.value
  print(string.format("----- [op_mode_handler] current_mode = %d",current_mode))
  if not device:get_field(MODE_STATUS) then -- before init
    print(string.format("----- [op_mode_handler] before init"))
    device:set_field(MODE_STATUS, "init", {persist = true})
    if current_mode == RGBW_MODE then
      device:send(cluster_base.write_manufacturer_specific_attribute(device,
        PRI_CLU, OP_MODE_ATTR, MFG_CODE, data_types.Uint32, RGBW_MODE))
    else
      device:emit_event(capabilities.mode.mode(SUPPORTED_MODES[2]))
      do_refresh(driver, device)
    end
  elseif device:get_field(MODE_STATUS) == "init" then -- init
    device:set_field(MODE_STATUS, "change", {persist = true})
    print(string.format("----- [op_mode_handler] after init"))
    local sub_mode = COLOR_TEMP_MODE
    if current_mode == COLOR_TEMP_MODE then sub_mode = RGBW_MODE end
    device:send(cluster_base.write_manufacturer_specific_attribute(device,
      PRI_CLU, SUB_MODE_ATTR, MFG_CODE, data_types.Uint32, sub_mode))
  end
  print(string.format("----- [op_mode_handler] exit"))
end

local function sub_mode_handler(driver, device, value)
  print(string.format("----- [sub_mode_handler] entry"))
  device:set_field(MODE_STATUS, "init", {persist = true})
  local sub_mode = value.value
  print(string.format("----- [sub_mode_handler] sub_mode = %d", sub_mode))
  if sub_mode == RGBW_MODE then -- new mode = dual color temperature
    device:emit_event(capabilities.mode.mode(SUPPORTED_MODES[2]))
    device:try_update_metadata({ profile = "aqara-led-temperature" })
  else
    device:emit_event(capabilities.mode.mode(SUPPORTED_MODES[1]))
    device:try_update_metadata({ profile = "aqara-led-rgbw" })
  end
end

local aqara_lightstrip_driver_handler = {
  NAME = "Aqara Lightstrip Driver Handler",
  discovery = discovery.handle_discovery,
  capability_handlers = {
    [capabilities.colorControl.ID] = {
      [capabilities.colorControl.commands.setColor.NAME] = set_color_handler,
      -- [capabilities.colorControl.commands.setHue.NAME] = set_hue_handler,
      -- [capabilities.colorControl.commands.setSaturation.NAME] = set_saturation_handler
    },
    [capabilities.mode.ID] = {
      [capabilities.mode.commands.setMode.NAME] = set_mode_handler
    },
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = do_refresh
    }
  },
  zigbee_handlers = {
    attr = {
      [ColorControl.ID] = {
        [ColorControl.attributes.CurrentX.ID] = current_x_attr_handler,
        [ColorControl.attributes.CurrentY.ID] = current_y_attr_handler
      },
      [PRI_CLU] = {
        [OP_MODE_ATTR] = op_mode_handler,
        [SUB_MODE_ATTR] = sub_mode_handler
      }
    }
  },
  lifecycle_handlers = {
    init = device_init,
    added = device_added,
    infoChanged = device_info_changed
  },
  can_handle = is_aqara_products
}

return aqara_lightstrip_driver_handler