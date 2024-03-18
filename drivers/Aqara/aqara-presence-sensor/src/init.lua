local log = require "log"

local capabilities = require "st.capabilities"
local Driver = require "st.driver"
local utils = require "st.utils"

local discovery = require "discovery"
local fields = require "fields"

local fp2_discovery_helper = require "fp2.discovery_helper"
local fp2_device_manager = require "fp2.device_manager"
local multipleZonePresence = require "multipleZonePresence"
local EventSource = require "lunchbox.sse.eventsource"

local PresenceSensor = capabilities.presenceSensor
local MovementSensor = capabilities["stse.movementSensor"]

local DEFAULT_MONITORING_INTERVAL = 300
local CREDENTIAL_KEY_HEADER = "Authorization"

local function handle_sse_event(driver, device, msg)
  driver.device_manager.handle_sse_event(driver, device, msg.type, msg.data)
end

local function status_update(driver, device)
  print("----- [status_update] entry")
  local conn_info = device:get_field(fields.CONN_INFO)
  if not conn_info then
    log.warn(string.format("refresh : failed to find conn_info, dni = %s", device.device_network_id))
  else
    local resp, err, status = conn_info:get_attr()

    if err or status ~= 200 then
      log.error(string.format("refresh : failed to get attr, dni= %s, err= %s, status= %s", device.device_network_id, err,
        status))
      if status == 404 then
        log.info(string.format("refresh : deleted, dni = %s", device.device_network_id))
        device:offline()
      end
    else
      if not resp["0.4.85"] == false then
        device:emit_event(capabilities.illuminanceMeasurement.illuminance(tonumber(resp["0.4.85"])))
      end

      local event_action = "not present"
      if not resp["3.51.85"] == false and resp["3.51.85"] == "1" then event_action = "present" end
      -- device:emit_component_event(device.profile.components["main"], PresenceSensor.presence(event_action))
      device:emit_event(PresenceSensor.presence(event_action))

      event_action = multipleZonePresence.notPresent
      if not resp["3.1.85"] == false and resp["3.1.85"] == "1" then event_action = multipleZonePresence.present end
      multipleZonePresence.changeState("1", event_action)
      print("----- [status_update] 3.1.85 = "..event_action)

      event_action = multipleZonePresence.notPresent
      if not resp["3.2.85"] == false and resp["3.2.85"] == "1" then event_action = multipleZonePresence.present end
      multipleZonePresence.changeState("2", event_action)
      print("----- [status_update] 3.2.85 = "..event_action)

      event_action = multipleZonePresence.notPresent
      if not resp["3.3.85"] == false and resp["3.3.85"] == "1" then event_action = multipleZonePresence.present end
      multipleZonePresence.changeState("3", event_action)
      print("----- [status_update] 3.3.85 = "..event_action)

      event_action = multipleZonePresence.notPresent
      if not resp["3.4.85"] == false and resp["3.4.85"] == "1" then event_action = multipleZonePresence.present end
      multipleZonePresence.changeState("4", event_action)
      print("----- [status_update] 3.4.85 = "..event_action)

      device:emit_event(MovementSensor.movement("noMovement"))
    end
  end
  print("----- [status_update] exit")
end

local function create_sse(driver, device, credential)
  log.info(string.format("create_sse : dni = %s", device.device_network_id))
  local conn_info = device:get_field(fields.CONN_INFO)

  if not driver.device_manager.is_valid_connection(driver, device, conn_info) then
    log.error("create_sse : invalid connection")
    return
  end

  local sse_url = driver.device_manager.get_sse_url(driver, device, conn_info)
  if not sse_url then
    log.error("failed to get sse_url")
  else
    log.trace(string.format("Creating SSE EventSource for %s, sse_url= %s", device.device_network_id, sse_url))
    local eventsource = EventSource.new(sse_url, { [CREDENTIAL_KEY_HEADER] = credential }, nil)
    -- sync
    status_update(driver, device)
    -- end of sync

    eventsource.onmessage = function(msg)
      if msg then
        handle_sse_event(driver, device, msg)
      end
    end

    eventsource.onerror = function()
      log.error(string.format("Eventsource error: dni= %s", device.device_network_id))
      device:offline()
    end

    eventsource.onopen = function()
      log.info(string.format("Eventsource open: dni = %s", device.device_network_id))
      device:online()
    end

    local old_eventsource = device:get_field(fields.EVENT_SOURCE)
    if old_eventsource then
      log.info(string.format("Eventsource Close: dni = %s", device.device_network_id))
      old_eventsource:close()
    end
    device:set_field(fields.EVENT_SOURCE, eventsource)
  end
end

local function update_connection(driver, device, device_ip, device_info)
  local device_dni = device.device_network_id
  log.info(string.format("update connection, dni = %s", device_dni))

  local conn_info = driver.discovery_helper.get_connection_info(driver, device_dni, device_ip, device_info)

  local credential = device:get_field(fields.CREDENTIAL)

  conn_info:add_header(CREDENTIAL_KEY_HEADER, credential)

  if driver.device_manager.is_valid_connection(driver, device, conn_info) then
    device:set_field(fields.CONN_INFO, conn_info)

    create_sse(driver, device, credential)
  end
end


local function find_new_connetion(driver, device)
  log.info(string.format("find new connection for dni= %s", device.device_network_id))
  local ip_table = discovery.find_ip_table(driver)
  local ip = ip_table[device.device_network_id]
  if ip then
    device:set_field(fields.DEVICE_IPV4, ip, { persist = true })
    local device_info = device:get_field(fields.DEVICE_INFO)
    update_connection(driver, device, ip, device_info)
  end
end

local function check_and_update_connection(driver, device)
  local conn_info = device:get_field(fields.CONN_INFO)
  if not driver.device_manager.is_valid_connection(driver, device, conn_info) then
    device:offline()
    find_new_connetion(driver, device)
    conn_info = device:get_field(fields.CONN_INFO)
  end

  if driver.device_manager.is_valid_connection(driver, device, conn_info) then
    device:online()
  end
end

local function create_monitoring_thread(driver, device, device_info)
  local old_timer = device:get_field(fields.MONITORING_TIMER)
  if old_timer ~= nil then
    log.info(string.format("monitoring_timer: dni= %s, remove old timer", device.device_network_id))
    device.thread:cancel_timer(old_timer)
  end

  local monitoring_interval = DEFAULT_MONITORING_INTERVAL

  log.info(string.format("create_monitoring_thread: dni= %s", device.device_network_id))
  local new_timer = device.thread:call_on_schedule(monitoring_interval, function()
    check_and_update_connection(driver, device)
    driver.device_manager.device_monitor(driver, device, device_info)
  end, "monitor_timer")
  device:set_field(fields.MONITORING_TIMER, new_timer)
end



local function do_refresh(driver, device, cmd)
  log.info(string.format("refresh : dni= %s", device.device_network_id))
  check_and_update_connection(driver, device)
  status_update(driver, device)
end

local function device_removed(driver, device)
  log.info(string.format("device_removed : dni= %s", device.device_network_id))
  local eventsource = device:get_field(fields.EVENT_SOURCE)
  if eventsource then
    log.info(string.format("Eventsource Close: dni= %s", device.device_network_id))
    eventsource:close()
  end
end

local function device_init(driver, device)
  log.info(string.format("device_init : dni = %s", device.device_network_id))

  if device:get_field(fields._INIT) then
    log.info(string.format("device_init : already initialized. dni = %s", device.device_network_id))
    return
  end

  local device_dni = device.device_network_id

  driver.controlled_devices[device_dni] = device

  local device_ip = device:get_field(fields.DEVICE_IPV4)
  local device_info = device:get_field(fields.DEVICE_INFO)
  local credential = device:get_field(fields.CREDENTIAL)

  if not credential then
    log.error("failed to find credential.")
    device:offline()
    return
  end

  log.trace(string.format("Creating device monitoring for %s", device.device_network_id))
  create_monitoring_thread(driver, device, device_info)
  update_connection(driver, device, device_ip, device_info)

  -- status_update(driver, device)
  multipleZonePresence.zoneInfoTable = utils.deep_copy(device:get_latest_state("main", multipleZonePresence.id, "zoneState", {}))
  multipleZonePresence.updateAttribute(driver, device)

  do_refresh(driver, device, nil)
  device:set_field(fields._INIT, true, { persist = false })
end

local lan_driver = Driver("aqara-fp2",
  {
    discovery = discovery.do_network_discovery,
    lifecycle_handlers = {
      added = discovery.device_added,
      init = device_init,
      removed = device_removed
    },
    capability_handlers = {
      [capabilities.refresh.ID] = {
        [capabilities.refresh.commands.refresh.NAME] = do_refresh,
      },
      [multipleZonePresence.capability] = {
        [multipleZonePresence.commands.createZone.name] = multipleZonePresence.commands.createZone.handler,
        [multipleZonePresence.commands.deleteZone.name] = multipleZonePresence.commands.deleteZone.handler,
        [multipleZonePresence.commands.updateZoneName.name] = multipleZonePresence.commands.updateZoneName.handler,
      }
    },
    discovery_helper = fp2_discovery_helper,
    device_manager = fp2_device_manager,
    controlled_devices = {},
  }
)

log.info("Starting lan driver")
lan_driver:run()
log.warn("lan driver exiting")
