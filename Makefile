PACKAGE_NAME = distrodeck
VERSION = 0.8.1

.PHONY: deb fpm man

deb:
	dpkg-buildpackage -us -uc

fpm:
	fpm -s dir -t deb -n $(PACKAGE_NAME) -v $(VERSION) \
		--prefix=/usr/bin distrodeck distrodeck.py

man:
	./tools/gen-man.sh
