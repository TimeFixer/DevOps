IMAGE_NAME = quotes-scraper
WORKER_CONTAINER = quotes-worker
NETWORK_NAME = floci-net

.PHONY: build provision deploy run clean destroy ci

# 1. Сборка Docker-образа скрапера
build:
	docker build -t $(IMAGE_NAME) .

# 2. Поднятие Floci, ожидание готовности порта 4566 и создание ресурсов Terraform
provision:
	docker compose up -d
	@echo "Ожидание запуска Floci на порту 4566..."
	@for i in $$(seq 1 30); do \
		if curl -s http://localhost:4566 >/dev/null 2>&1; then break; fi; \
		sleep 1; \
	done
	cd infra && terraform init && terraform apply -auto-approve

# 3. Сборка и запуск фонового воркера с подключением к сети floci-net
deploy: build
	@docker rm -f $(WORKER_CONTAINER) >/dev/null 2>&1 || true
	@BUCKET=$$(cd infra && terraform output -raw bucket_name) && \
	QUEUE_URL=$$(cd infra && terraform output -raw queue_url) && \
	docker run -d \
		--name $(WORKER_CONTAINER) \
		--network $(NETWORK_NAME) \
		-v $(CURDIR)/out:/app/out \
		-e AWS_ACCESS_KEY_ID=test \
		-e AWS_SECRET_ACCESS_KEY=test \
		-e AWS_REGION=us-east-1 \
		-e AWS_ENDPOINT_URL=http://floci:4566 \
		-e S3_BUCKET_NAME=$$BUCKET \
		-e SQS_QUEUE_URL=$$QUEUE_URL \
		$(IMAGE_NAME)
	@echo "Воркер $(WORKER_CONTAINER) запущен."

# 4. Отправка тестового задания в SQS и проверка результата в S3
run:
	docker run --rm --network floci-net -v $(CURDIR)/out:/app/out -e AWS_ACCESS_KEY_ID=test -e AWS_SECRET_ACCESS_KEY=test -e AWS_REGION=us-east-1 -e AWS_ENDPOINT_URL=http://floci:4566 -e S3_BUCKET_NAME=$$(cd infra && terraform output -raw bucket_name) -e SQS_QUEUE_URL=$$(cd infra && terraform output -raw queue_url) $(IMAGE_NAME) node src/send-task.js
# 5. Очистка локальных артефактов
clean:
	-@docker rm -f $(WORKER_CONTAINER) >/dev/null 2>&1 || true
	-@docker rmi $(IMAGE_NAME) >/dev/null 2>&1 || true
	rm -rf out
	@echo "Cleanup completed successfully."

# 6. Удаление инфраструктуры Terraform и остановка Floci
destroy:
	-@docker rm -f $(WORKER_CONTAINER) >/dev/null 2>&1 || true
	@if [ -d "infra/.terraform" ] && docker ps --format '{{.Names}}' | grep -q '^floci$$'; then \
		cd infra && terraform destroy -auto-approve; \
	fi
	docker compose down -v
	rm -f infra/terraform.tfstate infra/terraform.tfstate.backup
	@echo "Infrastructure destroyed and containers stopped."

# 7. Проверка для CI
ci:
	cd infra && terraform fmt -check
	cd infra && terraform init -backend=false
	cd infra && terraform validate
	cd infra && terraform plan
	@echo "Terraform CI успешно пройден!"