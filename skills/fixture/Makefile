JTD_CODEGEN ?= ../../target/release/jtd-codegen
SCHEMA_DIR  := schemas
OUT_DIR     := generated
SCHEMAS     := $(wildcard $(SCHEMA_DIR)/*.jtd.json)
VALIDATORS  := $(patsubst $(SCHEMA_DIR)/%.jtd.json,$(OUT_DIR)/%.mjs,$(SCHEMAS))
OUT_DIR_LUA := $(OUT_DIR)/lua
LUA_SKILL   := ../lua
LUAJIT      ?= luajit

.PHONY: validators validators-py validators-lua clean-validators \
        test-validators test-validators-py test-validators-lua check-lua-types FORCE

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

# Lua: one validator module plus a Teal declaration per schema, no luarocks deps.
validators-lua: FORCE
	@mkdir -p $(OUT_DIR_LUA)
	@$(LUAJIT) $(LUA_SKILL)/codegen_validators.lua --out $(OUT_DIR_LUA) \
	  --binary $(JTD_CODEGEN) --barrel validators $(SCHEMAS)

FORCE:

clean-validators:
	rm -rf $(OUT_DIR)

test-validators: validators
	node test.mjs

test-validators-py: validators-py
	python3 test_py.py

test-validators-lua: validators-lua
	$(LUAJIT) $(LUA_SKILL)/test_validators.lua $(OUT_DIR_LUA)

# Opt-in: type-check the generated Teal declarations when tl is installed.
check-lua-types: validators-lua
	@command -v tl >/dev/null 2>&1 \
	  || { echo "SKIP check-lua-types: tl (Teal) not on PATH; install with: luarocks --lua-version=5.1 install tl"; exit 0; }
	@for file in $(OUT_DIR_LUA)/*.d.tl; do \
	  if ! tl check "$$file" >/dev/null 2>&1; then echo "tl check FAILED: $$file"; tl check "$$file"; exit 1; fi; \
	done
	@echo "tl check: every generated declaration type-checks"
