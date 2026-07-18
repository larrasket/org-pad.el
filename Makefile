EMACS ?= emacs
EL    := org-pad.el

.PHONY: test compile lint zip fake-ipad clean swift app verify-web

test:
	$(EMACS) -Q --batch -L . -l tests/org-pad-test.el \
		-f ert-run-tests-batch-and-exit

compile:
	$(EMACS) -Q --batch -L . \
		--eval '(setq byte-compile-error-on-warn t)' \
		--eval '(setq byte-compile-docstring-max-column 100)' \
		-f batch-byte-compile $(EL)

zip:
	rm -f OrgPad.swiftpm.zip
	zip -r -X OrgPad.swiftpm.zip OrgPad.swiftpm -x '*/.build/*'

swift:
	swift tests/verify_models.swift
	swift tests/verify_export.swift
	@tmp=$$(mktemp -d); cp OrgPad.swiftpm/Sources/SmartInk.swift $$tmp/SmartInk.swift; \
	 cp tests/verify_smartink.swift $$tmp/main.swift; \
	 ( cd $$tmp && swiftc SmartInk.swift main.swift -o sv && ./sv ); rm -rf $$tmp

typecheck:
	xcrun -sdk iphoneos swiftc -typecheck -target arm64-apple-ios16.0 \
		OrgPad.swiftpm/Sources/*.swift

web:
	cd web && node verify.mjs && node verify_receiver.mjs && node smoke.mjs && node smoke_receiver.mjs

fake-ipad:
	./fake-ipad.sh $(ARGS)

clean:
	rm -f *.elc tests/*.elc
