# Технический аудит RepsCounter

Дата: **24 октября 2026 года**. Статус: **In Development**.

Проверена первоначальная версия [`5d81a44`](https://github.com/Alexander6Shevtsov/RepsCounter/commit/5d81a440ca316c669da0a09823c7f057d4914d71), тег [`starter-v0.1.0`](https://github.com/Alexander6Shevtsov/RepsCounter/tree/starter-v0.1.0). Репозиторий публичный, основная ветка — `main`.

## Обновление этапа №2: исправление A01

В ветке `fix/scene-lifecycle`, созданной от `main` (`3eff7cb`), выполнена минимальная миграция на программный UIKit scene lifecycle. `SceneDelegate` создаёт `UIWindow(windowScene:)` и прежний `WorkoutViewController` с теми же зависимостями. В `App/Info.plist` явно зарегистрирована одна сцена без Storyboard; portrait перенесён из AppDelegate в plist для сохранения поведения на iOS 17+. AppDelegate остаётся точкой входа процесса. Подробности: [архитектура](ARCHITECTURE.md).

| Проверка исправления | Фактический результат |
|---|---|
| Debug, generic iOS Simulator | **BUILD SUCCEEDED** |
| Release, generic iOS device | **BUILD SUCCEEDED**, без подписи и установки на iPhone |
| XCTest, iPhone 18 Pro Max / iOS Simulator 27.0 | **10 прошли, 0 ошибок, 0 пропусков** |
| XCTest, iPhone 16 Pro / iOS Simulator 18.6 | **10 прошли, 0 ошибок, 0 пропусков** |
| Отдельный запуск приложения на iOS Simulator 27.0 | Главный экран тренировки отображается; сообщение об отсутствии задней камеры закрыто, отказа запуска A01 нет |
| Собранные Debug/Release Info.plist | Корректные `UIWindowScene`/`RepsCounter.SceneDelegate`, multiple scenes `false`, без storyboard-ключей; portrait, `MinimumOSVersion = 17.0`, прежний camera permission и Dark сохранены |
| Проверка diff | Domain, Services, Presentation и исходные 8 тестов не изменены |

Среда исправления: **Xcode 27.1 (27A9275), Swift 6.4, SDK 27.1, Swift language mode 5**. Добавлены два `SceneLifecycleTests`: проверка обработанного plist приложения и фактической связки `UIWindowScene → SceneDelegate → UIWindow → WorkoutViewController`, включая видимость окна и тёмное оформление. Тесты не создают сцену вручную.

**A01 исправлен и проверен в этой ветке; merge в main не выполнялся.** Runtime iOS 17 недоступен, поэтому запуск на минимальной версии не подтверждён; deployment target 17.0 сохранён. Физический iPhone и камера не проверялись. Предупреждения non-Sendable `CameraService`, deprecated `imageEdgeInsets` и остальные замечания A02–A11 остаются отдельными задачами. Ни новых функций, ни изменений алгоритма/хранилища/UI в этот этап не включено.

Ниже сохранены исторические результаты аудита первоначальной версии, включая отказ A01 до исправления.

## Объём и сохранность исходников

Изучены все 16 Swift-файлов: 13 файлов приложения и 3 файла XCTest, всего 963 строки; `project.pbxproj`, общая схема, workspace, README, LICENSE, `.gitignore`, все три Markdown-документа в `Docs` и `Concept.png`. Изображение является концептом интерфейса, а не подтверждением работающих функций.

Все 26 файлов из архива побайтово совпали с первым коммитом. Архив не содержал Git-истории: история начинается с неизменённого импорта, а результаты аудита добавлены отдельно. SHA-256 архива `RepsCounter-Starter.zip`:

```text
73aba6fee2dedf97c6f9ca7a8232daa35be26b5c089569de7c7aee0adab60aeb
```

Перечень исходных файлов и их контрольные суммы: [BASELINE_MANIFEST.json](BASELINE_MANIFEST.json). Swift-код, тесты, зависимости и настройки Xcode в рамках аудита не изменялись.

## Фактически выполненные проверки

Среда: **Xcode 27.1 (27A9275), Swift 6.4, SDK iOS/iOS Simulator 27.1**. Проект использует **Swift language mode 5**, что не равно версии установленного компилятора. Все сборки выполнялись с `CODE_SIGNING_ALLOWED=NO`.

| Проверка | Результат | Практическое ограничение |
|---|---|---|
| Debug, generic iOS Simulator, исходные настройки | **BUILD SUCCEEDED** | Есть предупреждения; это не запуск приложения |
| Release, generic iOS device, исходные настройки | **BUILD SUCCEEDED** | Без подписи, установки на iPhone и App Store archive |
| Debug, Swift 5 + `SWIFT_STRICT_CONCURRENCY=complete` | **BUILD SUCCEEDED**, предупреждения изоляции | Параметр задан только команде проверки |
| Диагностика с `SWIFT_VERSION=6` + strict complete | **BUILD FAILED** | Ошибка передачи `self.camera` через границу изоляции, `WorkoutViewController.swift:54`; текущие настройки проекта сохранены |
| XCTest, iPhone 18 Pro Max, iOS Simulator 27.0 | **TEST FAILED**, до исполнения методов XCTest | Приложение-хост аварийно завершилось: отсутствует обязательный `UIScene` lifecycle |
| XCTest, iPhone 16 Pro, iOS Simulator 18.6 | **TEST SUCCEEDED: 8 тестов, 0 ошибок** | 3 теста геометрии, 4 FSM, 1 Core Data in-memory; камера и UI не проверяются |
| Отдельная диагностика паузы отдыха | Дефект воспроизведён: `60 → 58 → 60` секунд | macOS Swift-probe с исходной Domain/ViewModel и заглушкой хранилища; это не XCTest и не запуск на iPhone |
| Статическая проверка ограничений | Storyboard/XIB, force unwrap/cast, `try!`, `unowned`, `// MARK:` и комментарии в Swift-коде не найдены | Проверен текущий объём исходников; коротких собственных имён переменных/методов менее 4 символов не обнаружено |

Полные журналы, сводки результатов Xcode и диагностическая проверка паузы сохранены в локальном пакете материалов аудита. Исходные `.xcresult` также оставлены в рабочей папке проверки. Первые обращения к CoreSimulator в ограниченном окружении были недоступны; для исполнения XCTest использован доступ к системной службе симулятора. Это ограничение окружения не относится к дефектам приложения.

Команды для повторения основных проверок из корня репозитория (доступные destination нужно выбрать в своей среде):

```sh
xcodebuild -project RepsCounter.xcodeproj -scheme RepsCounter -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project RepsCounter.xcodeproj -scheme RepsCounter -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project RepsCounter.xcodeproj -scheme RepsCounter -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO SWIFT_STRICT_CONCURRENCY=complete build
xcodebuild -project RepsCounter.xcodeproj -scheme RepsCounter -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO SWIFT_VERSION=6 SWIFT_STRICT_CONCURRENCY=complete build
xcodebuild -project RepsCounter.xcodeproj -scheme RepsCounter -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.6' -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test
xcodebuild -project RepsCounter.xcodeproj -scheme RepsCounter -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 18 Pro Max,OS=27.0' -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test
```

**Не проверены:** Xcode 26, реальная iOS 17, физический iPhone, работа камеры/совмещение скелета, точность распознавания, VoiceOver, визуальная компоновка на размерах Accessibility, энергопотребление, нагрев и длительная работа. Доступные рантаймы iOS 17 отсутствовали. Успешная сборка и 8 модульных тестов не подтверждают готовность приложения к эксплуатации.

## Соответствие требованиям

| Требование | Оценка |
|---|---|
| Swift, UIKit, iOS 17+ | Выполнено в конфигурации: deployment target 17.0 у проекта и обоих target в Debug/Release. Сгенерированный Info.plist содержит `MinimumOSVersion = 17.0` |
| Без Storyboard | Выполнено: программная вёрстка, нет `.storyboard`, `.xib`, `UIMainStoryboardFile` |
| Камера и разрешения | `NSCameraUsageDescription` есть на русском в обоих app build configuration и проверен в собранном Info.plist; запрос `.video` и отказ обработаны |
| Локальная обработка | По коду выполнено: AVFoundation → Vision → Domain; сетевого слоя, записи/загрузки видео нет. Core Data хранит только сводку тренировки |
| MVVM + Clean Architecture | Частично: отдельный Domain и ViewModel главного экрана; границы инфраструктуры и экрана истории требуют точечной доработки |
| Dependency Injection | Есть конструкторное внедрение на уровне AppDelegate, но конкретные зависимости и встроенное время мешают тестовым подстановкам |
| Swift Concurrency | Частично: `async/await`, MainActor, GCD для кадров/сессии; strict diagnostics выявляет проблемы изоляции камеры |
| Dynamic Type | Частично: системные text styles используются, но автообновление шрифтов не включено, основной счётчик фиксированного размера |
| XCTest | Есть target, shared scheme и 8 проходящих на iOS 18.6 тестов; временное состояние ViewModel и ошибки не покрыты |
| Минимум зависимостей | Сторонних зависимостей, package references, Podfile и Cartfile нет |
| Русский интерфейс, английский код | Основные строки UI на русском, имена кода на английском. `developmentRegion = en`; системные элементы и локализацию нужно проверить отдельно |
| Устройства/ориентация | Только iPhone (`TARGETED_DEVICE_FAMILY = 1`), `.portrait` в AppDelegate, Mac Catalyst отключён. iPad не заявлен |

Доступ к микрофону и медиатеке не требуется текущему коду: захватываются только видеокадры для локального анализа, запись отсутствует. Новые разрешения добавлять без потребности не следует.

## Архитектура, SOLID и управление памятью

Основное разделение исходной версии оправданно: `AppDelegate` собирал зависимости (после исправления A01 это делает `SceneDelegate`); `CameraService` управляет захватом; `PoseDetector` адаптирует Vision в собственную модель; `PoseAnalyzer` вычисляет угол; `SquatCounter` содержит чистый конечный автомат; `WorkoutViewModel` управляет тренировкой; UIKit отображает состояние. Domain зависит только от Foundation/CoreGraphics, не от UIKit, Vision, AVFoundation или Core Data.

SRP в большинстве небольших типов соблюдён. Главный контроллер дополнительно управляет камерой и создаёт экран истории, а контроллер истории читает хранилище и форматирует данные. Это допустимый объём для прототипа, но отделение состояния истории и координации жизненного цикла уже имеет практическое основание.

Основной пробел Clean Architecture — DIP: ViewModel принимает конкретный `WorkoutPersistence` из инфраструктуры; сама создаёт анализатор, счётчик и таймер, напрямую читает `Date()`. `CameraService` сам создаёт `PoseDetector`. Достаточны узкий контракт хранилища и управляемое время для регрессионных тестов; отдельные use case для каждого метода и полная перестройка слоёв сейчас не обоснованы. Нарушений LSP/ISP по существующим небольшим типам не выявлено; возможность расширения упражнения пока ограничена конкретным `SquatCounter` и фиксированными целями, но добавлять универсальную систему упражнений на этапе аудита не требуется.

Замыкания UI и таймера используют `weak self`; очевидного цикла удержания ViewModel/контроллера не найдено. `NSManagedObject` не передаются между очередями: наружу возвращаются value-сводки. Повторяющийся Timer имеет отдельный риск очистки, описанный ниже.

## Приоритеты

- **P1** — блокирует запуск или выполнение основного сценария в проверенной конфигурации.
- **P2** — исправить до развития функций: корректность данных/состояния, доступность, проверяемость и конкурентность.
- **P3** — техническая гигиена и подготовка к дальнейшему развитию.

У замечаний отдельно указано основание: реальное исполнение, диагностика компилятора, статический анализ или риск, требующий устройства.

### A01 · P1 · Приложение не запускается на iOS 27 при текущем SDK

**Статус этапа №2:** исправлено и проверено в `fix/scene-lifecycle`; см. результаты в начале документа. Ниже описано исходное состояние.

**Место:** `RepsCounter/App/AppDelegate.swift:4–19`, `RepsCounter.xcodeproj/project.pbxproj:61,63`.

Приложение создаёт окно через старый app-delegate lifecycle, генерация scene manifest отключена, SceneDelegate и конфигурации сцен отсутствуют. При запуске XCTest с SDK 27.1 на iOS Simulator 27.0 приложение-хост завершилось до подключения тестового раннера:

```text
Application failed to launch: UIScene life cycle is required for apps built with this SDK.
```

**Рекомендация:** программный `UIWindowSceneDelegate`, конфигурация сцены и создание окна с `UIWindowScene`. Сохранить UIKit, MVVM и iOS 17. Это технически необходимая адаптация жизненного цикла. Повторить запуск и XCTest на iOS 27 и нижней поддерживаемой версии. [Требование Apple](https://developer.apple.com/documentation/uikit/transitioning-to-the-uikit-scene-based-life-cycle).

### A02 · P2 · Границы изоляции камеры не проходят Swift 6

**Место:** `Services/CameraService.swift:19–26,40–55`, `Presentation/WorkoutViewController.swift:54` (здесь и далее Swift-пути относительно `RepsCounter/`).

Swift 5 strict build предупреждает о захвате non-Sendable `self` в `sessionQueue.async` и передаче `self.camera` из MainActor. Отдельная диагностическая сборка в Swift 6 действительно падает на строке 54. Текущая Swift 5 сборка успешна; фактическая гонка данных в приложении не воспроизводилась.

**Рекомендация:** определить единственного владельца состояния сессии и исполняющий контекст, ограничить наружный mutable доступ к сессии/callback, определить безопасную передачу позы на MainActor и отмену старта. Рассмотреть actor с подходящим serial executor либо тщательно изолированную очередь; блокирующий `startRunning()` оставить вне main. Не скрывать диагностику без обоснования через `@unchecked Sendable`. [Swift Sendable](https://docs.swift.org/latest/documentation/swift/sendable/).

### A03 · P2 · Ошибка сохранения завершает сессию без возможности повтора

**Место:** `Presentation/WorkoutViewModel.swift:84–100`, `Presentation/WorkoutViewController.swift:200–208,218–220`.

По коду `isFinished = true` и остановка таймера происходят до попытки сохранения. При ошибке повторный `finish()` сразу возвращается, кнопки отключены. Дополнительно контроллер безусловно пытается показать сообщение о завершении после alert ошибки, что создаёт конкурирующие презентации. Отказ диска в iOS не моделировался.

**Рекомендация:** различать завершение тренировки и результат сохранения, сохранять итог для повторной попытки и показывать одно соответствующее сообщение. Добавить тест с хранилищем, которое выдаёт ошибку, затем успешно сохраняет без дубликата.

### A04 · P2 · После ошибки Core Data остаётся несохранённая запись

**Место:** `Services/WorkoutPersistence.swift:34–45,48–59`.

`context.save()` может бросить ошибку после вставки объекта. Удаления этой вставки или отката нет. `history()` использует fetch с `includesPendingChanges = true` по умолчанию, поэтому способна показать ещё не записанную тренировку; последующее успешное сохранение может записать её вместе с новой. Это вывод из кода и контракта Core Data, не воспроизведённый отказ диска.

**Рекомендация:** транзакционная запись в выделенном контексте либо очистка конкретной созданной записи при ошибке. Общий `rollback()` применять только если контекст не содержит независимых изменений. Проверить ошибку записи и повтор с новым контекстом/хранилищем. [Apple: pending changes](https://developer.apple.com/documentation/coredata/nsfetchrequest/includespendingchanges).

### A05 · P2 · Пауза неправильно влияет на отдых и незавершённое движение

**Место:** `Presentation/WorkoutViewModel.swift:48–52,70–81,108–117`.

Подтверждено отдельным запуском: во время паузы отдых продолжает уменьшаться, после продолжения возвращается назад (`60 → 58 → 60`). Причина — `publish()` использует `Date()`, хотя для общего времени предусмотрен `pausedAt`.

Статически также видно: фаза счётчика и сглаживание переживают паузу. Если пауза включена в нижней точке приседа, движение после продолжения стоя может завершить старый цикл; стабильные кадры до/после паузы считаются последовательными. Требуемую семантику паузы следует зафиксировать явно.

**Рекомендация:** единый источник времени, заморозка остатка отдыха, сброс незавершённого движения с сохранением уже засчитанных повторений; XCTest на паузу в каждой фазе и во время отдыха.

### A06 · P2 · Жизненный цикл камеры и прерывания не обработаны

**Место:** `Services/CameraService.swift:28–57`, `Presentation/WorkoutViewController.swift:47–64`, `App/AppDelegate.swift:7–28`.

Нет реакции на потерю активности, прерывания и runtime errors AVFoundation; `cameraStarted` отражает первую попытку запуска. После выдачи разрешения в Settings нет явного повторного запуска при возврате. Задача старта не хранится/не отменяется, актуальность сессии после `await` не проверяется: поздний старт после завершения тренировки остаётся возможным сценарием. Таймер тренировки запускается ещё до получения разрешения. При открытой истории распознавание также продолжает работать — ожидаемое поведение нужно определить.

Это подтверждённые пропуски обработки; конкретные последствия для камеры требуют физического iPhone.

**Рекомендация:** связать состояние тренировки с доступностью камеры и активностью сцены, обрабатывать notifications прерываний/ошибок, согласовать stop/start и отмену, сбрасывать устаревшую позу. Проверить отказ → Settings → возврат, фон, звонок и завершение во время запроса разрешения. [Apple: события сессии](https://developer.apple.com/documentation/avfoundation/avcapturesession/didstartrunningnotification).

### A07 · P2 · Dynamic Type реализован не полностью

**Место:** `Presentation/WorkoutViewController.swift:97–114,134–141,157–168`.

Основной счётчик имеет фиксированные 112 pt. Для остальных labels и titleLabel кнопок используются text styles, но не включён `adjustsFontForContentSizeCategory`: изменение размера текста во время работы автоматически не применяется. Верхний стек не связан нижним ограничением с кнопками; перекрытие при больших шрифтах — риск, визуально не проверенный.

**Рекомендация:** `UIFontMetrics` для счётчика, автообновление шрифтов, переносы и адаптация компоновки. Проверить маленький iPhone, AX1–AX5 и VoiceOver. [Apple: автообновление шрифта](https://developer.apple.com/documentation/uikit/uicontentsizecategoryadjusting/adjustsfontforcontentsizecategory).

### A08 · P2 · Недостаточно тестов состояния и ошибок

**Место:** `RepsCounterTests/`, `Presentation/WorkoutViewModel.swift:22–45`.

8 существующих тестов проходят на iOS 18.6, но нет тестов ViewModel, времени/паузы/отдыха, ошибки сохранения и повтора, `PoseAnalyzer`, confidence, aspect ratio и смены видимой ноги. Встроенные `Timer`, `Date()` и конкретный persistence затрудняют такие проверки.

**Рекомендация:** точечные seams для хранилища и времени; регрессионные XCTest по A03–A05, затем анализатор и крайние случаи FSM. Видеофикстуры хранить/обрабатывать локально, без автоматической отправки кадров.

### A09 · P2 · Core Data API не выражает изоляцию main context

**Место:** `Services/WorkoutPersistence.swift:11,34–59`, `RepsCounterTests/WorkoutPersistenceTests.swift:5`.

`viewContext` — main-queue context. Методы сервиса не помечены MainActor и не используют `context.perform`; тест также не выражает эту изоляцию. Текущие вызовы UI происходят на main actor, тест прошёл; утверждать существующую гонку нельзя.

**Рекомендация:** явно изолировать текущий небольшой репозиторий на MainActor либо использовать `perform` и отдельный контекст при обоснованном выносе работы. [Apple: Core Data concurrency](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreData/Concurrency.html).

### A10 · P3 · Состояние завершения и ресурсы требуют уточнения

**Место:** `Presentation/WorkoutViewModel.swift:43–45,84–105`.

`elapsedSeconds` после завершения продолжает вычисляться от текущей даты, хотя сохранённая сводка уже фиксирована. При текущем UI таймер остановлен, поэтому это прежде всего несогласованность API состояния. Timer инвалидируется только в `finish()`; освобождение модели без finish оставляет в RunLoop таймер с пустым weak callback. Цикла удержания ViewModel нет.

Поле `sets` включает частично выполненный подход при наличии хотя бы одного повторения, тогда как README описывает completed sets.

**Рекомендация:** фиксировать момент завершения, явно отменять ресурсы и согласовать смысл количества подходов; закрепить тестами.

### A11 · P3 · История, диагностика и конфигурация перед выпуском

**Место:** `Presentation/WorkoutHistoryViewController.swift:20–27,41–44`, `Services/PoseDetector.swift:37–38`, `Presentation/WorkoutViewController.swift:146`, `project.pbxproj:70–71`.

- История загружается и форматируется в контроллере; ошибку он пытается показать в `viewDidLoad`, до гарантированного появления. Вынести состояние/ошибку в небольшую ViewModel при исправлении сценария истории.
- Ошибки Vision превращаются в обычное отсутствие человека. Добавить различимое диагностическое состояние без логирования/сохранения кадров.
- `imageEdgeInsets` устарел с iOS 15; компилятор выдаёт предупреждение. Перейти на `UIButton.Configuration` при работе с доступностью.
- Development region — `en`, app icon и конфигурация launch screen отсутствуют. Перед выпуском проверить русские системные элементы, форматы, launch screen и иконку. Отсутствие production-оформления не мешает выполненной unsigned-сборке.
- Core Data модель программная и без сохранённых версий. До изменения схемы определить миграцию; текущая схема сама по себе не сломана, автоматическая миграция по умолчанию не отключена.

## Что не является найденной ошибкой

- `startRunning()` вынесен на serial session queue; Vision обрабатывается на отдельной serial frame queue с пропуском поздних кадров и ограничением частоты. Переносить тяжёлую работу на MainActor нельзя.
- `.right` в Vision, aspect ratio с перестановкой сторон и обратное преобразование координат overlay согласованы с предположением rear camera/portrait. Доказанной ошибки преобразования не найдено; совмещение проверить на устройстве.
- FSM использует гистерезис, три стабильных наблюдения, обработку невалидных углов и повторное определение стоячей позы после 12 пропусков. Геометрия защищена от нулевых векторов и выхода косинуса за `[-1, 1]`.
- Гонка первоначальной загрузки Core Data не подтверждена: текущая загрузка не включает `shouldAddStoreAsynchronously`, значение по умолчанию — `false` ([Apple](https://developer.apple.com/documentation/coredata/nspersistentstoredescription/shouldaddstoreasynchronously)).
- Предупреждение об отсутствии AppIntents metadata не означает дефект приложения: AppIntents не используется.

## Решение по следующему этапу

Рекомендуемый порядок и критерии готовности вынесены в [NEXT_TASKS.md](NEXT_TASKS.md). Сначала устранить A01, затем ошибки состояния/сохранения и изоляции камеры; только после повторных проверок переходить к новым функциям.

На этапе №1 были подготовлены репозиторий, исходная история и аудит. На согласованном этапе №2 исправлен только A01 в отдельной ветке, без merge. Исправление остальных дефектов и развитие приложения не начаты и требуют отдельного согласования.
