# Политика конфиденциальности RepsCounter / RepsCounter Privacy Policy

**Дата вступления в силу / Effective date:** 17 ноября 2026 г. / November 17, 2026

## Русский

### 1. О приложении

RepsCounter — приложение для iPhone, которое помогает подсчитывать повторения упражнений с помощью камеры и хранить историю тренировок. Разработчик: **Александр Шевцов** ([GitHub](https://github.com/Alexander6Shevtsov)).

Эта политика описывает работу текущей версии приложения. Если в приложении появятся дополнительные функции, изменяющие обработку данных, политика будет обновлена.

### 2. Доступ к камере и распознавание позы

С вашего разрешения RepsCounter использует камеру iPhone для отображения изображения, обнаружения положения тела и подсчёта повторений. Анализ кадров и координат суставов выполняется **локально на устройстве** с помощью системных технологий Apple (AVFoundation и Vision).

Приложение **не записывает фото или видео**, не сохраняет кадры камеры в историю тренировок и **не отправляет изображения, видео или координаты суставов разработчику либо на внешние серверы**.

Вы можете запретить доступ к камере в настройках iPhone. Без этого разрешения функции распознавания упражнений недоступны.

### 3. История тренировок

После завершения и сохранения тренировки RepsCounter записывает в локальную базу данных на устройстве:

- дату и время тренировки;
- продолжительность тренировки;
- количество повторений и подходов;
- внутренний случайный идентификатор записи.

Эти сведения используются только для отображения истории и результатов тренировок. Они хранятся локально с помощью Core Data; приложение не передаёт их разработчику и не синхронизирует с собственным сервером.

### 4. Передача данных и сторонние сервисы

В текущей версии RepsCounter нет регистрации аккаунта, рекламы, сторонних аналитических инструментов, рекламных SDK и встроенной облачной синхронизации. Разработчик не получает через приложение персональные данные или результаты тренировок.

При переходе по ссылке на эту политику откроется GitHub. Обработка данных при посещении сайта GitHub регулируется собственной политикой конфиденциальности GitHub и не является сбором данных приложением RepsCounter.

Операционная система iOS может включать локальные данные приложения в резервную копию устройства согласно настройкам резервного копирования пользователя и правилам Apple. RepsCounter не управляет такими копиями.

### 5. Срок хранения и удаление

История тренировок остаётся на устройстве, пока приложение установлено и его данные не удалены. Текущая версия приложения не содержит отдельной функции удаления одной тренировки или очистки всей истории.

Чтобы удалить локальную историю вместе с приложением, используйте **Настройки iPhone → Основные → Хранилище iPhone → RepsCounter → Удалить приложение**. Функция «Сгрузить приложение» может сохранять его данные и поэтому не заменяет удаление.

Если данные приложения были включены в резервную копию iPhone, для управления резервными копиями используйте настройки Apple/iCloud. У разработчика нет серверной копии истории, которую нужно было бы запрашивать для удаления.

### 6. Управление разрешениями

Разрешение на использование камеры можно отозвать в любое время через **Настройки iPhone → Конфиденциальность и безопасность → Камера → RepsCounter** (или в настройках самого приложения). Отзыв разрешения не удаляет ранее сохранённую локальную историю.

### 7. Контакт

По вопросам конфиденциальности можно связаться с разработчиком через [GitHub Issues проекта RepsCounter](https://github.com/Alexander6Shevtsov/RepsCounter/issues/new). Обращения GitHub могут быть публичными — не указывайте там личные или конфиденциальные сведения.

### 8. Изменения политики

При изменении способов обработки данных актуальная версия политики и дата её обновления будут опубликованы по этому адресу.

---

## English

### 1. About RepsCounter

RepsCounter is an iPhone app that uses the camera to help count exercise repetitions and maintain a workout history. Developer: **Alexander Shevtsov** ([GitHub](https://github.com/Alexander6Shevtsov)).

This policy describes the current version of the app. We will update it if new features change how information is handled.

### 2. Camera access and pose detection

With your permission, RepsCounter uses your iPhone camera to display a live preview, detect body pose, and count exercise repetitions. Camera frames and joint coordinates are processed **on your device** using Apple's AVFoundation and Vision technologies.

The app **does not record photos or videos**, does not save camera frames to your workout history, and **does not transmit camera images, videos, or joint coordinates to the developer or external servers**.

You may revoke camera permission in iPhone Settings. Exercise detection is unavailable without camera access.

### 3. Workout history

When you finish and save a workout, RepsCounter stores the following in an on-device database:

- workout date and time;
- workout duration;
- repetition and set counts;
- an internally generated random record identifier.

This information is used only to display your workout history and results. It is stored locally using Core Data; the app does not send it to the developer or sync it with an app-operated server.

### 4. Data sharing and third-party services

The current version of RepsCounter has no user accounts, advertising, third-party analytics, advertising SDKs, or built-in cloud synchronization. The developer does not receive personal information or workout results through the app.

Opening this policy link takes you to GitHub. Any information processed when you visit GitHub is governed by GitHub's own privacy policy, not by RepsCounter's in-app data handling.

iOS may include locally stored app data in device backups depending on your settings and Apple's backup policies. RepsCounter does not control those backups.

### 5. Retention and deletion

Workout history remains on the device while the app and its data remain installed. The current version does not provide an individual-workout delete or clear-history function.

To remove locally stored workout history along with the app, go to **iPhone Settings → General → iPhone Storage → RepsCounter → Delete App**. **Offload App** may retain the app's data and is not a substitute for deletion.

If app data is included in an iPhone backup, manage your backups using Apple/iCloud settings. The developer has no server-side copy of your workout history to delete.

### 6. Permission controls

You may revoke camera permission at any time through **iPhone Settings → Privacy & Security → Camera → RepsCounter** (or the app's entry in Settings). Revoking camera permission does not delete previously saved local workout history.

### 7. Contact

For privacy questions, contact the developer using [RepsCounter GitHub Issues](https://github.com/Alexander6Shevtsov/RepsCounter/issues/new). GitHub issues may be public; please do not post personal or sensitive information there.

### 8. Updates

If the app's data-handling practices change, the updated policy and its effective date will be published at this address.
