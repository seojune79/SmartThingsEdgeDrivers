local log = require "log"
local json = require "st.json"
local fields = require "fields"

local capabilities = require "st.capabilities"
local multipleZonePresence = require "multipleZonePresence"

local PresenceSensor = capabilities.presenceSensor
local MovementSensor = capabilities["stse.movementSensor"]

local MOVEMENT_TIME = 5

local device_manager = {}
device_manager.__index = device_manager

local FP2_MODES = { "ZoneDetection", "FallDetection", "SleepMonitoring" }

function device_manager.presence_handler(driver, device, zone, evt_value)
    local evt_action = "not present"
    if evt_value == 1 then evt_action = "present" end
    device:emit_event(PresenceSensor.presence(evt_action))
end

function device_manager.zone_presence_handler(driver, device, zone, evt_value)
    local zoneInfo = multipleZonePresence.findZoneById(zone)
    if not zoneInfo then
        multipleZonePresence.createZone("zone" .. zone, zone)
    end
    local evt_action = multipleZonePresence.notPresent
    if evt_value == 1 then evt_action = multipleZonePresence.present end
    multipleZonePresence.changeState(zone, evt_action)
    multipleZonePresence.updateAttribute(driver, device)
end

function device_manager.illuminance_handler(driver, device, zone, evt_value)
    device:emit_event(capabilities.illuminanceMeasurement.illuminance(evt_value))
end

function device_manager.work_mode_handler(driver, device, zone, evt_value)
    local mode = 1
    if evt_value == 0x05 then
        mode = 2
    elseif evt_value == 0x09 then
        mode = 3
    end
    device:emit_event(capabilities.mode.mode(FP2_MODES[mode]))
end

function device_manager.init_work_mode(device)
    device:emit_event(capabilities.mode.supportedModes(FP2_MODES, { visibility = {displayed=false}}))
    device:emit_event(capabilities.mode.mode(FP2_MODES[1]))
end

local resource_id = {
    ["3.51.85"] = { zone = "", event_handler = device_manager.presence_handler },
    ["3.1.85"] = { zone = "1", event_handler = device_manager.zone_presence_handler },
    ["3.2.85"] = { zone = "2", event_handler = device_manager.zone_presence_handler },
    ["3.3.85"] = { zone = "3", event_handler = device_manager.zone_presence_handler },
    ["3.4.85"] = { zone = "4", event_handler = device_manager.zone_presence_handler },
    ["3.5.85"] = { zone = "5", event_handler = device_manager.zone_presence_handler },
    ["3.6.85"] = { zone = "6", event_handler = device_manager.zone_presence_handler },
    ["3.7.85"] = { zone = "7", event_handler = device_manager.zone_presence_handler },
    ["3.8.85"] = { zone = "8", event_handler = device_manager.zone_presence_handler },
    ["3.9.85"] = { zone = "9", event_handler = device_manager.zone_presence_handler },
    ["3.10.85"] = { zone = "10", event_handler = device_manager.zone_presence_handler },
    ["3.11.85"] = { zone = "11", event_handler = device_manager.zone_presence_handler },
    ["3.12.85"] = { zone = "12", event_handler = device_manager.zone_presence_handler },
    ["3.13.85"] = { zone = "13", event_handler = device_manager.zone_presence_handler },
    ["3.14.85"] = { zone = "14", event_handler = device_manager.zone_presence_handler },
    ["3.15.85"] = { zone = "15", event_handler = device_manager.zone_presence_handler },
    ["3.16.85"] = { zone = "16", event_handler = device_manager.zone_presence_handler },
    ["3.17.85"] = { zone = "17", event_handler = device_manager.zone_presence_handler },
    ["3.18.85"] = { zone = "18", event_handler = device_manager.zone_presence_handler },
    ["3.19.85"] = { zone = "19", event_handler = device_manager.zone_presence_handler },
    ["3.20.85"] = { zone = "20", event_handler = device_manager.zone_presence_handler },
    ["3.21.85"] = { zone = "21", event_handler = device_manager.zone_presence_handler },
    ["3.22.85"] = { zone = "22", event_handler = device_manager.zone_presence_handler },
    ["3.23.85"] = { zone = "23", event_handler = device_manager.zone_presence_handler },
    ["3.24.85"] = { zone = "24", event_handler = device_manager.zone_presence_handler },
    ["3.25.85"] = { zone = "25", event_handler = device_manager.zone_presence_handler },
    ["3.26.85"] = { zone = "26", event_handler = device_manager.zone_presence_handler },
    ["3.27.85"] = { zone = "27", event_handler = device_manager.zone_presence_handler },
    ["3.28.85"] = { zone = "28", event_handler = device_manager.zone_presence_handler },
    ["3.29.85"] = { zone = "29", event_handler = device_manager.zone_presence_handler },
    ["3.30.85"] = { zone = "30", event_handler = device_manager.zone_presence_handler },
    ["0.4.85"] = { zone = "", event_handler = device_manager.illuminance_handler },
    ["14.49.85"] = { zone = "", event_handler = device_manager.work_mode_handler }
}

function device_manager.handle_status(driver, device, status)
    if not status then
        log.error("device_manager.handle_status : status is nil")
        return
    end

    for k, _ in pairs(status) do
        if resource_id[k] then
            resource_id[k].event_handler(driver, device, resource_id[k].zone, tonumber(status[k]))
        end
    end
end

function device_manager.update_status(driver, device)
    local conn_info = device:get_field(fields.CONN_INFO)

    -- if not conn_info then
    --     log.warn(string.format("device_manager.update_status : failed to find conn_info, dni = %s",
    --         device.device_network_id))
    --     return
    -- end

    -- local response, err, status = conn_info:get_attr()

    -- if err or status ~= 200 then
    --     log.error(string.format("device_manager.update_status : failed to get status, dni= %s, err= %s, status= %s",
    --         device.device_network_id, err, status))
    --     if status == 404 then
    --         log.info(string.format("device_manager.update_status : deleted, dni = %s", device.device_network_id))
    --         device:offline()
    --     end
    --     return
    -- end
end

local sse_event_handlers = {
    ["message"] = device_manager.handle_status
}

function device_manager.handle_sse_event(driver, device, event_type, data)
    local status, device_json = pcall(json.decode, data)

    local event_handler = sse_event_handlers[event_type]
    if event_handler then
        event_handler(driver, device, device_json)
    else
        log.error(string.format("handle_sse_event : unknown event type. dni = %s, event_type = '%s'",
            device.device_network_id, event_type))
    end
end

function device_manager.refresh(driver, device)
    device_manager.update_status(driver, device)
end

function device_manager.is_valid_connection(driver, device, conn_info)
    -- if not conn_info then
    --     log.error(string.format("device_manager.is_valid_connection : failed to find conn_info, dni = %s",
    --         device.device_network_id))
    --     return false
    -- end
    -- local _, err, status = conn_info:get_attr()
    -- if err or status ~= 200 then
    --     log.error(string.format(
    --     "device_manager.is_valid_connection : failed to connect to device, dni = %s, err= %s, status= %s",
    --         device.device_network_id, err, status))
    --     return false
    -- end

    return true
end

function device_manager.device_monitor(driver, device, device_info)
    --TODO: add device monitoring logic (ip change, online/offline, etc ..)
    log.info(string.format("device_monitor = %s", device.device_network_id))
    device_manager.refresh(driver, device)
end

function device_manager.get_sse_url(driver, device, conn_info)
    return conn_info:get_sse_url()
end

return device_manager
