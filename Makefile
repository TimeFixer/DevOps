SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

VM_NAME ?= quotes-vm
URL ?= https://quotes.toscrape.com/scroll
TIMEOUT ?= 90

MULTIPASS := multipass.exe
LAB_DIR := .lab
SSH_KEY := $(HOME)/.ssh/quotes_lab_key
SSH_HOST := 172.24.208.1
SSH_PORT := 2222
KNOWN_HOSTS := $(LAB_DIR)/known_hosts
INVENTORY := infra/ansible/inventories/lab/hosts.yml
ANSIBLE_ENV := ANSIBLE_CONFIG=$(CURDIR)/infra/ansible/ansible.cfg ANSIBLE_ROLES_PATH=$(CURDIR)/infra/ansible/roles

.PHONY: setup provision deploy run verify fault-test destroy ci

setup:
	ansible-galaxy collection install -r infra/ansible/requirements.yml

provision:
	@mkdir -p "$(LAB_DIR)" infra/ansible/inventories/lab "$(HOME)/.ssh"
	@test -f "$(SSH_KEY)" || (ssh-keygen -t ed25519 -N "" -f "$(SSH_KEY)" -C "lab-ansible" -q && chmod 600 "$(SSH_KEY)")
	@if ! $(MULTIPASS) list --format csv | tr -d '\r' | awk -F, 'NR>1 {print $$1}' | grep -qx "$(VM_NAME)"; then 		PUBKEY=$$(cat "$(SSH_KEY).pub"); 		sed "s|__SSH_PUBLIC_KEY__|$$PUBKEY|g" infra/cloud-init.yaml > "$(LAB_DIR)/cloud-init.rendered.yaml"; 		$(MULTIPASS) launch 24.04 --name "$(VM_NAME)" --cpus 2 --memory 4G --disk 20G --cloud-init - < "$(LAB_DIR)/cloud-init.rendered.yaml"; 		$(MULTIPASS) exec "$(VM_NAME)" -- cloud-init status --wait >/dev/null; 	fi
	@IP=$$($(MULTIPASS) info "$(VM_NAME)" --format csv | tr -d '\r' | awk -F, 'NR==1{for(i=1;i<=NF;i++) if($$i=="Ipv4") col=i} NR==2{print $$col}'); 	echo "$$IP" > "$(LAB_DIR)/vm_ip"; 	PUBKEY=$$(cat "$(SSH_KEY).pub"); 	$(MULTIPASS) exec "$(VM_NAME)" -- bash -lc "mkdir -p /home/ubuntu/.ssh && chmod 700 /home/ubuntu/.ssh && grep -qxF '$$PUBKEY' /home/ubuntu/.ssh/authorized_keys 2>/dev/null || echo '$$PUBKEY' >> /home/ubuntu/.ssh/authorized_keys; chmod 600 /home/ubuntu/.ssh/authorized_keys && chown -R ubuntu:ubuntu /home/ubuntu/.ssh"; 	ssh-keyscan -p "$(SSH_PORT)" -H "$(SSH_HOST)" 2>/dev/null > "$(KNOWN_HOSTS)" || true; 	printf -- "---\nall:\n  children:\n    scraper_vm:\n      hosts:\n        $(VM_NAME):\n          ansible_host: $(SSH_HOST)\n          ansible_port: $(SSH_PORT)\n          ansible_user: ubuntu\n          ansible_ssh_private_key_file: $(SSH_KEY)\n          ansible_ssh_common_args: \"-o StrictHostKeyChecking=no -o UserKnownHostsFile=$(CURDIR)/$(KNOWN_HOSTS)\"\n" > "$(INVENTORY)"; 	if ssh -i "$(SSH_KEY)" -p "$(SSH_PORT)" -o StrictHostKeyChecking=no -o UserKnownHostsFile="$(KNOWN_HOSTS)" -o BatchMode=yes "admin@$(SSH_HOST)" true 2>/dev/null; then 		sed -i 's/ansible_user: ubuntu/ansible_user: admin/' "$(INVENTORY)"; 	else 		$(ANSIBLE_ENV) ansible-playbook -i "$(INVENTORY)" infra/ansible/playbooks/bootstrap.yml && 		sed -i 's/ansible_user: ubuntu/ansible_user: admin/' "$(INVENTORY)"; 	fi; 	$(ANSIBLE_ENV) ansible-playbook -i "$(INVENTORY)" infra/ansible/playbooks/site.yml

deploy:
	@$(ANSIBLE_ENV) ansible-playbook -i "$(INVENTORY)" infra/ansible/playbooks/site.yml --tags scraper

run:
	@JOB_ID="job-$$(date +%s)-$$$$"; echo "$$JOB_ID" > "$(LAB_DIR)/last_job_id"; 	ssh -i "$(SSH_KEY)" -p "$(SSH_PORT)" -o StrictHostKeyChecking=no -o UserKnownHostsFile="$(KNOWN_HOSTS)" -o BatchMode=yes "admin@$(SSH_HOST)" 		"sudo docker compose -f /srv/quotes-scraper/app/deploy/compose.yaml exec -T redis redis-cli XADD jobs '*' job_id '$$JOB_ID' url '$(URL)'"; 	echo "job_id=$$JOB_ID"

verify:
	@$(ANSIBLE_ENV) ansible-playbook -i "$(INVENTORY)" infra/ansible/playbooks/verify.yml
	@JOB_ID="$${JOB_ID:-$$(cat $(LAB_DIR)/last_job_id)}"; 	VM_IP=$$(cat "$(LAB_DIR)/vm_ip"); 	DEADLINE=$$(( $$(date +%s) + $(TIMEOUT) )); 	while [ $$(date +%s) -lt $$DEADLINE ]; do 		CODE=$$(scp -i "$(SSH_KEY)" -P "$(SSH_PORT)" -o StrictHostKeyChecking=no -o UserKnownHostsFile="$(KNOWN_HOSTS)" -o BatchMode=yes "admin@$(SSH_HOST):/srv/quotes-scraper/results/$$JOB_ID.json" "$(LAB_DIR)/res.json" >/dev/null 2>&1 && echo 200 || echo 404); 		PEND=$$(ssh -i "$(SSH_KEY)" -p "$(SSH_PORT)" -o StrictHostKeyChecking=no -o UserKnownHostsFile="$(KNOWN_HOSTS)" -o BatchMode=yes "admin@$(SSH_HOST)" "sudo docker compose -f /srv/quotes-scraper/app/deploy/compose.yaml exec -T redis redis-cli XPENDING jobs scrapers" | head -n1 | tr -d '\r'); 		TMP=$$(ssh -i "$(SSH_KEY)" -p "$(SSH_PORT)" -o StrictHostKeyChecking=no -o UserKnownHostsFile="$(KNOWN_HOSTS)" -o BatchMode=yes "admin@$(SSH_HOST)" "find /srv/quotes-scraper/results -maxdepth 1 -name '*.tmp' | wc -l" | tr -d '\r'); 		[ "$$CODE" = "200" ] && [ "$$PEND" = "0" ] && [ "$$TMP" = "0" ] && break; 		sleep 2; 	done; 	python3 -c "import json; d=json.load(open('$(LAB_DIR)/res.json')); assert isinstance(d,list) and len(d)>0"

fault-test:
	@JOB_ID="fault-$$(date +%s)"; 	SSH_CMD="ssh -i $(SSH_KEY) -p $(SSH_PORT) -o StrictHostKeyChecking=no -o UserKnownHostsFile=$(KNOWN_HOSTS) -o BatchMode=yes admin@$(SSH_HOST)"; 	$$SSH_CMD "sudo docker compose -f /srv/quotes-scraper/app/deploy/compose.yaml exec -T redis redis-cli XADD jobs '*' job_id '$$JOB_ID' url '$(URL)'" >/dev/null; 	for _ in $$(seq 1 100); do 		[ "$$($$SSH_CMD "sudo docker compose -f /srv/quotes-scraper/app/deploy/compose.yaml exec -T redis redis-cli XPENDING jobs scrapers" | head -n1 | tr -d '\r')" -ge 1 ] 2>/dev/null && break; 		sleep 0.2; 	done; 	$$SSH_CMD "sudo docker compose -f /srv/quotes-scraper/app/deploy/compose.yaml kill -s SIGKILL scraper"; 	test "$$($$SSH_CMD "sudo docker compose -f /srv/quotes-scraper/app/deploy/compose.yaml exec -T redis redis-cli XPENDING jobs scrapers" | head -n1 | tr -d '\r')" -ge 1; 	$$SSH_CMD "sudo docker compose -f /srv/quotes-scraper/app/deploy/compose.yaml up -d scraper" >/dev/null; 	DEADLINE=$$(( $$(date +%s) + $(TIMEOUT) )); 	while [ $$(date +%s) -lt $$DEADLINE ]; do 		PEND=$$($$SSH_CMD "sudo docker compose -f /srv/quotes-scraper/app/deploy/compose.yaml exec -T redis redis-cli XPENDING jobs scrapers" | head -n1 | tr -d '\r'); 		DONE=$$($$SSH_CMD "test -f /srv/quotes-scraper/results/$$JOB_ID.json && echo 1 || echo 0" | tr -d '\r'); 		[ "$$DONE" = "1" ] && [ "$$PEND" = "0" ] && break; 		sleep 2; 	done; 	$$SSH_CMD "cp /srv/quotes-scraper/results/$$JOB_ID.json /tmp/f1.json"; 	H1=$$($$SSH_CMD "sha256sum /tmp/f1.json | awk '{print $1}'" | tr -d '\r'); 	$$SSH_CMD "sudo docker compose -f /srv/quotes-scraper/app/deploy/compose.yaml exec -T redis redis-cli XADD jobs '*' job_id '$$JOB_ID' url '$(URL)'" >/dev/null; sleep 3; 	H2=$$($$SSH_CMD "sha256sum /srv/quotes-scraper/results/$$JOB_ID.json | awk '{print $1}'" | tr -d '\r'); 	test "$$($$SSH_CMD "find /srv/quotes-scraper/results -maxdepth 1 -name '*$$JOB_ID*' | wc -l" | tr -d '\r')" = "1"; 	test "$$H1" = "$$H2"

destroy:
	@if $(MULTIPASS) list --format csv 2>/dev/null | tr -d '\r' | awk -F, 'NR>1 {print $$1}' | grep -qx "$(VM_NAME)"; then 		$(MULTIPASS) delete --purge "$(VM_NAME)"; 	fi
	@rm -rf "$(LAB_DIR)" infra/ansible/inventories/lab

ci:
	ansible-galaxy collection install -r infra/ansible/requirements.yml
	yamllint .
	$(ANSIBLE_ENV) ansible-lint infra/ansible/playbooks/
	$(ANSIBLE_ENV) ansible-playbook -i infra/ansible/inventories/hosts.example.yml --syntax-check 		infra/ansible/playbooks/bootstrap.yml infra/ansible/playbooks/site.yml infra/ansible/playbooks/verify.yml
	docker compose -f deploy/compose.yaml config -q
