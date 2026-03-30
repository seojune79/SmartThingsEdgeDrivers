# Aqara Smart Bathroom Heater T1 — SmartThings Edge Driver

## 개요

Aqara 스마트 욕실 환풍 난방기 T1 (`lumi.airrtc.bathroomv01`)을 SmartThings에 통합하는
ZigBee 3.0 Edge Driver입니다.

---

## 지원 기능

| SmartThings 기능 | 디바이스 기능 | ZigBee 클러스터 |
|---|---|---|
| `switch` (On/Off) | 주조명 켜기/끄기 | On/Off (0x0006) |
| `switchLevel` | 주조명 밝기 0~100% | Level Control (0x0008) |
| `colorTemperature` | 색온도 2700K~6500K | Color Control (0x0300) |
| `thermostatMode` | 동작 모드 | Thermostat (0x0201) SystemMode |
| `thermostatHeatingSetpoint` | 설정 온도 25~45°C | Thermostat OccupiedHeatingSetpoint |
| `temperatureMeasurement` | 현재 실내 온도 | Thermostat LocalTemperature |
| `thermostatFanMode` | 팬 속도 | Fan Control (0x0202) |
| `thermostatOperatingState` | 현재 동작 상태 | (derived from SystemMode) |

---

## 동작 모드 매핑

SmartThings `thermostatMode`와 디바이스 `SystemMode` 간 매핑:

| SmartThings | 디바이스 SystemMode | 설명 |
|---|---|---|
| `off` | 0x00 | 정지 |
| `heat` | 0x04 | 난방 (열풍) |
| `auto` | 0x07 | 환풍 (강제 열풍) |
| `cool` | 0x08 | 건조 |
| `emergency heat` | 0x80 | 환풍 (저속 ventilate) |

> ⚠️ SmartThings `thermostatMode`가 "fan only"를 지원하지 않으므로
> "auto"와 "emergency heat"를 환풍 모드 두 가지에 대응시켰습니다.

---

## 팬 속도 매핑

SmartThings `thermostatFanMode`와 디바이스 `FanMode` 간 매핑:

| SmartThings | 디바이스 FanMode | 설명 |
|---|---|---|
| `auto` | 0x05 | 자동 |
| `on` | 0x02 | 중속 (medium) |
| `circulate` | 0x01 | 저속 (low) |
| `followSchedule` | 0x03 | 고속 (high) |

> 스펙 노트: `on`, `auto`, `smart` 모드는 디바이스 내부적으로 medium과 동일하게 동작합니다.

---

## 설치 방법

1. SmartThings CLI 또는 Developer Workspace에 드라이버를 업로드합니다.
2. 허브에 드라이버를 설치합니다.
3. 디바이스의 페어링 버튼(리셋 버튼)을 길게 눌러 ZigBee 페어링 모드로 진입합니다.
4. SmartThings 앱에서 디바이스 추가 → 허브 검색으로 등록합니다.

---

## 중요: fingerprint 확인 필요

`fingerprints.yml`의 `zigbeeModel` 값이 실제 디바이스와 다를 수 있습니다.

아래 방법으로 실제 모델 ID를 확인하세요:
- Zigbee 스니퍼로 Basic 클러스터의 `ModelIdentifier (0x0005)` 속성 읽기
- SmartThings 앱 로그에서 fingerprint 미일치 메시지 확인 후 모델 ID 추출

확인 후 `fingerprints.yml`의 `zigbeeModel` 항목을 수정하세요.

---

## Aqara 전용 클러스터 (0xFCC0) 확장 기능

`src/aqara_cluster.lua`에는 Aqara 전용 클러스터 속성들이 정의되어 있습니다:

| 속성 | ID | 설명 |
|---|---|---|
| AC 압축 코드 | 0x024F | 공조 통합 제어 Uint64 코드 |
| 항온 제어 스위치 | 0x02BE | 항온 기능 활성화 (기본: 1=활성) |
| 항온 도달 상태 | 0x02BF | 설정 온도 도달 여부 |
| 지연 정지 시간 | 0x02A5 | 전원 OFF 후 지연 정지 (초 단위, 기본 900초) |
| 沐光 모드 | 0x02A6 | 욕실 채광 모드 |
| 상시 밝기 | 0x0508 | 전원 투입 시 초기 밝기 |
| 상시 색온도 | 0x050C | 전원 투입 시 초기 색온도 (mired) |
| DND 스위치 | 0x0256 | 방해 금지 모드 |
| DND 시간 | 0x0257 | 방해 금지 시간대 (기본 21:00~09:00) |
| 야간 조명 | 0x0526 | 저밝기 야간 조명 |

이 속성들은 `aqara_cluster.lua`의 `M.write_attribute()` 함수로 직접 제어할 수 있습니다.

---

## 파일 구조

```
aqara-bathroom-heater-t1/
├── config.yml                          # 드라이버 패키지 설정
├── fingerprints.yml                    # ZigBee 디바이스 fingerprint
├── profiles/
│   └── aqara-bathroom-heater-t1.yml   # SmartThings 기능 프로파일
├── src/
│   ├── init.lua                        # 메인 드라이버 (capability/attribute 핸들러)
│   └── aqara_cluster.lua               # Aqara 0xFCC0 클러스터 상수 및 AC 코드 인코더
└── README.md
```

---

## 참조

- SmartThings Edge Driver SDK: https://developer.smartthings.com/docs/edge-device-drivers/
- ZigBee Cluster Library (ZCL) Rev.7
- Aqara ZB3.0 浴霸 T1 게이트웨이 통신 프로토콜 문서
