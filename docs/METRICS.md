# Metric catalog

The catalog below follows [Metrics.swift](../Sources/GarminBar/Models/Metrics.swift): 60 health fields and one device-status field. A definition is a supported parser/display field, not a promise that every watch supplies it. Only valid received health fields are selectable. Watch battery appears beside device information, without a health card or history chart. This app uses normal Garmin Bluetooth services; heart-rate broadcast is not required.

## Evidence and presentation

- Instinct 2 Solar / China: fresh heart rate, Body Battery, stress, steps, respiration, SpO₂, RR and calories were received; original activity/health FIT uploads and daily cloud records were verified. [Recorded scope](../VERIFICATION.md).
- Training readiness and wheelchair pushes are catalog candidates; this watch did not establish their availability. Other watch models and real Global account uploads are unverified.
- Daily summaries are individual values. Heart rate, Body Battery, stress, steps, respiration, SpO₂, floors, activity intervals and valid solar minutes have separate timeline parsers when the endpoint supplies records. Missing intervals stay empty.
- The legacy `hrv` service-12 field is displayed as RR (milliseconds). Its complete beat sequence, timing and exact semantics remain unverified; the local journal is downsampled. It is not a validated live RMSSD/SDNN measurement and is never used to synthesize overnight HRV.
- Overnight HRV comes from cloud summaries and timed readings: nightly average, seven-day average, best five-minute average, status and personal baseline. Missing values stay missing and each card shows its record date. China-account verification returned two summaries and 72 night samples; no seven-day average was supplied.
- Instinct 2 Solar battery was received through the Garmin device-status protocol. It refreshes after connection, on change notifications and every five minutes while the file channel is idle. This is periodic battery telemetry, not a guaranteed per-second stream. Standard GATT battery remains a fallback for devices exposing it.
- Solar intensity is a time series. Sunlight and charging durations are explicitly labeled estimates from valid input minutes, not measured outdoor time.

## All 61 fields

| Stable field ID | 中文 | English | Unit | Source |
| --- | --- | --- | --- | --- |
| `heartRate` | 心率 | Heart rate | BPM | Bluetooth |
| `bodyBattery` | 身体电量 | Body Battery | / 100 | Bluetooth + daily cloud |
| `stress` | 身体压力 | Stress | / 100 | Bluetooth |
| `steps` | 今日步数 | Today's steps | steps | Bluetooth + daily cloud |
| `calories` | 今日总热量 | Total calories | kcal | Bluetooth + daily cloud |
| `floors` | 上楼层数 | Floors climbed | floors | Bluetooth + daily cloud |
| `intensityMinutes` | 今日强度分钟 | Intensity minutes | min | Bluetooth |
| `respiration` | 呼吸频率 | Respiration rate | brpm | Bluetooth + daily cloud |
| `spo2` | 血氧 | SpO₂ | % | Bluetooth + daily cloud |
| `hrv` | 心搏间期（RR） | RR interval | ms | Bluetooth |
| `activeTime` | 活动时长 | Active time | min | Bluetooth + daily cloud |
| `trainingReadiness` | 训练准备度 | Training readiness | / 100 | Bluetooth; watch support unverified |
| `pushes` | 推行次数 | Pushes | times | Bluetooth; watch support unverified |
| `watchBattery` | 手表电池 | Watch battery | % | Device status only; Garmin device status / standard GATT |
| `hrv.lastNight` | 夜间 HRV | Overnight HRV | ms | Cloud night summary |
| `hrv.weeklyAverage` | HRV 七天平均 | 7-day HRV average | ms | Cloud night summary; optional |
| `hrv.status` | HRV 状态 | HRV status | — | Cloud status; optional |
| `hrv.lastNightHigh` | HRV 最高五分钟 | Highest 5-minute HRV | ms | Cloud night summary |
| `daily.restingHeartRate` | 静息心率 | Resting heart rate | BPM | Daily cloud summary |
| `daily.minHeartRate` | 今日最低心率 | Minimum heart rate | BPM | Daily cloud summary |
| `daily.maxHeartRate` | 今日最高心率 | Maximum heart rate | BPM | Daily cloud summary |
| `daily.averageStressLevel` | 今日平均压力 | Average stress | / 100 | Daily cloud summary |
| `daily.maxStressLevel` | 今日最高压力 | Maximum stress | / 100 | Daily cloud summary |
| `daily.bodyBatteryHighestValue` | 今日最高身体电量 | Highest Body Battery | / 100 | Daily cloud summary |
| `daily.bodyBatteryLowestValue` | 今日最低身体电量 | Lowest Body Battery | / 100 | Daily cloud summary |
| `daily.bodyBatteryChargedValue` | 今日身体电量恢复 | Body Battery charged | pts | Daily cloud summary |
| `daily.bodyBatteryDrainedValue` | 今日身体电量消耗 | Body Battery drained | pts | Daily cloud summary |
| `daily.totalDistanceMeters` | 今日距离 | Distance | km | Daily cloud summary |
| `daily.dailyStepGoal` | 步数目标 | Step goal | steps | Daily cloud summary |
| `daily.activeKilocalories` | 活动热量 | Active calories | kcal | Daily cloud summary |
| `daily.bmrKilocalories` | 静息热量 | Resting calories | kcal | Daily cloud summary |
| `daily.netRemainingKilocalories` | 剩余热量预算 | Remaining calorie budget | kcal | Daily cloud summary |
| `daily.floorsDescended` | 下楼层数 | Floors descended | floors | Daily cloud summary |
| `daily.userFloorsAscendedGoal` | 上楼目标 | Floors climbed goal | floors | Daily cloud summary |
| `daily.moderateIntensityMinutes` | 中等强度分钟 | Moderate intensity minutes | min | Daily cloud summary |
| `daily.vigorousIntensityMinutes` | 高强度分钟 | Vigorous intensity minutes | min | Daily cloud summary |
| `daily.intensityMinutesGoal` | 强度分钟目标 | Intensity minutes goal | min | Daily cloud summary |
| `daily.sleepingSeconds` | 今日睡眠时长 | Sleep duration | hr | Daily cloud summary |
| `daily.sedentarySeconds` | 静坐时长 | Sedentary time | hr | Daily cloud summary |
| `daily.highlyActiveSeconds` | 高强度活动时长 | Highly active time | min | Daily cloud summary |
| `daily.averageSpo2` | 平均血氧 | Average SpO₂ | % | Daily cloud summary |
| `daily.lowestSpo2` | 最低血氧 | Lowest SpO₂ | % | Daily cloud summary |
| `daily.avgWakingRespirationValue` | 平均清醒呼吸 | Average waking respiration | brpm | Daily cloud summary |
| `daily.highestRespirationValue` | 最高呼吸频率 | Highest respiration rate | brpm | Daily cloud summary |
| `daily.lowestRespirationValue` | 最低呼吸频率 | Lowest respiration rate | brpm | Daily cloud summary |
| `daily.restStressDuration` | 压力休息时长 | Rest time | min | Daily cloud summary |
| `daily.lowStressDuration` | 低压力时长 | Low stress time | min | Daily cloud summary |
| `daily.mediumStressDuration` | 中压力时长 | Medium stress time | min | Daily cloud summary |
| `daily.highStressDuration` | 高压力时长 | High stress time | min | Daily cloud summary |
| `daily.activityStressDuration` | 活动压力时长 | Active stress time | min | Daily cloud summary |
| `daily.uncategorizedStressDuration` | 未分类压力时长 | Unclassified stress time | min | Daily cloud summary |
| `daily.restStressPercentage` | 压力休息占比 | Rest percentage | % | Daily cloud summary |
| `daily.lowStressPercentage` | 低压力占比 | Low stress percentage | % | Daily cloud summary |
| `daily.mediumStressPercentage` | 中压力占比 | Medium stress percentage | % | Daily cloud summary |
| `daily.highStressPercentage` | 高压力占比 | High stress percentage | % | Daily cloud summary |
| `daily.activityStressPercentage` | 活动压力占比 | Active stress percentage | % | Daily cloud summary |
| `daily.uncategorizedStressPercentage` | 未分类压力占比 | Unclassified stress percentage | % | Daily cloud summary |
| `daily.lastSevenDaysAvgRestingHeartRate` | 近七天静息心率 | 7-day resting heart rate | BPM | Daily cloud summary |
| `solarIntensity` | 太阳能强度 | Solar intensity | % | Cloud minute records |
| `sunlightMinutes` | 日照时长（估算） | Sunlight time (estimated) | min | Estimate from valid solar minutes |
| `solarChargingMinutes` | 太阳能充电（估算） | Solar charging (estimated) | min | Estimate from valid solar minutes |

## Coverage gaps

| Data family | Current coverage | Not yet implemented / verified |
| --- | --- | --- |
| HRV and RR | Cloud night/history charts; legacy service-12 reading | Validated continuous beat stream; live RMSSD/SDNN |
| Sleep | Daily duration | Sleep score, deep/light/REM/awake stages and timeline |
| Training and recovery | Training-readiness parser candidate | Verified readiness on this watch, recovery time, training load/status, VO₂ max, race predictions |
| Body Battery | Current value, daily extrema/charge/drain, timeline | Event annotations and contributing factors |
| Body measurements | None | Weight, body composition, hydration, blood pressure; may require separate devices/manual entry |
| Battery | Instinct 2 Solar percentage verified | Charging state and remaining-hours fields parsed but not yet verified on this watch |

A hidden metric may mean no valid reading has arrived, rather than proof that the hardware cannot support it. These gaps are not selectable placeholders or promises of support.

## Original files

Activity and health FIT files are downloaded unchanged, retained in a private local queue and uploaded to the selected Garmin cloud region. This is a separate path from live metric notifications. Do not submit raw FIT or personal health/location records to public issues.

[Device support](DEVICES.md) · [Contributing](../CONTRIBUTING.md)
