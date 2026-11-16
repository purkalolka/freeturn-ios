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

- Здоровье снимается каждые 2 с: `state`, `streams/total`, `rx/tx`; возраст WireGuard
  handshake — раз в 10 с (`MobileTunnelStats()` — это IPC-чтение всего устройства).
- Триггеры: 0 потоков — 3 с; потеряна половина и больше — 10 с; один-два потока — 20 с;
  `tx` без `rx` — 8 с и не меньше 4 КБ отправлено (один медленный запрос не считается);
  handshake старше 140 с при трафике; смена физического пути (`NEProvider.defaultPath` +
  `NWPathMonitor`) и `wake()` — сразу.
- Действия: при частичной деградации — `MobileEnsureStreams()`, то есть перезапуск только
  залипших потоков (ядро сравнивает их с соседями: поток отправлял, ничего не получил, а
  другие получают). Полный `MobileReconnect()` — только когда мертвы все потоки, сменилась
  сеть или сессия «зависла в connecting»; тогда пересобираются все TURN-аллокации, но
  туннель, fd и ключи WireGuard остаются. Дальше — остановка сессии и старт на новом `dup`
  tun-fd, в конце `cancelTunnelWithError` и свежий процесс через on-demand.
- Начатое восстановление не прерывается: дедлайн 75 с, продлевается пока растут потоки или
  `rx`; бэкофф 5/15/30/60/120 с с джиттером.
- Капча: восстановление на паузе (ядро само продлевает дедлайн), решение — в приложении
  или по уведомлению.
- On-demand (`NEOnDemandRuleConnect`) включается вместе с VPN в приложении и Control Center
  и выключается перед явным stop. После jetsam, краша или перезагрузки VPN поднимается сам;
  остановка из Settings при включённом on-demand снова запустит туннель — выключайте VPN
  через приложение.
- Логи: одна строка `[RECOVERY] <phase>: <detail>` на смену фазы.

Ветка `fix/tunnel-recovery` использует ядро из ветки `fix/stream-recovery`
(`purkalolka/free-turn-proxy`): `MobileEnsureStreams`, `RestartStream`, `StreamsDetail`.
При сборке этой ветки передавайте `core_ref=fix/stream-recovery` (вход workflow); после
merge ядра в `main` верните `core_ref=main`.

## Приватность логов

Всё, что пишется в `tunnel.log` и уходит в приложение по каналу, проходит через
`Shared/Redactor.swift`: share-ссылки `freeturn://`, ссылки VK, captcha URL, токены и
session id в query-параметрах и JSON-телах заменяются на `<redacted>`. В репозитории нет
ни реальных ссылок, ни логов устройств.
