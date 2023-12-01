local log = require "log"
local json = require "st.json"
local fields = require "fields"

local capabilities = require "st.capabilities"

local PresenceSensor = capabilities.presenceSensor
local MovementSensor = capabilities["stse.movementSensor"]

local MOVEMENT_TIMER = { "timer1", "timer2", "timer3", "timer4 " }
local MOVEMENT_TIME = 5

local device_manager = {}
device_manager.__index = device_manager

function device_manager.handle_status(driver, device, status)
    local MAIN = "main"
    local AREA1 = "area1"
    local AREA2 = "area2"
    local AREA3 = "area3"
    local AREA4 = "area4"
    local comps = {
        main = device.profile.components[MAIN],
        area1 = device.profile.components[AREA1],
        area2 = device.profile.components[AREA2],
        area3 = device.profile.components[AREA3],
        area4 = device.profile.components[AREA4]
    }
    if not status then
        log.error("device_manager.handle_status : status is nil")
        return
    end

    if not status["13.21.85"] == false then
        print("----- [13.21.8]")
        local area_id = math.floor(status["13.21.85"] / 256)
        local event_id = status["13.21.85"] % 256
        local event_action = "noMovement"

        local no_movement = function()
            device:emit_component_event(comps[string.format("area%d", area_id)], MovementSensor.movement("noMovement"))
        end
        device:set_field(MOVEMENT_TIMER[area_id], device.thread:call_with_delay(MOVEMENT_TIME, no_movement))

        if event_id == 0x01 then
            event_action = "enter"
        elseif event_id == 0x02 then
            event_action = "leave"
        elseif event_id == 0x10 then
            event_action = "approaching"
        elseif event_id == 0x20 then
            event_action = "goingAway"
        end

        if event_action ~= "noMovement" then
            device:emit_component_event(comps[string.format("area%d", area_id)], MovementSensor.movement(event_action))
        end

        if event_id == 0x04 then
            local target_comp
            if area_id == 1 then
                target_comp = comps[AREA1]
            elseif area_id == 2 then
                target_comp = comps[AREA2]
            elseif area_id == 3 then
                target_comp = comps[AREA3]
            elseif area_id == 4 then
                target_comp = comps[AREA4]
            end
            device:emit_component_event(target_comp, PresenceSensor.presence("present"))
        elseif event_id == 0x08 then
            local target_comp
            if area_id == 1 then
                target_comp = comps[AREA1]
            elseif area_id == 2 then
                target_comp = comps[AREA2]
            elseif area_id == 3 then
                target_comp = comps[AREA3]
            elseif area_id == 4 then
                target_comp = comps[AREA4]
            end
            device:emit_component_event(target_comp, PresenceSensor.presence("not present"))
        end
    end

    -- if not status["3.51.85"] == false then
    --     local event_id = "not present"
    --     if status["3.51.85"] == 1 then event_id = "present" end
    --     device:emit_component_event(comps[MAIN], PresenceSensor.presence(event_id))
    -- end

    if not status["3.1.85"] == false then
        print("----- [3.1.85]")
        local event_id = "not present"
        if tonumber(status["3.1.85"]) == 1 then event_id = "present" end
        -- device:emit_component_event(comps[AREA1], PresenceSensor.presence(event_id))
    end

    if not status["3.2.85"] == false then
        print("----- [3.2.85]")
        local event_id = "not present"
        if tonumber(status["3.2.85"]) == 1 then event_id = "present" end
        -- device:emit_component_event(comps[AREA2], PresenceSensor.presence(event_id))
    end

    if not status["3.3.85"] == false then
        print("----- [3.3.85]")
        local event_id = "not present"
        if tonumber(status["3.3.85"]) == 1 then event_id = "present" end
        device:emit_component_event(comps[AREA3], PresenceSensor.presence(event_id))
    end

    if not status["3.4.85"] == false then
        print("----- [3.4.85]")
        local event_id = "not present"
        if tonumber(status["3.4.85"]) == 1 then event_id = "present" end
        device:emit_component_event(comps[AREA4], PresenceSensor.presence(event_id))
    end

    if not status["0.4.85"] == false then
        device:emit_event(capabilities.illuminanceMeasurement.illuminance(tonumber(status["0.4.85"])))
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
