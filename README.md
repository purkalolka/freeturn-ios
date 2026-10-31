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
