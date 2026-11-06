# Keyboard Cleaner

Небольшое macOS-приложение для временной блокировки клавиатуры во время чистки.

- Блокирует все клавиши, включая F1–F12, яркость и громкость (при выданном доступе Accessibility).
- Закрывает все подключённые мониторы, чтобы случайно не кликнуть по другим приложениям.
- Не даёт дисплею уснуть, пока клавиатура заблокирована.
- Разблокировка — удержание кнопки мышью/трекпадом 3 секунды.

## Сборка

Требуется macOS 12+ и Swift toolchain (Xcode или Command Line Tools). Команда ниже создаёт универсальное приложение (Apple Silicon + Intel), проверяет подпись и собирает ZIP с контрольной суммой:

```sh
./build.sh archive
```

Результат: `release/KeyboardCleaner-1.0.0.zip` и `release/KeyboardCleaner-1.0.0.zip.sha256`.

Параметры:

```sh
VERSION=1.0.1 BUILD_NUMBER=2 ./build.sh archive   # версия
ARCHITECTURES=arm64 ./build.sh archive            # только Apple Silicon
MACOS_MIN_VERSION=13.0 ./build.sh archive         # минимальная macOS
```

## Подписанный и нотаризованный релиз

Без Developer ID приложение подписывается ad-hoc: при первом запуске Gatekeeper предупредит пользователя, и открыть его можно через `System Settings → Privacy & Security → Open Anyway`.

Чтобы пользователи могли запускать приложение без предупреждений, нужен аккаунт Apple Developer:

1. Один раз сохраните учётные данные для нотаризации:

   ```sh
   xcrun notarytool store-credentials KeyboardCleanerNotary \
       --apple-id "you@example.com" --team-id TEAMID --password "app-specific-password"
   ```

2. Соберите, подпишите, нотаризуйте и прикрепите тикет одной командой:

   ```sh
   CODE_SIGN_IDENTITY="Developer ID Application: Ваше имя (TEAMID)" \
   NOTARY_PROFILE=KeyboardCleanerNotary \
   VERSION=1.0.0 BUILD_NUMBER=1 ./build.sh archive
   ```

## Accessibility

Для полной блокировки клавиш разрешите приложению доступ в `System Settings → Privacy & Security → Accessibility`. Без доступа работает частичная блокировка (системные клавиши — яркость, громкость, Siri — могут срабатывать). После пересборки с новой подписью macOS может потребовать выдать разрешение заново.

Диагностический журнал (не более 512 КБ) записывается в:

```text
~/Library/Logs/KeyboardCleaner/diagnostic.log
```
