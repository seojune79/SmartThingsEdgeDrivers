local clusters = require "st.zigbee.zcl.clusters"
local cluster_base = require "st.zigbee.cluster_base"
local capabilities = require "st.capabilities"
local data_types = require "st.zigbee.data_types"
local utils = require "st.utils"
local switch_defaults = require "st.zigbee.defaults.switch_defaults"
local device_management = require "st.zigbee.device_management"
local OnOff = clusters.OnOff
local ColorControl = clusters.ColorControl
local Level = clusters.Level

local PRI_CLU = 0xFCC0
local PRI_ATTR = 0x0009
local MFG_CODE = 0x115F
local OP_MODE_ATTR = 0x0509
local SUB_MODE_ATTR = 0x050F

local MAIN_COMP = "main"
local LAMP1_COMP = "lamp1"
local LAMP2_COMP = "lamp2"
local MODE_COMP = "mode"
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
local dimming_rate = 20
local CONVERSION_CONSTANT = 1000000

local is_aqara_products = function(opts, driver, device, ...)
  return device:get_manufacturer() == FINGERPRINTS.mfr and device:get_model() == FINGERPRINTS.model
end

local function isRGBW_MODE(device)
  local lastMode = device:get_latest_state(MODE_COMP, capabilities.mode.ID, capabilities.mode.mode.NAME) or 0
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

local function switch_on_handler(driver, device, cmd)
  print("----- [switch_on_handler] entry")
  if cmd.component == "main" then
    print("----- [switch_on_handler] main")
    device:send(OnOff.commands.On(device):to_endpoint(1))
    if not isRGBW_MODE(device) then
      print("----- [switch_on_handler] main + color temp")
      device:send(OnOff.commands.On(device):to_endpoint(2))
    end
  elseif cmd.component == "lamp1" then
    print("----- [switch_on_handler] lamp1")
    device:send(OnOff.commands.On(device):to_endpoint(1))
  elseif cmd.component == "lamp2" then
    print("----- [switch_on_handler] lamp2")
    device:send(OnOff.commands.On(device):to_endpoint(2))
  end
  print("----- [switch_on_handler] entry")
end

local function switch_off_handler(driver, device, cmd)
  print("----- [switch_off_handler] entry")
  if cmd.component == MAIN_COMP then
    print("----- [switch_off_handler] main")
    device:send(OnOff.commands.Off(device):to_endpoint(1))
    if not isRGBW_MODE(device) then
      print("----- [switch_off_handler] main + color temp")
      device:send(OnOff.commands.Off(device):to_endpoint(2))
    end
  elseif cmd.component == LAMP1_COMP then
    print("----- [switch_off_handler] lamp1")
    device:send(OnOff.commands.Off(device):to_endpoint(1))
  elseif cmd.component == LAMP2_COMP then
    print("----- [switch_off_handler] lamp2")
    device:send(OnOff.commands.Off(device):to_endpoint(2))
  end
  print("----- [switch_off_handler] entry")
end

local function set_level_handler(driver, device, cmd)
  local level = math.floor(cmd.args.level / 100.0 * 254)
  if cmd.component == MAIN_COMP then
    device:send(Level.commands.MoveToLevelWithOnOff(device, level, dimming_rate):to_endpoint(1))
    if not isRGBW_MODE(device) then
      device:send(Level.commands.MoveToLevelWithOnOff(device, level, dimming_rate):to_endpoint(2))
    end
  elseif cmd.component == LAMP1_COMP then
    device:send(Level.commands.MoveToLevelWithOnOff(device, level, dimming_rate):to_endpoint(1))
  elseif cmd.component == LAMP2_COMP then
    device:send(Level.commands.MoveToLevelWithOnOff(device, level, dimming_rate):to_endpoint(2))
  end
end

local function set_color_temp_handler(driver, device, cmd)
  local temp_in_mired = utils.round(CONVERSION_CONSTANT / cmd.args.temperature)
  if cmd.component == MAIN_COMP then
    device:send(ColorControl.commands.MoveToColorTemperature(device, temp_in_mired, dimming_rate):to_endpoint(1))
    if not isRGBW_MODE(device) then
      device:send(ColorControl.commands.MoveToColorTemperature(device, temp_in_mired, dimming_rate):to_endpoint(2))
    end
  elseif cmd.component == LAMP1_COMP then
    device:send(ColorControl.commands.MoveToColorTemperature(device, temp_in_mired, dimming_rate):to_endpoint(1))
  elseif cmd.component == LAMP2_COMP then
    device:send(ColorControl.commands.MoveToColorTemperature(device, temp_in_mired, dimming_rate):to_endpoint(2))
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

local function onoff_handler(driver, device, value, zb_rx)
  print("----- [onoff_handler] entry")
  local main_comp = device.profile.components[MAIN_COMP]
  local lamp1_comp = device.profile.components[LAMP1_COMP]
  local lamp2_comp = device.profile.components[LAMP2_COMP]
  local evt = capabilities.switch.switch.off()
  if value.value then evt = capabilities.switch.switch.on() end

  if zb_rx.address_header.src_endpoint.value == 1 then
    print("----- [onoff_handler] src endpoint = 1")
    device:emit_component_event(main_comp, evt)
    if not isRGBW_MODE(device) then
      print("----- [onoff_handler/src endpoint = 1] COLOR TEMP Mode")
      device:emit_component_event(lamp1_comp, evt)
    end
  else
    print("----- [onoff_handler] src endpoint = 2")
    device:emit_component_event(lamp2_comp, evt)
  end
  print("----- [onoff_handler] exit")
end

local function current_level_handler(driver, device, value, zb_rx)
  local main_comp = device.profile.components[MAIN_COMP]
  local lamp1_comp = device.profile.components[LAMP1_COMP]
  local lamp2_comp = device.profile.components[LAMP2_COMP]
  local level = math.floor((value.value / 254.0 * 100) + 0.5)
  local evt = capabilities.switchLevel.level(level)

  if zb_rx.address_header.src_endpoint.value == 1 then
    device:emit_component_event(main_comp, evt)
    if not isRGBW_MODE(device) then
      device:emit_component_event(lamp1_comp, evt)
    end
  else
    device:emit_component_event(lamp2_comp, evt)
  end
end

local function current_color_temp_mireds_handler(driver, device, value, zb_rx)
  local main_comp = device.profile.components[MAIN_COMP]
  local lamp1_comp = device.profile.components[LAMP1_COMP]
  local lamp2_comp = device.profile.components[LAMP2_COMP]
  local mired = utils.round(CONVERSION_CONSTANT / value.value)
  local evt = capabilities.colorTemperature.colorTemperature(mired)

  if zb_rx.address_header.src_endpoint.value == 1 then
    device:emit_component_event(main_comp, evt)
    if not isRGBW_MODE(device) then
      device:emit_component_event(lamp1_comp, evt)
    end
  else
    device:emit_component_event(lamp2_comp, evt)
  end
end

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
  local endpoint = 1
  if component_id == LAMP2_COMP then endpoint = 2 end
  return endpoint
end

local function endpoint_to_component(device, ep)
  local component = MAIN_COMP
  if not isRGBW_MODE(device) then
    component = LAMP1_COMP
  end
  if ep == 2 then component = LAMP2_COMP end
  return component
end

local function device_init(driver, device)
  device:set_component_to_endpoint_fn(component_to_endpoint)
  device:set_endpoint_to_component_fn(endpoint_to_component)
end

local function device_added(driver, device)
  device:emit_component_event(device.profile.components[MODE_COMP], capabilities.mode.supportedModes(SUPPORTED_MODES, {visibility = {displayed = false}}))
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
    do_refresh(driver, device)
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

local function do_configure(driver, device)
  device:configure()
  device:send(device_management.build_bind_request(device, OnOff.ID, driver.environment_info.hub_zigbee_eui))
end

local function change_plugin_mode(device, value)
  local mode = 1
  local profile_name = "aqara-led-rgbw"
  if value == COLOR_TEMP_MODE then
    mode = 2
    profile_name = "aqara-led-temperature"
  end
  device:emit_component_event(device.profile.components[MODE_COMP], capabilities.mode.mode(SUPPORTED_MODES[mode]))
  device:try_update_metadata({ profile = profile_name })
end

local function op_mode_handler(driver, device, value)
  print(string.format("----- [op_mode_handler] entry"))
  local current_mode = value.value
  print(string.format("----- [op_mode_handler] current_mode = %d",current_mode))
  if not device:get_field(MODE_STATUS) then -- before init
    print(string.format("----- [op_mode_handler] before init"))
    device:set_field(MODE_STATUS, "init", {persist = true})
    if current_mode == COLOR_TEMP_MODE then
      change_plugin_mode(device, COLOR_TEMP_MODE)
    else
      device:emit_component_event(device.profile.components[MODE_COMP], capabilities.mode.mode(SUPPORTED_MODES[1]))
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
    change_plugin_mode(device, COLOR_TEMP_MODE)
  else
    change_plugin_mode(device, RGBW_MODE)
  end
end

local aqara_lightstrip_driver_handler = {
  NAME = "Aqara Lightstrip Driver Handler",
  capability_handlers = {
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME] = switch_on_handler,
      [capabilities.switch.commands.off.NAME] = switch_off_handler
    },
    [capabilities.switchLevel.ID] = {
      [capabilities.switchLevel.commands.setLevel.NAME] = set_level_handler
    },
    [capabilities.colorTemperature.ID] = {
      [capabilities.colorTemperature.commands.setColorTemperature.NAME] = set_color_temp_handler,
    },
    [capabilities.colorControl.ID] = {
      [capabilities.colorControl.commands.setColor.NAME] = set_color_handler
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
      [OnOff.ID] = {
        [OnOff.attributes.OnOff.ID] = onoff_handler
      },
      [Level.ID] = {
        [Level.attributes.CurrentLevel.ID] = current_level_handler
      },
      [ColorControl.ID] = {
        [ColorControl.attributes.ColorTemperatureMireds.ID] = current_color_temp_mireds_handler,
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
    infoChanged = device_info_changed,
    doConfigure = do_configure
  },
  can_handle = is_aqara_products
}

return aqara_lightstrip_driver_handler
