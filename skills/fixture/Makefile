JTD_CODEGEN ?= ../../target/release/jtd-codegen
SCHEMA_DIR  := schemas
OUT_DIR     := generated
SCHEMAS     := $(wildcard $(SCHEMA_DIR)/*.jtd.json)
VALIDATORS  := $(patsubst $(SCHEMA_DIR)/%.jtd.json,$(OUT_DIR)/%.mjs,$(SCHEMAS))

.PHONY: validators validators-py clean-validators test-validators test-validators-py FORCE

validators: $(VALIDATORS) $(OUT_DIR)/validators.mjs

$(OUT_DIR)/%.mjs: $(SCHEMA_DIR)/%.jtd.json
	@mkdir -p $(OUT_DIR)
	$(JTD_CODEGEN) --target js $< > $@

$(OUT_DIR)/validators.mjs: $(VALIDATORS)
	@mkdir -p $(OUT_DIR)
	@rm -f $@
	@for f in $(VALIDATORS); do \
	  stem=$$(basename "$$f" .mjs); \
	  cap=$$(echo "$$stem" | sed -E 's/(^|-)([a-z])/\U\2/g'); \
	  echo "export { validate as validate$$cap } from \"./$$stem.mjs\";" >> $@; \
	done

validators-py: $(OUT_DIR)/__init__.py

$(OUT_DIR)/__init__.py: FORCE
	@mkdir -p $(OUT_DIR)
	@rm -f $(OUT_DIR)/*.py $(OUT_DIR)/__init__.py
	@for schema in $(SCHEMAS); do \
	  stem=$$(basename "$$schema" .jtd.json); \
	  snake=$$(echo "$$stem" | sed 's/-/_/g'); \
	  $(JTD_CODEGEN) --target python "$$schema" > "$(OUT_DIR)/$$snake.py"; \
	done
	@for schema in $(SCHEMAS); do \
	  stem=$$(basename "$$schema" .jtd.json); \
	  snake=$$(echo "$$stem" | sed 's/-/_/g'); \
	  echo "from .$$snake import validate as validate_$$snake" >> $@; \
	done

FORCE:

clean-validators:
	rm -rf $(OUT_DIR)

test-validators: validators
	node test.mjs

test-validators-py: validators-py
	python3 test_py.py
