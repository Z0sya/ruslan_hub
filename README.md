# ruslan_hub

Репозиторий публикации статического сайта ЖМЫХVERSE.

В `site/` находится готовая сборка из `D:\ruslan_hub\zhmyhverse-server`:
React, JavaScript-модули Vite, CSS и PWA service worker. Исходных компонентов,
`package.json` и прежних тестов в предоставленной папке нет. Поэтому CI проверяет
и упаковывает готовую сборку; он не выполняет фиктивную пересборку React.

При PR в `main` и изменениях `main` Actions проверяет ссылки на ресурсы,
наличие ленивых JS-модулей, синтаксис JavaScript и shell, а также тесты публикации.
Архив привязан к проверенному SHA, в том числе при ручном запуске.

Деплой выключен, пока переменная `DEPLOY_ENABLED` не равна `true`.
После включения он выполняется только после успешного CI на `main`, под `deploy`,
в `/var/www/main-site`. Публикация проверяется по HTTP; при ошибке возвращается
предыдущая версия. Каталог `/var/www/decoy`, VPN и nginx автоматически не меняются.

Настройка сервера, secrets, первого запуска и отката: [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md).

Локальная проверка (Python 3.10+, Node.js, Bash и ShellCheck):

```sh
python3 scripts/check_site.py
python3 -m unittest discover -s tests -v
find site -name '*.js' -print0 | xargs -0 -n1 node --check
shellcheck -x scripts/*.sh
```

Тесты переключения версий выполняются на Linux в изолированных временных папках.
На Windows они пропускаются. Проверки ресурсов и упаковки работают на обеих ОС.
Полноценные пользовательские сценарии React и офлайн-обновления PWA пока не покрыты.
