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

function device_manager.presence_handler(driver, device, zone, evt_value)
    local evt_action = "not present"
    if evt_value == 1 then evt_action = "present" end
    device:emit_event(PresenceSensor.presence(evt_action))
end

function device_manager.zone_presence_handler(driver, device, zone, evt_value)
    local zoneInfo = multipleZonePresence.findZoneById(zone)
    if not zoneInfo then
        multipleZonePresence.createZone("zone"..zone, zone)
    end
    local evt_action = multipleZonePresence.notPresent
    if evt_value == 1 then evt_action = multipleZonePresence.present end
    multipleZonePresence.changeState(zone, evt_action)
    multipleZonePresence.updateAttribute(driver, device)
end

function device_manager.illuminance_handler(driver, device, zone, evt_value)
    device:emit_event(capabilities.illuminanceMeasurement.illuminance(evt_value))
end

local resource_id = {
    { id="3.51.85", zone="", event_handler=device_manager.presence_handler },
    { id="3.1.85", zone="1", event_handler=device_manager.zone_presence_handler },
    { id="3.2.85", zone="2", event_handler=device_manager.zone_presence_handler },
    { id="3.3.85", zone="3", event_handler=device_manager.zone_presence_handler },
    { id="3.4.85", zone="4", event_handler=device_manager.zone_presence_handler },
    { id="0.4.85", zone="", event_handler=device_manager.illuminance_handler }
}

function device_manager.handle_status(driver, device, status, pack)
    if not status then
        log.error("device_manager.handle_status : status is nil")
        return
    end
    for k, v in pairs(resource_id) do
        if not status[v.id] == false then
            v.event_handler(driver, device, v.zone, tonumber(status[v.id]))
            if pack then goto continue end
        end
    end
    ::continue::
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
        event_handler(driver, device, device_json, true)
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
