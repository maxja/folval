.PHONY: help init plan provision refresh inventory galaxy configure up gpu d3d9 serve destroy clean

ENV_FILE := .env.secrets
OP := op run --env-file=$(ENV_FILE) --
TFDIR := provisioning
CFG := configuration

help:
	@echo "Usage:"
	@echo "  make init        - tofu init"
	@echo "  make plan        - preview (needs .env.secrets)"
	@echo "  make provision   - create VM, NOT started"
	@echo "  make refresh     - re-read state (agent IP etc.)"
	@echo "  make up          - start VM via API, wait for guest-agent IP"
	@echo "  make inventory   - write configuration/inventory/hosts.yaml (winrm)"
	@echo "  make galaxy      - install collections (one-time)"
	@echo "  make configure   - guest roles: nvidia_driver, game_stack, frida"
	@echo "                     TAGS/ARGS supported"
	@echo "  make gpu         - gpu-ready probe (restart until problem=0)"
	@echo "  make d3d9        - THE GATE: d3d9probe + result"
	@echo "  make serve       - brain staging server on 192.168.100.1:8080"
	@echo "  make destroy     - tear down VM"
	@echo "  make clean       - remove generated inventory"

init:
	$(OP) tofu -chdir=$(TFDIR) init

plan:
	$(OP) tofu -chdir=$(TFDIR) plan

provision:
	$(OP) tofu -chdir=$(TFDIR) apply -auto-approve

refresh:
	$(OP) tofu -chdir=$(TFDIR) apply -refresh-only -auto-approve

# Start the VM (API) and poll the guest agent until it reports an IP.
up:
	$(OP) tofu -chdir=$(TFDIR) apply -auto-approve -var vm_started=true
	@echo "Waiting for QEMU guest agent to report an IP..."
	@for i in $$(seq 1 60); do \
	  IP=$$($(OP) tofu -chdir=$(TFDIR) output -raw vm_primary_ip 2>/dev/null); \
	  if [ -n "$$IP" ] && [ "$$IP" != "null" ]; then echo "✓ guest IP: $$IP"; exit 0; fi; \
	  sleep 10; \
	done; echo "ERROR: agent IP never appeared (is qemu-ga running in the guest?)"; exit 1

inventory:
	@IP=$$($(OP) tofu -chdir=$(TFDIR) output -raw vm_primary_ip 2>&1) && [ -n "$$IP" ] && [ "$$IP" != "null" ] || { \
	  echo "ERROR: no vm_primary_ip — run 'make up' first"; exit 1; }; \
	  mkdir -p $(CFG)/inventory && \
	  printf 'all:\n  children:\n    windows:\n      hosts:\n        folval3:\n          ansible_host: %s\n' "$$IP" > $(CFG)/inventory/hosts.yaml && \
	  echo "✓ inventory written — folval3: $$IP"

galaxy:
	ansible-galaxy collection install -r $(CFG)/requirements.yaml

configure:
	ANSIBLE_CONFIG=$(CFG)/ansible.cfg $(OP) ansible-playbook -i $(CFG)/inventory/hosts.yaml $(CFG)/site.yaml $(if $(TAGS),--tags $(TAGS)) $(if $(ARGS),$(ARGS))

gpu:
	ANSIBLE_CONFIG=$(CFG)/ansible.cfg $(OP) ansible-playbook -i $(CFG)/inventory/hosts.yaml $(CFG)/gpu.yaml

d3d9:
	ANSIBLE_CONFIG=$(CFG)/ansible.cfg $(OP) ansible-playbook -i $(CFG)/inventory/hosts.yaml $(CFG)/d3d9.yaml

serve:
	setsid nohup python3 -m http.server 8080 --bind 192.168.100.1 --directory $(CURDIR)/.. > /tmp/folval-push.log 2>&1 & sleep 2 && curl -s -o /dev/null -w "staging: %{http_code}\n" "http://192.168.100.1:8080/push/" && echo "(pid $$! logged to /tmp/folval-push.log)"

destroy:
	$(OP) tofu -chdir=$(TFDIR) destroy

clean:
	rm -f $(CFG)/inventory/hosts.yaml
