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
local log           = require "log"

local aqara = require "aqara_cluster"

local OnOff        = zcl_clusters.OnOff
local Level        = zcl_clusters.Level
local ColorControl = zcl_clusters.ColorControl

-- ──────────────────────────────────────────────
-- AC 압축코드 상수
-- ──────────────────────────────────────────────
local PWR  = { OFF=0x0, ON=0x1, INVALID=0xF }  -- INVALID=no-change
-- AC mode bits27-24:
--   0 = warm air (난방)     → ST "heat"
--   3 = drying  (건조)      → ST "cool"
--   4 = blowing (열풍환풍)   → ST "auto"
--   5 = ventilation (환기)  → ST "emergency heat"
local MODE = { HEAT=0x0, DRY=0x3, BLOW=0x4, VENT=0x5, INVALID=0xF }
-- bits23-20: fan speed
--   0=low  1=middle  2=high  3=auto
local FAN_LOW    = 0x0
local FAN_MID    = 0x1
local FAN_HIGH   = 0x2
local FAN_AUTO   = 0x3
local FAN_INVALID= 0xF
-- SmartThings fanSpeed(1~3) → AC fan 값
local SPEED_TO_FAN = { [1]=FAN_LOW, [2]=FAN_MID, [3]=FAN_HIGH }
-- AC fan 값 → SmartThings fanSpeed(1~3), auto=2(middle)
local FAN_TO_SPEED = { [0]=1, [1]=2, [2]=3, [3]=2 }
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
-- OFF: pwr=0 (bits31-28=0)
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

local STOP_TIME_MAP = {
  ["0"] = 15,
  ["1"] = 30,
  ["2"] = 45,
  ["3"] = 60,
  ["4"] = 75,
  ["5"] = 90,
  ["6"] = 120
}

-- ──────────────────────────────────────────────
-- 유틸리티
-- ──────────────────────────────────────────────
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

-- 현재 저장된 AC fan 값 반환 (없으면 AUTO)
local function current_fan(device)
  return device:get_field("fan_speed_ac") or FAN_AUTO
end
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
--   dir_swing: bits19-16  0xC=swing 0xD=fixed
--   setpoint : °C         hi32 bits63-48 (×0.01°C)
-- ──────────────────────────────────────────────
local function send_ac_code(device, params)
  -- 전체 0xF(no-change)로 초기화
  local hi32 = 0xFFFFFFFF   -- bits63-32: setpoint=0xFFFF, actual=0xFFFF
  local lo32 = 0xFFFFFFFF   -- bits31-0 : pwr=F, mode=F, fan=F, dir=F, swing=F, 0xFF, 0xFF

  -- setpoint 설정 (bits63-48)
  if params.setpoint ~= nil then
    local sp_raw = math.floor(clamp(params.setpoint, 16, 45) * 100) & 0xFFFF
    hi32 = (sp_raw << 16) | (hi32 & 0xFFFF)  -- bits63-48=setpoint, bits47-32=0xFFFF
    -- bits15-8=0xFF, bits7-0=0xFF (setpoint 유효 조건 충족 신호 — lo32는 그대로)
  end

  -- pwr 설정 (bits31-28)
  if params.pwr ~= nil then
    lo32 = (lo32 & 0x0FFFFFFF) | ((params.pwr & 0xF) << 28)
  end

  -- mode 설정 (bits27-24)
  if params.mode ~= nil then
    lo32 = (lo32 & 0xF0FFFFFF) | ((params.mode & 0xF) << 24)
  end

  -- fan 설정 (bits23-20)
  if params.fan ~= nil then
    lo32 = (lo32 & 0xFF0FFFFF) | ((params.fan & 0xF) << 20)
  end

  -- swing 설정 (bits17-16만, bits19-18 direction은 0xF 그대로 유지)
  if params.swing ~= nil then
    lo32 = (lo32 & 0xFFFCFFFF) | ((params.swing & 0x3) << 16)
  end

  log.info(string.format(
    "[AC코드] pwr=%s mode=%s fan=%s swing=%s setpoint=%s → BE:0x%08X%08X",
    tostring(params.pwr), tostring(params.mode), tostring(params.fan),
    tostring(params.swing), tostring(params.setpoint), hi32, lo32))

  -- big-endian (MSB first)
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
  heat    = { setpoint=25, swing="swing", fan_speed=2 },
  cool    = { swing="swing", fan_speed=2 },
  dryair  = { swing="swing", fan_speed=2 },
  fanonly = { fan_speed=2 },
}

local function save_mode_state(device, mode, field, value)
  local key = "mode_state." .. mode .. "." .. field
  device:set_field(key, value, { persist = true })
  log.info(string.format("[persist] 저장: %s = %s", key, tostring(value)))
end

local function load_mode_state(device, mode, field)
  local key = "mode_state." .. mode .. "." .. field
  local val = device:get_field(key)
  log.info(string.format("[persist] 읽기: %s = %s", key, tostring(val)))
  return val
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
        fan = SPEED_TO_FAN[v]
        device:set_field("fan_speed_ac", fan)
        device:emit_event(capabilities.fanSpeed.fanSpeed(v))
      end
    end
  end

  if setpoint ~= nil or swing ~= nil or fan ~= nil then
    send_ac_code(device, { setpoint=setpoint, swing=swing, fan=fan })
    log.info(string.format("[persist] 복원 전송: mode=%s sp=%s sw=%s fan=%s",
      st_mode, tostring(setpoint), tostring(swing), tostring(fan)))
  end
end

-- ──────────────────────────────────────────────
-- [CAPABILITY → DEVICE]
-- ──────────────────────────────────────────────

local function handle_switch_on(driver, device, cmd)
  log.info("주조명 ON")
  device:send(OnOff.server.commands.On(device))
end

local function handle_switch_off(driver, device, cmd)
  log.info("주조명 OFF")
  device:send(OnOff.server.commands.Off(device))
end

local function handle_switch_level(driver, device, cmd)
  local level = cmd.args.level
  local zb = math.floor(clamp(level, 1, 100) / 100 * 0xFE)
  log.info(string.format("밝기 설정: %d%% → ZB 0x%02X", level, zb))
  device:send(Level.server.commands.MoveToLevelWithOnOff(
    device, data_types.Uint8(zb), data_types.Uint16(0x0000)
  ))
end

local function handle_color_temperature(driver, device, cmd)
  local kelvin = clamp(cmd.args.temperature, 2700, 6500)
  local mired  = clamp(kelvin_to_mired(kelvin), MIRED_MIN, MIRED_MAX)
  log.info(string.format("색온도 설정: %dK → %d mired", kelvin, mired))
  device:send(ColorControl.server.commands.MoveToColorTemperature(
    device, data_types.Uint16(mired), data_types.Uint16(0x0000)
  ))
end

local function handle_thermostat_mode(driver, device, cmd)
  local st_mode = cmd.args.mode
  local ac = ST_TO_AC[st_mode]
  if not ac then
    log.warn("알 수 없는 thermostatMode: " .. tostring(st_mode))
    return
  end

  -- 모드 변경: pwr+mode 설정, heat 모드는 마지막 설정 온도도 포함
  -- off 제외한 모든 모드는 pwr=0x1(ON) 명시적으로 설정
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
  log.info(string.format("모드 설정: %s (pwr=0x%X mode=0x%X setpoint=%s)",
    st_mode, pwr, ac.mode, tostring(setpoint)))
  send_ac_code(device, { pwr=pwr, mode=ac.mode, setpoint=setpoint })

  device:set_field("thermostat_mode", st_mode)
  device:emit_event(capabilities.thermostatMode.thermostatMode(st_mode))
  restore_mode_state(device, st_mode)

  -- non-off 명령: 디바이스가 pwr=1 리포트로 가동 확인할 때까지 off 동기화 차단
  if st_mode ~= "off" then
    device:set_field("pending_on_mode", st_mode)
  else
    device:set_field("pending_on_mode", nil)
  end
end

local function handle_heating_setpoint(driver, device, cmd)
  local temp_c = clamp(cmd.args.setpoint, 16, 45)
  device:set_field("heating_setpoint", temp_c)
  log.info(string.format("설정 온도: %.1f°C", temp_c))
  save_current_mode_field(device, "setpoint", temp_c)

  -- 설정 온도 변경: setpoint만 설정, 나머지 no-change(F)
  local cur = device:get_field("thermostat_mode") or "off"
  if cur == "heat" then
    log.info(string.format("설정 온도 AC코드 전송: %.1f°C", temp_c))
    send_ac_code(device, { setpoint=temp_c })
  end

  device:emit_event(capabilities.thermostatHeatingSetpoint.heatingSetpoint(
    { value = temp_c, unit = "C" }
  ))
end

local function handle_fan_mode(driver, device, cmd)
  local st_fan = cmd.args.fanOscillationMode
  local swing  = ST_FAN_TO_SWING[st_fan] or SWING_ON

  -- 스윙 모드 변경: bits17-16만 설정, 나머지 no-change
  log.info(string.format("팬 모드 설정: %s → swing=0x%X", st_fan, swing))
  device:set_field("fan_mode", st_fan)
  save_current_mode_field(device, "swing", st_fan)
  send_ac_code(device, { swing=swing })
  device:emit_event(capabilities.fanOscillationMode.fanOscillationMode(st_fan))
end

local function handle_fan_speed(driver, device, cmd)
  local speed = clamp(cmd.args.speed, 1, 3)
  local fan   = SPEED_TO_FAN[speed] or FAN_AUTO
  device:set_field("fan_speed_ac", fan)
  log.info(string.format("팬 속도 설정: %d → AC fan=0x%X", speed, fan))
  save_current_mode_field(device, "fan_speed", speed)

  -- 팬 속도 변경: fan만 설정, 나머지 no-change
  send_ac_code(device, { fan=fan })
  device:emit_event(capabilities.fanSpeed.fanSpeed(speed))
end

-- ──────────────────────────────────────────────
-- [DEVICE → CAPABILITY] 수신 핸들러
-- ──────────────────────────────────────────────

local function on_off_attr_handler(driver, device, value, zb_rx)
  local state = value.value
  log.info("주조명: " .. tostring(state))
  device:emit_event(capabilities.switch.switch(state and "on" or "off"))
end

local function current_level_handler(driver, device, value, zb_rx)
  local raw = value.value
  local pct = clamp(math.floor(raw / 0xFE * 100), 1, 100)
  log.info(string.format("밝기: 0x%02X → %d%%", raw, pct))
  device:emit_event(capabilities.switchLevel.level(pct))
end

local function color_temp_handler(driver, device, value, zb_rx)
  local mired = value.value
  if mired == 0 then return end
  local kelvin = mired_to_kelvin(mired)
  kelvin = clamp(kelvin, 2700, 6500)  -- 범위 초과 시 경계값으로 표시
  log.info(string.format("색온도: %d mired → %dK (표시)", mired, kelvin))
  device:emit_event(capabilities.colorTemperature.colorTemperature(kelvin))
end

-- ★ AC 압축코드 수신 핸들러 (0xFCC0/0x024F)
-- SDK는 Uint64를 big-endian 8바이트 문자열로 전달
local function ac_code_attr_handler(driver, device, value, zb_rx)
  local raw = value.value
  local hi32, lo32

  if type(raw) == "string" then
    -- 빅엔디언: b[1]=MSB
    local b = {string.byte(raw, 1, 8)}
    hi32 = ((b[1] or 0) << 24) | ((b[2] or 0) << 16) | ((b[3] or 0) << 8) | (b[4] or 0)
    lo32 = ((b[5] or 0) << 24) | ((b[6] or 0) << 16) | ((b[7] or 0) << 8) | (b[8] or 0)
  else
    hi32 = (raw >> 32) & 0xFFFFFFFF
    lo32 =  raw        & 0xFFFFFFFF
  end

  -- lo32 파싱
  local pwr      = (lo32 >> 28) & 0xF
  local mode     = (lo32 >> 24) & 0xF
  local fan_set  = (lo32 >> 20) & 0xF
  local b15_8    = (lo32 >>  8) & 0xFF
  local b7_0     =  lo32        & 0xFF
  local bits7_2  = (b7_0 >> 2) & 0x3F
  local fan_act  =  b7_0        & 0x03

  -- hi32 파싱 (setpoint 유효 조건: bits15-8≥0xFE, bits7-2=63)
  local hi_valid = (b15_8 >= 0xFE) and (bits7_2 == 63)
  local setpoint_raw = (hi32 >> 16) & 0xFFFF
  local setpoint_str = (hi_valid and setpoint_raw ~= 0xFFFF)
                       and string.format("%.2f°C", setpoint_raw / 100.0) or "n/a"

  log.info(string.format(
    "[AC코드 수신] pwr=%X mode=%X fan=%X fan_act=%X setpoint=%s | 0x%08X%08X",
    pwr, mode, fan_set, fan_act, setpoint_str, hi32, lo32))

  -- 설정 온도 업데이트
  if hi_valid and setpoint_raw ~= 0xFFFF then
    local sp = setpoint_raw / 100.0
    device:set_field("heating_setpoint", sp)
    device:emit_event(capabilities.thermostatHeatingSetpoint.heatingSetpoint(
      { value = sp, unit = "C" }
    ))
  end

  -- fan speed 파싱 (bits23-20)
  if fan_set <= 2 then  -- 0=low,1=mid,2=high (3=auto 제외)
    local speed = FAN_TO_SPEED[fan_set] or 2
    device:set_field("fan_speed_ac", fan_set)
    device:emit_event(capabilities.fanSpeed.fanSpeed(speed))
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

  -- pwr=0이면 OFF, pwr≠0이면 mode 비트로 결정
  local st_mode
  if pwr == 0x0 then
    st_mode = "off"
  else
    st_mode = AC_MODE_TO_ST[mode] or "heat"  -- 알 수 없는 모드는 heat로 처리
  end

  local pending = device:get_field("pending_on_mode")

  if st_mode ~= "off" then
    -- pwr=1: 디바이스가 실제로 가동 중 → pending 해제 후 정상 동기화
    device:set_field("pending_on_mode", nil)
  else
    -- pwr=0: 대기/꺼짐 리포트
    if pending ~= nil then
      -- 아직 pending_on_mode가 있으면 디바이스가 가동 준비 중 → off로 덮어쓰지 않음
      log.info("모드 동기화 스킵: 디바이스 가동 대기 중 (pending=" .. pending .. ")")
      return
    end
  end

  local current = device:get_field("thermostat_mode")
  if current ~= st_mode then
    log.info("모드 동기화: " .. tostring(current) .. " → " .. st_mode)
    device:set_field("thermostat_mode", st_mode)
    device:emit_event(capabilities.thermostatMode.thermostatMode(st_mode))
  end
end

-- 항온 도달 상태 (0x02BF)
local function thermostat_state_handler(driver, device, value, zb_rx)
  local state = value.value
  log.info("항온 상태: " .. (state == 1 and "도달" or "미달"))
  -- 항온 도달 (상태 표시 제거됨)
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


local function device_init(driver, device)
  -- mode init
  device:emit_event(capabilities.thermostatMode.supportedThermostatModes(SUPPORTED_THERMOSTAT_MODES, { visibility = { displayed = false } }))
  log.info("device_init: " .. (device.label or device.id))
  -- 지원 fanOscillationMode 목록 고정 (swing/fixed만 표시)
  device:emit_event(capabilities.fanOscillationMode.supportedFanOscillationModes(
    SUPPORTED_FAN_MODES, { visibility = { displayed = false } }
  ))
  -- 난방 설정 온도 범위 고정 (16~45°C)
  device:emit_event(capabilities.thermostatHeatingSetpoint.heatingSetpointRange(
    { value = { minimum = 16, maximum = 45, step = 1 }, unit = "C" }
  ))
  -- 조명 상태 읽기
  device:send(OnOff.attributes.OnOff:read(device))
  device:send(Level.attributes.CurrentLevel:read(device))
  device:send(ColorControl.attributes.ColorTemperatureMireds:read(device))
  -- AC코드 상태는 디바이스 자동 heartbeat 리포트(0xFCC0/0x024F)로 수신
  -- (read 요청 시 이전 상태로 응답해 thermostatMode를 덮어쓰는 문제 방지)
end

local function device_added(driver, device)
  log.info("device_added: " .. (device.label or device.id))
  if device:get_latest_state("main", capabilities.thermostatHeatingSetpoint.ID, capabilities.thermostatHeatingSetpoint.heatingSetpoint.NAME) == nil then
    device:emit_event(capabilities.thermostatHeatingSetpoint.heatingSetpoint( { value = 25, unit = "C" } ))
    send_ac_code(device, { setpoint=25 })
  end
  if device:get_latest_state("main", capabilities.fanSpeed.ID, capabilities.fanSpeed.fanSpeed.NAME) == nil then
    device:emit_event(capabilities.fanSpeed.fanSpeed(2))
  end
  if device:get_latest_state("main", capabilities.fanOscillationMode.ID, capabilities.fanOscillationMode.fanOscillationMode.NAME) == nil then
    device:emit_event(capabilities.fanOscillationMode.fanOscillationMode("swing"))
  end
end

local function send_night_light(device, new)
  local start_min = (tonumber(new.nightLightStartHour) * 60 + tonumber(new.nightLightStartMin)) & 0xFFF
  local end_half  = ((tonumber(new.nightLightEndHour) * 60 + tonumber(new.nightLightEndMin)) * 2) & 0xFFF
  local on_val    = (start_min << 12) | end_half
  local val       = new.nightLightMode and on_val or (on_val + 1)
  log.info(string.format("야간 조명 모드: %s (0x%08X) start=%02d:%02d end=%02d:%02d",
    new.nightLightMode and "on" or "off", val,
    tonumber(new.nightLightStartHour), tonumber(new.nightLightStartMin),
    tonumber(new.nightLightEndHour),   tonumber(new.nightLightEndMin)))
  device:send(cluster_base.write_manufacturer_specific_attribute(
    device, aqara.CLUSTER_ID, aqara.ATTR_NIGHT_LIGHT,
    aqara.MFG_CODE, data_types.Uint32, val))
end

local function device_do_configure(driver, device)
  log.info("device_do_configure")
end

-- local function set_mute_beep(device, status)
--   local val = status and 1 or 0
--   device:send(cluster_base.write_manufacturer_specific_attribute(
--     device, aqara.CLUSTER_ID, aqara.ATTR_DND_SWITCH,
--     aqara.MFG_CODE, data_types.Uint8, val))
--   if val == 0 then -- 비프음 비활성화 시 24시간 설정(항상 OFF 목적)
--     -- local fulltime = (0x12) | (0x00 << 8) | (0x12 << 16) | (0x00 << 24)
--     device:send(cluster_base.write_manufacturer_specific_attribute(
--       device, aqara.CLUSTER_ID, aqara.ATTR_DND_TIME,
--       aqara.MFG_CODE, data_types.Uint32, 0x00120012))
--   end
-- end

local function info_changed(driver, device, event, args)
  log.info("info_changed")
  if args.old_st_store.preferences == nil then return end

  local old = args.old_st_store.preferences
  local new = device.preferences

  -- ① 야간 조명 모드 (0x0518, Uint32)
  --   bits23-12: 시작시간(분)  bits11-0: 종료시간(분×2)
  --   ON  = (시작분 << 12) | (종료분 × 2)
  --   OFF = 현재 ON 값 + 1
  -- ① 야간 조명 모드 (0x0518, Uint32)
  --   bits23-12: 시작시간(분)  bits11-0: 종료시간(분×2)
  --   ON  = (시작분 << 12) | (종료분 × 2)
  --   OFF = 현재 ON 값 + 1
  local mode_changed = old.nightLightMode ~= new.nightLightMode
  local time_changed =
    old.nightLightStartHour ~= new.nightLightStartHour or
    old.nightLightStartMin  ~= new.nightLightStartMin  or
    old.nightLightEndHour   ~= new.nightLightEndHour   or
    old.nightLightEndMin    ~= new.nightLightEndMin
  if mode_changed then
    send_night_light(device, new)
  elseif time_changed and new.nightLightMode == true then
    send_night_light(device, new)
  end

  -- ③ 동작 비프음 소거 (0x0256, Uint8)
  if old.muteBeep ~= new.muteBeep or device:get_field("inited") == nil then
    local val = new.muteBeep and 1 or 0
    device:set_field("inited", true)
    device:send(cluster_base.write_manufacturer_specific_attribute(
      device, aqara.CLUSTER_ID, aqara.ATTR_DND_SWITCH,
      aqara.MFG_CODE, data_types.Uint8, val))
    if val == 0 then -- 비프음 비활성화 시 24시간 설정(항상 OFF 목적)
      -- local fulltime = (0x12) | (0x00 << 8) | (0x12 << 16) | (0x00 << 24)
      device:send(cluster_base.write_manufacturer_specific_attribute(
        device, aqara.CLUSTER_ID, aqara.ATTR_DND_TIME,
        aqara.MFG_CODE, data_types.Uint32, 0x00120012))
    end
  end

  -- -- ④ 동작 비프음 소거 기간 (0x0257, Uint32: byte0=start_hr, byte1=start_min, byte2=end_hr, byte3=end_min)
  -- if old.muteBeepStartHour ~= new.muteBeepStartHour or
  --    old.muteBeepStartMin  ~= new.muteBeepStartMin  or
  --    old.muteBeepEndHour   ~= new.muteBeepEndHour   or
  --    old.muteBeepEndMin    ~= new.muteBeepEndMin    then
  --   local sh = new.muteBeepStartHour & 0xFF
  --   local sm = new.muteBeepStartMin  & 0xFF
  --   local eh = new.muteBeepEndHour   & 0xFF
  --   local em = new.muteBeepEndMin    & 0xFF
  --   local val = (sh) | (sm << 8) | (eh << 16) | (em << 24)
  --   if new.muteBeep == true then
  --     log.info(string.format("비프음 소거 기간: %02d:%02d ~ %02d:%02d", sh, sm, eh, em))
  --     device:send(cluster_base.write_manufacturer_specific_attribute(
  --       device, aqara.CLUSTER_ID, aqara.ATTR_DND_TIME,
  --       aqara.MFG_CODE, data_types.Uint32, 0x00120012))
  --   end
  -- end

  -- ⑤ 색온도 동기화 (0x02A6, Boolean)
  if old.colorTempSync ~= new.colorTempSync then
    local val = new.colorTempSync and true or false
    log.info(string.format("색온도 동기화: %s", new.colorTempSync and "on" or "off"))
    device:send(cluster_base.write_manufacturer_specific_attribute(
      device, aqara.CLUSTER_ID, aqara.ATTR_BATH_LIGHT_MODE,
      aqara.MFG_CODE, data_types.Boolean, val))
  end

  -- ⑥ 항온 모드 (0x02BE, Uint8)
  if old.thermostatCtrl ~= new.thermostatCtrl then
    local val = new.thermostatCtrl and 1 or 0
    log.info(string.format("항온 모드: %s", new.thermostatCtrl and "enable" or "disable"))
    device:send(cluster_base.write_manufacturer_specific_attribute(
      device, aqara.CLUSTER_ID, aqara.ATTR_THERMOSTAT_CTRL_SW,
      aqara.MFG_CODE, data_types.Uint8, val))
  end

  -- 예약 종료 시간 설정 (0x02A5, Uint32)
  if old.timeLapseStopTime ~= new.timeLapseStopTime then
    local minutes = STOP_TIME_MAP[new.timeLapseStopTime] or 0
    local seconds = minutes * 60
    log.info(string.format("예약 종료 시간 설정: %02d 분", STOP_TIME_MAP[new.timeLapseStopTime] or 0))
    local val = math.floor(seconds)
    device:send(cluster_base.write_manufacturer_specific_attribute(
      device, aqara.CLUSTER_ID, aqara.ATTR_DELAY_STOP_TIME,
      aqara.MFG_CODE, data_types.Uint32, val))
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
    capabilities.fanSpeed,
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
    [capabilities.fanSpeed.ID] = {
      [capabilities.fanSpeed.commands.setFanSpeed.NAME] = handle_fan_speed,
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
        [aqara.ATTR_AC_CODE]          = ac_code_attr_handler,    -- 0x024F
        [aqara.ATTR_THERMOSTAT_STATE] = thermostat_state_handler, -- 0x02BF
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
