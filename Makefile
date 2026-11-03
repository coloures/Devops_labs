# Единственная точка входа лабораторной 3.
#
# Control node должен быть POSIX-окружением (WSL2/Linux/macOS): GNU make и
# Ansible работают здесь, а Multipass на Windows вызывается как multipass.exe.
# Все команды — только через make.

SHELL := /bin/sh
.DEFAULT_GOAL := help

# ---------- Целевая виртуальная машина ----------
VM_NAME      ?= quotes-lab3
UBUNTU_IMAGE ?= 24.04
VM_CPUS      ?= 2
VM_MEMORY    ?= 4G
VM_DISK      ?= 20G
VM_TIMEOUT   ?= 1800
BOOTSTRAP_USER ?= bootstrap

# Multipass: на Windows/WSL берём multipass.exe, иначе linux-клиент.
MULTIPASS ?= $(shell command -v multipass.exe 2>/dev/null || command -v multipass 2>/dev/null || echo multipass)

# ---------- Пути ----------
LAB_DIR      := .lab
KEY          := $(LAB_DIR)/id_ed25519
KNOWN_HOSTS  := $(LAB_DIR)/known_hosts
LAB_CLOUD    := $(LAB_DIR)/cloud-init.yaml
VM_IP_FILE   := $(LAB_DIR)/vm_ip
LAST_JOB     := $(LAB_DIR)/last_job_id

ANSIBLE_DIR  := infra/ansible
INVENTORY    := $(ANSIBLE_DIR)/inventories/lab/hosts.yml
INVENTORY_EX := $(ANSIBLE_DIR)/inventories/hosts.example.yml
PLAYBOOKS    := $(ANSIBLE_DIR)/playbooks

# ansible-core игнорирует ansible.cfg, лежащий в world-writable каталоге
# (например, bind-mount с Windows), поэтому roles_path дублируем переменной
# окружения — она от этой проверки не зависит.
export ANSIBLE_ROLES_PATH := $(abspath $(ANSIBLE_DIR)/roles)

# ---------- Параметры запуска ----------
URL            ?= https://quotes.toscrape.com/scroll
VERIFY_TIMEOUT ?= 180

# job_id для make run / make fault-test. По умолчанию — свежий UUID
# (вычисляется один раз за запуск make); переопределяется: make run JOB_ID=abc.
ifeq ($(origin JOB_ID),undefined)
JOB_ID := $(shell cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '-' | cut -c1-12 || date +%s)
endif

# job_id для make verify. По умолчанию — последний из make run; переопределяется:
# make verify JOB=abc.
ifeq ($(origin JOB),undefined)
JOB := $(shell cat $(LAST_JOB) 2>/dev/null)
endif

.PHONY: help check-tools setup deps vm-up inventory wait-for-cloud-init \
        provision bootstrap site deploy run verify fault-test destroy ci \
        yaml-check ansible-lint syntax-check compose-config check-inventory

help:
	@echo "Лабораторная 3: скрапер на Ubuntu VM под управлением Ansible"
	@echo ""
	@echo "  make provision    создать VM (cloud-init) + inventory + применить Ansible"
	@echo "  make deploy       развернуть/обновить стек Redis + scraper + Nginx"
	@echo "  make run          добавить одно задание (URL=<url>) в stream jobs"
	@echo "  make verify       проверить задание (JOB=<job_id>, timeout $(VERIFY_TIMEOUT)s)"
	@echo "  make fault-test   доказать отказоустойчивость (падение до XACK)"
	@echo "  make destroy      удалить VM и $(LAB_DIR)/ (повторный запуск безопасен)"
	@echo "  make ci           линт + syntax-check + docker compose config (как в CI)"
	@echo ""
	@echo "  переменные: VM_NAME=$(VM_NAME) UBUNTU_IMAGE=$(UBUNTU_IMAGE) URL=$(URL)"

# ---------- Инструменты control node ----------
check-tools:
	@command -v ssh >/dev/null 2>&1 || { echo "Ошибка: нет ssh (openssh-client)"; exit 1; }
	@command -v ssh-keygen >/dev/null 2>&1 || { echo "Ошибка: нет ssh-keygen (openssh-client)"; exit 1; }
	@command -v python3 >/dev/null 2>&1 || { echo "Ошибка: нет python3 (нужен для генерации inventory)"; exit 1; }
	@command -v ansible-playbook >/dev/null 2>&1 || { echo "Ошибка: нет ansible-playbook. Установите ansible-core."; exit 1; }
	@$(MULTIPASS) version >/dev/null 2>&1 || { echo "Ошибка: не найден Multipass ('$(MULTIPASS)'). В WSL он вызывается как multipass.exe."; exit 1; }

# ---------- Подготовка control node: .lab/ и SSH-ключ ----------
setup: check-tools
	@mkdir -p $(LAB_DIR)
	@if [ ! -f $(KEY) ]; then \
		ssh-keygen -t ed25519 -N '' -C 'quotes-lab3' -f $(KEY) >/dev/null; \
		echo "создан SSH-ключ $(KEY)"; \
	else \
		echo "SSH-ключ $(KEY) уже существует"; \
	fi
	@touch $(KNOWN_HOSTS)
	@sed "s|__SSH_PUBLIC_KEY__|$$(cat $(KEY).pub)|" infra/cloud-init.yaml > $(LAB_CLOUD)
	@echo "cloud-init для VM: $(LAB_CLOUD)"

# ---------- Коллекции Ansible ----------
deps:
	ansible-galaxy collection install -r $(ANSIBLE_DIR)/requirements.yml

# ---------- Создание VM (Multipass) с bootstrap через cloud-init ----------
vm-up: setup deps
	@if $(MULTIPASS) info $(VM_NAME) >/dev/null 2>&1; then \
		echo "VM $(VM_NAME) уже существует — создание пропущено"; \
	else \
		echo "создаю VM $(VM_NAME): Ubuntu $(UBUNTU_IMAGE), $(VM_CPUS) CPU, $(VM_MEMORY) RAM, $(VM_DISK) disk"; \
		$(MULTIPASS) launch $(UBUNTU_IMAGE) \
			--name $(VM_NAME) \
			--cpus $(VM_CPUS) \
			--memory $(VM_MEMORY) \
			--disk $(VM_DISK) \
			--timeout $(VM_TIMEOUT) \
			--cloud-init $(LAB_CLOUD); \
	fi

# ---------- Генерация inventory из данных Multipass ----------
inventory:
	@mkdir -p $(LAB_DIR) $(ANSIBLE_DIR)/inventories/lab
	@i=0; \
	 until ip=$$($(MULTIPASS) info $(VM_NAME) --format json 2>/dev/null \
			| python3 -c "import json,sys; d=json.load(sys.stdin); print((d.get('info',{}).get('$(VM_NAME)',{}).get('ipv4') or [''])[0])" 2>/dev/null) \
			&& [ -n "$$ip" ]; do \
	   i=$$((i+1)); \
	   if [ $$i -gt 60 ]; then echo "Ошибка: Multipass так и не отдал IPv4"; exit 1; fi; \
	   sleep 2; \
	 done; \
	 echo "$$ip" > $(VM_IP_FILE); \
	 ssh-keyscan -H "$$ip" >> $(KNOWN_HOSTS) 2>/dev/null || true; \
	 { \
	   echo '---'; \
	   echo '# Сгенерировано `make inventory`. В git не коммитится.'; \
	   echo 'all:'; \
	   echo '  children:'; \
	   echo '    lab:'; \
	   echo '      hosts:'; \
	   echo '        scraper:'; \
	   echo "          ansible_host: $$ip"; \
	   echo '          ansible_user: $(BOOTSTRAP_USER)'; \
	   echo "          ansible_ssh_private_key_file: $(abspath $(KEY))"; \
	   echo "          ansible_ssh_common_args: '-o UserKnownHostsFile=$(abspath $(KNOWN_HOSTS)) -o StrictHostKeyChecking=accept-new'"; \
	   echo '          ansible_python_interpreter: /usr/bin/python3'; \
	 } > $(INVENTORY); \
	 echo "inventory готов: $(INVENTORY) (ansible_host=$$ip, user=$(BOOTSTRAP_USER))"

# ---------- Ожидание cloud-init на VM ----------
wait-for-cloud-init:
	@ip=$$(cat $(VM_IP_FILE)); \
	 i=0; \
	 until ssh -i $(KEY) -o BatchMode=yes -o ConnectTimeout=5 \
			-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$(KNOWN_HOSTS) \
			$(BOOTSTRAP_USER)@$$ip 'cloud-init status --wait' >/dev/null 2>&1; do \
	   i=$$((i+1)); \
	   if [ $$i -gt 90 ]; then echo "Ошибка: cloud-init не завершился за отведённое время"; exit 1; fi; \
	   echo "жду cloud-init ($$i/90)..."; \
	   sleep 5; \
	 done; \
	 echo "cloud-init завершён:"; \
	 ssh -i $(KEY) -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
			-o UserKnownHostsFile=$(KNOWN_HOSTS) $(BOOTSTRAP_USER)@$$ip 'cloud-init status --long' || true

# ---------- Ansible ----------
check-inventory:
	@test -f $(INVENTORY) || { echo "Ошибка: нет $(INVENTORY). Сначала выполните make provision."; exit 1; }

provision: vm-up inventory wait-for-cloud-init
	@$(MAKE) bootstrap
	@$(MAKE) site
	@echo "Готово: VM $(VM_NAME) настроена, стек развёрнут. Дальше: make run && make verify"

bootstrap: check-inventory
	cd $(ANSIBLE_DIR) && ansible-playbook -i inventories/lab/hosts.yml playbooks/bootstrap.yml

site: check-inventory
	cd $(ANSIBLE_DIR) && ansible-playbook -i inventories/lab/hosts.yml playbooks/site.yml

deploy: check-inventory
	cd $(ANSIBLE_DIR) && ansible-playbook -i inventories/lab/hosts.yml playbooks/deploy.yml

run: check-inventory
	@mkdir -p $(LAB_DIR)
	@echo "$(JOB_ID)" > $(LAST_JOB)
	cd $(ANSIBLE_DIR) && ansible-playbook -i inventories/lab/hosts.yml playbooks/run.yml \
		-e job_id=$(JOB_ID) -e job_url="$(URL)"
	@echo "job_id=$(JOB_ID) сохранён в $(LAST_JOB)"

verify: check-inventory
	@test -n "$(JOB)" || { echo "Ошибка: не задан job_id. Сделайте make run или make verify JOB=<id>."; exit 1; }
	cd $(ANSIBLE_DIR) && ansible-playbook -i inventories/lab/hosts.yml playbooks/verify.yml \
		-e job_id=$(JOB) -e verify_timeout=$(VERIFY_TIMEOUT)

fault-test: check-inventory
	@mkdir -p $(LAB_DIR)
	@echo "$(JOB_ID)" > $(LAST_JOB)
	cd $(ANSIBLE_DIR) && ansible-playbook -i inventories/lab/hosts.yml playbooks/fault.yml \
		-e job_id=$(JOB_ID) -e job_url="$(URL)"
	@echo "fault-test: job_id=$(JOB_ID)"

# ---------- Удаление окружения (повторный запуск безопасен) ----------
destroy:
	-@$(MULTIPASS) delete --purge $(VM_NAME)
	-@rm -rf $(LAB_DIR)
	-@rm -rf $(ANSIBLE_DIR)/inventories/lab
	@echo "VM $(VM_NAME) и $(LAB_DIR)/ удалены; окружение можно создать заново"

# ---------- Линт и проверки: то же самое выполняет CI ----------
ci: deps yaml-check ansible-lint syntax-check compose-config

# Проверка YAML (yamllint ставится вместе с ansible-lint).
yaml-check:
	yamllint -c .yamllint infra deploy .github

# Статические проверки плейбуков и ролей.
ansible-lint:
	cd $(ANSIBLE_DIR) && ansible-lint

# Синтаксическая проверка playbook-ов на примере inventory (без подключения к VM).
syntax-check:
	cd $(ANSIBLE_DIR) && for pb in playbooks/*.yml; do \
		echo "syntax-check $$pb"; \
		ansible-playbook --syntax-check -i inventories/hosts.example.yml "$$pb" || exit 1; \
	done

# Проверка compose-файла без обращения к Docker daemon.
compose-config:
	docker compose -f deploy/compose.yaml config --quiet
	@echo "docker compose config: ok"
