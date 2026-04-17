-- ============================================================
-- init.lua  ·  Aqara Smart Bathroom Heater T1 — SmartThings Edge Driver
--
-- 제어 방식: 오직 0xFCC0/0x024F 녹미(Lumi) 공조 압축코드만 사용
-- Thermostat / FanControl 클러스터 일절 사용하지 않음
--
-- 압축코드 64-bit 레이아웃 (big-endian 기준, bit63=MSB):
--   [63:48] setpoint  int16 ×0.01°C  (bits15-8≥0xFE, bits7-2=63 일 때 유효)
--   [47:32] actual    int16 ×0.01°C  (동일 조건)
--   [31:28] power     0=off 1=on 2=toggle E=circle F=invalid
--   [27:24] mode      0=heat 1=cool 2=auto 3=dry 4=wind 5=breathe E=circle F=invalid
--   [23:20] fan_set   0=low 1=mid 2=high 3=auto E=circle F=invalid
--   [19:18] direction 0=horiz 1=vert 2=circle 3=invalid
--   [17:16] swing     0=swing 1=fix 2=circle
--   [15:8]  temp_set  0~240°C  0xFF=invalid
--   [7:2]   temp_act  0~63°C (실제)
--   [1:0]   fan_act   0=off 1=low 2=mid 3=high
--
-- 스펙 예시:
--   대기         : 0xFFFFFFFF 0FFF FFFF
--   난방 40°C 중속: 0x0FA0FFFF 101C FFFF
--   상태동기(OFF) : 0xFFFF0AF0 0FFF FFFC
-- ============================================================

local capabilities  = require "st.capabilities"
local ZigbeeDriver  = require "st.zigbee"
local cluster_base  = require "st.zigbee.cluster_base"
local zcl_clusters  = require "st.zigbee.zcl.clusters"
local data_types    = require "st.zigbee.data_types"

local aqara = require "aqara_cluster"

local OnOff        = zcl_clusters.OnOff
local Level        = zcl_clusters.Level
local ColorControl = zcl_clusters.ColorControl

-- ──────────────────────────────────────────────
-- AC 압축코드 상수
-- ──────────────────────────────────────────────
local PWR  = { OFF=0x0, ON=0x1 }
-- AC mode bits27-24:
--   0 = warm air (난방)     → ST "heat"
--   3 = drying  (건조)      → ST "dryair"
--   4 = blowing (열풍환풍)   → ST "cool"
--   5 = ventilation (환기)  → ST "fanonly"
local MODE = { HEAT=0x0, DRY=0x3, BLOW=0x4, VENT=0x5, INVALID=0xF }
-- bits23-20: fan speed
--   0=low  1=middle  2=high  3=auto
local FAN_LOW    = 0x0
local FAN_MID    = 0x1
local FAN_HIGH   = 0x2
local FAN_AUTO   = 0x3
local FAN_INVALID= 0xF
-- SmartThings mode("저속"/"중속"/"고속") → AC fan 값
local MODE_TO_FAN = { ["저속"]=FAN_LOW, ["중속"]=FAN_MID, ["고속"]=FAN_HIGH }
-- AC fan 값 → SmartThings mode 문자열, auto=중속
local FAN_TO_MODE = { [0]="저속", [1]="중속", [2]="고속", [3]="중속" }
-- bits17-16: swing 2비트만 설정 (bits19-18 direction은 no-change=0x3 유지)
--   swing=0 → 스윙 (바람 방향 자동 이동)
--   swing=1 → 고정 (바람 방향 고정)
local SWING_ON  = 0x0   -- bits17-16 = 00 (swing)
local SWING_OFF = 0x1   -- bits17-16 = 01 (fixed)

-- SmartThings fanOscillationMode → swing 비트 값
local ST_FAN_TO_SWING = {
  ["swing"] = SWING_ON,
  ["fixed"] = SWING_OFF,
}

-- SmartThings thermostatMode → AC 파라미터
local ST_TO_AC = {
  ["off"]     = { pwr=PWR.OFF, mode=MODE.INVALID, fan=FAN_INVALID },
  ["heat"]    = { pwr=PWR.ON,  mode=MODE.HEAT,    fan=FAN_AUTO    }, -- warm air
  ["dryair"]  = { pwr=PWR.ON,  mode=MODE.DRY,     fan=FAN_AUTO    }, -- drying
  ["cool"]    = { pwr=PWR.ON,  mode=MODE.BLOW,    fan=FAN_AUTO    }, -- blowing
  ["fanonly"] = { pwr=PWR.ON,  mode=MODE.VENT,    fan=FAN_AUTO    }, -- ventilation
}

-- AC mode → SmartThings mode 역매핑
local AC_MODE_TO_ST = {
  [0x0] = "heat",    -- warm air
  [0x3] = "dryair",  -- drying
  [0x4] = "cool",    -- blowing
  [0x5] = "fanonly", -- ventilation
}

-- 색온도 범위
local MIRED_MIN = 153
local MIRED_MAX = 370

-- ──────────────────────────────────────────────
-- 유틸리티
-- ──────────────────────────────────────────────
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

local function kelvin_to_mired(k) return math.floor(1000000 / k) end
local function mired_to_kelvin(m) return math.floor(1000000 / m) end

-- ──────────────────────────────────────────────
-- AC 압축코드 빌드 & 전송
-- 기본값 0xFFFFFFFFFFFFFFFF (모든 필드 = 0xF = no-change/invalid)
-- 에서 변경이 필요한 필드만 덮어써서 전송
-- params 테이블 (nil이면 해당 필드 no-change):
--   pwr      : bits31-28  0=off 1=on
--   mode     : bits27-24  0=heat 3=dry 4=blow 5=vent
--   fan      : bits23-20  0=low 1=mid 2=high 3=auto
--   swing    : bits17-16  0=swing 1=fixed
--   setpoint : °C         hi32 bits63-48 (×0.01°C)
-- ──────────────────────────────────────────────
local function send_ac_code(device, params)
  local hi32 = 0xFFFFFFFF
  local lo32 = 0xFFFFFFFF

  if params.setpoint ~= nil then
    local sp_raw = math.floor(clamp(params.setpoint, 16, 45) * 100) & 0xFFFF
    hi32 = (sp_raw << 16) | (hi32 & 0xFFFF)
  end

  if params.pwr ~= nil then
    lo32 = (lo32 & 0x0FFFFFFF) | ((params.pwr & 0xF) << 28)
  end

  if params.mode ~= nil then
    lo32 = (lo32 & 0xF0FFFFFF) | ((params.mode & 0xF) << 24)
  end

  if params.fan ~= nil then
    lo32 = (lo32 & 0xFF0FFFFF) | ((params.fan & 0xF) << 20)
  end

  if params.swing ~= nil then
    lo32 = (lo32 & 0xFFFCFFFF) | ((params.swing & 0x3) << 16)
  end

  local bytes = string.char(
    (hi32 >> 24) & 0xFF,
    (hi32 >> 16) & 0xFF,
    (hi32 >>  8) & 0xFF,
     hi32        & 0xFF,
    (lo32 >> 24) & 0xFF,
    (lo32 >> 16) & 0xFF,
    (lo32 >>  8) & 0xFF,
     lo32        & 0xFF
  )

  device:send(cluster_base.write_manufacturer_specific_attribute(
    device, aqara.CLUSTER_ID, aqara.ATTR_AC_CODE, aqara.MFG_CODE,
    data_types.Uint64, bytes
  ))
end

-- ──────────────────────────────────────────────
-- 모드별 상태 persist 저장/복원
-- ──────────────────────────────────────────────
local MODE_FIELDS = {
  heat    = { "setpoint", "swing", "fan_speed" },
  cool    = { "swing", "fan_speed" },
  dryair  = { "swing", "fan_speed" },
  fanonly = { "fan_speed" },
}

local MODE_DEFAULTS = {
  heat    = { setpoint=25, swing="swing", fan_speed="중속" },
  cool    = { swing="swing", fan_speed="중속" },
  dryair  = { swing="swing", fan_speed="중속" },
  fanonly = { fan_speed="중속" },
}

local function save_mode_state(device, mode, field, value)
  device:set_field("mode_state." .. mode .. "." .. field, value, { persist = true })
end

local function load_mode_state(device, mode, field)
  return device:get_field("mode_state." .. mode .. "." .. field)
end

local function save_current_mode_field(device, field, value)
  local mode = device:get_field("thermostat_mode") or "off"
  local fields = MODE_FIELDS[mode]
  if fields then
    for _, f in ipairs(fields) do
      if f == field then
        save_mode_state(device, mode, field, value)
        return
      end
    end
  end
end

local function restore_mode_state(device, st_mode)
  local fields = MODE_FIELDS[st_mode]
  if not fields then return end

  local defaults = MODE_DEFAULTS[st_mode] or {}
  local setpoint, swing, fan = nil, nil, nil

  for _, field in ipairs(fields) do
    if field == "setpoint" then
      local v = load_mode_state(device, st_mode, "setpoint") or defaults.setpoint
      if v ~= nil then
        setpoint = clamp(v, 16, 45)
        device:emit_event(capabilities.thermostatHeatingSetpoint.heatingSetpoint(
          { value = setpoint, unit = "C" }
        ))
      end
    elseif field == "swing" then
      local v = load_mode_state(device, st_mode, "swing") or defaults.swing
      if v ~= nil then
        swing = ST_FAN_TO_SWING[v]
        device:set_field("fan_mode", v)
        device:emit_event(capabilities.fanOscillationMode.fanOscillationMode(v))
      end
    elseif field == "fan_speed" then
      local v = load_mode_state(device, st_mode, "fan_speed") or defaults.fan_speed
      if v ~= nil then
        fan = MODE_TO_FAN[v]
        device:set_field("fan_speed_ac", fan)
        device:emit_event(capabilities.mode.mode(v))
      end
    end
  end

  if setpoint ~= nil or swing ~= nil or fan ~= nil then
    send_ac_code(device, { setpoint=setpoint, swing=swing, fan=fan })
  end
end

-- ──────────────────────────────────────────────
-- [CAPABILITY → DEVICE]
-- ──────────────────────────────────────────────

local function handle_switch_on(driver, device, cmd)
  device:send(OnOff.server.commands.On(device))
end

local function handle_switch_off(driver, device, cmd)
  device:send(OnOff.server.commands.Off(device))
end

local function handle_switch_level(driver, device, cmd)
  local level = cmd.args.level
  local zb = math.floor(clamp(level, 1, 100) / 100 * 0xFE)
  device:send(Level.server.commands.MoveToLevelWithOnOff(
    device, data_types.Uint8(zb), data_types.Uint16(0x0000)
  ))
end

local function handle_color_temperature(driver, device, cmd)
  local kelvin = clamp(cmd.args.temperature, 2700, 6500)
  local mired  = clamp(kelvin_to_mired(kelvin), MIRED_MIN, MIRED_MAX)
  device:send(ColorControl.server.commands.MoveToColorTemperature(
    device, data_types.Uint16(mired), data_types.Uint16(0x0000)
  ))
end

local function handle_thermostat_mode(driver, device, cmd)
  local st_mode = cmd.args.mode
  local ac = ST_TO_AC[st_mode]
  if not ac then return end

  local pwr = (st_mode == "off") and PWR.OFF or PWR.ON
  local setpoint = nil
  if st_mode == "heat" then
    local state = device:get_latest_state("main",
      capabilities.thermostatHeatingSetpoint.ID,
      capabilities.thermostatHeatingSetpoint.heatingSetpoint.NAME)
    if state ~= nil then
      setpoint = clamp(state, 16, 45)
    end
  end

  send_ac_code(device, { pwr=pwr, mode=ac.mode, setpoint=setpoint })
  device:set_field("thermostat_mode", st_mode)
  device:emit_event(capabilities.thermostatMode.thermostatMode(st_mode))
  restore_mode_state(device, st_mode)

  if st_mode ~= "off" then
    device:set_field("pending_on_mode", st_mode)
  else
    device:set_field("pending_on_mode", nil)
  end
end

local function handle_heating_setpoint(driver, device, cmd)
  local temp_c = clamp(cmd.args.setpoint, 16, 45)
  device:set_field("heating_setpoint", temp_c)
  save_current_mode_field(device, "setpoint", temp_c)

  local cur = device:get_field("thermostat_mode") or "off"
  if cur == "heat" then
    send_ac_code(device, { setpoint=temp_c })
  end

  device:emit_event(capabilities.thermostatHeatingSetpoint.heatingSetpoint(
    { value = temp_c, unit = "C" }
  ))
end

local function handle_fan_mode(driver, device, cmd)
  local st_fan = cmd.args.fanOscillationMode
  local swing  = ST_FAN_TO_SWING[st_fan] or SWING_ON

  device:set_field("fan_mode", st_fan)
  save_current_mode_field(device, "swing", st_fan)
  send_ac_code(device, { swing=swing })
  device:emit_event(capabilities.fanOscillationMode.fanOscillationMode(st_fan))
end

local function handle_mode(driver, device, cmd)
  local fan_mode = cmd.args.mode  -- "저속" / "중속" / "고속"
  local fan      = MODE_TO_FAN[fan_mode] or FAN_AUTO
  device:set_field("fan_speed_ac", fan)
  save_current_mode_field(device, "fan_speed", fan_mode)
  send_ac_code(device, { fan=fan })
  device:emit_event(capabilities.mode.mode(fan_mode))
end

-- ──────────────────────────────────────────────
-- [DEVICE → CAPABILITY] 수신 핸들러
-- ──────────────────────────────────────────────

local function on_off_attr_handler(driver, device, value, zb_rx)
  device:emit_event(capabilities.switch.switch(value.value and "on" or "off"))
end

local function current_level_handler(driver, device, value, zb_rx)
  local pct = clamp(math.floor(value.value / 0xFE * 100), 1, 100)
  device:emit_event(capabilities.switchLevel.level(pct))
end

local function color_temp_handler(driver, device, value, zb_rx)
  local mired = value.value
  if mired == 0 then return end
  local kelvin = clamp(mired_to_kelvin(mired), 2700, 6500)
  device:emit_event(capabilities.colorTemperature.colorTemperature(kelvin))
end

-- ★ AC 압축코드 수신 핸들러 (0xFCC0/0x024F)
-- SDK는 Uint64를 big-endian 8바이트 문자열로 전달
local function ac_code_attr_handler(driver, device, value, zb_rx)
  local raw = value.value
  local hi32, lo32

  if type(raw) == "string" then
    local b = {string.byte(raw, 1, 8)}
    hi32 = ((b[1] or 0) << 24) | ((b[2] or 0) << 16) | ((b[3] or 0) << 8) | (b[4] or 0)
    lo32 = ((b[5] or 0) << 24) | ((b[6] or 0) << 16) | ((b[7] or 0) << 8) | (b[8] or 0)
  else
    hi32 = (raw >> 32) & 0xFFFFFFFF
    lo32 =  raw        & 0xFFFFFFFF
  end

  local pwr     = (lo32 >> 28) & 0xF
  local mode    = (lo32 >> 24) & 0xF
  local fan_set = (lo32 >> 20) & 0xF
  local b15_8   = (lo32 >>  8) & 0xFF
  local b7_0    =  lo32        & 0xFF
  local bits7_2 = (b7_0 >> 2) & 0x3F

  -- setpoint 유효 조건: bits15-8≥0xFE, bits7-2=63
  local hi_valid     = (b15_8 >= 0xFE) and (bits7_2 == 63)
  local setpoint_raw = (hi32 >> 16) & 0xFFFF

  if hi_valid and setpoint_raw ~= 0xFFFF then
    local sp = setpoint_raw / 100.0
    device:set_field("heating_setpoint", sp)
    device:emit_event(capabilities.thermostatHeatingSetpoint.heatingSetpoint(
      { value = sp, unit = "C" }
    ))
  end

  -- fan speed 파싱 (bits23-20): 0=low,1=mid,2=high (3=auto 제외)
  if fan_set <= 2 then
    local fan_mode = FAN_TO_MODE[fan_set] or "중속"
    device:set_field("fan_speed_ac", fan_set)
    device:emit_event(capabilities.mode.mode(fan_mode))
  end

  -- swing 상태 파싱 (bits17-16: 0=swing, 1=fixed, 나머지는 업데이트 안 함)
  local swing_bit = (lo32 >> 16) & 0x3
  if swing_bit == 0 then
    device:set_field("fan_mode", "swing")
    device:emit_event(capabilities.fanOscillationMode.fanOscillationMode("swing"))
  elseif swing_bit == 1 then
    device:set_field("fan_mode", "fixed")
    device:emit_event(capabilities.fanOscillationMode.fanOscillationMode("fixed"))
  end

  -- pwr=F(no-change/invalid): 모드 동기화 생략
  if pwr == 0xF then return end

  local st_mode
  if pwr == 0x0 then
    st_mode = "off"
  else
    st_mode = AC_MODE_TO_ST[mode] or "heat"
  end

  local pending = device:get_field("pending_on_mode")

  if st_mode ~= "off" then
    device:set_field("pending_on_mode", nil)
  else
    if pending ~= nil then return end
  end

  local current = device:get_field("thermostat_mode")
  if current ~= st_mode then
    device:set_field("thermostat_mode", st_mode)
    device:emit_event(capabilities.thermostatMode.thermostatMode(st_mode))
  end
end

-- ──────────────────────────────────────────────
-- 수명주기
-- ──────────────────────────────────────────────

local SUPPORTED_THERMOSTAT_MODES = {
  capabilities.thermostatMode.thermostatMode.off.NAME,
  capabilities.thermostatMode.thermostatMode.heat.NAME,
  capabilities.thermostatMode.thermostatMode.dryair.NAME,
  capabilities.thermostatMode.thermostatMode.cool.NAME,
  capabilities.thermostatMode.thermostatMode.fanonly.NAME
}

local SUPPORTED_FAN_MODES = {
  capabilities.fanOscillationMode.fanOscillationMode.swing.NAME,
  capabilities.fanOscillationMode.fanOscillationMode.fixed.NAME
}

local SUPPORTED_SPEED_MODES = { "저속", "중속", "고속" }

local function device_init(driver, device)
  device:emit_event(capabilities.thermostatMode.supportedThermostatModes(
    SUPPORTED_THERMOSTAT_MODES, { visibility = { displayed = false } }
  ))
  device:emit_event(capabilities.fanOscillationMode.supportedFanOscillationModes(
    SUPPORTED_FAN_MODES, { visibility = { displayed = false } }
  ))
  device:emit_event(capabilities.mode.supportedModes(
    SUPPORTED_SPEED_MODES, { visibility = { displayed = false } }
  ))
  device:emit_event(capabilities.thermostatHeatingSetpoint.heatingSetpointRange(
    { value = { minimum = 16, maximum = 45, step = 1 }, unit = "C" }
  ))
  device:send(OnOff.attributes.OnOff:read(device))
  device:send(Level.attributes.CurrentLevel:read(device))
  device:send(ColorControl.attributes.ColorTemperatureMireds:read(device))
end

local function device_added(driver, device)
  if device:get_latest_state("main", capabilities.thermostatHeatingSetpoint.ID,
      capabilities.thermostatHeatingSetpoint.heatingSetpoint.NAME) == nil then
    device:emit_event(capabilities.thermostatHeatingSetpoint.heatingSetpoint(
      { value = 25, unit = "C" }
    ))
    send_ac_code(device, { setpoint=25 })
  end
  if device:get_latest_state("main", capabilities.mode.ID,
      capabilities.mode.mode.NAME) == nil then
    device:emit_event(capabilities.mode.mode("중속"))
  end
  if device:get_latest_state("main", capabilities.fanOscillationMode.ID,
      capabilities.fanOscillationMode.fanOscillationMode.NAME) == nil then
    device:emit_event(capabilities.fanOscillationMode.fanOscillationMode("swing"))
  end
end

local function send_night_light(device, new)
  local start_min = (tonumber(new.nightLightStartHour) * 60) & 0xFFF
  local end_half  = (tonumber(new.nightLightEndHour) * 60) & 0xFFF
  local on_val    = (start_min << 12) | end_half
  local val       = new.nightLightMode and on_val or (on_val + 1)
  device:send(cluster_base.write_manufacturer_specific_attribute(
    device, aqara.CLUSTER_ID, aqara.ATTR_NIGHT_LIGHT,
    aqara.MFG_CODE, data_types.Uint32, val))
end

local function device_do_configure(driver, device) end

local function info_changed(driver, device, event, args)
  if args.old_st_store.preferences == nil then return end

  local old = args.old_st_store.preferences
  local new = device.preferences

  -- ① 야간 조명 모드 (0x0518, Uint32)
  --   bits23-12: 시작시간(분)  bits11-0: 종료시간(분×2)
  --   ON  = (시작분 << 12) | (종료분 × 2)
  --   OFF = 현재 ON 값 + 1
  local mode_changed = old.nightLightMode ~= new.nightLightMode
  local time_changed =
    old.nightLightStartHour ~= new.nightLightStartHour or
    old.nightLightEndHour   ~= new.nightLightEndHour
  if mode_changed then
    send_night_light(device, new)
  elseif time_changed and new.nightLightMode == true then
    send_night_light(device, new)
  end

  -- ② 동작 비프음 소거 (0x0256, Uint8)
  if old.muteBeep ~= new.muteBeep or device:get_field("inited") == nil then
    local val = new.muteBeep and 1 or 0
    device:set_field("inited", true)
    device:send(cluster_base.write_manufacturer_specific_attribute(
      device, aqara.CLUSTER_ID, aqara.ATTR_DND_SWITCH,
      aqara.MFG_CODE, data_types.Uint8, val))
    if val == 0 then
      device:send(cluster_base.write_manufacturer_specific_attribute(
        device, aqara.CLUSTER_ID, aqara.ATTR_DND_TIME,
        aqara.MFG_CODE, data_types.Uint32, 0x00120012))
    end
  end

  -- ③ 색온도 동기화 (0x02A6, Boolean)
  if old.colorTempSync ~= new.colorTempSync then
    device:send(cluster_base.write_manufacturer_specific_attribute(
      device, aqara.CLUSTER_ID, aqara.ATTR_BATH_LIGHT_MODE,
      aqara.MFG_CODE, data_types.Boolean, new.colorTempSync and true or false))
  end

  -- ④ 항온 모드 (0x02BE, Uint8)
  if old.thermostatCtrl ~= new.thermostatCtrl then
    device:send(cluster_base.write_manufacturer_specific_attribute(
      device, aqara.CLUSTER_ID, aqara.ATTR_THERMOSTAT_CTRL_SW,
      aqara.MFG_CODE, data_types.Uint8, new.thermostatCtrl and 1 or 0))
  end
end

-- ──────────────────────────────────────────────
-- 드라이버
-- ──────────────────────────────────────────────
local aqara_bathroom_heater_driver = ZigbeeDriver("aqara-bathroom-heater-t1", {
  supported_capabilities = {
    capabilities.switch,
    capabilities.switchLevel,
    capabilities.colorTemperature,
    capabilities.thermostatMode,
    capabilities.thermostatHeatingSetpoint,
    capabilities.fanOscillationMode,
    capabilities.mode,
  },

  capability_handlers = {
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME]  = handle_switch_on,
      [capabilities.switch.commands.off.NAME] = handle_switch_off,
    },
    [capabilities.switchLevel.ID] = {
      [capabilities.switchLevel.commands.setLevel.NAME] = handle_switch_level,
    },
    [capabilities.colorTemperature.ID] = {
      [capabilities.colorTemperature.commands.setColorTemperature.NAME] = handle_color_temperature,
    },
    [capabilities.thermostatMode.ID] = {
      [capabilities.thermostatMode.commands.setThermostatMode.NAME] = handle_thermostat_mode,
    },
    [capabilities.thermostatHeatingSetpoint.ID] = {
      [capabilities.thermostatHeatingSetpoint.commands.setHeatingSetpoint.NAME] = handle_heating_setpoint,
    },
    [capabilities.fanOscillationMode.ID] = {
      [capabilities.fanOscillationMode.commands.setFanOscillationMode.NAME] = handle_fan_mode,
    },
    [capabilities.mode.ID] = {
      [capabilities.mode.commands.setMode.NAME] = handle_mode,
    },
  },

  zigbee_handlers = {
    attr = {
      [OnOff.ID] = {
        [OnOff.attributes.OnOff.ID] = on_off_attr_handler,
      },
      [Level.ID] = {
        [Level.attributes.CurrentLevel.ID] = current_level_handler,
      },
      [ColorControl.ID] = {
        [ColorControl.attributes.ColorTemperatureMireds.ID] = color_temp_handler,
      },
      [aqara.CLUSTER_ID] = {
        [aqara.ATTR_AC_CODE] = ac_code_attr_handler,  -- 0x024F
      },
    },
  },
  health_check = false,
  lifecycle_handlers = {
    init        = device_init,
    added       = device_added,
    doConfigure = device_do_configure,
    infoChanged = info_changed,
  },
})

aqara_bathroom_heater_driver:run()
