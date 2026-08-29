# .DEFAULT_GOAL := local
.PHONY: publish pre-publish clean fresh test-dev test test-run-build test-run-build-restore eject-dev config config_qa config_demo deploy deploy_qa deploy_demo run run_qa run_prod server start local tailwind tailwind-build add_submodules create_ssl_certs copy_ssl_certs config_lib run_lib sast-test
SHELL := /bin/bash

# General Commands
help:
	cat Makefile

install:
	npm install

update:
	npm update
	npm audit fix

lock:
	npm install --package-lock-only

build-dev:
	npm run build

build-prod:
	npm run build-prod

build: build-dev

dev:
	npm install --dev

clean:
	npm cache clean --force && rm -rf node_modules

fresh: clean install

# Development Commands
test-dev:
	npm run test-dev

test:
	npm run test

test-run-build:
	. scripts/build_prod_test.sh
	. scripts/build_prod_test.sh restore
 
test-run-build-restore:
	. scripts/build_prod_test.sh restore

eject-dev:
	npm run eject-dev

config:
	bash ./node_modules/genericsuite-fe-scripts/scripts/change_env_be_endpoint.sh dev

config_qa:
	bash ./node_modules/genericsuite-fe-scripts/scripts/change_env_be_endpoint.sh qa

config_demo:
	bash ./node_modules/genericsuite-fe-scripts/scripts/change_env_be_endpoint.sh demo

deploy: tailwind-build config
	bash ./node_modules/genericsuite-fe-scripts/scripts/aws_deploy_to_s3.sh

deploy_qa: tailwind-build config_qa
	bash ./node_modules/genericsuite-fe-scripts/scripts/aws_deploy_to_s3.sh

deploy_demo: tailwind-build config_demo
	bash ./node_modules/genericsuite-fe-scripts/scripts/aws_deploy_to_s3.sh

run: tailwind-build config
	bash ./node_modules/genericsuite-fe-scripts/scripts/run_app_frontend.sh dev

run_qa: tailwind-build config_qa
	bash ./node_modules/genericsuite-fe-scripts/scripts/run_app_frontend.sh qa

run_prod: tailwind-build build-prod
	# sh run_app_frontend.sh
	npm start

server: run
start: run
local: run

tailwind:
	npx @tailwindcss/cli -i ./src/input.css -o ./public/output.css --watch

tailwind-build:
	npx @tailwindcss/cli -i ./src/input.css -o ./public/output.css

add_submodules:
	bash ./node_modules/genericsuite-fe-scripts/scripts/add_github_submodules.sh

create_ssl_certs:
	bash ./node_modules/genericsuite-fe-scripts/scripts/create_ssl_certs.sh create

copy_ssl_certs:
	bash ./node_modules/genericsuite-fe-scripts/scripts/create_ssl_certs.sh copy

## NPM scripts library

config_lib:
	bash ./node_modules/genericsuite-fe-scripts/scripts/change_env_be_endpoint.sh dev

run_lib: config_lib
	bash ./node_modules/genericsuite-fe-scripts/scripts/run_app_frontend.sh dev

sast-test:
	bash ./node_modules/genericsuite-fe-scripts/scripts/sast_test.sh

pre-publish:
	@echo "No pre-publish necessary for genericsuite-fe-scripts"

publish:
	@echo "Are you sure you want to publish genericsuite-fe-scripts? (Ctrl-C to cancel)"
	@read answer < /dev/tty
	npm publish --access=public
