# Darkone framework documentation
# darkone@darkone.yt

_default:
	@just --list

dev:
	@echo Launching dev environment...
	npm run dev

build:
	#!/usr/bin/env bash
	echo Building and deploying...
	rm -rf dist
	if [ ! -d darkone-linux.github.io ] ;then
		git clone git@github.com:darkone-linux/darkone-linux.github.io.git
	fi
	if [ ! -f darkone-linux.github.io/.nojekyll ] ;then
		touch darkone-linux.github.io/.nojekyll
	fi
	npm run build
	rsync -rv --delete --exclude README.md --exclude .nojekyll --exclude .git dist/ darkone-linux.github.io/

deploy:
	#!/usr/bin/env bash
	LAST_MESG=`git log -1 --pretty=%B | head -n 1`
	cd darkone-linux.github.io && \
	    git pull && \
	    git add . && \
	    git commit -m "$LAST_MESG" && \
	    git push -u origin main

upgrade:
	@echo Full upgrade of doc dependencies...
	npx @astrojs/upgrade
	npm update
	npm upgrade

