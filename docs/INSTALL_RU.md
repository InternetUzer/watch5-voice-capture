# Установка на Huawei Watch 5 — DevEco Studio

**Статус:** прототип без подтверждённой успешной сборки HAP и проверки на реальных часах.

## Если возникает «Cannot Open Project. Select an OpenHarmony or HarmonyOS project»

1. Убедитесь, что открыт каталог `watch/`, а не корень репозитория.
2. Обновите исходники из GitHub. В исправлении 0.1.1 добавлен обязательный `modelVersion` в корневой `oh-package.json5`; синхронизирован `hvigor/hvigor-config.json5`.
3. Если DevEco всё равно не распознаёт проект, откройте File → New → Create Project → HarmonyOS → Wearable → Empty Ability (Stage). DevEco создаст совместимые с установленной IDE конфигурации и SDK.
4. В созданном проекте перенесите исходники из `watch/entry/src/main/ets/` и необходимые ресурсы, добавьте разрешения из `watch/entry/src/main/module.json5`, **не перезаписывая** автоматически созданные файлы сборки.
5. Выполните Sync Project; если IDE показывает ошибки — скопируйте полный текст первой ошибки.

## Подключение

- Установите совместимый HarmonyOS SDK и активируйте отладку HDC на часах.
- Порт `5555` — лишь пример; используйте адрес и порт, указанные часами.
- В Windows PowerShell с пробелами в пути:

```powershell
& "C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe" tconn 192.168.0.172:ПОРТ
```

## Сборка

1. DevEco Studio → File → Open → каталог `watch/` (либо новый проект по инструкции выше).
2. Sync Project. При необходимости настройте SDK по подсказкам IDE.
3. File → Project Structure → Signing Configs → Configure signing.
4. Build → Build Hap(s). Исправьте ошибки компиляции, если будут: исходники ещё не проверены IDE.

## Установка

```powershell
hdc list targets
hdc install "ПОЛНЫЙ_ПУТЬ_К_ПОДПИСАННОМУ_HAP"
```

Дайте приложению разрешение на микрофон, включите мониторинг и проверьте звук, локальные WAV и фоновую работу. Запись запускается пользователем с индикацией микрофона; скрытый старт в фоне не реализован.

## Сервер

`server/` содержит FastAPI приложение приёма WAV. Используйте HTTPS и секретный API-ключ. Автоматический фоновый upload отсутствует в v0.1.
