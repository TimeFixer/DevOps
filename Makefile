SHELL := /bin/bash

VM_NAME ?= quotes-vm
SSH_HOST ?= 127.0.0.1
SSH_PORT ?= 2222
SSH_KEY ?= $(HOME)/.ssh/quotes_lab_key
SSH_PUBKEY ?= $(SSH_KEY).pub

LAB_DIR := .lab
VM_IP_FILE := $(LAB_DIR)/vm_ip
KNOWN_HOSTS := $(LAB_DIR)/known_hosts
INVENTORY := $(LAB_DIR)/hosts.yml
LAB_PUBKEY := $(LAB_DIR)/id_ed25519.pub

ANSIBLE_INVENTORY ?= infra/ansible/inventories/lab/hosts.yml
ANSIBLE_ENV ?= ANSIBLE_HOST_KEY_CHECKING=False ANSIBLE_ROLES_PATH=$(CURDIR)/infra/ansible/roles

URL ?= https://quotes.toscrape.com/scroll
TIMEOUT ?= 120

LOCAL_PORT ?= 8080
VM_PORT ?= 18080

MULTIPASS ?= multipass.exe

OUT_DIR ?= out
OUT_FILE ?= $(OUT_DIR)/result.json

.PHONY: all sync-ip provision run verify fault tunnel destroy

all: provision run verify

sync-ip:
	@mkdir -p "$(LAB_DIR)"
	@NEW_IP=$$($(MULTIPASS) info "$(VM_NAME)" --format csv 2>/dev/null | tr -d '\r' | awk -F, 'NR==1{for(i=1;i<=NF;i++) if($$i=="Ipv4") col=i} NR==2{print $$col}'); \
	test -n "$$NEW_IP" || { echo "Failed to get IP for $(VM_NAME)"; exit 1; }; \
	echo "$$NEW_IP" > "$(VM_IP_FILE)"; \
	CUR_IP=$$(powershell.exe -NoProfile -Command "netsh interface portproxy show v4tov4" 2>/dev/null | awk '/0\.0\.0\.0[[:space:]]+$(SSH_PORT)/{print $$3}' | tr -d '\r'); \
	if [ "$$CUR_IP" != "$$NEW_IP" ]; then \
		echo "Updating Windows portproxy $(SSH_PORT) -> $$NEW_IP (requires Administrator)..."; \
		powershell.exe -NoProfile -Command "Start-Process powershell -Verb RunAs -Wait -ArgumentList '-NoProfile -Command \"netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=$(SSH_PORT) 2>\$$null; netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=$(SSH_PORT) connectaddress=$$NEW_IP connectport=22\"'"; \
	fi

provision: sync-ip
	@mkdir -p "$(LAB_DIR)" "$$(dirname "$(SSH_KEY)")"
	@if [ ! -f "$(SSH_KEY)" ]; then \
		ssh-keygen -t ed25519 -N "" -f "$(SSH_KEY)" -C "lab-ansible"; \
	fi
	@cp "$(SSH_PUBKEY)" "$(LAB_PUBKEY)"
	@chmod 644 "$(LAB_PUBKEY)"
	@ssh-keyscan -p "$(SSH_PORT)" -H "$(SSH_HOST)" 2>/dev/null > "$(KNOWN_HOSTS)" || true
	@printf -- "---\nall:\n  children:\n    scraper_vm:\n      hosts:\n        $(VM_NAME):\n          ansible_host: $(SSH_HOST)\n          ansible_port: $(SSH_PORT)\n          ansible_user: ubuntu\n          ansible_ssh_private_key_file: $(SSH_KEY)\n          ansible_ssh_common_args: \"-o StrictHostKeyChecking=no -o UserKnownHostsFile=$(CURDIR)/$(KNOWN_HOSTS)\"\n" > "$(INVENTORY)"
	@if ssh -i "$(SSH_KEY)" -p "$(SSH_PORT)" -o StrictHostKeyChecking=no -o UserKnownHostsFile="$(KNOWN_HOSTS)" -o BatchMode=yes "admin@$(SSH_HOST)" true 2>/dev/null; then \
		sed -i 's/ansible_user: ubuntu/ansible_user: admin/' "$(INVENTORY)"; \
	else \
		PUBKEY=$$(cat "$(LAB_PUBKEY)"); \
		$(MULTIPASS) exec "$(VM_NAME)" -- bash -lc "mkdir -p /home/ubuntu/.ssh && chmod 700 /home/ubuntu/.ssh && grep -qxF '$$PUBKEY' /home/ubuntu/.ssh/authorized_keys 2>/dev/null || echo '$$PUBKEY' >> /home/ubuntu/.ssh/authorized_keys; chmod 600 /home/ubuntu/.ssh/authorized_keys && chown -R ubuntu:ubuntu /home/ubuntu/.ssh"; \
		$(ANSIBLE_ENV) ansible-playbook -i "$(INVENTORY)" infra/ansible/playbooks/bootstrap.yml -e "admin_ssh_pubkey_path=$(CURDIR)/$(LAB_PUBKEY)" && \
		sed -i 's/ansible_user: ubuntu/ansible_user: admin/' "$(INVENTORY)"; \
	fi
	@$(ANSIBLE_ENV) ansible-playbook -i "$(INVENTORY)" infra/ansible/playbooks/site.yml -e "admin_ssh_pubkey_path=$(CURDIR)/$(LAB_PUBKEY)"

run: sync-ip
	@mkdir -p "$(LAB_DIR)" "$(OUT_DIR)"
	@JOB_ID="job-$$(date +%s)-$$$$"; \
	echo "$$JOB_ID" > "$(LAB_DIR)/last_job_id"; \
	ssh -i "$(SSH_KEY)" -p "$(SSH_PORT)" -o StrictHostKeyChecking=no -o UserKnownHostsFile="$(KNOWN_HOSTS)" -o BatchMode=yes "admin@$(SSH_HOST)" \
		"sudo docker compose -f /srv/quotes-scraper/app/deploy/compose.yaml exec -T redis redis-cli XADD jobs '*' job_id '$$JOB_ID' url '$(URL)'"; \
	echo "job_id=$$JOB_ID"; \
	DEADLINE=$$(( $$(date +%s) + $(TIMEOUT) )); \
	while [ $$(date +%s) -lt $$DEADLINE ]; do \
		if scp -i "$(SSH_KEY)" -P "$(SSH_PORT)" -o StrictHostKeyChecking=no -o UserKnownHostsFile="$(KNOWN_HOSTS)" -o BatchMode=yes \
			"admin@$(SSH_HOST):/srv/quotes-scraper/results/$$JOB_ID.json" "$(OUT_FILE)" >/dev/null 2>&1; then \
			PEND=$$(ssh -i "$(SSH_KEY)" -p "$(SSH_PORT)" -o StrictHostKeyChecking=no -o UserKnownHostsFile="$(KNOWN_HOSTS)" -o BatchMode=yes "admin@$(SSH_HOST)" \
				"sudo docker compose -f /srv/quotes-scraper/app/deploy/compose.yaml exec -T redis redis-cli XPENDING jobs scrapers" | head -n1 | tr -d '\r'); \
			TMP=$$(ssh -i "$(SSH_KEY)" -p "$(SSH_PORT)" -o StrictHostKeyChecking=no -o UserKnownHostsFile="$(KNOWN_HOSTS)" -o BatchMode=yes "admin@$(SSH_HOST)" \
				"find /srv/quotes-scraper/results -maxdepth 1 -name '*.tmp' | wc -l" | tr -d '\r'); \
			if [ "$$PEND" = "0" ] && [ "$$TMP" = "0" ]; then \
				python3 -c "import json; d=json.load(open('$(OUT_FILE)')); assert isinstance(d,list) and len(d)>0; print('saved $(OUT_FILE), count:', len(d))"; \
				exit 0; \
			fi; \
		fi; \
		sleep 2; \
	done; \
	echo "Timed out waiting for result of $$JOB_ID" >&2; \
	exit 1

verify: sync-ip
	@$(ANSIBLE_ENV) ansible-playbook -i "$(ANSIBLE_INVENTORY)" infra/ansible/playbooks/verify.yml \
		-e "ansible_user=admin ansible_ssh_private_key_file=$(SSH_KEY)"
	@JOB_ID="$${JOB_ID:-$$(cat $(LAB_DIR)/last_job_id)}"; \
	DEADLINE=$$(( $$(date +%s) + $(TIMEOUT) )); \
	while [ $$(date +%s) -lt $$DEADLINE ]; do \
		CODE=$$(scp -i "$(SSH_KEY)" -P "$(SSH_PORT)" -o StrictHostKeyChecking=no -o UserKnownHostsFile="$(KNOWN_HOSTS)" -o BatchMode=yes "admin@$(SSH_HOST):/srv/quotes-scraper/results/$$JOB_ID.json" "$(LAB_DIR)/res.json" >/dev/null 2>&1 && echo 200 || echo 404); \
		PEND=$$(ssh -i "$(SSH_KEY)" -p "$(SSH_PORT)" -o StrictHostKeyChecking=no -o UserKnownHostsFile="$(KNOWN_HOSTS)" -o BatchMode=yes "admin@$(SSH_HOST)" "sudo docker compose -f /srv/quotes-scraper/app/deploy/compose.yaml exec -T redis redis-cli XPENDING jobs scrapers" | head -n1 | tr -d '\r'); \
		TMP=$$(ssh -i "$(SSH_KEY)" -p "$(SSH_PORT)" -o StrictHostKeyChecking=no -o UserKnownHostsFile="$(KNOWN_HOSTS)" -o BatchMode=yes "admin@$(SSH_HOST)" "find /srv/quotes-scraper/results -maxdepth 1 -name '*.tmp' | wc -l" | tr -d '\r'); \
		[ "$$CODE" = "200" ] && [ "$$PEND" = "0" ] && [ "$$TMP" = "0" ] && break; \
		sleep 2; \
	done; \
	python3 -c "import json; d=json.load(open('$(LAB_DIR)/res.json')); assert isinstance(d,list) and len(d)>0"

fault: sync-ip
	@JOB_ID="fault-$$(date +%s)"; \
	SSH_CMD="ssh -i $(SSH_KEY) -p $(SSH_PORT) -o StrictHostKeyChecking=no -o UserKnownHostsFile=$(KNOWN_HOSTS) -o BatchMode=yes admin@$(SSH_HOST)"; \
	$$SSH_CMD "sudo docker compose -f /srv/quotes-scraper/app/deploy/compose.yaml exec -T redis redis-cli XADD jobs '*' job_id '$$JOB_ID' url '$(URL)'" >/dev/null; \
	for _ in $$(seq 1 100); do \
		[ "$$($$SSH_CMD "sudo docker compose -f /srv/quotes-scraper/app/deploy/compose.yaml exec -T redis redis-cli XPENDING jobs scrapers" | head -n1 | tr -d '\r')" -ge 1 ] 2>/dev/null && break; \
		sleep 0.2; \
	done; \
	$$SSH_CMD "sudo docker compose -f /srv/quotes-scraper/app/deploy/compose.yaml kill -s SIGKILL scraper"; \
	test "$$($$SSH_CMD "sudo docker compose -f /srv/quotes-scraper/app/deploy/compose.yaml exec -T redis redis-cli XPENDING jobs scrapers" | head -n1 | tr -d '\r')" -ge 1; \
	$$SSH_CMD "sudo docker compose -f /srv/quotes-scraper/app/deploy/compose.yaml up -d scraper" >/dev/null; \
	DEADLINE=$$(( $$(date +%s) + $(TIMEOUT) )); \
	while [ $$(date +%s) -lt $$DEADLINE ]; do \
		PEND=$$($$SSH_CMD "sudo docker compose -f /srv/quotes-scraper/app/deploy/compose.yaml exec -T redis redis-cli XPENDING jobs scrapers" | head -n1 | tr -d '\r'); \
		DONE=$$($$SSH_CMD "test -f /srv/quotes-scraper/results/$$JOB_ID.json && echo 1 || echo 0" | tr -d '\r'); \
		[ "$$DONE" = "1" ] && [ "$$PEND" = "0" ] && break; \
		sleep 2; \
	done; \
	$$SSH_CMD "cp /srv/quotes-scraper/results/$$JOB_ID.json /tmp/f1.json"; \
	H1=$$($$SSH_CMD "sha256sum /tmp/f1.json | awk '{print $$1}'" | tr -d '\r'); \
	$$SSH_CMD "sudo docker compose -f /srv/quotes-scraper/app/deploy/compose.yaml exec -T redis redis-cli XADD jobs '*' job_id '$$JOB_ID' url '$(URL)'" >/dev/null; \
	sleep 3; \
	H2=$$($$SSH_CMD "sha256sum /tmp/f1.json | awk '{print $$1}'" | tr -d '\r'); \
	test "$$($$SSH_CMD "find /srv/quotes-scraper/results -maxdepth 1 -name '*$$JOB_ID*' | wc -l" | tr -d '\r')" = "1"; \
	test "$$H1" = "$$H2"

destroy:
	@$(MULTIPASS) delete --purge "$(VM_NAME)" 2>/dev/null || true
	@rm -rf "$(LAB_DIR)"