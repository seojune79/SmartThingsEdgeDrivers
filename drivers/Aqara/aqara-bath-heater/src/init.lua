local log = require "log"
local capabilities = require "st.capabilities"
local ZigbeeDriver = require "st.zigbee"
local clusters = require "st.zigbee.zcl.clusters"
local cluster_base = require "st.zigbee.cluster_base"
local data_types = require "st.zigbee.data_types"
local utils = require "st.utils"
local bit_conv = require "u64bit_utils"

-- Component
local MAIN = "main"
local LIGHT = "light"

-- Private
local PRI_CLU = 0xFCC0
local REMOTE_ATTR = 0x024F
local MFG_CODE = 0x115F

-- Thermostat
local Thermostat = clusters.Thermostat
local ThermostatSystemMode = Thermostat.attributes.SystemMode


local THERMOSTAT_STATUS = "thermostatStatus"

local THERMOSTAT_MODE_MAP = {
  [ThermostatSystemMode.SLEEP] = capabilities.thermostatMode.thermostatMode.on, -- ventilation(0x09)
  [ThermostatSystemMode.OFF] = capabilities.thermostatMode.thermostatMode.off, -- off(0x00)
  [ThermostatSystemMode.HEAT] = capabilities.thermostatMode.thermostatMode.heat, -- warm air(0x04)
  [ThermostatSystemMode.DRY] = capabilities.thermostatMode.thermostatMode.dryair, -- drying(0x08)
  [ThermostatSystemMode.FAN_ONLY] = capabilities.thermostatMode.thermostatMode.fanonly -- blowing(0x07)
}

local SUPPORTED_THERMOSTAT_MODES = {
  capabilities.thermostatMode.thermostatMode.on.NAME,
  capabilities.thermostatMode.thermostatMode.off.NAME,
  capabilities.thermostatMode.thermostatMode.heat.NAME,
  capabilities.thermostatMode.thermostatMode.dryair.NAME,
  capabilities.thermostatMode.thermostatMode.fanonly.NAME
}

local SUPPORTED_FAN_MODES = {
  capabilities.fanOscillationMode.fanOscillationMode.swing.NAME,
  capabilities.fanOscillationMode.fanOscillationMode.fixed.NAME
}

-- Light
local OnOff = clusters.OnOff
local Level = clusters.Level
local ColorControl = clusters.ColorControl

-- utils
local CONVERSION_CONSTANT = 1000000

local function get_current_thermostat_mode(device)
  return device:get_latest_state(MAIN, capabilities.thermostatMode.ID, capabilities.thermostatMode.thermostatMode.NAME)
end

local function toValue(payload, start, length)
  return utils.deserialize_int(payload, length, false, false)
end

local function toHex(value, length)
  return utils.serialize_int(value, length, false, false)
end

local function device_added(self, device)
  -- mode init
  device:emit_component_event(device.profile.components[MAIN], capabilities.thermostatMode.supportedThermostatModes(SUPPORTED_THERMOSTAT_MODES, { visibility = { displayed = false } }))
  device:emit_component_event(device.profile.components[MAIN], capabilities.thermostatHeatingSetpoint.heatingSetpointRange({ value = { minimum = 16, maximum = 45, step = 0.1 }, unit = "C" }))
  if device:get_latest_state(MAIN, capabilities.thermostatHeatingSetpoint.ID, capabilities.thermostatHeatingSetpoint.heatingSetpoint.NAME) == nil then
    device:emit_component_event(device.profile.components[MAIN], capabilities.thermostatHeatingSetpoint.heatingSetpoint({value = 21, unit = "C"}))
  end
  device:emit_component_event(device.profile.components[MAIN], capabilities.fanOscillationMode.supportedFanOscillationModes(SUPPORTED_FAN_MODES, { visibility = { displayed = false } }))
end

-- capabilities handlers

local function set_thermostat_mode(driver, device, command)
  local remote_cmd = 0xffffffffffffffff

  if command.args.mode == "off" then -- off
    remote_cmd = bit_conv.set_bits(remote_cmd, 28, 4, 0x0)
  elseif command.args.mode == "heat" then -- heat(warm)
    remote_cmd = bit_conv.set_bits(remote_cmd, 24, 4, 0x0)
  elseif command.args.mode == "fanonly" then -- blowing(wind)
    remote_cmd = bit_conv.set_bits(remote_cmd, 24, 4, 0x4)
  elseif command.args.mode == "dryair" then -- dry
    remote_cmd = bit_conv.set_bits(remote_cmd, 24, 4, 0x3)
  elseif command.args.mode == "on" then -- on
    remote_cmd = bit_conv.set_bits(remote_cmd, 24, 4, 0x5)
  end

  device:send(cluster_base.write_manufacturer_specific_attribute(device, PRI_CLU, REMOTE_ATTR, MFG_CODE, data_types.Uint64, toHex(remote_cmd, 8)))
end

local function set_heating_point(driver, device, command)
  local set_temperature = command.args.setpoint * 100
  local remote_cmd = 0xfffffffffffffffff
  remote_cmd = bit_conv.set_bits(remote_cmd, 48, 16, set_temperature )
  device:send(cluster_base.write_manufacturer_specific_attribute(device, PRI_CLU, REMOTE_ATTR, MFG_CODE, data_types.Uint64, toHex(remote_cmd, 8)))
end

local function set_fan_speed_handler(driver, device, command)
  local set_fan_speed = command.args.speed-1
  local remote_cmd = 0xfffffffffffffffff
  if set_fan_speed < 0 or set_fan_speed > 2 then set_fan_speed = 0xF end
  remote_cmd = bit_conv.set_bits(remote_cmd, 20, 4, set_fan_speed)
  device:send(cluster_base.write_manufacturer_specific_attribute(device, PRI_CLU, REMOTE_ATTR, MFG_CODE, data_types.Uint64, toHex(remote_cmd, 8)))
end

local function set_fan_oscillation_mode(driver, device, command)
  local remote_cmd = 0xfffffffffffffffff
  local set_mode = 0x3
  if command.args.fanOscillationMode == "swing" then set_mode = 0
  elseif command.args.fanOscillationMode == "fixed" then set_mode = 1 end
  remote_cmd = bit_conv.set_bits(remote_cmd, 16, 2, set_mode)
  device:send(cluster_base.write_manufacturer_specific_attribute(device, PRI_CLU, REMOTE_ATTR, MFG_CODE, data_types.Uint64, toHex(remote_cmd, 8)))
end

local function switch_on_handler(driver, device, command)
  device:send(OnOff.commands.On(device))
end

local function switch_off_handler(driver, device, command)
  device:send(OnOff.commands.Off(device))
end

local function set_level_handler(driver, device, command)
  local level = math.floor(command.args.level / 100.0 * 254)
  device:send(Level.commands.MoveToLevelWithOnOff(device, level))
end

local function set_color_temp_handler(driver, device, command)
  local temp_in_mired = utils.round(CONVERSION_CONSTANT / command.args.temperature)
  device:send(ColorControl.commands.MoveToColorTemperature(device, temp_in_mired))
end

local function do_refresh(self, device)
end

-- zigbee handlers

local function thermostat_mode_handler(driver, device, value, zb_rx)
  local thermostat_mode = value.value
  if THERMOSTAT_MODE_MAP[thermostat_mode] then
    device:emit_event(THERMOSTAT_MODE_MAP[thermostat_mode]())
  end
end

local function on_off_attr_handler(driver, device, value, zb_rx)
  local attr = capabilities.switch.switch
  device:emit_component_event(device.profile.components[LIGHT], value.value == false and attr.off() or attr.on())
end

local function light_level_handler(driver, device, value, zb_rx)
  local level = math.floor((value.value / 254.0 * 100) + 0.5)
  device:emit_component_event(device.profile.components[LIGHT], capabilities.switchLevel.level(level))
end

local function color_temp_mireds_handler(driver, device, value, zb_rx)
  local mired = utils.clamp_value(utils.round(CONVERSION_CONSTANT / value.value), 2700, 6500)
  device:emit_component_event(device.profile.components[LIGHT], capabilities.colorTemperature.colorTemperature(mired))
end

local function remote_signal_handler(driver, device, value, zb_rx)
  local status = utils.deserialize_int(value.value, 8, false, false)
  device:set_field(THERMOSTAT_STATUS, status, { persist = true })

  -- thermostat switch
  local thermostat_switch = bit_conv.get_bits(status, 28, 4)
  if thermostat_switch == 0 then device:emit_component_event(device.profile.components[MAIN], capabilities.thermostatMode.thermostatMode.off()) end

  -- thermostat mode
  local thermostat_mode = bit_conv.get_bits(status, 24, 4)
  if thermostat_mode == 0 then
    device:emit_component_event(device.profile.components[MAIN], capabilities.thermostatMode.thermostatMode.heat())
  elseif thermostat_mode == 4 then
    device:emit_component_event(device.profile.components[MAIN], capabilities.thermostatMode.thermostatMode.fanonly())
  elseif thermostat_mode == 3 then
    device:emit_component_event(device.profile.components[MAIN], capabilities.thermostatMode.thermostatMode.dryair())
  elseif thermostat_mode == 5 then
    device:emit_component_event(device.profile.components[MAIN], capabilities.thermostatMode.thermostatMode.on())
  end

  -- fan speed
  local fan_speed = bit_conv.get_bits(status, 0, 2)
  if fan_speed < 4 then
    device:emit_component_event(device.profile.components[MAIN], capabilities.fanSpeed.fanSpeed(fan_speed))
  end

  -- swing mode
  local swing_mode = bit_conv.get_bits(status, 16, 2)
  if swing_mode == 0 then
    device:emit_component_event(device.profile.components[MAIN], capabilities.fanOscillationMode.fanOscillationMode.swing())
  elseif swing_mode == 1 then
    device:emit_component_event(device.profile.components[MAIN], capabilities.fanOscillationMode.fanOscillationMode.fixed())
  end

  -- heating point
  local check_point1 = bit_conv.get_bits(status, 2, 6)
  local check_point2 = bit_conv.get_bits(status, 8, 8)
  local current_mode = get_current_thermostat_mode(device)
  -- if current_mode == capabilities.thermostatMode.thermostatMode.heat.NAME and check_point1 == 63 and check_point2 >= 254 then
  if check_point1 == 63 and check_point2 >= 254 then
    local heating_temperature = bit_conv.get_bits(status, 48, 16)
    if heating_temperature < 0xFFFF then
      device:emit_component_event(device.profile.components[MAIN], capabilities.thermostatHeatingSetpoint.heatingSetpoint({value = (heating_temperature/100), unit = "C"}))
    end
  end
end

local aqara_bath_heater_handler = {
  NAME = "Aqara Bath Heater T1",
  capability_handlers = {
    [capabilities.thermostatMode.ID] = {
      [capabilities.thermostatMode.commands.setThermostatMode.NAME] = set_thermostat_mode
    },
    [capabilities.thermostatHeatingSetpoint.ID] = {
      [capabilities.thermostatHeatingSetpoint.commands.setHeatingSetpoint.NAME] = set_heating_point
    },
    [capabilities.fanSpeed.ID] = {
      [capabilities.fanSpeed.commands.setFanSpeed.NAME] = set_fan_speed_handler,
    },
    [capabilities.fanOscillationMode.ID] = {
      [capabilities.fanOscillationMode.commands.setFanOscillationMode.NAME] = set_fan_oscillation_mode,
    },
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
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = do_refresh,
    },
  },
  zigbee_handlers = {
    attr = {
      [Thermostat.ID] = {
        [Thermostat.attributes.SystemMode.ID] = thermostat_mode_handler
      },
      [OnOff.ID] = {
        [OnOff.attributes.OnOff.ID] = on_off_attr_handler
      },
      [Level.ID] = {
        [Level.attributes.CurrentLevel.ID] = light_level_handler
      },
      [ColorControl.ID] = {
        [ColorControl.attributes.ColorTemperatureMireds.ID] = color_temp_mireds_handler
      },
      [PRI_CLU] = {
        [REMOTE_ATTR] = remote_signal_handler
      }
    }
  },
  lifecycle_handlers = {
    added = device_added
  },
  health_check = false,
}

local aqara_bath_heater_t1_driver = ZigbeeDriver("aqara_bath_heater_t1", aqara_bath_heater_handler)
aqara_bath_heater_t1_driver:run()

