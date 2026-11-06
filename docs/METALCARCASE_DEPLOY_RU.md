# Watch5 Voice Capture на сервере metalcarcase.ru / REG.RU

## Что подготовлено

Отдельный WSGI-сервис для приватного поддомена `voice.metalcarcase.ru`:
- `server/app/wsgi.py` — Flask/WSGI обработчик приёма WAV и выгрузки в Яндекс Диск.
- `server/passenger_wsgi.py` — загрузчик для Passenger.
- `server/app/yandex_disk.py` — клиент Яндекс REST API.
- `server/tests/test_wsgi.py` — тесты без настоящего OAuth-токена.

Не изменяйте существующий сайт `metalcarcase.ru`, приложение `~/metalcarcase-production`, публичный каталог `~/www/metalcarcase.ru/`, Docker Compose и его клиентскую базу.

## 1. Поддомен и отдельный Python-сайт

В ISPmanager или панели REG.RU создайте новый сайт **voice.metalcarcase.ru** как самостоятельное Python-приложение. Укажите A-запись DNS поддомена на тот же IP, что и существующий сервер. Установите HTTPS-сертификат через панель. Убедитесь, что веб-обработчик для этого нового сайта действительно WSGI/Passenger.

**Важно:** конфигурация Python в ISPmanager зависит от типа хостинга и режима обработчика. На некоторых конфигурациях доступен Python web-server через PM2, а Passenger/WSGI требует отдельной настройки администратора. Не заменяйте настройки действующего сайта. Если Passenger недоступен, используйте ASGI/FastAPI из `server/app/main.py` через поддерживаемый reverse proxy или получите разрешение на отдельный WSGI-сайт у хостинга.

## 2. Изолированный исходный код и приватные данные

При наличии SSH в домашнем каталоге пользователя хостинга:

```bash
cd ~
git clone https://github.com/InternetUzer/watch5-voice-capture.git
cd ~/watch5-voice-capture/server
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
mkdir -p ~/watch5-audio-private
chmod 700 ~/watch5-audio-private
```

Для Passenger в каталоге НОВОГО сайта расположите точку входа `passenger_wsgi.py` из `server/`, не исходники или секреты. В его окружении Python должен использовать виртуальную среду `~/watch5-voice-capture/server/.venv`.

## 3. Секреты без публикации в GitHub

Создайте файл `~/.watch5-voice-capture.env`, доступный только владельцу:

```bash
umask 077
python3 -c 'import secrets; print(secrets.token_urlsafe(48))'
```

Используйте результат в `WATCH_API_KEY=` (для часов). Получите отдельный OAuth-токен Яндекс Диска с правом записи, не пересылайте его через чат. Образец **с заменителями**, никогда не настоящий токен:

```dotenv
WATCH_API_KEY=replace_with_random_generated_secret
YANDEX_DISK_TOKEN=replace_with_yandex_oauth_token
YANDEX_DISK_FOLDER=disk:/Watch5-Voice-Capture
WATCH_STORAGE_DIR=/home/USERNAME/watch5-audio-private
WATCH_APP_ROOT=/home/USERNAME/watch5-voice-capture/server
```

`WATCH_STORAGE_DIR` должен указывать на приватный каталог вне `~/www`. Затем `chmod 600 ~/.watch5-voice-capture.env`.

Для доступа к Диску: https://oauth.yandex.ru/client/new/ и https://yandex.ru/dev/disk/rest/.

## 4. Проверка до подключения часов

В новой виртуальной среде:

```bash
cd ~/watch5-voice-capture/server
.venv/bin/python -m pytest -q
```

После назначения поддомена и запуска WSGI-приложения:

```bash
curl -fsS https://voice.metalcarcase.ru/health
```

Ожидается `{"status":"ok"}`. Это подтверждает маршрут до сервиса, **но не** OAuth-загрузку в Диск. Для проверки облачной загрузки используйте небольшой WAV через защищённый POST с секретом, затем убедитесь, что файл появился в личной папке Яндекс Диска.

## 5. Настройки приложения часов

После успешной подписи и установки HAP:
- Server URL: `https://voice.metalcarcase.ru/v1/recordings`
- API key: ваш `WATCH_API_KEY`.

OAuth-токен Яндекс Диска вводится **только на сервере**, не на часах. Приём файлов ограничен 8 MiB, загрузка с часов пока выполняется вручную. Если Яндекс Диск недоступен, сервер сохраняет WAV и возвращает ошибку вместо ложного успешного ответа.

## Что не сделано

- Нет прямого доступа к твоему REG.RU/ISPmanager из ChatGPT: автоматического изменения DNS, настройки Python-сайта и проверки продакшн-адреса здесь не было.
- Не добавлена автоматическая расшифровка и автоматическое чтение приватного Яндекс Диска из этого чата.
- Подписанный HAP и работа на физических часах ещё не проверены.
- Очередь повторной отправки сервер→Яндекс Диск и автоматическая очистка локального архива не реализованы.
