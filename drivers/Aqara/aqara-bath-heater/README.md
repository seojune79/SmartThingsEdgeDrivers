# Aqara Smart Bathroom Heater T1 — SmartThings Edge Driver

SmartThings용 Aqara 욕실 난방/환풍기 T1 (`lumi.bhf_light.acn001`) Edge Driver입니다.

## 지원 기기

| 항목 | 값 |
|---|---|
| 제조사 | Aqara |
| 모델 | lumi.bhf_light.acn001 |
| 프로토콜 | ZigBee 3.0 |

## 제어 방식

- 모든 온도조절 제어: `0xFCC0/0x024F` Aqara AC 압축코드(Uint64) 사용
- Thermostat / FanControl 클러스터 사용하지 않음
- 조명 제어: 표준 ZigBee OnOff / Level / ColorControl 클러스터

## Capabilities

| Capability | 설명 |
|---|---|
| `switch` | 주조명 On/Off |
| `switchLevel` | 밝기 (1~100%) |
| `colorTemperature` | 색온도 (2700K~6500K) |
| `thermostatMode` | 모드: off / heat / dryair / cool / fanonly |
| `thermostatHeatingSetpoint` | 설정 온도 (16~45°C, step=1°C) |
| `fanOscillationMode` | 바람 방향: swing / fixed |
| `fanSpeed` | 팬 속도 (1=약풍, 2=중풍, 3=강풍) |

## 모드별 Capability 가시성

| 모드 | 설정 온도 | 바람 방향 | 팬 속도 |
|---|---|---|---|
| heat (난방) | ✅ | ✅ | ✅ |
| dryair (건조) | ❌ | ✅ | ✅ |
| cool (환풍) | ❌ | ✅ | ✅ |
| fanonly (환기) | ❌ | ❌ | ✅ |
| off | ❌ | ❌ | ❌ |

## AC 압축코드 매핑

```
bits63-48 : 설정 온도 (×0.01°C)
bits47-32 : 실제 온도 (×0.01°C)
bits31-28 : 전원 (0=off, 1=on, F=no-change)
bits27-24 : 모드 (0=heat, 3=dry, 4=wind, 5=breathe, F=no-change)
bits23-20 : 팬 속도 (0=low, 1=mid, 2=high, 3=auto, F=no-change)
bits19-18 : 방향 (항상 3=invalid)
bits17-16 : 스윙 (0=swing, 1=fixed)
bits15-8  : 0xFF
bits7-0   : 0xFF
```

## Preferences (설정)

| 설정 | 속성 | 설명 |
|---|---|---|
| 야간 조명 모드 | `0x0518` | ON/OFF 및 시간 설정 (시작/종료 시:분) |
| 동작 비프음 소거 | `0x0256/0x0257` | ON/OFF 및 소거 시간 설정 |
| 색온도 동기화 | `0x050B` | 주변 색온도와 동기화 |
| 항온 모드 | `0x02BE` | 설정 온도 도달 시 자동 대기 |
| 예약 종료 시간 | `0x02A5` | 15/30/45/60/75/90/120분 |

## 설치

```bash
smartthings edge:drivers:package .
smartthings edge:drivers:install <driver-id> -C <channel-id> -H <hub-id>
```

## 디버깅

```bash
smartthings edge:drivers:logcat <driver-id> --hub-address=<hub-ip>
```

AC 압축코드 파싱 도구:
```bash
lua ac_code_parser.lua <hex값>
# 예: lua ac_code_parser.lua 0BB80B03101CFFFE
```
