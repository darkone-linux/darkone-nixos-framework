# Darkone framework documentation
# darkone@darkone.yt

_default:
	@just --list

# Lauch the dev environment
dev:
	@echo Launching dev environment...
	npm run dev

# Build + deploy
update: codegen build deploy

# Build the documentation
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

# Just pull built site from remote
pull:
	cd darkone-linux.github.io && git pull --rebase

# Deploy: pull + add + commit + push + GA deploy
deploy:
	#!/usr/bin/env bash
	LAST_MESG=`git log -1 --pretty=%B | head -n 1`
	cd darkone-linux.github.io && \
	    git pull --rebase --autostash && \
	    git add . && \
	    git commit -m "$LAST_MESG" && \
	    git push -u origin main

# Amend the current commit of built doc
amend:
	#!/usr/bin/env bash
	cd darkone-linux.github.io && \
	    git add . && \
	    git commit --amend --no-edit && \
	    git push --force -u origin main

# Git status of built doc
status:
	#!/usr/bin/env bash
	cd darkone-linux.github.io && git status

# Built doc git diff
diff:
	#!/usr/bin/env bash
	cd darkone-linux.github.io && git diff

# Upgrade astro & starlight + dependencies
upgrade:
	@echo Full upgrade of doc dependencies...
	npx @astrojs/upgrade
	npm update
	npm upgrade

# Generate documentation from code
codegen:
	@echo Full upgrade of doc dependencies...
	php ../src/generate.php doc
	@echo Done.

