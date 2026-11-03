# quotes-scraper — лабораторная 3

Скрапер на Python + Playwright разворачивается на обычной **Ubuntu 24.04 VM**,
поднятой Multipass, а вся конфигурация описана кодом (Ansible + Docker Compose).

Облачные компоненты предыдущей лабораторной заменены **серверными**:

| Лабораторная 2 (облако) | Лабораторная 3 (сервер) |
|---|---|
| SQS очередь `quotes-jobs` | **Redis Stream** `jobs` + consumer group `scrapers` |
| S3 bucket `quotes-results` | **локальные файлы** `/srv/quotes-scraper/results/<job_id>.json` |
| floci (эмулятор SQS/S3) | — (не нужен) |
| (нет) | **Nginx** отдаёт результаты по HTTP |

Сервер можно удалить и собрать заново: `make destroy` + `make provision`.
Повторный запуск Ansible не меняет уже настроенную систему (`changed=0`).

## Архитектура

```
control node (WSL2 / Linux)                 целевая VM (Ubuntu 24.04, Multipass)
+--------------------------+                +-------------------------------------------+
| make provision           |                | cloud-init (bootstrap):                   |
|  - multipass launch      | ---- SSH ----->|   пользователь bootstrap + ключ + sudo    |
|  - ждём cloud-init       |                |   python3 (для Ansible), НЕ docker        |
|  - генерируем inventory  |                |                                           |
|  - ansible-playbook      | ---- SSH ----->| roles: bootstrap -> docker_engine ->      |
|    bootstrap.yml site.yml|                |        scraper -> ssh_hardening           |
+--------------------------+                |                                           |
                                            | docker compose up -d                      |
                                            |  +---------------+   stream jobs           |
                                            |  | redis  (AOF)  |<-----------.            |
                                            |  | 6379 не наружу|            |            |
                                            |  +---------------+            |            |
                                            |  +---------------------------+|            |
                                            |  | scraper (Playwright)      ||            |
                                            |  | XREADGROUP -> scrape ->   ||            |
                                            |  | tmp + rename -> XACK      ||            |
                                            |  +--------------+------------+            |
                                            |                 v                         |
                                            |      /srv/quotes-scraper/results/abc.json |
                                            |  +--------------+                         |
                                            |  | nginx :8080  |<-- только для чтения    |
                                            |  +--------------+                         |
                                            +-------------------------------------------+
```

## Требования к host (control node)

Control node должен быть **POSIX-окружением**: GNU make, Ansible и ssh работают
именно там. На Windows это **WSL2**, а Multipass вызывается как `multipass.exe`.

| Инструмент | Зачем | Проверка |
|---|---|---|
| Multipass (`multipass.exe` на Windows) | создаёт/удаляет VM | `multipass version` |
| GNU Make | единственная точка входа | `make --version` |
| ansible-core >= 2.15 | playbook-и и роли | `ansible-playbook --version` |
| openssh-client (`ssh`, `ssh-keygen`, `ssh-keyscan`) | ключ и подключение к VM | `ssh -V` |
| python3 | генерация inventory | `python3 -V` |
| Docker + compose plugin | только для `make ci` | `docker compose version` |

Коллекции Ansible (`community.docker`, `ansible.posix`) ставятся из
`infra/ansible/requirements.yml` командой `make deps`.

Целевая VM создаётся автоматически: **Ubuntu 24.04, 2 CPU, 4 GB RAM, 20 GB disk**
(переменные `UBUNTU_IMAGE`, `VM_CPUS`, `VM_MEMORY`, `VM_DISK` в `Makefile`).

## Команды

Все команды — только через `make` (ручные multipass/ansible/ssh не считаются сдачей).

```bash
make provision   # создать VM, дождаться cloud-init, сгенерировать inventory, применить Ansible
make deploy      # развернуть/обновить стек Redis + scraper + Nginx (только роль scraper)
make run         # создать job_id и добавить одно задание в stream jobs: URL=<url>
make verify      # проверить задание JOB=<job_id> насквозь (timeout VERIFY_TIMEOUT=180)
make fault-test  # доказать отказоустойчивость: падение до XACK -> pending -> доигрывание
make destroy     # удалить VM и .lab/ (повторный запуск завершается без ошибки)
make ci          # deps + yamllint + ansible-lint + syntax-check + docker compose config

make setup       # подготовить control node: .lab/, SSH-ключ, cloud-init для VM
make deps        # установить коллекции Ansible из requirements.yml
make bootstrap   # только playbook bootstrap.yml (создать admin)
make site        # только playbook site.yml (docker + приложение + hardening)
make help        # список команд
```

Параметры: `VM_NAME`, `UBUNTU_IMAGE`, `VM_CPUS`, `VM_MEMORY`, `VM_DISK`,
`URL`, `JOB`/`JOB_ID`, `VERIFY_TIMEOUT`, `MULTIPASS`.

### Полный сценарий

```bash
make provision
make run URL=https://quotes.toscrape.com/scroll
make verify
make fault-test
make destroy
```

### Переменные

| Переменная | По умолчанию | Назначение |
|---|---|---|
| `VM_NAME` | `quotes-lab3` | имя инстанса Multipass |
| `UBUNTU_IMAGE` | `24.04` | версия образа Ubuntu |
| `VM_CPUS` / `VM_MEMORY` / `VM_DISK` | `2` / `4G` / `20G` | параметры VM |
| `URL` | `https://quotes.toscrape.com/scroll` | URL задания для `run`/`fault-test` |
| `JOB` / `JOB_ID` | свежий UUID | `verify` берёт последний job_id, `run` создаёт новый |
| `VERIFY_TIMEOUT` | `180` | лимит ожидания в секундах |
| `HTTP_PORT` | `8080` | внешний порт Nginx на VM |

## Что делает каждая часть

### 1. cloud-init — только bootstrap

`infra/cloud-init.yaml` создаёт временного пользователя `bootstrap` (SSH-ключ,
`sudo`, `python3`) и больше ничего. **Docker и приложение через cloud-init не
ставятся** — иначе конфигурация после первого входа перестала бы быть кодом.

### 2. Ansible — постоянная конфигурация

| Playbook | Роль | Что делает |
|---|---|---|
| `bootstrap.yml` | `bootstrap` | создаёт `admin` с ключом и sudo, **проверяет реальный вход** под `admin` |
| `site.yml` | `docker_engine` | Docker Engine, Buildx, Compose plugin из apt-репозитория Docker |
| `site.yml` | `scraper` | копирует приложение, собирает образ только при изменении исходников, поднимает Compose |
| `site.yml` | `ssh_hardening` | запрещает `root`/password/keyboard-interactive, отключает `bootstrap`, `sshd -t` |

`site.yml` подключается **уже под `admin`** (`ansible_user` переопределяется на
уровне play) и первым делом проверяет `whoami`. Только после этого работает
`ssh_hardening` — так отключение bootstrap-входа не может заблокировать доступ.

### 3. Docker Compose

`deploy/compose.yaml`: Redis (AOF + том, порт `6379` **не публикуется**),
скрапер (пишет в `/srv/quotes-scraper/results`) и Nginx (публикует **только** HTTP
`8080:80`, каталог результатов монтирует **только для чтения**).

### 4. Redis Streams

Stream `jobs`, consumer group `scrapers`. Задание = `job_id` + `url`.
Воркер (`src/worker.py`):

1. забирает запись (`XREADGROUP` -> она попадает в pending entries list);
2. пишет JSON во временный файл, `fsync`, атомарный `rename` в `<job_id>.json`;
3. и только затем `XACK`. Повторная доставка того же `job_id` не перезаписывает файл.

## Структура репозитория

```
.
├── Dockerfile                  # multistage: deps -> browser -> runtime
├── Makefile                    # единственная точка входа
├── src/
│   ├── scrape.py               # Playwright-скрапер
│   └── worker.py               # Redis Streams -> JSON на диск -> XACK
├── deploy/
│   ├── compose.yaml            # redis + scraper + nginx
│   ├── nginx.conf              # раздача /results/<job_id>.json
│   └── redis.conf              # AOF, bind 0.0.0.0, без публикации порта
├── infra/
│   ├── cloud-init.yaml         # bootstrap VM
│   └── ansible/
│       ├── ansible.cfg
│       ├── requirements.yml
│       ├── inventories/
│       │   ├── hosts.example.yml       # пример (использует CI)
│       │   └── lab/hosts.yml           # генерируется, не коммитится
│       ├── playbooks/                  # bootstrap, site, deploy, run, verify, fault
│       └── roles/                      # bootstrap, docker_engine, scraper, ssh_hardening
├── .lab/                       # ключи, inventory, логи (не коммитится)
└── .github/workflows/ci.yml    # CI: make ci
```

## CI

GitHub Actions (`.github/workflows/ci.yml`) на PR в `main` ставит ansible-core
и ansible-lint, затем запускает `make ci` — ту же точку входа, что и локально:
коллекции из `requirements.yml`, `yamllint`, `ansible-lint`,
`ansible-playbook --syntax-check` на `hosts.example.yml` и `docker compose config`.

## Запуск на Windows (WSL2 + Multipass)

1. Установить **Multipass** для Windows и **WSL2** (`wsl --install`).
2. В WSL поставить инструменты control node:
   `sudo apt-get install -y make python3 openssh-client` и
   `pipx install ansible-core` (или `pip install ansible-core ansible-lint`).
3. Проверить инструменты: `make check-tools` (в WSL `multipass.exe` виден
   из Windows-`PATH`).
4. Из WSL в каталоге репозитория: `make provision && make run && make verify`.

Если Multipass стоит на Linux (не Windows), `make` сам вызовет `multipass`
вместо `multipass.exe`.

### Как посмотреть глазами на виртуалке

Эти команды нужны только для наглядности — сдача идёт через `make`.

```bash
# 0) IP виртуалки (его же пишет make inventory)
multipass list                      # или: cat .lab/vm_ip

# 1) подключиться (после hardening — только под admin)
ssh -i .lab/id_ed25519 admin@<ip>   # временный bootstrap отключён

# 2) контейнеры и стек
sudo docker ps                      # quotes-redis, quotes-scraper, quotes-nginx
sudo docker compose -f /srv/quotes-scraper/deploy/compose.yaml ps

# 3) результаты
sudo ls -l /srv/quotes-scraper/results
curl http://127.0.0.1:8080/results/<job_id>.json
curl http://127.0.0.1:8080/health

# 4) Redis Streams: stream, группа, pending
sudo docker exec quotes-redis redis-cli XLEN jobs
sudo docker exec quotes-redis redis-cli XINFO GROUPS jobs
sudo docker exec quotes-redis redis-cli XPENDING jobs scrapers

# 5) SSH hardening и группы
sudo sshd -T | grep -E 'permitrootlogin|passwordauthentication|kbdinteractive'
sudo sshd -t && echo "sshd -t ok"
id admin                            # в списке групп НЕТ docker
sudo ss -ltnp | grep -E ':6379|:8080'   # 6379 не слушает наружу, 8080 — да
```

`make fault-test` можно наблюдать так: пока основной скрапер остановлен, после
запуска одноразового воркера в fault-режиме `XPENDING jobs scrapers` показывает
`1` — задание висит; после `docker start quotes-scraper` счётчик уходит в `0`,
а файл появляется.

## Вопросы защиты (кратко)

1. **Где заканчивается cloud-init и начинается Ansible?** cloud-init — только
   bootstrap VM (временный пользователь, ключ, sudo, python). Всё, что настраивается
   после первого входа, — playbook-и; иначе конфигурация перестаёт быть кодом и не
   перезапускается идемпотентно.
2. **Почему hardening только после входа под `admin`?** Сначала создаём `admin` и
   **проверяем реальный вход** (`whoami` в новом play + ключ). Иначе отключение
   bootstrap-входа могло бы заблокировать единственный способ доступа. `sshd -t`
   проверяет конфиг до перезапуска, handler применяет изменения только при них.
3. **Почему `admin` не в группе `docker`?** Доступ к docker-сокету равен root-доступу.
   Команды docker выполняются через `become` (sudo), а не через членство в группе.
4. **Role vs playbook.** Playbook — сценарий (какие хосты, порядок), role —
   переиспользуемый набор задач/handlers/defaults. Второй запуск даёт `changed=0`,
   потому что все задачи декларативны и идемпотентны (файлы не меняются, handler не
   срабатывает, apt/docker не переустанавливаются).
5. **Streams + consumer group vs List + BLPOP.** `BLPOP` сразу удаляет элемент: при
   падении воркера задание теряется. Stream + group держит запись в PEL до `XACK`,
   поэтому задание можно доиграть.
6. **Что в PEL и как перехватить зависшее?** PEL хранит id записи, консьюмера и
   время последней доставки. Другой консьюмер перехватывает через `XAUTOCLAIM`
   (или `XCLAIM`) и продолжает обработку.
7. **Почему tmp + rename и XACK последним?** Запись во временный файл и атомарный
   `rename` гарантируют, что читатель никогда не увидит половину файла; `XACK` после
   записи гарантирует, что подтверждается только реально сохранённое задание.
8. **Что AI-агент сделал не так с первого раза?** Первая версия удалила артефакты
   лабораторной 2 (OpenTofu/floci) — этого задание не требовало. Замечено по
   замечанию к git-статусу; файлы восстановлены, lab-3 сделана аддитивно.
