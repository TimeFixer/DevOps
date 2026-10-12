IMAGE_NAME = quotes-scraper

.PHONY: build run clean ci

build:
	docker build -t $(IMAGE_NAME) .

run:
	mkdir -p out
	docker run --rm -v $(CURDIR)/out:/app/out $(IMAGE_NAME)

clean:
	docker rmi $(IMAGE_NAME) || true
	rm -rf out
	@echo "Cleanup completed successfully."

ci: build run
	@echo "Проверка валидности JSON..."
	@cat out/result.json | python3 -m json.tool > /dev/null || (echo "Невалидный JSON!" && exit 1)
	@echo "CI успешно пройден!"