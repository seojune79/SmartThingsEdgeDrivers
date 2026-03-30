-- ============================================================
-- aqara_cluster.lua
-- Aqara 전용 클러스터(0xFCC0) 속성 상수 및 유틸리티
-- ============================================================

local data_types   = require "st.zigbee.data_types"
local cluster_base = require "st.zigbee.cluster_base"
local zcl_messages = require "st.zigbee.zcl"
local buf_lib      = require "st.buf"

local M = {}

-- ──────────────────────────────────────────────
-- 클러스터 / 속성 상수
-- ──────────────────────────────────────────────
M.CLUSTER_ID = 0xFCC0
M.MFG_CODE   = 0x115F   -- Lumi/Aqara manufacturer code

-- 주요 속성 ID
M.ATTR_FIRMWARE_VERSION     = 0x00EE  -- Uint32  (bit24~31 reserved, 23~16 heater, 15~8 BT host, 7~0 ZigBee)
M.ATTR_AC_CODE              = 0x024F  -- Uint64  (녹미 공조 압축 코드)
M.ATTR_THERMOSTAT_CTRL_SW   = 0x02BE  -- Uint8   (0=disable, 1=enable)
M.ATTR_THERMOSTAT_STATE     = 0x02BF  -- Uint8   (0=not reached, 1=reached setpoint)
M.ATTR_DELAY_STOP_TIME      = 0x02A5  -- Uint32  unit:sec, 0=immediate
M.ATTR_BATH_LIGHT_MODE      = 0x02A6  -- Bool    (沐光 모드)
M.ATTR_POWER_ON_BRIGHTNESS  = 0x0508  -- Uint8   (0x00=disabled, 0x01~0xFE=level)
M.ATTR_POWER_ON_COLOR_TEMP  = 0x050C  -- Uint16  (0=disabled, 153~370 mired)
M.ATTR_SEARCH_REMOTE_START  = 0x02A2  -- Bool    (0=stop, 1=start)
M.ATTR_SEARCH_REMOTE_TIME   = 0x02A3  -- Uint32  unit:sec (default 1200)
M.ATTR_SEARCH_REMOTE_STATUS = 0x02A4  -- ostring
M.ATTR_DND_SWITCH           = 0x0256  -- Uint8   (0=off, 1=on)
M.ATTR_DND_TIME             = 0x0257  -- Uint32  byte0=start_hr,1=start_min,2=end_hr,3=end_min
M.ATTR_NIGHT_LIGHT          = 0x0518  -- Uint32  야간 조명 모드 (bits23-12=시작분, bits11-0=종료분×2)
                                          --   ON = (시작분 << 12) | (종료분 × 2), OFF = ON값 + 1
M.ATTR_COLOR_TEMP_SYNC      = 0x050B  -- Bool    색온도 동기화
                                          --   예: 0x004EC438 = 21:00~9:00
                                          --   OFF = 현재값 + 1
M.ATTR_DEVICE_REBOOT        = 0x00E8  -- Bool    (write 1 to reboot)
M.ATTR_JOIN_ON_POWER        = 0x00F3  -- Uint8   (0=off, 1=on)
M.ATTR_SN                   = 0x00FE  -- cstring (serial number)
M.ATTR_POWER_MEMORY         = 0x0201  -- Bool    (0=disable, 1=enable)
M.ATTR_HEARTBEAT            = 0x00F7  -- (read-only, reported on boot)
M.ATTR_TOTAL_VERSION        = 0x00EE

-- ──────────────────────────────────────────────
-- AC 압축 코드 인코더 / 디코더
-- ──────────────────────────────────────────────
--
-- 64-bit 레이아웃 (MSB → LSB):
--   [63:48] setpoint  int16 (×0.01°C) — valid only if [15:8]≥0xFE and [7:2]=63
--   [47:32] actual    int16 (×0.01°C) — valid only if above condition
--   [31:28] on/off    0=off 1=on 2=toggle E=circle F=invalid
--   [27:24] mode      0=heat 1=cool 2=auto 3=dry 4=wind 5=breathe E=circle F=invalid
--   [23:20] fan_set   0=low 1=mid 2=high 3=auto E=circle F=invalid
--   [19:18] direction 0=horiz 1=vert 2=circle 3=invalid
--   [17:16] swing     0=swing 1=fix 2=circle 3=invalid
--   [15:8]  temp_set  0~240°C, 243=up 244=down FF=invalid
--   [7:2]   temp_act  0~63°C (actual)
--   [1:0]   fan_act   0=off 1=low 2=mid 3=high
--
-- Lua는 정수형이 53-bit이므로 high/low 32-bit 두 부분으로 분리해서 계산합니다.

M.AC_INVALID = 0xF   -- nibble "invalid / no change"

-- F=invalid 를 사용해 "변경 없음"을 표시하는 기본 스탠바이 코드
M.AC_STANDBY = {hi32 = 0xFFFFFFFF, lo32 = 0x0FFFFFFF}

--- AC 압축 코드를 빌드합니다.
-- @param params table  {power, mode, fan, temp_set, direction, swing}
--   power     : 0=off  1=on  2=toggle  0xF=invalid(no change)
--   mode      : 0=heat 1=cool 2=auto 3=dry 4=wind  0xF=invalid
--   fan       : 0=low  1=mid  2=high  3=auto        0xF=invalid
--   temp_set  : 25~45 (°C) or 0xFF=invalid
--   direction : 0=horiz 1=vert 2=circle 3=invalid
--   swing     : 0=swing 1=fix  2=circle 3=invalid
-- @return {hi32, lo32}
function M.build_ac_code(params)
  local power     = params.power     or 0xF
  local mode      = params.mode      or 0xF
  local fan       = params.fan       or 0xF
  local temp_set  = params.temp_set  -- nil = 0xFF
  local direction = params.direction or 3   -- invalid
  local swing     = params.swing     or 2   -- circle

  -- hi32: bits 63~32 → setpoint(16) + actual(16)
  local hi32 = 0xFFFFFFFF   -- setpoint/actual 모두 invalid

  -- lo32: bits 31~0
  --   [31:28] power
  --   [27:24] mode
  --   [23:20] fan_set
  --   [19:18] direction
  --   [17:16] swing
  --   [15:8]  temp_set_byte
  --   [7:2]   temp_actual (FF=invalid pattern)
  --   [1:0]   fan_actual  (FF=invalid pattern)
  local temp_byte = (temp_set ~= nil) and math.floor(temp_set) or 0xFF
  if temp_byte > 240 then temp_byte = 0xFF end

  -- bits 31~16 of lo32
  local lo_hi16 = (power  * 0x1000)  -- bits 31~28
               + (mode   * 0x0100)   -- bits 27~24
               + (fan    * 0x0010)   -- bits 23~20
               + (direction * 0x0004)-- bits 19~18 (shifted into nibble)
               + swing               -- bits 17~16 (approximated, see note)

  -- Note: direction(2bit) and swing(2bit) occupy bits 19~16 together as a nibble
  -- Re-calculate more carefully:
  --   bits 23~20: fan_set   (4 bit)
  --   bits 19~18: direction (2 bit)
  --   bits 17~16: swing     (2 bit)
  -- Combined nibble for bits 23~16:
  --   upper nibble (23~20) = fan
  --   lower nibble (19~16) = (direction << 2) | swing
  local dir_swing_nibble = ((direction & 0x3) * 4) + (swing & 0x3)
  local byte_23_16 = (fan * 0x10) + dir_swing_nibble

  -- bits 31~24
  local byte_31_24 = (power * 0x10) + mode

  -- bits 15~8: temp_set_byte
  local byte_15_8 = temp_byte & 0xFF

  -- bits 7~0: actual readings → set to 0xFF (invalid)
  local byte_7_0 = 0xFF

  local lo32 = (byte_31_24 * 0x1000000)
             + (byte_23_16 * 0x10000)
             + (byte_15_8  * 0x100)
             + byte_7_0

  return { hi32 = hi32, lo32 = lo32 }
end

--- lo32를 파싱하여 상태 테이블로 반환합니다.
function M.parse_lo32(lo32)
  local byte_31_24 = math.floor(lo32 / 0x1000000) & 0xFF
  local byte_23_16 = math.floor(lo32 / 0x10000)   & 0xFF
  local byte_15_8  = math.floor(lo32 / 0x100)     & 0xFF
  local byte_7_0   = lo32 & 0xFF

  local power     = math.floor(byte_31_24 / 0x10)
  local mode      = byte_31_24 & 0x0F
  local fan_set   = math.floor(byte_23_16 / 0x10)
  local dir_swing = byte_23_16 & 0x0F
  local direction = math.floor(dir_swing / 4)
  local swing     = dir_swing & 0x3
  local temp_set  = byte_15_8
  local temp_act  = math.floor(byte_7_0 / 4)
  local fan_act   = byte_7_0 & 0x03

  return {
    power     = power,
    mode      = mode,
    fan_set   = fan_set,
    direction = direction,
    swing     = swing,
    temp_set  = (temp_set <= 240) and temp_set or nil,
    temp_act  = (temp_act < 63)   and temp_act or nil,
    fan_act   = fan_act,
  }
end

--- 디바이스에 Uint64 속성을 쓰는 헬퍼
-- hi32, lo32를 받아서 8바이트 리틀엔디언 바이트 배열로 변환
function M.ac_code_to_bytes(hi32, lo32)
  -- ZigBee는 리틀엔디언
  local bytes = {}
  local v = lo32
  for i = 1, 4 do
    bytes[i] = v & 0xFF
    v = math.floor(v / 256)
  end
  v = hi32
  for i = 5, 8 do
    bytes[i] = v & 0xFF
    v = math.floor(v / 256)
  end
  return bytes
end

--- cluster_base를 이용해 Aqara 전용 속성 쓰기
function M.write_attribute(device, attr_id, data_type, value)
  local write_body = cluster_base.write_manufacturer_specific_attribute(
    device,
    M.CLUSTER_ID,
    attr_id,
    M.MFG_CODE,
    data_type,
    value
  )
  device:send(write_body)
end

return M
