# Исправление сборки DevEco Studio 6.1.1 / 00303168

В проекте Watch5 Voice Capture первоначально отсутствовал `runtimeOS`, и DevEco мог определять проект как OpenHarmony. На компьютере установлена DevEco Studio 6.1.1.280 с SDK HarmonyOS 6.1.1 (API 24), но проект ошибочно пытался использовать OpenHarmony SDK 12.

В проекте исправлено:
- `watch/build-profile.json5`: `runtimeOS: "HarmonyOS"` в продукте;
- удалён `compileSdkVersion: 12` — HarmonyOS использует встроенный SDK IDE;
- сохранены `compatibleSdkVersion` и `targetSdkVersion` = `5.0.0(12)` как исходные минимальные параметры до сверки с прошивкой часов;
- `watch/entry/build-profile.json5`: `runtimeOS: "HarmonyOS"` в модуле.

## Локальное применение без повторной загрузки ZIP

В Windows PowerShell, предварительно закрыв IDE:

```powershell
$project = 'C:\Users\Serega\DevecostudioProjects\watch5-voice-capture\watch'
Copy-Item "$project\build-profile.json5" "$project\build-profile.json5.bak" -Force
Copy-Item "$project\entry\build-profile.json5" "$project\entry\build-profile.json5.bak" -Force
# Рекомендуется git pull в корневом каталоге репозитория, если нет локальных правок.
```

Для локальных файлов с изменениями после миграции нужно аккуратно вручную добавить `runtimeOS` и убрать OpenHarmony `compileSdkVersion: 12`, не уничтожая настройки, созданные миграцией.

## Важно

Это исправление конфигурации, а не подтверждение успешной сборки HAP. Если ошибка `00303168` сохраняется, проверить SDK Manager, структуру `sdk/default`, логи и параметры путей SDK. После прохождения конфигурационного этапа возможны ошибки ArkTS, которые следует исправить отдельно.
