-- ============================================================
-- aqara_cluster.lua
-- Aqara 전용 클러스터(0xFCC0) 속성 상수 및 유틸리티
-- ============================================================

local M = {}

-- ──────────────────────────────────────────────
-- 클러스터 / 속성 상수
-- ──────────────────────────────────────────────
M.CLUSTER_ID = 0xFCC0
M.MFG_CODE   = 0x115F   -- Lumi/Aqara manufacturer code

-- 주요 속성 ID
M.ATTR_AC_CODE            = 0x024F  -- Uint64  (녹미 공조 압축 코드)
M.ATTR_THERMOSTAT_CTRL_SW = 0x02BE  -- Uint8   (0=disable, 1=enable)
M.ATTR_THERMOSTAT_STATE   = 0x02BF  -- Uint8   (0=not reached, 1=reached setpoint)
M.ATTR_BATH_LIGHT_MODE    = 0x02A6  -- Bool    (沐光 모드 / 색온도 동기화)
M.ATTR_DND_SWITCH         = 0x0256  -- Uint8   (0=off, 1=on)
M.ATTR_DND_TIME           = 0x0257  -- Uint32  byte0=start_hr,1=start_min,2=end_hr,3=end_min
M.ATTR_NIGHT_LIGHT        = 0x0518  -- Uint32  야간 조명 모드 (bits23-12=시작분, bits11-0=종료분×2)
                                        --   ON = (시작분 << 12) | (종료분 × 2), OFF = ON값 + 1

return M
