# freeturn-ios

iOS-клиент для [free-turn-proxy](https://github.com/purkalolka/free-turn-proxy) (Network Extension, packet tunnel).

Приложение принимает два значения:

- `freeturn://...` — share-ссылка (peer, ключ обфускации, WireGuard/AmneziaWG-конфиг внутри);
- ссылка на звонок VK.

Сборка — GitHub Actions (`iOS unsigned IPA`): собирает `Mobile.xcframework` из ядра
`purkalolka/free-turn-proxy`, архивирует приложение без подписи и публикует `FreeTurn-unsigned.ipa`
в Releases. Дальше IPA подписывается своим сертификатом (с capability Network Extension → Packet Tunnel).

Bundle ID: `com.purkalolka.freeturn` и `com.purkalolka.freeturn.tunnel`, app group
`group.com.purkalolka.freeturn` (см. `project.yml`, `Shared/SharedLog.swift`, `FreeTurn/VPNController.swift`).

## Канал связи приложение ↔ расширение

Основной транспорт — loopback TCP (`127.0.0.1`, порты `47831–47840`), JSON-lines:
расширение слушает, приложение подключается. По каналу идут лог, счётчик потоков,
captcha URL и команды (`snapshot`, `clear`, `reconnect`). Он не зависит от App Group,
provisioning profile и `sendProviderMessage`, поэтому работает и при подписи сторонним
подписантом. Файловый лог в App Group и IPC остались как резервные источники.
Код: `Shared/ControlProtocol.swift`, `FreeTurn/ControlClient.swift`,
`FreeTurnTunnel/ControlServer.swift`.

## Фоновое поведение и восстановление

Пока туннель поднят, процесс расширения — долгоживущий, а приложение в фоне (и закрытым)
не участвует: `UIBackgroundModes`, `BGTaskScheduler` и фоновых сессий нет. Поэтому всё
восстановление живёт в расширении — `FreeTurnTunnel/RecoveryController.swift`.

- Каждые 5 с снимается здоровье: состояние ядра, `streams/total`, `rx/tx`, возраст
  WireGuard handshake (`MobileGetState()`, `MobileTunnelStats()`).
- Триггеры: потоки ниже `total` без прогресса 45 с; `tx > 0` при `rx == 0` 30 с;
  handshake старше 210 с при наличии трафика; смена физического пути
  (`NEProvider.defaultPath` + `NWPathMonitor`); `wake()`.
- Начатое восстановление не прерывается: дедлайн 120 с, продлевается пока растёт число
  потоков или `rx`. Затем бэкофф 15/30/60/120/300 с с джиттером.
- Лестница: 3 мягких восстановления (`MobileReconnect` — только TURN-аллокации, туннель и
  fd остаются), затем 2 жёстких (остановка сессии и старт заново на новом `dup` tun-fd),
  затем `cancelTunnelWithError` — свежий процесс поднимает on-demand.
- Капча: восстановление на паузе (ядро само продлевает дедлайн), решение — в приложении
  или по уведомлению.
- On-demand (`NEOnDemandRuleConnect`) включается вместе с VPN в приложении и Control Center
  и выключается перед явным stop. После jetsam, краша или перезагрузки VPN поднимается сам;
  остановка из Settings при включённом on-demand снова запустит туннель — выключайте VPN
  через приложение.
- Логи: одна строка `[RECOVERY] <phase>: <detail>` на смену фазы.
- Ограничение: per-stream статистики в mobile API нет, поэтому «часть потоков мертва при
  полном счётчике» ловится только по handshake и `rx`.

## Приватность логов

Всё, что пишется в `tunnel.log` и уходит в приложение по каналу, проходит через
`Shared/Redactor.swift`: share-ссылки `freeturn://`, ссылки VK, captcha URL, токены и
session id в query-параметрах и JSON-телах заменяются на `<redacted>`. В репозитории нет
ни реальных ссылок, ни логов устройств.
